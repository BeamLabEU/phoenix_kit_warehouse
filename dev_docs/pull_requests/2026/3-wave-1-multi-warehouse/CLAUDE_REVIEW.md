# PR #3 Review — Wave 1: multi-warehouse, transfers with cancellation, deficit control, turnover

- **PR:** [#3](https://github.com/BeamLabEU/phoenix_kit_warehouse/pull/3)
- **Author:** timujinne (Tymofii Shapovalov)
- **Merge commit:** `a2f8196` (+8,930 / −238, 65 files)
- **Reviewer:** Claude (Sonnet 5) — 4 parallel vertical reviews (multi-warehouse stock scope,
  Transfers end-to-end, Turnover report, post-review hardening commits), each finding
  independently re-verified against the actual code before being accepted.
- **Date:** 2026-07-13

## TL;DR

This is a large, mostly well-executed feature wave: transfer ship/receive/cancel is
properly atomic (`Ecto.Multi` + `FOR UPDATE` status CAS on all three mutations), the
turnover report correctly attributes in/out per document type including split-leg
transfers, and the eight small "post-review hardening" commits at the tail of the PR
are all complete, not half-applied. Four real bugs survived into the merge, all fixed
in this review, plus one test that was already red before I started (unrelated to my
fixes) and one repo-wide pre-existing gate issue that this PR didn't cause. See below.

Severity legend: `BUG-CRITICAL/HIGH/MEDIUM` (wrong behaviour), `IMPROVEMENT-*`
(correct but risky/inefficient/inconsistent), `NITPICK` (cosmetic).

---

## High-severity correctness bugs — fixed in this review

### BUG-HIGH — Negative transfer quantity corrupts source-warehouse stock and permanently stalls the document

`web/transfer_form_live.ex` — `handle_event("set_transfer_qty", ...)` stored the
client-supplied `transfer_quantity` string verbatim, with **no non-negative clamp**,
unlike its siblings `goods_issue_form_live.ex`/`goods_receipt_form_live.ex` (both pipe
through `clamp_non_negative/1`).

`StockLedger.issue_quantity/3` (used by `ship_transfer/2`) is an atomic
`UPDATE ... WHERE quantity >= $qty SET quantity = quantity - $qty`. With a negative
`$qty`, the `WHERE` guard is trivially true and the arithmetic **adds** to the source
warehouse's stock instead of subtracting — while the transfer still flips to
`in_transit` as if a normal shipment happened.

- **Failure scenario:** a draft line gets `transfer_quantity = "-5"` (client-side
  `min="0"` on the `<input>` is not a server-side guarantee) → Ship inflates source
  stock by 5 instead of decrementing it, and the transfer reports `in_transit`. The
  document is then **permanently stuck**: both `receive_transfer/2` and cancelling an
  in-transit transfer route through `StockLedger.receive_quantity`, which the `Stock`
  changeset's `validate_number(:quantity, greater_than_or_equal_to: 0)` guard rejects
  for the resulting negative delta on the destination/reversal side, rolling back the
  whole `Ecto.Multi` — so the transfer can never be received or cancelled either.
- **Fix applied:** added `clamp_non_negative/1` to `transfer_form_live.ex` (same
  Decimal-compare pattern as the sibling forms) and wired it into `set_transfer_qty`.

### BUG-HIGH — Supplier-order generation reads on-hand stock across *all* warehouses instead of the internal order's own location

`supplier_orders.ex` — `generate_from_internal_order/2` and
`import_from_internal_orders/3` (not touched by this PR's diff, but the bug only
became *live* once this PR made `StockLedger.stock_for_items_at_location/2` the
correct way to read per-warehouse stock) called the unscoped
`StockLedger.stock_for_items/1` and collapsed the result `Map.new(&{&1.item_uuid, &1})`
— one row per item, whichever the DB happened to return last (no `order_by`), i.e. an
**arbitrary warehouse's** on-hand quantity, even though the internal order carries its
own `location_uuid`.

- **Failure scenario:** item X has 100 units at Warehouse A and 0 at Warehouse B. An
  internal order for Warehouse B requests 50. `on_hand` can resolve to Warehouse A's
  100, so `shortfall = max(0, 50-100) = 0` and the line is silently dropped — no
  supplier order gets generated for an item that's actually fully out of stock at the
  requesting warehouse. `import_from_internal_orders/3` has the same bug, compounded:
  it aggregates `item_uuids` across potentially several internal orders that can each
  target a *different* warehouse, so a single global snapshot can't be correct for any
  of them.
- **Fix applied:** `generate_from_internal_order/2` now reads via
  `stock_for_items_at_location(item_uuids, internal_order.location_uuid)`.
  `import_from_internal_orders/3` now builds a `stock_map_by_location` (one
  location-scoped query per distinct IO location) and each IO's lines are priced
  against its own location's map. Extracted into `build_stock_map_by_location/2` to
  keep the already-complex `import_from_internal_orders/3` from growing further (see
  the pre-existing-debt note below).

### BUG-MEDIUM — Goods Issue on-hand display shows cross-warehouse stock, not the issue's own location

`web/goods_issue_form_live.ex` — `load_on_hand_quantities/1` used the unscoped
`StockLedger.stock_for_items/1`; the figure is rendered next to each line's
issued-quantity input. For an item stocked at more than one warehouse, the keeper
could see a wrong on-hand number for the document's actual location. **Display only —
not exploitable for stock corruption**: the real post path already reads via
`stock_for_items_at_location/3` scoped to the document's location, and
`issue_quantity/3`'s atomic `WHERE quantity >= qty` guard rejects an over-issue
regardless of what the UI showed.
- **Fix applied:** scoped `load_on_hand_quantities/1` to `issue.location_uuid`, and
  re-run it after `set_location` changes the draft's warehouse (previously the
  on-hand figures went stale after a location change until the next full remount).

