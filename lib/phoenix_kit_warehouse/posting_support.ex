defmodule PhoenixKitWarehouse.PostingSupport do
  @moduledoc false
  # Shared pieces of the `create_and_post/2` functions on `GoodsIssues`,
  # `GoodsReceipts` and `Inventories`: line validation that needs no database,
  # attribute normalisation, and the `external_ref` idempotency lookup.
  #
  # Everything here runs BEFORE the document row is inserted wherever it can.
  # Document numbers come from a sequence, and a sequence is not rolled back
  # with the transaction that drew from it — so the only way a failed
  # create-and-post burns no number is to fail before the INSERT.

  import Ecto.Query

  alias PhoenixKitWarehouse.StockLedger

  @attr_keys ~w(location_uuid lines note reason external_ref track_value created_by_uuid)a

  @doc """
  Picks the known attributes out of an atom- or string-keyed map, atom-keys
  them, drops `nil` values (so schema defaults apply), and normalises
  `lines`.
  """
  @spec normalize_attrs(map()) :: map()
  def normalize_attrs(attrs) when is_map(attrs) do
    @attr_keys
    |> Map.new(&{&1, fetch(attrs, &1)})
    |> Map.update!(:location_uuid, &(&1 || StockLedger.default_location_uuid()))
    |> Map.update!(:lines, &normalize_lines/1)
    |> Map.update!(:external_ref, &blank_to_nil/1)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp fetch(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(key))
    end
  end

  defp normalize_lines(lines) when is_list(lines) do
    Enum.map(lines, fn
      line when is_map(line) -> Map.new(line, fn {key, value} -> {to_string(key), value} end)
      other -> other
    end)
  end

  defp normalize_lines(_other), do: []

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  @doc """
  Validates the lines of a create-and-post call without touching the
  database. `quantity_key` is the line field holding the quantity
  (`"issued_quantity"`, `"received_quantity"`, `"counted_quantity"`).

  Returns `{:ok, lines}` with every `item_uuid` canonicalised, or
  `{:error, :no_lines | :invalid_lines | {:duplicate_lines, item_uuids} |
  {:invalid_quantity, item_uuids}}`.
  """
  @spec validate_lines([map()], String.t()) :: {:ok, [map()]} | {:error, term()}
  def validate_lines([], _quantity_key), do: {:error, :no_lines}

  def validate_lines(lines, quantity_key) when is_list(lines) do
    with {:ok, lines} <- canonical_item_uuids(lines),
         :ok <- no_duplicates(lines) do
      no_negative_quantities(lines, quantity_key)
    end
  end

  defp canonical_item_uuids(lines) do
    lines
    |> Enum.reduce_while({:ok, []}, fn
      %{"item_uuid" => item_uuid} = line, {:ok, acc} when is_binary(item_uuid) ->
        case Ecto.UUID.cast(item_uuid) do
          {:ok, canonical} -> {:cont, {:ok, [Map.put(line, "item_uuid", canonical) | acc]}}
          :error -> {:halt, {:error, :invalid_lines}}
        end

      _line, _acc ->
        {:halt, {:error, :invalid_lines}}
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp no_duplicates(lines) do
    duplicated =
      lines
      |> Enum.frequencies_by(& &1["item_uuid"])
      |> Enum.filter(fn {_item_uuid, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    case duplicated do
      [] -> :ok
      _ -> {:error, {:duplicate_lines, Enum.filter(first_seen_order(lines), &(&1 in duplicated))}}
    end
  end

  defp first_seen_order(lines), do: lines |> Enum.map(& &1["item_uuid"]) |> Enum.uniq()

  defp no_negative_quantities(lines, quantity_key) do
    negative =
      for line <- lines,
          Decimal.lt?(StockLedger.to_decimal(line[quantity_key]), 0),
          do: line["item_uuid"]

    case negative do
      [] -> {:ok, lines}
      item_uuids -> {:error, {:invalid_quantity, item_uuids}}
    end
  end

  @doc """
  Serialises concurrent create-and-post calls that carry the same
  `external_ref` (transaction-scoped advisory lock) and returns the posted,
  non-deleted document of `schema` already holding that reference, if any.

  Must run inside the transaction. A `nil` ref is never deduplicated.
  """
  @spec find_posted_by_external_ref(Ecto.Repo.t(), module(), String.t() | nil) ::
          {:ok, struct() | nil}
  def find_posted_by_external_ref(_repo, _schema, nil), do: {:ok, nil}

  def find_posted_by_external_ref(repo, schema, external_ref) do
    lock_key = "pkw:#{schema.__schema__(:source)}:#{external_ref}"
    repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [lock_key])

    existing =
      repo.one(
        from(d in schema,
          where:
            d.external_ref == ^external_ref and d.status == "posted" and is_nil(d.deleted_at),
          limit: 1
        )
      )

    {:ok, existing}
  end
end
