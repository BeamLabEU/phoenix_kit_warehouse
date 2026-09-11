# PR #28 — Catch the module identity tests up with the UI pass

**Reviewed:** 2026-09-11 · **Author:** timujinne · **Verdict:** merged, no
further changes needed.

## What actually landed

PR #26 ("Warehouse UI pass") added a `:warehouse_stock` subtab (label
"In stock"), two inventory columns (`created_by`, `performed_by`), and
changed the root `:warehouse` tab's `match` from `:exact` to `:prefix` (so
the section stays highlighted while any subtab is open — the bare
`/admin/warehouse` path is now claimed by `:warehouse_stock`'s own regex
match). None of that was reflected in the three identity/config tests this
PR fixes, nor in `translatable_labels/0`.

- `test/phoenix_kit_warehouse_test.exs`: tab count 38 → 39 (verified via
  `mix run --eval` against `admin_tabs/0`: 39), and `root.match` assertion
  `:exact` → `:prefix` (verified against the actual `%Tab{}` literal).
- `test/phoenix_kit_warehouse/column_config/inventories_test.exs`:
  `all_column_ids/0` extended with `created_by`/`performed_by` (verified
  against `column_config/inventories.ex`, which defines both).
- `lib/phoenix_kit_warehouse.ex`: `"In stock"` added to
  `translatable_labels/0`. This function exists specifically to pin plain
  Tab-struct label strings that `mix gettext.extract` can't see (they're
  data, not `gettext()` macro calls) — confirmed `label: "In stock"` is one
  such literal, and confirmed it's genuinely rendered via `dgettext` at
  other call sites (`warehouse_header.ex`, `column_config/stock.ex`,
  `warehouse_browser.ex`), so the msgid needs to exist in this module's
  catalogue or the nav entry silently reverts to raw English.

## Review

Cross-checked `translatable_labels/0` against every `label:` string in
`admin_tabs/0` and `hidden_crud_tabs/0`. The ~28 hidden-CRUD-tab labels
("New Inventory", "Edit Transfer", etc.) are correctly *not* in the list:
those tabs are `visible: false` and never set `gettext_backend`/
`gettext_domain`, so they never go through translation and don't need
pinning. The PR's addition is complete for what actually changed. No BUG
or IMPROVEMENT findings in the PR diff itself.

## Gate fallout (not this PR — fixed in the same release pass)

Running `mix test`/`mix precommit` to validate #27+#28 for release surfaced
three pre-existing regressions, none caused by either PR, all from the
already-merged "lib upgrades" commit (4ef5f4c, a large dependency bump:
`phoenix_kit_catalogue` 0.18.0 → 0.28.5, core 2.13.6 → 2.22.17) landing
without anyone re-validating with the real exit code:

1. **BUG - CRITICAL (fixed).** `test/test_helper.exs` only ran core's
   `PhoenixKit.Migration.ensure_current/2`. Catalogue graduated to owning
   its own decentralized migration chain (`PhoenixKitCatalogue.Migrations`,
   discovered via `migration_module/0`) partway through that version range;
   its V2 (the per-language `slug` column) never got applied to the test
   DB, so every catalogue item insert failed with `column "slug" ... does
   not exist` — 144 of 813 tests. Fixed by adding
   `test/support/catalogue_migration.ex` (an `Ecto.Migration`-based wrapper,
   mirroring `phoenix_kit_crm`'s `PhoenixKitCRM.Test.SchemaMigration`
   pattern) and running it via `Ecto.Migrator.run/4` in `test_helper.exs`.
2. **BUG - MEDIUM (fixed).** `phoenix_kit_catalogue`'s `ItemSelectorModal`
   flipped `show_tray`'s default to `false` "since 2026-08-31" (its own
   moduledoc). None of this module's three embeds
   (`inventory_form_live.ex`, `internal_order_form_live.ex`,
   `transfer_form_live.ex`) passed it explicitly, so the cart-count/review
   tray silently disappeared from the item selector in all three forms —
   an actual UX regression, not just a test gap (caught by
   `inventory_form_live_comments_and_modal_test.exs`'s "preselects lines
   whose counted_quantity was stored as a JSONB string" test). Restored
   with `show_tray={true}` on all three embeds.
3. **BUG - MEDIUM (fixed).** `mix precommit` itself was failing
   (`credo --strict`, exit 8): six `ColumnConfig.*.columns/0` functions
   exceeded the configured cyclomatic-complexity ceiling (max 12) after
   the `created_by`/`performed_by` columns landed. This had gone unnoticed
   because every prior session (this one included, initially) checked the
   gate with `mix precommit | tail`, which reports `tail`'s exit code, not
   `mix`'s — the exact anti-pattern this project's own memory warns about.
   Fixed by extracting each column literal into its own named `defp
   *_column` function across all six `column_config/*.ex` files — pure
   code motion, no behavior change, confirmed by the still-green
   `all_column_ids/0` tests.

`mix precommit` and `mix test` (813 tests) are both green as of this pass.
See the sibling review doc for #27 for that PR's own findings (none).
