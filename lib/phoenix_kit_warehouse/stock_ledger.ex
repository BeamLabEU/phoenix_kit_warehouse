defmodule PhoenixKitWarehouse.StockLedger do
  @moduledoc """
  Context for managing warehouse stock balances.

  Provides functions to read stock levels and upsert quantities.
  Decimal coercion helpers ensure callers passing jsonb-origin strings
  or floats are handled safely.
  """

  import Ecto.Query

  alias PhoenixKitWarehouse.Stock

  @warehouse_type_setting "warehouse_location_type_uuid"
  @default_location_setting "warehouse_default_location_uuid"

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc "UUID of the LocationType that marks warehouses (admin-configurable setting), or nil."
  def warehouse_location_type_uuid do
    blank_to_nil(PhoenixKit.Settings.get_setting(@warehouse_type_setting))
  end

  @doc "Sets the LocationType UUID that marks warehouses. Pass `nil` to clear."
  def set_warehouse_location_type_uuid(uuid) do
    PhoenixKit.Settings.update_setting_with_module(
      @warehouse_type_setting,
      uuid || "",
      PhoenixKitWarehouse.module_key()
    )
  end

  @doc "UUID of the default warehouse Location stock is held at (setting), or nil."
  def default_location_uuid do
    blank_to_nil(PhoenixKit.Settings.get_setting(@default_location_setting))
  end

  @doc "Sets the default warehouse Location UUID. Pass `nil` to clear."
  def set_default_location_uuid(uuid) do
    PhoenixKit.Settings.update_setting_with_module(
      @default_location_setting,
      uuid || "",
      PhoenixKitWarehouse.module_key()
    )
  end

  defp blank_to_nil(v) when v in [nil, ""], do: nil
  defp blank_to_nil(v), do: v

  @doc "Returns all stock rows."
  def list_stock do
    repo().all(Stock)
  end

  @doc """
  Returns a map of `item_uuid => %{quantity: Decimal, unit_value: Decimal | nil}`
  for fast tree annotation.
  """
  def stock_map do
    Stock
    |> repo().all()
    |> Map.new(fn row ->
      {row.item_uuid, %{quantity: row.quantity, unit_value: row.unit_value}}
    end)
  end

  @doc "Returns stock rows for the given list of item UUIDs."
  def stock_for_items(item_uuids, target_repo \\ nil) do
    Stock
    |> where([s], s.item_uuid in ^item_uuids)
    |> (target_repo || repo()).all()
  end

  @doc """
  Returns the current quantity for the given item UUID as a Decimal.
  Returns `Decimal.new(\"0\")` if no row exists.
  """
  def get_quantity(item_uuid) do
    case repo().get_by(Stock, item_uuid: item_uuid) do
      nil -> Decimal.new("0")
      row -> row.quantity
    end
  end

  @doc """
  Returns the total stock value: Σ (quantity * unit_value), skipping rows
  where unit_value is nil.
  """
  def total_value do
    Stock
    |> where([s], not is_nil(s.unit_value))
    |> select([s], fragment("COALESCE(SUM(? * ?), 0)", s.quantity, s.unit_value))
    |> repo().one()
    |> to_decimal()
  end

  @doc """
  Upserts the stock quantity for `item_uuid`.

  Options:
  - `:unit_value` — when not nil, also sets the unit_value; when nil, leaves existing value intact.
  - `:repo` — override the repo (default from `PhoenixKit.RepoHelper.repo/0`), used by `Ecto.Multi` transactions.

  Returns `{:ok, %Stock{}}`.
  """
  def upsert_quantity(item_uuid, quantity, opts \\ []) do
    target_repo = Keyword.get(opts, :repo, repo())
    raw_unit_value = Keyword.get(opts, :unit_value)
    location_uuid = Keyword.get(opts, :location_uuid) || default_location_uuid()

    quantity_d = to_decimal(quantity)
    unit_value_d = to_decimal_or_nil(raw_unit_value)

    attrs = %{
      item_uuid: item_uuid,
      location_uuid: location_uuid,
      quantity: quantity_d,
      unit_value: unit_value_d
    }

    changeset = Stock.changeset(%Stock{}, attrs)

    on_conflict =
      if is_nil(unit_value_d) do
        {:replace, [:quantity, :updated_at]}
      else
        {:replace, [:quantity, :unit_value, :updated_at]}
      end

    target_repo.insert(changeset,
      conflict_target: [:item_uuid, :location_uuid],
      on_conflict: on_conflict,
      returning: true
    )
  end

  @doc """
  Additively increases the stock quantity for `item_uuid`.

  Unlike `upsert_quantity/3` which does an absolute SET, this function performs
  an additive INSERT … ON CONFLICT DO UPDATE SET quantity = quantity + EXCLUDED.quantity.

  Options:
  - `:unit_value` — when not nil, also sets the unit_value; when nil, leaves existing value intact.
  - `:repo` — override the repo (default from `PhoenixKit.RepoHelper.repo/0`), used by `Ecto.Multi` transactions.
  - `:location_uuid` — warehouse location (default: configured default warehouse).

  Returns `{:ok, %Stock{}}`.
  """
  def receive_quantity(item_uuid, quantity, opts \\ []) do
    target_repo = Keyword.get(opts, :repo, repo())
    raw_unit_value = Keyword.get(opts, :unit_value)
    location_uuid = Keyword.get(opts, :location_uuid) || default_location_uuid()

    quantity_d = to_decimal(quantity)
    unit_value_d = to_decimal_or_nil(raw_unit_value)

    attrs = %{
      item_uuid: item_uuid,
      location_uuid: location_uuid,
      quantity: quantity_d,
      unit_value: unit_value_d
    }

    changeset = Stock.changeset(%Stock{}, attrs)

    # Additive conflict resolution: quantity = existing + incoming
    on_conflict_query =
      if is_nil(unit_value_d) do
        from(s in Stock,
          update: [
            set: [
              quantity: fragment("? + EXCLUDED.quantity", s.quantity),
              updated_at: ^(DateTime.utc_now() |> DateTime.truncate(:second))
            ]
          ]
        )
      else
        from(s in Stock,
          update: [
            set: [
              quantity: fragment("? + EXCLUDED.quantity", s.quantity),
              unit_value: ^unit_value_d,
              updated_at: ^(DateTime.utc_now() |> DateTime.truncate(:second))
            ]
          ]
        )
      end

    target_repo.insert(changeset,
      conflict_target: [:item_uuid, :location_uuid],
      on_conflict: on_conflict_query,
      returning: true
    )
  end

  @doc """
  Conditionally decrements warehouse stock for `item_uuid`.

  Performs an atomic UPDATE with `WHERE quantity >= qty` to guard against
  driving stock negative. Never inserts a row — if no stock row exists for
  the item/location, the WHERE predicate matches 0 rows and the function
  returns `{:error, {:insufficient_stock, item_uuid}}`.

  Options:
  - `:repo` — override the repo (default from `PhoenixKit.RepoHelper.repo/0`), used by `Ecto.Multi` transactions.
  - `:location_uuid` — warehouse location (default: configured default warehouse).

  Returns:
  - `{:ok, new_quantity}` on success (Decimal).
  - `{:error, {:insufficient_stock, item_uuid}}` when stock row is missing
    OR when `quantity < qty` (covers both cases atomically via the WHERE guard).
  """
  def issue_quantity(item_uuid, quantity, opts \\ []) do
    target_repo = Keyword.get(opts, :repo, repo())
    location_uuid = Keyword.get(opts, :location_uuid) || default_location_uuid()

    qty_d = to_decimal(quantity)
    item_uuid_bin = Ecto.UUID.dump!(item_uuid)
    location_uuid_bin = if location_uuid, do: Ecto.UUID.dump!(location_uuid)

    result =
      target_repo.query(
        """
        UPDATE phoenix_kit_warehouse_stock
        SET quantity = quantity - $1, updated_at = NOW()
        WHERE item_uuid = $2 AND location_uuid = $3 AND quantity >= $1
        RETURNING quantity
        """,
        [qty_d, item_uuid_bin, location_uuid_bin]
      )

    case result do
      {:ok, %{rows: [[new_qty]]}} ->
        {:ok, to_decimal(new_qty)}

      {:ok, %{rows: []}} ->
        {:error, {:insufficient_stock, item_uuid}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Coerces a value to Decimal. nil and \"\" become `Decimal.new(\"0\")`.
  """
  def to_decimal(nil), do: Decimal.new("0")
  def to_decimal(""), do: Decimal.new("0")
  def to_decimal(%Decimal{} = v), do: v
  def to_decimal(v) when is_integer(v), do: Decimal.new(v)
  def to_decimal(v) when is_float(v), do: Decimal.from_float(v)

  def to_decimal(v) when is_binary(v) do
    # Normalise the et/ru decimal comma ("1,5") to a dot before parsing —
    # Decimal.parse/1 otherwise stops at the comma and silently truncates.
    case v |> String.replace(",", ".") |> Decimal.parse() do
      {d, _} -> d
      :error -> Decimal.new("0")
    end
  end

  def to_decimal(_), do: Decimal.new("0")

  @doc """
  Coerces a value to Decimal or nil. nil, blank strings, and empty strings
  return nil. All other values convert like `to_decimal/1`.
  """
  def to_decimal_or_nil(nil), do: nil
  def to_decimal_or_nil(""), do: nil

  def to_decimal_or_nil(s) when is_binary(s) do
    # Normalise the et/ru decimal comma ("1,5") to a dot before parsing.
    case s |> String.trim() |> String.replace(",", ".") do
      "" ->
        nil

      trimmed ->
        case Decimal.parse(trimmed) do
          {d, _} -> d
          :error -> nil
        end
    end
  end

  def to_decimal_or_nil(%Decimal{} = d), do: d
  def to_decimal_or_nil(n) when is_integer(n), do: Decimal.new(n)
  def to_decimal_or_nil(n) when is_float(n), do: Decimal.from_float(n)
  def to_decimal_or_nil(_), do: nil
end
