# PhoenixKit Warehouse

Warehouse module for [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit).

A drop-in PhoenixKit module — add it to a host app's deps and it is
auto-discovered, adding a **Warehouse** section to the admin panel. Like every
PhoenixKit module it has no endpoint, router, or Ecto repo of its own; it
borrows the host's via `phoenix_kit`.

> **Status:** implemented. Stock keeping, the document set and their posting
> rules below are in use; see `CHANGELOG.md` for the release history.

## Scope

### Stock per item and location

- One stock row per **catalogue item** and **location** (a PhoenixKit Locations
  record of the configured *warehouse* location type): `quantity` (never
  negative, enforced by a database check) and an optional `unit_value`.
- A **default warehouse** setting decides where a document lands when none is
  chosen. The admin UI also has a stock list, per-item minimums with a deficit
  view, and a turnover report (inflow and outflow per item over a date range).

### Documents

Documents are created as drafts and take effect when posted (a transfer ships
and then is received). Each has a number drawn from its own sequence, and a
draft can be soft-deleted. Most also have a storage folder for attachments
and a comment thread.

| Document | Effect on stock |
|---|---|
| **Goods receipt** | Adds each line's `received_quantity` (and sets `unit_value` when the line carries one). Can be created from a supplier order. |
| **Goods issue** | Subtracts each line's `issued_quantity`, never below zero; if any line is short the whole posting rolls back and the document stays a draft. Carries a **reason**: `production` (the default), `sale`, `damage` or `other`. Can be created from internal orders. |
| **Inventory document** (stocktake) | Sets the stock of each *listed* item to its `counted_quantity` (absolute, not a delta); other stock rows are untouched. Can be re-posted. |
| **Transfer** | Shipping subtracts from the source warehouse, receiving adds to the destination; cancelling an in-transit transfer credits the source back. |
| **Internal order**, **supplier order** | None. They record demand and procurement and feed the documents above. |

Posting semantics worth knowing:

- Posting is **atomic** and a **compare-and-swap on status**: the document row
  is locked and re-checked as a draft inside the transaction, so a repeated or
  stale post cannot apply stock twice.
- Every posted line records the **previous quantity** it replaced or changed.
  For an inventory document that quantity is read inside the posting
  transaction under a row lock, so the audit trail stays exact when other
  documents post concurrently.
- After posting, a goods receipt or goods issue keeps its lines; only the note
  and the storage folder can still be corrected.

### Programmatic posting

For callers that are not a person at a form (a shop, a POS, an integration),
`GoodsIssues.create_and_post/2`, `GoodsReceipts.create_and_post/2` and
`Inventories.create_and_post/2` create **and post in one transaction**: a
call refused by validation or the stock check leaves no draft and consumes
no document number. A failure after the insert (a database error while
posting) rolls the draft back too, but the number sequence has advanced.

- Each takes the document attributes and the posting user's UUID.
- Duplicate item lines are refused (`{:error, {:duplicate_lines, uuids}}`)
  rather than merged or dropped. A goods issue reports **every** short line at
  once (`{:error, {:insufficient_stock, [%{item_uuid, requested, available}]}}`).
- All three accept an `external_ref`, the document's number in the outside
  system. It is unique per document type among posted, non-deleted documents,
  and a repeat returns `{:ok, :already_posted, existing_document}` without
  writing anything, so a retried delivery is harmless. The lines of the repeat
  are not compared with the existing document's.

### Linking documents to host records

Documents link to host-owned records (orders, sub-orders, ...) through
`source_refs` and the generic `PhoenixKitWarehouse.SourceKinds` registry, so
the package has no dependency on any specific "order" concept. Kinds come from
the host's `config :phoenix_kit_warehouse, :source_kinds` list and from any
registered PhoenixKit module that exports `warehouse_source_kinds/0`; the two
are merged by kind, and the host's definition wins on a conflict.

### Other modules

Requires `phoenix_kit_catalogue` (the items), `phoenix_kit_locations` (the
warehouses), `phoenix_kit_billing` (currency formatting) and
`phoenix_kit_comments` (document comment threads). A plan source for core's
`mix phoenix_kit.media.reorganize` is included.

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
