# PR #46 — Use neutral host-application wording; one Estonian term

**Reviewed:** 2026-10-22 · **Author:** timujinne · **Verdict:** merged; no
findings.

## What landed

Comments, moduledocs, plan documents and test-support docs that named the
application this module was extracted from now say "the host application"; one
Estonian string uses `sisetellimus`.

## Checked and found sound

- The `lib/` hunks are comments and `@doc` text only (`column_config.ex`,
  `comments.ex`, `internal_orders.ex`, `inventories.ex`, `storage_folders.ex`,
  `view_configs.ex`, the components, the LiveViews): no code, no msgid moved.
  The `test/` hunks are comments, support-module docs and two test
  *descriptions* (a table name written as the host's; now the real
  `phoenix_kit_warehouse_stock`). The one test-support path (`/admin/andi/warehouse/...` in the router and
  endpoint docs) is corrected to the real `/admin/warehouse/...`.
- A repo-wide search for the old name finds nothing left outside the historical
  review documents.
- It also edited `1-warehouse-module/CLAUDE_REVIEW.md` (a past review) - the
  same wording change, harmless.
