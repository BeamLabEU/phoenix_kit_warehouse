# Changelog

All notable changes to this project will be documented in this file.

## 0.2.4 - 2026-07-20

### Fixed

- **Row-link overlay escaped its row on Safari/iPad** (PR #10) — Safari
  doesn't honor `position: relative` on `<tr>`, so the whole-row-clickable
  `::after` overlay on every index table (goods issues, goods receipts,
  internal orders, supplier orders, stocktakes, transfers) escaped to the
  `<table>`'s containing block; every row's overlay covered the entire
  table and the last row won hit-testing, so any row tap on iOS/iPadOS
  navigated to the last item. Fixed by adding Tailwind's `transform-gpu`
  utility alongside the existing `relative` class on each row — WebKit does
  honor a `transform` as a containing block on table rows. Reviewed: no
  affected file was missed, and the fix doesn't interact badly with the
  per-row `⋮` action menu (which portals to `<body>` on open) or any
  pinned/sticky table variant.

### Changed (review of PR #9)

- **`permission_metadata/0`'s attempted gettext declaration was reverted**
  — PR #9 added `gettext_backend`/`gettext_domain` to the warehouse's
  `permission_metadata/0`, intending to translate its label in the admin
  permissions matrix the same way `admin_tabs/0` already translates sidebar
  labels. Against the dependency actually pinned in `mix.lock`
  (`phoenix_kit` 1.7.205, published 2026-07-19, before core's
  `localized_module_label/1` work landed), no code reads those two keys —
  the permissions matrix still renders through the plain, untranslated
  `Permissions.module_label/1` — so the addition was inert in production
  and only introduced a new `mix dialyzer` `callback_type_mismatch`
  against the published `permission_meta()` behaviour type. Reverted
  `permission_metadata/0` to its original 4-key shape. Re-adding the two
  keys is the correct follow-up once `phoenix_kit` publishes a Hex release
  containing the localized-permission-labels feature and this repo's pin
  is bumped to it — `admin_tabs/0`'s per-tab gettext declarations are
  unaffected (that feature is real and already published). Full findings:
  `dev_docs/pull_requests/2026/9-permission-label-i18n/CLAUDE_REVIEW.md`
  and `dev_docs/pull_requests/2026/10-safari-row-link/CLAUDE_REVIEW.md`.

### Maintenance

- Removed a stale, unused `mix.lock` entry (`beamlab_ex_aws_sqs`, hex
  package v4.0.0) left over from the prior `phoenix_kit` 1.7.199 → 1.7.205
  bump, which renamed the dependency's key to `ex_aws_sqs` (same hex
  package, v5.0.0) and made the old lock entry unreferenced. Caught by
  `mix deps.unlock --check-unused`.

## 0.2.3 - 2026-07-16

### Changed

