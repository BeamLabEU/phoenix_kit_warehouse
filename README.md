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
- `Inventories.create_and_post/3` takes `skip_unchanged: true`: a stocktake
  where every counted line already holds its quantity returns
  `{:error, :unchanged}` and writes nothing, so its `external_ref` is not
  recorded either and a later call with it runs as a new stocktake.

### Linking documents to host records

Documents link to host-owned records (orders, sub-orders, ...) through
`source_refs` and the generic `PhoenixKitWarehouse.SourceKinds` registry, so
the package has no dependency on any specific "order" concept. Kinds come from
the host's `config :phoenix_kit_warehouse, :source_kinds` list and from any
registered PhoenixKit module that exports `warehouse_source_kinds/0`; the two
are merged by kind, and the host's definition wins on a conflict.

### Admin API tools (shop API)

On a host that runs PhoenixKit core with the shop API and has switched the admin
API on (Settings -> API), this module offers five tools to API keys. A key sees a
tool only while the Warehouse module is enabled and only if the key's scopes and
its owner's `warehouse` permission allow it. The three write tools are offered
only on a core that can hold a dangerous call for confirmation; on an older core
only the two read tools are.

| Tool | Scope | What it does |
|---|---|---|
| `warehouse.list_locations` | `warehouse.stock:read` | warehouse locations, the default one, and how far setup has got |
| `warehouse.get_stock` | `warehouse.stock:read` | quantity and unit value per location and the total, with the product's `unit`, for up to 50 products |
| `warehouse.receive_stock` | `warehouse.stock:receive` | one goods receipt with up to 500 lines |
| `warehouse.set_stock` | `warehouse.stock:adjust` | one stocktake that sets the listed products to counted quantities |
| `warehouse.issue_stock` | `warehouse.stock:issue` | one goods issue (write-off) with up to 500 lines |

How they behave, in short:

- A product is named by a ref: exactly one of `id` (the catalogue item UUID), `sku`
  or `external_id`. Only live (not trashed) catalogue items are accepted; `sku` and
  `external_id` need a catalogue release with the shop API support. Refs of every
  kind resolve inside one catalogue: `catalogue_id` is required when the shop has
  more than one active catalogue (otherwise the only active one is used; the refusal
  lists the catalogue ids to choose from as `allowed`); a deleted
  catalogue is refused, an archived one can be read but not written. An ambiguous
  ref is reported with the `candidates` it matches, at the top level of its row
  error.
- Each write tool creates and posts **one document in one transaction**. If any line
  is wrong nothing is posted and every problem is reported at once; a product on two
  lines is refused (`duplicate_line`); `issue_stock` reports every short line
  (`insufficient_stock`) and posts nothing. The answer is `422 insufficient_stock` with
  `posted: false` and `context.lines[{id, ref, sku, requested, available}]`: `id` is the
  product, `ref` the one you sent, `requested` and `available` decimal strings in the
  product's unit (the `unit` that `get_stock` answers).
- Through the HTTP/MCP executor the closed input schema refuses malformed shapes
  first, with `context.errors[{path, message}]` and no row `code`; the row errors
  with a `code` are for what the schema lets through.
- A call with more lines than core's `api_confirm_batch_over` setting (50 unless the
  host changed it) is held for confirmation: the first call answers a preview and a
  `confirm_token`, the same call with the token posts it. This holds for a retry of a
  posted `external_ref` too.
- `dry_run: true` (a control field every write tool takes) answers what the call would
  do (`would_post`, `would_skip`, `unchanged` for a stocktake that changes nothing, or
  the same refusal a real call gives) and writes nothing. A stocktake is worth
  previewing: the `from` of each line is the current stock. A preview that answers
  `unchanged` has nothing to confirm: the confirmed call would post no document either.
- Every posted line answers the stock before (`from`) and after (`to`). A confirmation
  code is bound to what the preview showed, including the current stock of every
  line: any other document that moves one of those products before the code is used
  invalidates it (`409`), and the call is previewed again.
