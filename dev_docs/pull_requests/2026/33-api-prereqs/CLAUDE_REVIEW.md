# PR #33 — Goods issue reason, external_ref, create_and_post and module-declared source kinds

**Reviewed:** 2026-10-11 · **Author:** timujinne · **Verdict:** merged; one
medium locking gap fixed post-merge, three limitations left on record.

## What landed

- **Migration chain V2** — `goods_issues.reason` (`NOT NULL DEFAULT
  'production'`), `external_ref` on goods issues / receipts / inventory
  documents, and one partial unique index per table over posted, non-deleted
  rows. `down/1` keeps the columns and indexes (rows written under V2 survive
  a rollback). V2 only ADDS objects, so core's manifest needs no change.
- **`create_and_post/2`** on `GoodsIssues`, `GoodsReceipts` and `Inventories`
  (one transaction; validation before the INSERT so a refusal burns no
  document number; `{:ok, :already_posted, doc}` for a repeated
  `external_ref`, serialised by a transaction-scoped advisory lock).
- **Locking** — inventory posting reads and writes the stock rows under one
  `FOR UPDATE` (missing rows are first claimed with `ON CONFLICT DO NOTHING`);
  goods receipts write their stock rows in item order.
- **Module-declared source kinds** — `SourceKinds.list_kinds/0` merges the
  host config with `warehouse_source_kinds/0` of registered modules; a broken
  module is logged once and skipped.
- UI: reason select on the goods issue form, `reason` / `external_ref` list
  columns, a flash naming the `external_ref` when posting a draft collides
  with a posted one, and "Inventory new" bails out with a flash when no
  default warehouse is set.

## Checked and found sound

- The V2 DDL is idempotent (`ADD COLUMN IF NOT EXISTS`, `CREATE UNIQUE INDEX
  IF NOT EXISTS`), widths come from the schemas' `v2_column_widths/0`, and the
  index names match the `unique_constraint(..., name:)` in each
  `post_changeset/3`.
- `PostingSupport.create_and_post/3` does everything it can before the INSERT;
  the `:existing` → `:guard` → `:draft` → `:post` order in the Multi is right
  (advisory lock first, then the stock locks).
- Lock order is consistent between `check_stock/3` (`ORDER BY item_uuid`),
  `Inventories.locked_prior_stock/3` and `GoodsReceipts.receive_lines/4`: a
  Postgres `uuid` sorts bytewise, which is the lowercase hex string order the
  receipts use, and `Ecto.UUID.cast/1` canonicalises to lowercase first.
- The `"kind"` → `"type"` change in the `SourceKinds` moduledoc is a doc fix:
  every producer and consumer of `source_refs` uses `"type"`.

## Findings

### BUG - MEDIUM — A posted goods issue still locked its stock rows in line order (fixed)

`create_and_post/2` (via `check_stock/3`) and the receipts take their stock
locks in item order, and the PR's own comment in `Inventories` admits "a goods
issue posted from a draft still locks in its own line order". That is a
deadlock waiting for the first API caller: an API `create_and_post` holding
`x` then wanting `y` meets a UI post of a draft with lines `[y, x]` that holds
`y` and wants `x`. Postgres kills one of them with `40P01`, which surfaces as
a raised `Postgrex.Error` in a LiveView handler (or a 500 for the API).

**Fix:** `GoodsIssues.issue_lines/4` now writes the stock rows in item order,
exactly as `GoodsReceipts.receive_lines/4` does, and returns the audited lines
in the document's own order. New test: lines `[high, low]` keep their order,
carry the right `previous_quantity` each, and decrement the right rows.

### IMPROVEMENT - MEDIUM — `Inventories.repost_document/2` still posts a stale struct

`post_document/2` was changed to post "the lines and `track_value` of the row
read under the status lock, not those of the struct passed in".
`repost_document/2` runs the same body but on the struct in hand, with no row
lock on the document and no in-transaction `posted` check, so a stale tab can
re-apply old counts over a corrected document. It is pre-existing and the
repost entry point is admin-only, so it was left; the fix is the same
`lock_status_step("posted", :not_posted)` pattern.

### IMPROVEMENT - LOW — `unit_value` and negative issued quantities are unchecked on the plain paths

`create_and_post/2` rejects negative / blank / unparseable quantities, but a
line's `unit_value` is passed through unchecked ("as on the plain post path"),
and the plain draft path (`post_goods_issue/2`) still accepts a negative
`issued_quantity`, which `StockLedger.issue_quantity/3` turns into an increase
(see the PR #32 review). The API path is now stricter than the UI path; the
real fix is a guard in `issue_quantity/3` itself. Not changed here: it alters
a ledger primitive's contract and wants its own change.

### NITPICK — `:already_posted` does not compare lines

Documented, and the right call for idempotent delivery (the outside system
owns the reference), but a caller that re-sends a *corrected* document under
the same `external_ref` gets `{:ok, :already_posted, old}` and no signal that
the lines differ. Worth a sentence in the README's API section if it is not
there already.

## Validation

`mix precommit` clean (format, compile with warnings as errors, credo
--strict, dialyzer, hex.audit) and `mix test`: 1078 tests, 0 failures.
