# phoenix_kit_warehouse

Warehouse module for [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit): stock balances, stocktakes (inventory counts), internal orders, supplier orders, goods receipt, and goods issue — a full warehouse-documents workflow with posting, correction, soft-delete, activity logging, per-document file storage, and optional comments.

## Requirements

- `phoenix_kit` core containing the **V140** versioned migration (the `phoenix_kit_warehouse_*` tables ship through core, like every other PhoenixKit module). Until a release containing V140 is published to Hex, point at a local checkout: `PHOENIX_KIT_PATH=../phoenix_kit mix test`.
- Required modules (enabled in Admin → Modules): **Catalogue** (`phoenix_kit_catalogue` — warehouse tracks catalogue items) and **Locations** (`phoenix_kit_locations` — every document carries a `location_uuid`).
- Optional: **Comments** (`phoenix_kit_comments`) — per-document comment threads appear automatically when installed and enabled; the module degrades gracefully without it. `phoenix_kit_billing` is used as a library dependency for currency display components.

## Installation

Add to your app's `mix.exs`:

```elixir
{:phoenix_kit_warehouse, "~> 0.1"}
```

Then `mix deps.get`, run `mix phoenix_kit.update` (applies core migrations up to V140), and enable **Warehouse** in Admin → Modules. Routes are auto-discovered via `phoenix_kit_routes()`; the admin UI appears under `/admin/warehouse` with sub-pages for stocktakes, internal orders, supplier orders, goods receipts, and goods issues. Module settings (warehouse location type, default location) live at `/admin/settings/warehouse`.

The module ships its own CSS sources (`css_sources/0`) and requires `:phoenix_kit` in `extra_applications` — both handled automatically by the standard PhoenixKit module wiring.

## Linking documents to host records (`source_kinds`)

Internal Orders and Goods Issues can reference arbitrary host-owned records (e.g. an order or sub-order in your app) through a generic `source_refs` JSONB list. The module never queries host tables — instead the host registers, per kind, three callbacks:

```elixir
config :phoenix_kit_warehouse,
  source_kinds: [
    %{
      kind: "sub_order",
      label: "Sub-order",
      search: {MyApp.Warehouse.Integration, :search_sub_orders, []},
      resolve: {MyApp.Warehouse.Integration, :resolve_sub_order, []},
      build_lines: {MyApp.Warehouse.Integration, :build_sub_order_lines, []}
    }
  ]
```

- `search.(query)` → `[%{uuid:, label:, extra:}]` — candidates for the generic source picker.
- `resolve.(uuid)` → `%{label:, path:}` or `:error` — renders a source ref as a link.
- `build_lines.(uuid, actor_uuid)` → `{:ok, lines}` or `:error` — builds document lines when importing from a picked source (optional per kind).

With **zero** `source_kinds` configured the module works standalone: pickers are empty and unresolvable refs render as plain UUIDs. See `PhoenixKitWarehouse.SourceKinds` for the full contract.

## Configuration

```elixir
# Optional: strip a prefix from displayed catalogue names in warehouse pickers
config :phoenix_kit_warehouse, catalogue_prefix: "MYPREFIX"
```

## Development

```bash
mix deps.get
createdb phoenix_kit_warehouse_test
PHOENIX_KIT_PATH=../phoenix_kit mix test   # DB-backed tests need a core checkout with V140
mix quality                                # format + credo + dialyzer
```

## License

MIT — see [LICENSE](LICENSE).
