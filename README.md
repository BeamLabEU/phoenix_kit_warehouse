# PhoenixKit Warehouse

Warehouse module for [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit).

A drop-in PhoenixKit module — add it to a host app's deps and it is
auto-discovered, adding a **Warehouse** section to the admin panel. Like every
PhoenixKit module it has no endpoint, router, or Ecto repo of its own; it
borrows the host's via `phoenix_kit`.

> **Status:** scaffold. Project configuration is in place; module code
> (schemas, contexts, admin UI, migrations) is not implemented yet.

## Planned scope

- **Inventory / stock** — warehouses, locations, and on-hand quantities.
- **Goods receipts / issues** — stock movements in and out.
- Integration with the Manufacturing module (goods issues / receipts) and
  other PhoenixKit modules.

## Installation

Add to your host app's `mix.exs`:

```elixir
{:phoenix_kit_warehouse, "~> 0.3"}
```

Then fetch deps, apply the module's tables, and enable it in
**Admin → Modules**:

```bash
mix deps.get
mix phoenix_kit.update
```

### Removing this module

There is deliberately **no automated uninstall**.
`PhoenixKitWarehouse.Migrations.down/1` never drops any of the 8
`phoenix_kit_warehouse_*` tables or a row in them, for any target version —
a host that merely removes this dependency from `mix.exs` has not consented
to deleting live stock balances and document history, and a migration
whose result depended on which packages happen to be compiled in would be
nondeterministic (it would break core's manifest, chain hash, and squash
verification). Removing the data is therefore a deliberate, manual operator
step, in FK-safe order (children before parents):

```sql
-- Only after removing :phoenix_kit_warehouse from mix.exs, and only if you
-- actually want every stock balance and document gone for good.
DROP TABLE phoenix_kit_warehouse_goods_issues;
DROP TABLE phoenix_kit_warehouse_goods_receipts;
DROP TABLE phoenix_kit_warehouse_supplier_orders;
DROP TABLE phoenix_kit_warehouse_internal_orders;
DROP TABLE phoenix_kit_warehouse_inventory_documents;
DROP TABLE phoenix_kit_warehouse_stock;
DROP TABLE phoenix_kit_warehouse_transfers;
DROP TABLE phoenix_kit_warehouse_min_stock;
-- The document-number sequences are not OWNED BY their columns, so
-- dropping the tables leaves them behind.
DROP SEQUENCE phoenix_kit_warehouse_goods_issues_number_seq;
DROP SEQUENCE phoenix_kit_warehouse_goods_receipts_number_seq;
DROP SEQUENCE phoenix_kit_warehouse_supplier_orders_number_seq;
DROP SEQUENCE phoenix_kit_warehouse_internal_orders_number_seq;
DROP SEQUENCE phoenix_kit_warehouse_inventory_documents_number_seq;
DROP SEQUENCE phoenix_kit_warehouse_transfers_number_seq;
```

If you want to keep the tables (e.g. you plan to reinstall the module
later) but stop this chain from tracking them, clear the version marker
instead — it lives only on the anchor table:

```sql
COMMENT ON TABLE phoenix_kit_warehouse_stock IS NULL;
```

## Development

See [`AGENTS.md`](AGENTS.md) for architecture, conventions, testing, and the
release checklist.

## License

MIT — see [LICENSE](LICENSE).
