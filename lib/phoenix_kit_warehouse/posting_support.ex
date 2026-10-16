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

  alias PhoenixKit.Utils.Number
  alias PhoenixKitWarehouse.StockLedger

  @attr_keys ~w(location_uuid lines note reason external_ref track_value created_by_uuid source_refs)a

  @doc """
  Picks the known attributes out of an atom- or string-keyed map, atom-keys
  them, drops `nil` values (so schema defaults apply), and normalises
  `lines`.
  """
  @spec normalize_attrs(map()) :: map()
  def normalize_attrs(attrs) when is_map(attrs) do
    @attr_keys
    |> Map.new(&{&1, fetch(attrs, &1)})
    |> Map.update!(:location_uuid, &(blank_to_nil(&1) || StockLedger.default_location_uuid()))
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
  Trims an `external_ref` change. A blank value becomes `nil`, so clearing the
  reference of a draft that already has one (a `nil` change) is allowed.
  """
  @spec trim_ref(String.t() | nil) :: String.t() | nil
  def trim_ref(value), do: blank_to_nil(value)

  @doc """
  The skeleton shared by the three `create_and_post/2` functions: normalise
  the attributes, validate the lines, build and validate the draft changeset,
  then insert and post in ONE transaction, answering a repeated
  `external_ref` with the existing document.

  Options:

  - `:schema` - the document schema (looked up for the `external_ref` check);
  - `:quantity_key` - the line field holding the quantity;
  - `:changeset` - `fn attrs, created_by_uuid -> changeset end`, the draft
    changeset for the normalised attributes;
  - `:guard` - optional `fn repo, changeset -> {:ok, term} | {:error, reason} end`
    run in the transaction before the INSERT (a failure there still burns no
    document number);
  - `:post` - `fn repo, draft -> {:ok, posted} | {:error, reason} end`.

  Returns `{:ok, posted}`, `{:ok, :already_posted, existing}` or
  `{:error, reason}`.
  """
  @spec create_and_post(map(), term(), keyword()) ::
          {:ok, struct()} | {:ok, :already_posted, struct()} | {:error, term()}
  def create_and_post(attrs, performed_by_uuid, opts) do
    attrs = normalize_attrs(attrs)
    created_by_uuid = Map.get(attrs, :created_by_uuid) || performed_by_uuid

    with {:ok, lines} <- validate_lines(attrs.lines, Keyword.fetch!(opts, :quantity_key)),
         {:ok, changeset} <- draft(opts, %{attrs | lines: lines}, created_by_uuid) do
      changeset
      |> create_and_post_multi(opts)
      |> PhoenixKit.RepoHelper.repo().transaction()
      |> case do
        {:ok, %{post: posted}} -> {:ok, posted}
        {:error, :existing, {:already_posted, existing}, _} -> {:ok, :already_posted, existing}
        {:error, _op, reason, _changes} -> {:error, reason}
      end
    end
  end

  defp draft(opts, attrs, created_by_uuid) do
    changeset = Keyword.fetch!(opts, :changeset).(attrs, created_by_uuid)
    if changeset.valid?, do: {:ok, changeset}, else: {:error, changeset}
  end

  defp create_and_post_multi(changeset, opts) do
    schema = Keyword.fetch!(opts, :schema)
    external_ref = Ecto.Changeset.get_field(changeset, :external_ref)
    guard = Keyword.get(opts, :guard, fn _repo, _changeset -> {:ok, nil} end)

    Ecto.Multi.run(Ecto.Multi.new(), :existing, fn repo, _changes ->
      case find_posted_by_external_ref(repo, schema, external_ref) do
        {:ok, nil} -> {:ok, nil}
        {:ok, existing} -> {:error, {:already_posted, existing}}
      end
    end)
    |> Ecto.Multi.run(:guard, fn repo, _changes -> guard.(repo, changeset) end)
    |> Ecto.Multi.insert(:draft, changeset)
    |> Ecto.Multi.run(:post, fn repo, %{draft: draft} ->
      Keyword.fetch!(opts, :post).(repo, draft)
    end)
  end

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
      valid_quantities(lines, quantity_key)
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

  # A quantity must be present, parse as a number and not be negative.
  # `StockLedger.to_decimal/1` would read a missing, blank or unparseable
  # value as 0 (an inventory line would then zero the stock), so it is not
  # used to decide validity.
  defp valid_quantities(lines, quantity_key) do
    invalid =
      for line <- lines, not valid_quantity?(Map.get(line, quantity_key)), do: line["item_uuid"]

    case invalid do
      [] -> {:ok, lines}
      item_uuids -> {:error, {:invalid_quantity, item_uuids}}
    end
  end

  defp valid_quantity?(%Decimal{} = quantity) do
    not Decimal.nan?(quantity) and not Decimal.inf?(quantity) and
      Decimal.compare(quantity, 0) != :lt
  end

  defp valid_quantity?(quantity) when is_integer(quantity), do: quantity >= 0
  defp valid_quantity?(quantity) when is_float(quantity), do: quantity >= 0

  defp valid_quantity?(quantity) when is_binary(quantity) do
    case Number.parse_decimal(quantity) do
      {:ok, decimal} -> valid_quantity?(decimal)
      {:error, _reason} -> false
    end
  end

  defp valid_quantity?(_other), do: false

  @doc """
  Serialises concurrent create-and-post calls that carry the same
  `external_ref` (transaction-scoped advisory lock) and returns the posted,
  non-deleted document of `schema` already holding that reference, if any.

  Must run inside the transaction: the lock is released with it. Outside one
  it would last a single statement and wait for any posting in flight with the
  same reference; use `posted_by_external_ref/3` for a read that must not wait.
  A `nil` ref is never deduplicated.
  """
  @spec find_posted_by_external_ref(Ecto.Repo.t(), module(), String.t() | nil) ::
          {:ok, struct() | nil}
  def find_posted_by_external_ref(_repo, _schema, nil), do: {:ok, nil}

  def find_posted_by_external_ref(repo, schema, external_ref) do
    lock_key = "pkw:#{schema.__schema__(:source)}:#{external_ref}"
    repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [lock_key])

    {:ok, posted_by_external_ref(repo, schema, external_ref)}
  end

  @doc """
  The posted, non-deleted document of `schema` holding `external_ref`, or
  `nil`, read without the advisory lock: it never waits for a posting in
  flight (whose document is not visible yet), so a miss is not proof that
  none is running. Safe outside a transaction; the transaction that posts
  re-checks with `find_posted_by_external_ref/3`.
  """
  @spec posted_by_external_ref(Ecto.Repo.t(), module(), String.t() | nil) :: struct() | nil
  def posted_by_external_ref(_repo, _schema, nil), do: nil

  def posted_by_external_ref(repo, schema, external_ref) do
    repo.one(
      from(d in schema,
        where: d.external_ref == ^external_ref and d.status == "posted" and is_nil(d.deleted_at),
        limit: 1
      )
    )
  end
end
