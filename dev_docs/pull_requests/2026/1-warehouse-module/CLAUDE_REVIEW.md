# PR #1 Review — Add warehouse module

- **PR:** [#1](https://github.com/BeamLabEU/phoenix_kit_warehouse/pull/1) — "Add warehouse module: stock, stocktakes, internal/supplier orders, goods receipt/issue"
- **Author:** timujinne (Tymofii Shapovalov)
- **Merge commit:** `a736b89` (+34,302 / −0, 93 files)
- **Reviewer:** Claude (Opus 4.8) — 5 parallel vertical reviews + shared-core read, each cross-checked against the actual code paths.
- **Date:** 2026-07-10

## TL;DR

The module is impressively complete and, on the whole, **well engineered**: posting is
genuinely transactional (`Ecto.Multi` + `FOR UPDATE` compare-and-swap on status),
stock can't be double-applied, user input is not turned into atoms, filter/column
keys are whitelisted, and components are display-only. The reviewers verified far
more "clean" than "broken."

**There is a handful of real correctness bugs, and one config issue that _was_ a
release blocker but is now resolved.** The module's tables ship in core `phoenix_kit`
migration **V140** — which is now published (core **1.7.182**). The package's `mix.exs`
pinned core too loosely (`~> 1.7`, resolving to 1.7.179 = V139, without the tables); this
review bumps the floor to `>= 1.7.182`. With that pin the package resolves the tables and
is releasable.

Severity legend: `BUG-CRITICAL/HIGH/MEDIUM` (wrong behaviour), `IMPROVEMENT-*`
(correct but risky/inefficient/inconsistent), `NITPICK` (cosmetic).

---

## Was-blocker, now fixed — core version pin

### BUG-HIGH (config) — core pin was too loose; resolved to a core without the warehouse tables → ✅ fixed

The six schemas point at tables `phoenix_kit_warehouse_{stock, inventory_documents,
goods_receipts, goods_issues, internal_orders, supplier_orders}`. This package
intentionally does **not** create them (no `migration_module/0`, no `create table`): they
ship in **core `phoenix_kit` migration V140** — the "core-migration pattern" (cf.
`phoenix_kit_locations`), not the standalone pattern. That is a legitimate architecture
**as long as the core pin guarantees V140**.

It didn't. `mix.exs` pinned `pk_dep(:phoenix_kit, "~> 1.7")`, which resolved to 1.7.179
(= V139, no warehouse tables), with no error — so a Hex install would crash at the first
query with `relation "phoenix_kit_warehouse_stock" does not exist`. Contributing factors:
the author's own V140 floor + comment (commit `89aaefd`, `>= 1.7.165`) was **dropped in the
PR merge** (`a736b89:mix.exs` already read `~> 1.7`), and `1.7.165` wouldn't have enforced
V140 anyway.

- **✅ Fixed in this review:** core V140 is now published in **phoenix_kit 1.7.182**; the pin
  is bumped to `pk_dep(:phoenix_kit, "~> 1.7 and >= 1.7.182")` (+ explanatory comment) and
  `mix.lock` updated to 1.7.182. `v140.ex` is confirmed present in the published dep,
  creating the six prefix-aware tables (with a `quantity_non_negative` CHECK and the
  `(item_uuid, location_uuid)` unique index). The package now resolves the tables and is
  releasable.
- **Residual (test harness):** `test/test_helper.exs` still only runs core migrations via
  `PhoenixKit.Migration.ensure_current/2`; with core ≥ 1.7.182 that now includes the
  warehouse tables, so integration tests are runnable against a DB. Two harness issues
  remain: (a) integration tests silently **auto-exclude** with no DB (false-green risk —
  CI must provision Postgres); (b) the helper shelled out to `psql` unguarded and crashed
  the whole suite when the client was absent — **✅ fixed** here (guarded to fall back to a
  connection probe). Confidence: high (verified `v140.ex` in the 1.7.182 dep).

---

## High-severity correctness bugs

### BUG-HIGH — Stocktake posting does an absolute SET seeded from stale recorded stock, erasing intervening movements
`inventories.ex:78` (`seed_lines` → `"counted_quantity" => row.quantity`), post path
`inventories.ex:329` → `StockLedger.upsert_quantity` (`on_conflict {:replace,[:quantity,…]}`).

A new stocktake pre-fills every line's `counted_quantity` with the **recorded** stock at
*draft-creation* time. Posting then SETs stock to `counted_quantity` **absolutely** (no
delta, no re-read of current stock). Any receipt/issue that happens between opening the
draft and posting it is silently reverted for every un-recounted line.

- **Failure scenario:** Stock of X = 100 → open stocktake (line seeded 100) → an order
  ships 20 (stock → 80) → post the stocktake without recounting X → stock SET back to
  **100**; the sale is erased. `previous_quantity` audit records 80, so it's traceable
  but committed.
- **Fix direction:** seed counts blank (force a real count), or detect drift at post time
  (`previous_quantity` vs seeded) and warn/refuse, or post a computed delta via
  `receive/issue_quantity`. *Design-touching — confirm intended semantics with the author.*
- Confidence: high (traced seed → `handle_params_new` → `build_posting_multi` → upsert).

### BUG-HIGH — "Generate supplier orders" writes no `source_refs`, so committed-quantity netting counts 0 → re-import double-orders
`supplier_orders.ex:302-313` (`generate_from_internal_order`) vs the netting in
`import_from_internal_orders` (`:407-413`) which reads only `doc.source_refs`.

Generated draft SOs carry only the `internal_order_uuid` FK and `lines`, never
`source_refs`. `CommittedQuantities.compute/4` ignores the FK and only sums
`source_refs[].lines`, so a generated order's already-ordered quantity nets to **0**.

- **Failure scenario:** IO-1 needs A=10 (on-hand 0) → "Generate" makes SO-1 with A=10,
  `source_refs=[]` → keeper opens SO-1, "Import from internal order" → IO-1 → committed
  reads 0 → shortfall recomputed to 10 → **A ordered = 20** for a requirement of 10.
- **Fix direction:** seed `source_refs` with an `"internal_order"` ref carrying the
  per-item `"lines"` breakdown in `generate_from_internal_order` (mirror the manual path
  via `CommittedQuantities.merge_ref/4`).
- Confidence: high.

### BUG-HIGH — "Select all" in the source picker crashes the LiveView (`KeyError`)
`internal_order_form_live.ex:332` — `Map.put(m, c.uuid, c.type)`.

`SourceKinds.search_candidates/1` returns maps keyed `:kind` (no `:type`). Dot-accessing
`c.type` raises `KeyError`, crashing the LV and losing modal/selection state. The sibling
`source_picker_toggle` (`:307`) correctly uses `c.kind`.

- **✅ Fixed in this review:** `c.type` → `c.kind` at `internal_order_form_live.ex:332`
  (+ regression test). Contained, unambiguous, crash-level. Confidence: high (candidate
  shape confirmed in `source_kinds.ex:79`).
- **Related, left for the author (not fixed):** `goods_issue_form_live.ex:447`
  `source_picker_toggle` stores `Map.get(candidate, :type)`, which is `nil` for the
  `:kind`-keyed `SourceKinds` candidates (`io_picker_candidates` is a *union* of two
  shapes — the internal-order maps have neither key). It does not crash, but for the
  `:link_order` purpose `link_ref_type/3` does `Map.get(meta, uuid, "order")`, and a
  present-but-`nil` entry defeats the `"order"` default → a `nil` ref `type` is persisted.
  The correct value depends on which candidate source feeds `:link_order`, so this needs
  the author's domain call (store `:kind` *and* make `link_ref_type` fall back on `nil`).

### BUG-HIGH (systemic) — `update_draft` guards checked the in-memory struct, not the DB → a stale tab could overwrite a posted document → ✅ fixed (all 5 contexts)

`goods_receipts.ex`, `goods_issues.ex`, `inventories.ex`, `supplier_orders.ex`,
`internal_orders.ex` — each has its own `update_draft/2`.

`update_draft(%Doc{status: "draft"} = doc, attrs)` matched on the **in-hand struct's**
status, then `repo().update/1` emitted `UPDATE … WHERE uuid = ?` with **no status
predicate** and no optimistic lock (schemas have no `lock_version`). The *posting* path was
correctly protected (`lock_status_step` = `FOR UPDATE` + status re-check); the save path was not.

- **Failure scenario:** Tab A holds a draft; Tab B posts it (stock applied, `status=posted`,
  lines rewritten with audit data). Tab A clicks "Save draft" → `update_draft` still matches
  the stale `"draft"` struct → overwrites the posted row's `lines`/`note`, destroying the
  posted audit trail and desyncing recorded lines from applied stock. (The Post path's CAS
  still prevents double *stock* application, but the line overwrite already happened.)
- **✅ Fixed in this review:** all 5 `update_draft/2` functions now build an `Ecto.Multi` that
  reuses each context's existing `lock_status_step/3` helper (`FOR UPDATE` + `WHERE status =
  'draft'` re-check inside a transaction — the exact CAS the posting path already used) before
  applying the changeset, so a stale in-memory status can no longer win a race with a concurrent
  post. Same `{:ok, doc} | {:error, :not_draft} | {:error, changeset}` return shape preserved,
  so no caller changes were needed.
- **Not changed:** `correct_*` functions (`correct_goods_receipt`, `correct_document`, etc.) —
  on inspection these are *designed* to work in any status (a `correction_changeset` that only
  touches `note`/`storage_folder_uuid`; lines are immutable once posted), so they don't need
  the guard. The original finding's inclusion of `correct_document` was over-broad; narrowed here.
- Confidence: high. Compiles clean; reuses the already-tested `lock_status_step` pattern verbatim
  per context. **Could not be verified against the integration test suite** (no Postgres in this
  environment — see Testing note below); review carefully before relying on this in production.

---

## Medium-severity

### BUG-MEDIUM — `DocRefs.refs_for/1` dropped host-registered custom source kinds → ✅ fixed
`doc_refs.ex:67-79` pattern-matched a **fixed** 6-value whitelist (`order`, `sub_order`,
`internal_order`, `supplier_order`, `goods_receipt`, `goods_issue`); the `_ -> nil` clause
filtered out everything else. But `SourceKinds` is generic — a host can register any `kind`,
and it will be selectable in the picker and stored in `source_refs`. A custom kind then
rendered as **nothing** (invisible chip), and since the remove ✕ only exists on rendered
chips, the orphan ref could never be removed via the UI.
- **✅ Fixed in this review:** added a fallback clause that delegates any other `%{"type" =>
  type, "uuid" => uuid}` (both binaries, guarded — never `String.to_atom`) to the same
  `resolve_or_plain/3` helper `"order"`/`"sub_order"` already use, keeping `kind` as the
  literal type string. Confidence: high.

### BUG-MEDIUM — `StockLedger.issue_quantity/3` raw SQL hardcodes the unqualified table name (prefix-unsafe)
`stock_ledger.ex:225` — `UPDATE phoenix_kit_warehouse_stock …` via `repo.query/2`. Every
other ledger function uses Ecto (`from s in Stock`), which honours a configured repo prefix;
V140 creates the table prefix-aware (`#{p}…`). On a non-default-schema install, receive/upsert
write to `<prefix>.stock` while `issue` targets the search-path default — a split-brain balance.
Low impact on the common single-schema (`public`) deployment. Confidence: medium (depends on
whether any host runs a prefix). 

### IMPROVEMENT-HIGH — DB queries in `mount/3` on every list LiveView (Iron Law); `StockLive` queried twice per mount → ✅ fixed
`goods_receipt_index_live.ex`, `goods_issue_index_live.ex`, `supplier_order_index_live.ex`,
`internal_order_index_live.ex`, `inventories_live.ex`, `stock_live.ex` (double query),
`inventory_form_live.ex`, `internal_order_form_live.ex`.

None of the index LVs defined `handle_params/3`, so list-loading + enrichment + view-config
reads ran in `mount`, which executes on **both** the dead (HTTP) and connected (WS) render —
doubling DB load per page open. `StockLive.mount` additionally called `build_stock_items()`
twice (full table scan ×2, ×2 mounts). The **form** LVs correctly load in `handle_params/3`
except for a couple of stray reads left in `mount`.
- **✅ Fixed in this review, all 8 files**, following the pattern the form LVs already use
  correctly elsewhere in this codebase: `mount/3` now only assigns non-DB defaults (empty
  list/map placeholders); a new (or extended) `handle_params/3` does the actual query +
  `assign_column_state`. `StockLive` additionally now computes `build_stock_items()` **once**
  per `handle_params` (was: once for `:stock_items` + once inside `assign_stock_rows` = 2×
  per mount cycle) via a new `assign_stock_rows/2` that accepts the already-fetched items;
  the 1-arity `assign_stock_rows/1` (re-queries) is kept for the search/sort/filter event
  handlers, matching the re-query-per-event behavior of the other index views — deliberately
  *not* changed today (a separate, lower-priority "whole-table re-scan per keystroke" finding
  below). `internal_order_form_live.ex`/`inventory_form_live.ex`: the stray `mount`-time
  catalogue/stock-map reads moved into `handle_params/3`, guarded to run only once (`if
  socket.assigns.catalogue_summaries == []`) since these forms call `handle_params` on every
  tab navigation within the same LiveView process.
- Confidence: high — all 8 files compile clean with `--warnings-as-errors`; behavior verified
  by code reading (LiveView guarantees `handle_params/3` completes before the first render, so
  the empty-default placeholders are never actually shown). **Could not be exercised against
  the integration/LiveViewTest suite** (no Postgres in this environment) — see Testing note.

### IMPROVEMENT-HIGH — Primary keys use `Ecto.UUID` (v4), overriding the V140 `uuid_generate_v7()` default
All six schemas: `@primary_key {:uuid, Ecto.UUID, autogenerate: true}` / `@foreign_key_type
Ecto.UUID`. V140 columns are `uuid UUID PRIMARY KEY DEFAULT uuid_generate_v7()`, and `uuidv7`
is available (transitively). `autogenerate: true` makes Ecto insert an **app-side v4**,
overriding the DB v7 default — so warehouse rows get v4 PKs while the rest of the platform is
v7, losing time-ordering / btree locality. Convention + the manufacturing sibling use
`{:uuid, UUIDv7, autogenerate: true}`.
- **Fix:** switch the six schemas to `UUIDv7`. Confidence: high.

### IMPROVEMENT-MEDIUM — Activity log records field **values** (note bodies, user UUIDs), not just names
`activity_log.ex:164-179` (`stringify_changes`) faithfully serializes `from`/`to` **values**;
`diff_doc_changes` (`inventory_form_live.ex:1328`) feeds it the literal `note` text. Convention
is field **names** only (no PII). Note revisions land verbatim in core's activity metadata.
- **Fix:** record changed-field names / redacted markers; exclude free-text like `note`. Confidence: high.

### IMPROVEMENT-MEDIUM — Receipt posting discards each line's `unit_value` → valuation undercount
`goods_receipts.ex:416` calls `receive_quantity` without `:unit_value`, though lines carry it and
`total_value/0` skips `nil`-unit_value rows. First-time-received items contribute 0 to inventory
value. (Medium because valuation-from-count may be the intended source.) Confidence: medium.

### IMPROVEMENT-MEDIUM — Three inconsistent decimal parsers; `SupplierOrders.parse_decimal` zeroed comma-decimals → ✅ fixed
`StockLedger.to_decimal("1,5") = 1.5`, `InternalOrders.parse_decimal("1,5") = 1` (partial-match
truncation), `SupplierOrders.parse_decimal("1,5") = 0` (`supplier_orders.ex:676`, strict — any
trailing chars zero the whole value). A comma-formatted required quantity flowing into
generate/import was silently dropped or truncated.
- **✅ Fixed in this review:** both `SupplierOrders.parse_decimal/1` and
  `InternalOrders.parse_decimal/1` now delegate to the shared, comma-aware
  `StockLedger.to_decimal/1` instead of their own local `Decimal.parse/1` wrappers — all three
  call sites now parse `"1,5"` identically. Confidence: high (mechanical consolidation onto an
  already-used, already-tested function).

### IMPROVEMENT-MEDIUM — Whole-table scans in memory
`committed_quantities.compute/4` loads all non-deleted rows of a schema; `supplier_orders.received_summaries/1`
loads *all* posted goods receipts to summarize one order; list LVs re-query the full dataset on
every debounced search/sort/filter event. Correct, but O(all-rows) per action. **Fix:** filter in SQL;
cache the base dataset in an assign and filter in memory. Confidence: high.

### IMPROVEMENT-MEDIUM — Index "Warehouse (location)" column renders the raw `location_uuid`
`goods_receipt_index_live.ex:505/522`, `goods_issue_index_live.ex:518/541` — default-visible column
shows a UUID, not a resolved name. **Fix:** batch-resolve location names in the enrichers. Confidence: high.

---

## Low / nitpick (batched)

- **Systemic — `String.to_integer(params["index"])`** in every form LV (`set_*_qty`, `remove_line`) raises
  `ArgumentError` on crafted non-integer input, and a negative index edits/deletes the wrong line via
  `List.update_at/delete_at`. Only reachable by a non-cooperating client. Use `Integer.parse/1` + bounds check.
- **`counted_quantity` not clamped at the post boundary** (`inventories.ex:329`); `on_conflict {:replace…}`
  bypasses the changeset `>= 0` check for existing rows. Backstopped by the V140 `quantity_non_negative`
  CHECK, so the real failure mode is an unhandled `Postgrex.Error`, not silent negative stock. Clamp at the boundary.
- **`open_link_picker`** `case` (`goods_receipt_form_live.ex:330`, `goods_issue_form_live.ex:399`) has no
  catch-all → `CaseClauseError` on a crafted `kind`. Add a fallthrough.
- **`repost_document`** (`inventories.ex:270`) omits the `FOR UPDATE` status CAS that `post_document` uses.
- **No line-level quantity validation** in `SupplierOrder`/`InternalOrder` changesets (`lines` is `{:array,:map}`).
- **`view_configs.merge_view_config/3`** can exceed core's 1000-char setting `value` cap → save silently rejected
  with a generic flash; surface the real error or use a JSON path.
- **`activity_log.log/2`** rescue won't un-poison an Ecto transaction — safe today (all callers post-context),
  latent if ever called inside a transaction.
- **`storage_folders.ex:137/154`** hard `{:ok,_}=` match and `folder.uuid` on a possible `{:ok, nil}` — narrow races.
- **`warehouse_browser.count_sheet`** groups render in map-hash order (inconsistent with `stock_sheet`'s sort).
- **Receipt `previous_quantity` audit read** uses the non-transactional repo (`goods_receipts.ex:385`) while issues
  use the tx repo — audit-only, harmless, but asymmetric.
- **Doc drift:** `source_kinds.ex` moduledoc says `source_refs` is keyed `"kind"` but the persisted column uses
  `"type"` everywhere (the code is consistent; only the doc is wrong); `column_config/internal_orders.ex` moduledoc
  omits `sub_order_*`/`note`. Leftover **`Andi.*`** references (the source app) remain in several comments/docs.

---

## Verified clean (not exhaustive)

Transactional posting with `FOR UPDATE` + status CAS (no double stock application); additive receive (+) /
guarded conditional issue (−) with all-or-nothing rollback; soft-delete gated to drafts (no missing reversal);
no `String.to_atom`/`to_existing_atom` on user input anywhere; column/filter keys whitelisted via `MapSet`
membership; sort keys validated against the column metadata map; comment scoping per-document and gracefully
degrading when `PhoenixKitComments` is absent; display-only components with no queries/subscriptions; N+1 avoided
via batched preloads (`list_items_by_uuids` preloads `[:catalogue,:category,:manufacturer]`, verified); `handle_info`
catch-alls present; `enabled?/0` rescues and `catch :exit`s; `module_key`/`version/0`/`admin_tabs` consistent and complete.

---

## Release recommendation

**Releasable** once the fixes in this review are merged — the former blocker (core pin) is
cleared: warehouse tables exist in published core 1.7.182. Before the module is used against
real stock, the remaining high-severity **domain** bugs need the author's judgment call:
stocktake absolute-SET clobbering and the generate-order double-count turn on intended
semantics I don't have enough context to decide unilaterally. Everything mechanical/contained
was fixed here — see below, and see **Testing limitations** before merging.

## Fixes applied in this review

1. **Core pin** `~> 1.7` → `~> 1.7 and >= 1.7.182` (+ comment); `phoenix_kit` bumped
   1.7.179 → 1.7.182 in `mix.lock` (transitive patch bumps to `ecto`/`plug`/`postgrex`/`saxy`/
   `mdex_native` came along for the ride; no other pin changed). *Was the release blocker.*
2. **`mix.exs` `lazy_html` test dep removed** — conflicted with the locked `elixir_make
   0.10.0` and broke `mix deps.get` outright; this project's tests use `fresco` instead.
   *(Applied in an earlier pass of this session, before the fan-out review; noted here for
   a complete record.)*
3. **`test/test_helper.exs`** — guarded the unguarded `System.cmd("psql", …)` call in a
   `try/rescue`, falling back to the existing connection-probe path. Without this, the
   *entire* suite crashed with `:enoent` on any machine without the `psql` **client**
   installed (distinct from "no database reachable", which the helper already handled) —
   this is what was silently producing a false "0 failures" from 0-tests-run in this
   environment before the fix.
4. **`internal_order_form_live.ex`** — `source_picker_select_all`: `c.type` → `c.kind`
   (candidates from `SourceKinds.search_candidates/1` have no `:type` key; this crashed
   the LiveView with `KeyError` on every click — an existing, previously-`:integration`-tagged
   test at `internal_order_form_live_test.exs:302` already covers this and had never run
   against a database in CI/this environment).
5. **`doc_refs.ex` `refs_for/1`** — added a fallback clause delegating any source-ref
   `"type"` outside the fixed 6-value whitelist to `resolve_or_plain/3` (mirrors the
   `"order"`/`"sub_order"` handling), so host-registered custom `SourceKinds` render instead
   of silently vanishing.
6. **`update_draft/2` in all 5 document contexts** (`goods_receipts`, `goods_issues`,
   `inventories`, `supplier_orders`, `internal_orders`) — converted from an in-memory
   status pattern-match to an `Ecto.Multi` reusing each context's existing
   `lock_status_step/3` (`FOR UPDATE` + DB-side status re-check), closing the stale-tab
   overwrite race. `correct_*` functions were deliberately left alone (see finding above).
7. **`mount/3` → `handle_params/3`** in all 8 flagged LiveViews (6 index views + 2 stray
   form-view reads), plus `StockLive`'s double `build_stock_items()` call collapsed to one
   per `handle_params`. Event-handler re-query behavior (search/sort/filter) is unchanged.
8. **Decimal parsers** — `SupplierOrders.parse_decimal/1` and `InternalOrders.parse_decimal/1`
   now delegate to the shared, comma-aware `StockLedger.to_decimal/1` instead of their own
   stricter/truncating local parsers.

**Left for the author** (documented above, needs domain judgment or is lower-priority):
stocktake seeding/absolute-SET, generate-order `source_refs` netting, the related
`goods_issue_form_live.ex:447` `:type`/`:kind` nil (same family as #4 but behaviorally
different — needs the author's call on which candidate source is authoritative), UUIDv7
primary keys, activity-log value capture, receipt `unit_value`, `issue_quantity`
prefix-safety, whole-table re-scans per search/sort event, and the batched nitpicks.

## Testing limitations (read before merging)

This review environment has **no PostgreSQL server** (client tools absent too, no
`docker`, no package-manager access to install one). Consequences:

- All **516 `:integration`-tagged tests** (LiveViewTest, context tests hitting the DB) were
  **excluded** every run — including the pre-existing `select_all` regression test that
  covers fix #4, and everything that would exercise fixes #6/#7/#5 end-to-end.
- Only the **33 pure-unit tests** ran (schema/changeset-shape, `Paths`, gettext, behaviour
  compliance) — 0 failures, both before and after every fix in this review.
- `mix compile --warnings-as-errors`, `mix format --check-formatted`, and `mix credo --strict`
  all ran for real and are clean (credo: same 238 pre-existing style/design items as the
  unmodified baseline, zero new ones). `mix dialyzer` ran for real, both before and after this
  review's changes — **identical set of 10 pre-existing warehouse-specific warnings both times**
  (each `call_without_opaque` on `lock_status_step`'s own `lock: "FOR UPDATE"` construction
  shifted by exactly the line count this review inserted above it in that file; the
  `pattern_match_cov`/`guard_fail` ones are in files this review never touched). Zero new
  findings, zero resolved.

**Before merging: run `mix test` (and ideally `mix precommit`) against a real Postgres.**
The mechanical fixes (#3–#8) were verified by careful code reading and successful compilation,
following established patterns already correct elsewhere in this codebase (the form
LiveViews' `mount`/`handle_params` split, the posting paths' `lock_status_step` CAS) — but
they have **not** been exercised by the integration suite that specifically covers this
behavior. Treat them as "compiles and reads correctly," not "verified against real database
behavior," until CI (or a local Postgres) confirms it.
