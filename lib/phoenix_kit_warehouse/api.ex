defmodule PhoenixKitWarehouse.API do
  @moduledoc """
  The admin API tools of the warehouse module.

  `PhoenixKitWarehouse.api_tools/0` returns `tools/1` to core, which collects
  the tools of every **enabled** module (`PhoenixKit.ModuleRegistry.all_api_tools/0`),
  checks the caller's rights, validates the input against the schema, and calls
  the handler as `handler.(input, ctx)`.

  | Tool | Scope | Does |
  |---|---|---|
  | `warehouse.list_locations` | `warehouse.stock:read` | the warehouse locations, the default one, how far setup has got |
  | `warehouse.get_stock` | `warehouse.stock:read` | per product: quantity and unit value per location, and the total |
  | `warehouse.receive_stock` | `warehouse.stock:receive` | one goods receipt with many lines |
  | `warehouse.set_stock` | `warehouse.stock:adjust` | one stocktake that sets the listed products to counted quantities |
  | `warehouse.issue_stock` | `warehouse.stock:issue` | one goods issue (write-off) with many lines |

  All four scopes need the role permission `warehouse`. Stock changes only
  through posted documents: each write tool creates and posts one document in
  one transaction.

  The tools follow the Warehouse module's own enabled state, not the shop's
  "Stock tracking" switch.
  """

  alias PhoenixKit.API.Tool
  alias PhoenixKitWarehouse.API.Schemas

  @compile {:no_warn_undefined, [PhoenixKit.API.Tool, PhoenixKit.API.Keys, PhoenixKit.API.Flow]}

  # Core holds a dangerous call for confirmation only when it has both the
  # confirmation codes and the enforcement; the catalogue's and the shop's
  # tools judge the same two markers.
  @markers [{PhoenixKit.API.Keys, :active?, 1}, {PhoenixKit.API.Flow, :gate, 1}]

  @permission "warehouse"
  @max_lines Schemas.max_lines()
  @max_refs Schemas.max_refs()

  @held_for_confirmation "A call with more lines than the confirmation threshold (core's " <>
                           "api_confirm_batch_over setting) is held for confirmation: the first " <>
                           "call answers a preview and a confirm_token, the same call with the " <>
                           "token posts it."

  @retry_conflict_tail "or has a line that a first call would refuse, the call is refused as " <>
                         "validation_failed with posted false and the posted document in the " <>
                         "context. When a product is gone since (trashed), its ref must match a " <>
                         "stored identity; quantities, unit values and duplicates are still checked. " <>
                         "A matching retry is skipped with an external_ref_lines_unverified effect, " <>
                         "which you must check."

  @retry_conflict_receipt "If the reference belongs to a posted document and this request differs " <>
                            "from it (other lines or unit values, or another warehouse or " <>
                            "catalogue that you state) " <> @retry_conflict_tail

  @retry_conflict_stocktake "If the reference belongs to a posted document and this request " <>
                              "differs from it (other lines, or another warehouse or catalogue " <>
                              "that you state) " <> @retry_conflict_tail

  @retry_conflict_issue "If the reference belongs to a posted document and this request differs " <>
                          "from it (other lines, or another warehouse, catalogue, reason or order " <>
                          "that you state) " <> @retry_conflict_tail

  @doc """
  The tools for `PhoenixKitWarehouse.api_tools/0`: `[]` on a core without the
  tool registry, the two read tools on a core that cannot hold a dangerous call
  for confirmation, all five otherwise. `markers` are the
  `{module, function, arity}` triples that must exist for the write tools to be
  offered; none at all means they are not. A core without the confirmation flow
  would run a 500-line stocktake on the first call.
  """
  @spec tools([{module(), atom(), arity()}]) :: [struct()]
  def tools(markers \\ @markers) do
    cond do
      not Code.ensure_loaded?(Tool) -> []
      confirmation_available?(markers) -> all_tools()
      true -> Enum.filter(all_tools(), & &1.annotations.read_only)
    end
  end

  # Whether core enforces the confirmation gate the write tools depend on:
  # every `{module, function, arity}` of `markers` is loaded and exported. No
  # markers to judge by is "no": the write tools are offered only on positive
  # evidence.
  @doc false
  @spec confirmation_available?([{module(), atom(), arity()}]) :: boolean()
  def confirmation_available?(markers \\ @markers)
  def confirmation_available?([]), do: false

  def confirmation_available?(markers) do
    Enum.all?(markers, fn {module, function, arity} ->
      Code.ensure_loaded?(module) and function_exported?(module, function, arity)
    end)
  end

  defp all_tools do
    [
      Tool.new!(
        name: "warehouse.list_locations",
        audience: :admin,
        scope: "warehouse.stock:read",
        permission: @permission,
        title: "List warehouse locations",
        description:
          "Lists the warehouse locations that stock can be kept at, marks the default one, and says how " <>
            "far the Warehouse setup has got (setup: ready, needs_location_type, needs_locations or " <>
            "needs_default_location). Use the ids as location_id in the other warehouse tools.",
        input_schema: Schemas.list_locations_input(),
        output_schema: Schemas.list_locations_output(),
        handler: {PhoenixKitWarehouse.API.Stock, :list_locations},
        annotations: annotations(read_only: true, idempotent: true)
      ),
      Tool.new!(
        name: "warehouse.get_stock",
        audience: :admin,
        scope: "warehouse.stock:read",
        permission: @permission,
        title: "Get stock",
        description:
          "Reads the stock of up to #{@max_refs} products: the quantity and unit value at each location " <>
            "that holds the product (or at one location_id), and the total. A product that cannot be " <>
            "found is reported in its own row; the other rows are still answered. Quantities are " <>
            "decimal strings, in the product's own unit (the unit field). unit_value has no currency: the " <>
            "warehouse keeps none.",
        input_schema: Schemas.get_stock_input(),
        output_schema: Schemas.get_stock_output(),
        handler: {PhoenixKitWarehouse.API.Stock, :get_stock},
        annotations: annotations(read_only: true, idempotent: true),
        max_items: @max_refs
      ),
      Tool.new!(
        name: "warehouse.receive_stock",
        audience: :admin,
        scope: "warehouse.stock:receive",
        permission: @permission,
        title: "Receive stock",
        description:
          "Posts one goods receipt with many lines: adds each line's quantity to the stock at the " <>
            "location (the default warehouse when location_id is omitted) and answers the document " <>
            "number and, per line, the stock before (from) and after (to). Atomic: if any line is " <>
            "wrong nothing is posted and every problem is reported. Send external_ref (your own " <>
            "document number) so that a retry is harmless: a repeated reference answers status " <>
            "\"skipped\" with the existing document. " <>
            @retry_conflict_receipt <> " " <> @held_for_confirmation,
        input_schema: Schemas.receive_stock_input(),
        output_schema: Schemas.write_output(),
        handler: {PhoenixKitWarehouse.API.Write, :receive_stock},
        annotations: annotations([]),
        max_items: @max_lines
      ),
      Tool.new!(
        name: "warehouse.set_stock",
        audience: :admin,
        scope: "warehouse.stock:adjust",
        permission: @permission,
        title: "Set stock (stocktake)",
        description:
          "Posts one stocktake document that sets each listed product to its counted quantity " <>
            "(absolute, not a delta; 0 is allowed). Other products are untouched. Answers the " <>
            "document number and, per line, the exact previous quantity (from) and the new one (to). " <>
            "Atomic. Send external_ref so that a retry is harmless: a repeated reference answers " <>
            "status \"skipped\" and does not reset stock that has moved since. " <>
            @retry_conflict_stocktake <> " " <> @held_for_confirmation,
        input_schema: Schemas.set_stock_input(),
        output_schema: Schemas.write_output(),
        handler: {PhoenixKitWarehouse.API.Write, :set_stock},
        annotations: annotations(destructive: true),
        max_items: @max_lines
      ),
      Tool.new!(
        name: "warehouse.issue_stock",
        audience: :admin,
        scope: "warehouse.stock:issue",
        permission: @permission,
        title: "Issue stock (write-off)",
        description:
          "Posts one goods issue with many lines: subtracts each line's quantity from the stock. " <>
            "reason is required (sale, damage, production, other). All lines are checked against stock " <>
            "first; if any is short the call answers insufficient_stock listing every short line and " <>
            "posts nothing. Send external_ref (your own document number) so that a retry is harmless: " <>
            "a repeated reference answers status \"skipped\" and writes nothing off a second time. " <>
            @retry_conflict_issue <>
            " " <>
            ~S|The basis is source: {"kind": "external", "ref": ...} (stored as the | <>
            ~S|document's external reference, so external_ref is not given beside it) or {"kind": "shop_order", | <>
            "\"id\": ...} (links the write-off to a shop order; needs the E-commerce module; " <>
            "external_ref may be sent with it). " <> @held_for_confirmation,
        input_schema: Schemas.issue_stock_input(),
        output_schema: Schemas.write_output(),
        handler: {PhoenixKitWarehouse.API.Write, :issue_stock},
        annotations: annotations(destructive: true),
        max_items: @max_lines
      )
    ]
  end

  # Every key is given explicitly so no tool depends on how the core fills
  # defaults for a partial map.
  defp annotations(opts) do
    Map.merge(
      %{read_only: false, destructive: false, idempotent: false, open_world: false},
      Map.new(opts)
    )
  end
end