- A posting that Postgres aborts to break a lock cycle with another document (a
  deadlock) is answered `500 internal_error` with `posted: false` and a `retry-after`
  of 1 second; nothing was changed and the same call can be sent again. A call that
  carried a confirmation code (above the confirmation threshold) has spent it: send it
  again without the code.
- `set_stock` that changes nothing (every listed product already holds its counted
  quantity) creates no document and burns no document number: it answers
  `status: "unchanged"` with the `results` (`action: "unchanged"`) and no `document`.
  A stocktake where at least one line changes is posted whole. After an `unchanged`
  answer the `external_ref` is not recorded (there is no document), so a later call with
  the same reference runs normally; use `Idempotency-Key` for replays.
- `external_ref` carries your own document number: sending it again answers
  `skipped` with the existing document and moves no stock (for a posted document;
  an `unchanged` `set_stock` posts none, see above). On `issue_stock`
  `source: {"kind": "external", "ref": ...}` is the same reference (do not send both).
  The retry is answered from the posted document before the lines are checked (a
  product trashed or a default warehouse changed since does not matter). What a retry
  is compared on: the lines (the product and the quantity of each, and for a receipt
  the `unit_value` of each), an explicit `location_id`, an explicit `catalogue_id`, an
  explicit `reason`, and the shop order of the `source`. A `location_id` or
  `catalogue_id` left out is not compared (the default warehouse may have moved), and
  neither is `note`. A request that differs is refused as `422 validation_failed` with
  `posted: false`, the posted `document` and `context.errors[{path, code, message}]`;
  it is never answered `skipped`, so a client that reads only the status cannot take a
  different request for one that went through. Nothing is posted. The lines of a retry are
  checked as in a first call: a line that a first call would refuse (a wrong quantity,
  an id that names no product, a product twice) is refused with the same errors, not
  answered `skipped`. The codes:
  - `external_ref_lines_differ`: the lines are not the posted ones.
  - `external_ref_basis_differs`: a stated `location_id`, `catalogue_id`, `reason` or
    shop order (`source`) is not the posted document's (the message names which).

  When a product no longer resolves (trashed since), its ref must match a stored
  product identity. Quantities, receipt unit values and duplicate products are
  still checked. A matching retry is answered `skipped` with an
  `external_ref_lines_unverified` effect, which a client must check. New documents
  retain product `external_id` refs in their lines for this comparison. For older
  documents without that snapshot, use the product UUID if its external ID no
  longer resolves; an unknown external ID is refused.
- `issue_stock` takes a required `reason` (`sale`, `damage`, `production`, `other`) and
  may link the write-off to a shop order with `source: {"kind": "shop_order", "id": ...}`
  (needs the E-commerce module, enabled, which registers that source kind). An issue
  with neither an `external_ref` nor an external source is
  not protected against a repeated request: if a call is repeated after a crash
  between the posting and the answer, the stock can be written off twice. Send a
  stable reference whenever a retry is possible.
- Quantities are decimal strings (or numbers) from 0 to 1000000000 with at most 6
  decimal places; receipts and issues need more than zero, a stocktake accepts 0.
- Stock is written only to **active** warehouse locations; without `location_id` the
  default warehouse is used, and without one the call fails and names the setting.
- Each posted document writes one Activity entry (`warehouse.goods_receipt.posted`,
  `warehouse.goods_issue.posted`, `warehouse.inventory.posted`) with `via: api`, the
  key prefix, the request id and, for an operation released from the approval queue,
  the approver. These entries follow the module's `:inventory_activity_logging`
  switch: a host that switched that log off gets no module entry for API documents
  either (core's own `api.request` entry is separate and does not name the document),
  and a failed write of an entry never fails a document. The document itself still
  records its number, its `external_ref`, its posting time and the key owner as its
  creator.
- The tools follow this module's own enabled state, not the shop's "Stock tracking"
  switch.

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
