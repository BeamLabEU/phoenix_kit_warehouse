defmodule PhoenixKitWarehouse.CostProposals do
  @moduledoc """
  Stateless derivation of purchase price proposals for posted goods receipts.

  A proposal is generated when a receipt line's `unit_value` (the price paid)
  differs from the current catalogued unit cost for the same item/supplier pair.

  ## No proposal without a junction row

  When the catalogue has no `item_supplier_info` junction row for an
  item/supplier pair, **no proposal is generated**. Linking a supplier to an
  item is a deliberate catalogue action, not a side-effect of receiving goods.
  This boundary is intentional: the warehouse must not implicitly create or
  imply catalogue relationships.

  ## Degradation without catalogue exports

  `catalogue_resolver/0` returns a resolver function that guards its call
  with `Code.ensure_loaded?` + `function_exported?`. When the catalogued
  `Catalogue.Suppliers.active_info_for/2` is absent (older release), the
  resolver returns `nil` for all pairs and `derive/3` yields no proposals.
  No crash, no error — the feature silently degrades to a no-op.
  """

  @doc """
  Derives price proposals from receipt lines.

  Arguments:

  - `lines` — list of receipt line maps (JSON keys: `"item_uuid"`, `"unit_value"`,
    `"name"`, `"sku"`).
  - `supplier_uuid` — the receipt's supplier UUID; `nil` yields no proposals.
  - `resolver` — a 2-arity function `(item_uuid, supplier_uuid) → info | nil`.
    Called once per eligible line. Return `nil` to skip a pair (no junction row).

  A line is eligible when both `item_uuid` and a numeric `unit_value` are
  present. `unit_value` may be a `Decimal`, string, integer, or float.

  A proposal is generated when the resolver returns a non-nil info struct
  **and** `Decimal.compare(unit_value, info.unit_cost || 0) != :eq`.

  Returns a list of proposal maps with keys:
  - `:item_uuid`
  - `:name`
  - `:sku`
  - `:info` — the junction row (pass back to `Catalogue.Suppliers.revise_unit_cost/3`)
  - `:current_cost` — `info.unit_cost` (may be `nil` when not yet set)
  - `:receipt_price` — the `unit_value` from the line as a `Decimal`
  """
  @spec derive(
          lines :: list(map()),
          supplier_uuid :: Ecto.UUID.t() | nil,
          resolver :: (Ecto.UUID.t(), Ecto.UUID.t() -> any() | nil)
        ) :: list(map())
  def derive(_lines, nil, _resolver), do: []

  def derive(lines, supplier_uuid, resolver)
      when is_binary(supplier_uuid) and is_function(resolver, 2) do
    Enum.flat_map(lines, fn line ->
      item_uuid = line["item_uuid"]
      unit_value = parse_decimal(line["unit_value"])

      if item_uuid && unit_value do
        info = resolver.(item_uuid, supplier_uuid)

        if info && diverges?(unit_value, info.unit_cost) do
          [
            %{
              item_uuid: item_uuid,
              name: line["name"],
              sku: line["sku"],
              info: info,
              current_cost: info.unit_cost,
              receipt_price: unit_value
            }
          ]
        else
          []
        end
      else
        []
      end
    end)
  end

  @doc """
  Returns a resolver function backed by `PhoenixKitCatalogue.Catalogue.Suppliers.active_info_for/2`.

  The resolver is guarded: when the catalogue module is not loaded or
  `active_info_for/2` is not exported, it returns `nil` for every call so
  the warehouse degrades gracefully on older catalogue releases.
  """
  @spec catalogue_resolver() :: (Ecto.UUID.t(), Ecto.UUID.t() -> any() | nil)
  def catalogue_resolver do
    fn item_uuid, supplier_uuid ->
      if Code.ensure_loaded?(PhoenixKitCatalogue.Catalogue.Suppliers) and
           function_exported?(PhoenixKitCatalogue.Catalogue.Suppliers, :active_info_for, 2) do
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(PhoenixKitCatalogue.Catalogue.Suppliers, :active_info_for, [
          item_uuid,
          supplier_uuid
        ])
      else
        nil
      end
    end
  end

  @doc """
  Applies `Catalogue.Suppliers.revise_unit_cost/3` for a proposal, guarded.

  **Currency caveat (documented deferral):** goods receipts carry no currency
  field, so receipt prices are assumed to be in the junction row's own
  `currency` (single-currency deployments). The proposals card displays the
  row currency next to both prices so the keeper sees what they are applying;
  a currency-aware comparison requires a receipt-level currency first.

  Returns `{:error, :catalogue_unavailable}` when the catalogue exports are
  absent (same degradation path as `catalogue_resolver/0`).
  """
  @spec apply_revision(map(), keyword()) ::
          {:ok, any()} | {:error, :catalogue_unavailable | :not_current | any()}
  def apply_revision(%{info: info, receipt_price: price}, opts) do
    if Code.ensure_loaded?(PhoenixKitCatalogue.Catalogue.Suppliers) and
         function_exported?(PhoenixKitCatalogue.Catalogue.Suppliers, :revise_unit_cost, 3) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(PhoenixKitCatalogue.Catalogue.Suppliers, :revise_unit_cost, [
        info,
        at_storage_scale(price),
        opts
      ])
    else
      {:error, :catalogue_unavailable}
    end
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  # unit_cost is stored as NUMERIC(14,4) (core V149) — both the divergence
  # comparison and the applied price are rounded to that scale, otherwise a
  # >4-dp receipt price (e.g. line total ÷ quantity) is rounded on store and
  # the proposal reappears forever after apply.
  @cost_scale 4

  @doc false
  def at_storage_scale(%Decimal{} = d), do: Decimal.round(d, @cost_scale)

  # A receipt price diverges from the catalogue cost when they are unequal
  # at the storage scale. When the catalogue cost is nil (price not yet
  # catalogued), any non-zero receipt price is treated as a divergence.
  defp diverges?(receipt_price, nil) do
    Decimal.compare(at_storage_scale(receipt_price), Decimal.new("0")) != :eq
  end

  defp diverges?(receipt_price, current_cost) do
    Decimal.compare(at_storage_scale(receipt_price), at_storage_scale(current_cost)) != :eq
  end

  defp parse_decimal(nil), do: nil
  defp parse_decimal(%Decimal{} = d), do: d

  defp parse_decimal(v) when is_binary(v) do
    # Tolerate comma decimal separators (ru/et locale input in line maps).
    case v |> String.trim() |> String.replace(",", ".") |> Decimal.parse() do
      {d, ""} -> d
      _ -> nil
    end
  end

  defp parse_decimal(v) when is_integer(v), do: Decimal.new(v)
  defp parse_decimal(v) when is_float(v), do: Decimal.from_float(v)
  defp parse_decimal(_), do: nil
end
