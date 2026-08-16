# PR #18 — Scope the row-link overlay to its row, and give permission labels a gettext backend

**Reviewed:** 2026-08-16 · **Author:** timujinne · **Verdict:** merged, one
test-coverage gap fixed.

## What actually landed

The merge title mentions two things, but the merge diff (`d08e12c..2a15cc5`)
only touches `lib/phoenix_kit_warehouse.ex` and the gettext catalogues — the
row-link-overlay fix (`0249674`/`d932606`, the Safari/iPad `<tr>` hit-testing
bug) had already reached `main` via an earlier PR (#8 merge, `29e7a48`), so
this branch's own copy of that fix was a no-op relative to `main`. Nothing to
review there; it's a stale merge-commit title, not a regression.

The real change: `use Gettext, backend: PhoenixKitWarehouse.Gettext` plus a
new `translatable_labels/0`, which calls `dgettext_noop/2` on every label
`permission_metadata/0` and `admin_tabs/0` declare, so `mix gettext.extract`
has *something* in this file to find their msgids in. Without it, the eight
admin-tab labels were only in `default.pot` by coincidence — they happen to
match strings `Web.WarehouseHeader` and `Web.TurnoverReportLive` already
extract, per the function's own moduledoc.

## Verification

- **Coverage cross-check** (by hand, since nothing enforced it — see below):
  every tab/metadata entry that sets `gettext_backend:` — the 7 sidebar tabs
  in `admin_tabs/0`, the `:warehouse_settings` tab in `settings_tabs/0`, and
  `permission_metadata/0`'s `label`/`description` — has its string covered by
  `translatable_labels/0`. `hidden_crud_tabs/0` correctly has no entries
  pinned, since none of those tabs set a `gettext_backend` in the first
  place.
- **`.pot` diff is real, not drift**: ran `mix gettext.extract` against a
  clean tree — it only reshuffles `#:` line-number references (pre-existing
  skew from unrelated line-count changes elsewhere), zero `msgid` lines
  added or removed. The one genuinely new catalogue entry
  (`"Warehouse stock, stocktakes, and document management"`) matches the PR's
  diff exactly; the other eight strings were already present, confirming the
  moduledoc's "already there by coincidence" claim.
- `mix precommit` — clean (format, compile --warnings-as-errors,
  deps.unlock, hex.audit, credo --strict, dialyzer).
- `mix test` — 781 tests, 10 pre-existing failures in
  `goods_issues_test.exs`/`goods_receipts_test.exs`
  (`add_source_ref/3` rejecting `"order"` with `:invalid_ref_type`),
  reproduced identically on `main` before this PR's changes. Unrelated to
  gettext/source_kinds; out of scope here, flagged for separate follow-up.

## IMPROVEMENT - MEDIUM (fixed)

`translatable_labels/0`'s whole purpose, per its own moduledoc, is to survive
someone rewording `WarehouseHeader`/`TurnoverReportLive` without a compile
error or failing test. But nothing tested `translatable_labels/0` itself —
if a future tab gained a `gettext_backend` and its label was never added to
the pinned list, nothing would catch it; the exact silent regression the
function exists to prevent. Added two tests to
`test/phoenix_kit_warehouse/gettext_test.exs` that re-derive the declared
label set from `admin_tabs/0`/`settings_tabs/0`/`permission_metadata/0` and
assert each is present in `translatable_labels/0`.