### BUG-MEDIUM — `TurnoverReportLive.mount/3` queries the DB directly, doubling query cost per page load

`web/turnover_report_live.ex` — `mount/3` called `assign_rows()` (a four-table scan
via `Turnover.compute/3`) and `StockLedger.list_warehouses()` directly, with no
`handle_params/3` at all. Phoenix LiveView calls `mount/3` twice on a fresh page load
(disconnected HTTP render, then connected WebSocket mount) — this is the exact
anti-pattern `StockLive` was fixed for elsewhere in this same PR (see its inline
comment: *"was: once for `:stock_items` in mount, then again... 2x per mount
cycle"*), and `TurnoverReportLive` was the sole remaining outlier among this module's
LiveViews.
- **Fix applied:** split `mount/3` (cheap placeholder assigns only) from a new
  `handle_params/3` (the actual `list_warehouses/0` + `assign_rows()` calls), matching
  `StockLive`'s pattern.

---

## Pre-existing issue surfaced by the gate (unrelated to this PR, fixed anyway)

### BUG-HIGH — `min_stock.ex` / `transfer.ex` schemas missing `use PhoenixKit.SchemaPrefix`

`mix test` (no DB needed) was already red before I made any changes:
`PhoenixKitWarehouse.SchemaPrefixConformanceTest` asserts every table-backed schema
uses `PhoenixKit.SchemaPrefix`. This PR's own commit `ab6bc13` ("Add
PhoenixKit.SchemaPrefix to all table-backed schemas") retrofitted every *existing*
V140-backed schema but missed the *two new* schemas this same PR introduces
(`MinStock`, `Transfer`) — a two-lists-out-of-sync gap between the retrofit commit and
the schemas added later in the same branch. Without `SchemaPrefix`, these two schemas
would silently query the default Postgres schema instead of the host's configured
prefix on any non-default-schema install, while every sibling table-backed schema
honors it correctly.
- **Fix applied:** added `use PhoenixKit.SchemaPrefix` (right after `use Ecto.Schema`,
  matching every other schema's ordering) to both files. `mix test` is green again
  (38 tests, 0 failures).

---

## Verified clean (not exhaustive)

Transfer ship/receive/cancel: each wraps its status flip + stock posting in one
`Ecto.Multi`, locks the row `FOR UPDATE` and re-checks status inside the transaction
(serializes concurrent ship/receive/cancel attempts); cancel-from-`in_transit`
reversal uses the locked row's own frozen `transfer_quantity`, not a value that could
have drifted. Line-index parsing (`parse_line_index/2`) rejects non-numeric and
out-of-bounds client input and is wired into every client-indexed list operation in
`transfer_form_live.ex`. Turnover: in/out attribution is correct per document type
including transfers' two-sided location split (source = out, destination = in, only
once actually shipped/received); date-window boundaries match each document type's
own semantically-relevant timestamp field; the "balance is current, not historical"
caveat is surfaced both as an always-visible caption and a header tooltip, matching
the commit's own claim. All eight "post-review hardening" tail commits
(`reserved_by_item` posted-only filter, UUIDv7 PKs, `:kind`/`:type` SourceKinds fix in
both goods_issue and goods_receipt forms, transfer line-index guard, StockLive
mount→handle_params, zero-stock deficit rows, StockLive item-list caching, StockLive
admin? guard) are complete — not partially applied to only one of the affected files
or handlers.

---

## Gate note: `mix precommit` / `mix credo --strict` do not currently exit 0 in this repo

`mix precommit` halts at the `credo --strict` step of its `quality.ci` alias before
ever reaching `dialyzer` (Mix aliases stop at the first non-zero-exit task). Verified
this is **pre-existing and repo-wide**, not something this PR (or this review's fixes)
introduced: `git stash` back to the pre-review tree reproduces the identical finding
composition — 2 refactoring opportunities, 41 readability issues, 248 design
suggestions, exit code 14 — on the unmodified `main` branch. The only local
attributable change is `supplier_orders.ex:import_from_internal_orders/3`'s cyclomatic
complexity moving from 15 to 16 (still over the configured max of 12, was already over
before this PR touched nothing in that file) — an unavoidable consequence of the
per-location stock-map fix above, minimized by extracting
`build_stock_map_by_location/2`. Ran `mix dialyzer` directly instead (see below) to get
real type-checking signal since the alias chain never reaches it.

Ran independently and passed:
- `mix compile --warnings-as-errors` — clean.
- `mix format --check-formatted` — clean (this runs before credo in the alias, so its
  success is implied by credo having run at all).
- `mix test` — 38 tests, 0 failures, 695 excluded (no local PostgreSQL — integration
  suite auto-excludes per this repo's documented testing stance; see `AGENTS.md`).
- `mix dialyzer` — 11 warnings, all the same pre-existing, already-documented
  `call_without_opaque` shape on each context's `lock_status_step/3` helper (an
  `Ecto.Multi` opaque-type limitation, not a real type error — PR #1's review recorded
  this exact pattern at 10 occurrences across `goods_issues.ex`, `goods_receipts.ex`,
  `internal_orders.ex`, `inventories.ex`, `supplier_orders.ex`). The 11th is
  `transfers.ex:481`, new only because `Transfers` is a new context reusing that same
  established `lock_status_step` pattern — not a new class of warning. The remaining 4
  (`pattern_match_cov` ×2, `guard_fail` ×2 in `inventories.ex`,
  `web/components/warehouse_browser.ex`, `storage_folders.ex`) are in files this PR
  didn't touch and match PR #1's "pattern_match_cov/guard_fail ones are in files this
  review never touched" note.

## Testing limitations

No PostgreSQL in this review environment (client tools absent too), so all
`:integration`-tagged tests — including the new Transfers/Deficits/Turnover suites
this PR adds, and specifically the cancel-from-`in_transit` reverse-posting test the
PR author flagged as never having run against a real database — were excluded every
run. The four bug fixes above were verified by tracing the actual code paths (Ecto
query construction, changeset guards, `Ecto.Multi` step composition) to a concrete
failure scenario, and the module compiles clean and the non-DB unit suite passes, but
none of this was exercised against real Postgres. **Run `mix test` against a real
database (see `PHOENIX_KIT_PATH` note in `AGENTS.md`, though a Hex-published
`phoenix_kit` ≥ 1.7.189 already satisfies this package's pin as of this review) before
relying on the Transfers/Deficits/Turnover code paths in production.**
