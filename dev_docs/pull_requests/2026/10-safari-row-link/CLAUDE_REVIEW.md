# Review: PR #10 — Fix row-link overlay escaping its row on Safari/iPad

- **Author**: timujinne (Timujeen)
- **Merged**: 622ec6c into main via 387b7a7, 2026-07-20
- **Files touched**: `goods_issue_index_live.ex`, `goods_receipt_index_live.ex`,
  `internal_order_index_live.ex`, `inventories_live.ex`,
  `supplier_order_index_live.ex`, `transfer_index_live.ex` (1 line each)

## Context

Each index LiveView renders its number-cell link with
`after:absolute after:inset-0 after:z-0` so the whole row is clickable
(e.g. `goods_issue_index_live.ex:475`). That overlay needs `position:
relative` (or another containing-block-establishing property) on the `<tr>`
to size to the row instead of escaping upward. Safari/WebKit does not honor
`position: relative` on `<tr>` — so on iOS/iPadOS the `::after` overlay
escaped to the `<table>`'s containing block, every row's overlay covered the
whole table, and the last-painted row won hit-testing for clicks anywhere in
the table. The fix adds Tailwind's `transform-gpu` utility
(`transform: translateZ(0)`) alongside the existing `relative` class on each
row — WebKit does honor a `transform` as a containing block on table rows.

## Verification

- Confirmed the bug mechanism is real and Safari-specific: `position:
  relative` on `<tr>` is a documented WebKit gap (table rows/cells are
  "internal table" boxes in CSS2.1 and older WebKit versions never made them
  positioned-element containing blocks), while `transform` establishing a
  containing block applies uniformly across engines per spec and is a
  standard workaround.
- Checked every other `table_default_row` call site in the repo for the same
  overlay pattern (`after:absolute after:inset-0`) to make sure the fix
  covers all affected rows and none were missed — a classic
  "list that must stay in sync" risk when a fix is applied file-by-file:
  - `stock_live.ex:703` uses `table_default_row class={["relative", ...]}`
    but has no `after:absolute` link in any of its cells — its rows aren't
    whole-row-clickable (only a per-row action button), so it correctly
    doesn't need the fix.
  - `turnover_report_live.ex` doesn't use the overlay pattern at all.
  - The six files this PR touched are exactly the six that define a
    `render_cell("number", ...)` clause with the overlay link. No file was
    missed.
- Checked whether adding `transform` to the `<tr>` could regress the
  per-row `⋮` action menu (`<.table_row_menu>`, rendered in a `w-12` cell
  next to the overlay link in every touched file) — a `transform` on an
  ancestor establishes a new containing block for `position: fixed`
  descendants too, which would matter if the menu relied on `fixed`
  positioning while still nested under the row. Read
  `table_row_menu.ex:126-131`: the menu's `<ul>` is `position: fixed` but is
  explicitly documented as portaled to `<body>` by the `RowMenu` JS hook
  while open ("so `position: fixed` escapes table containing blocks") — by
  the time it's actually displayed as `fixed`, it's no longer a descendant
  of the transformed `<tr>`, so this fix doesn't affect it.
- Checked for `table-pin-rows` / `table-pin-cols` (sticky) variants on the
  touched tables, since `transform` on a row can also break `position:
  sticky` containment — none of the six use a pinned variant (only
  `variant="zebra"` on a couple), so no sticky-positioning interaction.
- The `<.table_default_row>` component (`table_default.ex:527-555`) just
  passes `@class` straight onto the `<tr>` — no conflicting class or
  existing `transform-*` utility to collide with.

## Finding

None. The fix is correctly scoped (all six affected views, no extras and no
gaps), uses a standard, cross-engine-safe technique, and doesn't interact
badly with the row-menu portal or any sticky-table variant in this repo.

## Verification of the fix

No fix needed for this PR itself. Ran the project's `mix precommit` gate
against the full merged tree (covers PR #9, PR #10, this review's fixes,
and a stale `mix.lock` cleanup — see below):

- `mix compile --force --warnings-as-errors`: clean.
- `mix deps.unlock --check-unused`: found and removed one stale entry
  (`beamlab_ex_aws_sqs`, left over from the prior `phoenix_kit` 1.7.199 →
  1.7.205 bump renaming its dep key to `ex_aws_sqs`) — pre-existing,
  unrelated to PR #9/#10, now clean.
- `mix hex.audit`: clean ("No retired or security advisory packages found").
- `mix format --check-formatted`: clean.
- `mix credo --strict`: exits non-zero (2 refactoring, 41 readability, 248
  design suggestions), which aborts the `quality.ci` alias chain before
  `dialyzer` runs — but this count is byte-identical to the baseline
  recorded in `dev_docs/pull_requests/2026/6-junction-primary-fallback/CLAUDE_REVIEW.md`
  (run 2026-07-16). Pre-existing repo-wide baseline, zero new findings.
- `mix dialyzer` (run standalone since credo blocks the alias): initially
  showed **12** findings — one new one, `callback_type_mismatch` at
  `lib/phoenix_kit_warehouse.ex:114`, caused by PR #9's
  `gettext_backend`/`gettext_domain` addition (see PR #9's review doc for
  the full story — that addition was reverted here). After the revert,
  re-ran clean at **11** findings, byte-identical to the PR #6 baseline
  file:line-for-line. No findings in any file this PR (#10) touched.