- **`resolve_suppliers/1` gained a guarded junction-primary fallback clause**
  (PR #6), sitting between the `primary_supplier_uuid` scalar check and
  manufacturer resolution: a `Code.ensure_loaded?`/`function_exported?`-guarded
  call to `PhoenixKitCatalogue.Catalogue.Suppliers.primary_for_item/1` (the
  catalogue V151 junction `is_primary` row), falling back to manufacturer
  resolution (with a warning) when the primary row's supplier isn't locally
  resolvable. The guard is correctly written — no crash risk against a
  dependency that doesn't export the function.

### Fixed (review of PR #6)

- **Neither `resolve_suppliers/1` non-manufacturer clause is actually reachable
  against the currently pinned `phoenix_kit_catalogue ~> 0.10` dependency** —
  corrected during review, not a new bug from this PR. `phoenix_kit_catalogue`
  0.10.0 (still Hex's latest as of this release) never shipped
  `primary_supplier_uuid` *or* `Suppliers.primary_for_item/1`: both were added
  and (in the scalar's case) removed entirely in catalogue commits *after*
  0.10.0 was tagged, and remain unpublished. This also means the 0.2.2
  changelog entry below and PR #5's review overstated the scalar's status —
  it was never live in any published catalogue release, not just removed by a
  later one. `resolve_suppliers/1` today is functionally equivalent to
  manufacturer-only resolution for every item. Rewrote the misleading code
  comments to state this plainly (with the mechanism activating automatically,
  no code change needed, once catalogue publishes the junction release and
  this repo's `mix.lock` picks it up), and replaced two pre-existing tests
  that asserted unreachable scalar-based behavior (and would have failed
  against the real dependency) with tests that lock in the real,
  currently-shipping fallback behavior. Full findings:
  `dev_docs/pull_requests/2026/6-junction-primary-fallback/CLAUDE_REVIEW.md`.

### Notes

- **Dependency lockfile advance** (no `mix.exs` constraint change):
  `hackney` 4.5.2 → 4.6.0.

## 0.2.2 - 2026-07-14

### Added

- **Goods receipt lines can now set stock `unit_value` on posting** (PR #5).
  When a receipt line carries a `"unit_value"` field, posting writes it to
  `phoenix_kit_warehouse_stock.unit_value` for that item/location via
  `StockLedger.receive_quantity/3`'s existing `:unit_value` option (last
  posted receipt wins). Absent/`nil` leaves the existing value untouched.

### Fixed

- **`resolve_suppliers/1` stopped honoring `item.primary_supplier_uuid`** (PR
  #5 fix, applied during review). PR #5 rewrote supplier resolution to prefer
  a `PhoenixKitCatalogue.Catalogue.Suppliers.primary_for_item/1` junction
  lookup, on the premise that core's V149 migration removed the
  `primary_supplier_uuid` scalar. It didn't: V149 is a purely additive
  per-supplier-pricing junction table, and the scalar remains the item's
  documented default supplier. Against the pinned `phoenix_kit_catalogue ~>
  0.10` dependency, `primary_for_item/1` doesn't exist, so the new code
  silently fell through to manufacturer-only resolution — any item that
  relied on `primary_supplier_uuid` (generic/unbranded materials with no
  manufacturer, or breaking a tie between a manufacturer's multiple linked
  suppliers) stopped auto-assigning a supplier during
  `generate_from_internal_order/2`. Reverted `resolve_suppliers/1` to check
  `primary_supplier_uuid` first, manufacturer as fallback — the original
  pre-PR behavior. Full findings:
  `dev_docs/pull_requests/2026/5-parties-resolver-unit-value/CLAUDE_REVIEW.md`.

## 0.2.1 - 2026-07-14

### Fixed

- **Stale `V143` migration references renumbered to `V144`** (PR #4). When core's
  consolidation PR merged, the migration creating `phoenix_kit_warehouse_transfers`
  and `phoenix_kit_warehouse_min_stock` was renumbered upstream — core's own V143
  slot went to the new-login-security-alerts migration instead. Every `V143`
  reference in this package (`AGENTS.md`, `min_stock_settings.ex` moduledoc,
  `mix.exs` comments) now points to `V144`, and the `phoenix_kit` dependency pin is
  tightened to `~> 1.7.190` (1.7.189 tops out at V142 and does not carry the
  tables).
- **This CHANGELOG's own 0.2.0 entry still referenced `V143`/`>= 1.7.189` after
  PR #4 landed** — corrected post-release as part of reviewing that PR (see
  `dev_docs/pull_requests/2026/4-v144-renumber-and-pin/CLAUDE_REVIEW.md`).

## 0.2.0 - 2026-07-13

Wave 1: multi-warehouse, transfers, deficit control, turnover.

### Added

- **Multi-warehouse stock scope**: per-location stock balances
  (`StockLedger.stock_map_for_location/1`, `get_quantity/2`), a warehouse
  selector on goods receipt/issue/inventory drafts, and a "per warehouse /
  all warehouses" scope toggle on the Stock page (persisted per user).
- **Transfers**: new document type with a draft → in_transit → done
  lifecycle, atomic ship/receive stock postings, and cancellation (draft:
  void; in_transit: reverses the ship posting back to the source
  warehouse).
- **Deficit control**: per-item minimum stock, an available-quantity
  calculation (on-hand minus posted reserves — draft documents don't
  reserve), zero-stock deficits surfaced even with no `Stock` row, and a
  "create supplier order" action from a deficit row.
- **Turnover report**: aggregated in/out/balance per item over a date
  range, optionally scoped to one warehouse; `balance` is documented as
  current on-hand, not a historical balance as of the end date.
- **Related documents**: a shared upstream/downstream linked-documents
  list component on Internal Order / Supplier Order cards.
- `Transfer`/`MinStock` tables now ship in core `phoenix_kit`'s migration
  V144 instead of this package's own migrator (which is retired); this
  package defines schemas only and owns no DDL.

### Fixed

- `StockLedger.stock_map/0`, `Deficits`, `Inventories`, `GoodsReceipts`,
  `GoodsIssues` previous-quantity audit snapshots, and the `SourceKinds`
  link picker in the goods receipt/issue forms were all made
  warehouse-aware or corrected for multi-location stock (see
  [`dev_docs/pull_requests/2026/3-wave-1-multi-warehouse/CLAUDE_REVIEW.md`](dev_docs/pull_requests/2026/3-wave-1-multi-warehouse/CLAUDE_REVIEW.md)
  for the full list, plus this release's own post-merge fixes below).
- Post-merge review fixes: `SupplierOrders.generate_from_internal_order/2`
  and `import_from_internal_orders/3` now read on-hand stock from the
  internal order's own warehouse instead of an arbitrary one;
  `TransferFormLive`'s quantity input is now clamped non-negative
  (a negative value could otherwise inflate source-warehouse stock and
  permanently stall the transfer); `TurnoverReportLive` no longer queries
  the database in `mount/3` (was doubling the report query on every page
  load); `Transfer`/`MinStock` schemas now use `PhoenixKit.SchemaPrefix`,
  matching every other table-backed schema in this package.

### Requires

- `phoenix_kit >= 1.7.190` — `Transfer`/`MinStock` tables ship in core
  migration V144 (renumbered from a provisional V143 before publish;
  1.7.189 tops out at V142, so it does *not* satisfy this pin — corrected
  post-release, see PR #4).

## 0.1.0 - 2026-07-10

Initial release.

### Added

- **Inventory & stock**: `Stock` balances per item/location, `StockLedger`
  context (upsert/receive/issue with an atomic, non-negative-guarded
  conditional decrement), and stocktakes (`InventoryDocument`) that count
  and post adjustments.
- **Goods receipts & goods issues**: transactional posting (`Ecto.Multi` +
  `FOR UPDATE` compare-and-swap on status) that additively increases
  (receipts) or conditionally decreases (issues) warehouse stock, with a
  per-line `previous_quantity` audit trail.
- **Supplier orders & internal orders**: draft → posted document lifecycle,
  many-to-many traceability via a generic `source_refs` / `SourceKinds`
  registry (host apps can register their own linkable "order" kinds),
  committed-quantity netting to avoid re-ordering already-requested stock.
- **Admin UI**: index + form LiveViews for every document type, a shared
  `ColumnConfig` engine (sortable/filterable/configurable columns, per-user
  view persistence), file attachments via `StorageFolders`, and comments
  via `PhoenixKitComments` (optional — degrades gracefully when absent).
- Activity logging, i18n (en/et/ru), and the `PhoenixKit.Module` admin-tab
  integration (`module_key: "warehouse"`).
- Project scaffold: `mix.exs` (with the `pk_dep/3` helper, `quality` /
  `quality.ci` / `precommit` aliases, and dialyzer config), `config/`,
  `.formatter.exs`, `.credo.exs`, `.gitignore`, `LICENSE`, and `AGENTS.md`.

### Requires

- `phoenix_kit >= 1.7.182` — the warehouse DB tables ship in core migration
  V140, first published in that core release.

### Known issues

See [`dev_docs/pull_requests/2026/1-warehouse-module/CLAUDE_REVIEW.md`](dev_docs/pull_requests/2026/1-warehouse-module/CLAUDE_REVIEW.md)
for the full review. Notably: stocktake posting can clobber stock movements
that happened between opening the count and posting it (absolute-SET
semantics), and "Generate supplier orders" doesn't record `source_refs`, so
re-importing the same internal order into a second supplier order can
double the ordered quantity. Both need a maintainer decision on intended
semantics before being fixed.
