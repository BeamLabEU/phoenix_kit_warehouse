# PR #39 — One draft per source for internal and supplier orders, and a trash view

**Reviewed:** 2026-10-21 · **Author:** timujinne · **Verdict:** merged; no
bugs found. The locking holds up; two nitpicks left on record.

## What landed

- `InternalOrders.replace_draft_for_source/3`, `SupplierOrders.generate_from_internal_order/3`
  with `supersede_drafts: true`, and `restore_*_order/3` with `swap: true`:
  they send the live drafts of the same source (internal order) or the same
  (internal order, supplier) pair to the trash, in one transaction, behind
  `config :phoenix_kit_warehouse, one_draft_per_source: true` (off by default).
- `DraftTrash` (shared locking and the move itself), `soft_delete_*` now
  locking the row, `update_unless_trashed/2` for the metadata writes, and
  `{:error, :deleted}` from the draft writers.
- A "Trash" tab on both list pages, a read-only banner + Restore button on a
  trashed document's form, activity entries for trash and restore, and
  `TrashMessages` flashes.

## Checked and found sound

- **Lock order.** Every operation takes the advisory lock of the source (or of
  the internal order) first and the row locks after, rows in uuid order
  (`DraftTrash.lock_query/1`). A restore locks its own (trashed) row first, but
  a replace never locks a trashed row (its query filters `deleted_at`), and two
  operations on one source are serialised by the advisory lock before either
  takes a row, so there is no cycle. A combined draft touched by two sources is
  locked in the same global uuid order by both.
- **Stale reads.** `trash_ids/3` repeats `status = 'draft' AND deleted_at IS
  NULL` in the UPDATE, so a draft posted between the lock and the move is
  skipped, and the caller logs only what really moved. Restore re-reads the
  row under the lock and drops the swap if its source changed.
- **What is never trashed.** Posted documents, combined drafts (more than one
  distinct source) and refs of an unreadable shape are kept
  (`only_source/3`, `only_internal_order/2`), which is the safe side: a wrongly
  trashed combined draft would destroy the demand of its other sources.
- **Trash releases quantities.** `CommittedQuantities.compute/5` filters
  `deleted_at`, so a superseded draft stops counting as "already ordered";
  `DocRefs` also filters trashed rows from the related-documents lists.
- **Stale tabs.** The form's `@trash_blocked` events reload the order and only
  then decide, and every writer that can answer `{:error, :deleted}` is
  handled in both forms (`trashed_meanwhile/1`).
- Activity is written after the commit and never inside the caller's
  transaction by design (documented on each function).
- Gate: the new files compile with `--warnings-as-errors`; full suite green.

## Findings

### NITPICK — A restore with the switch on trashes other live drafts without asking

`generate_supplier_orders` shows a `data-confirm` naming the drafts that may
move; the Restore button (list and form) does not, although with
`one_draft_per_source` on it can send a live draft someone is editing to the
trash. Left as is: the flash afterwards names the documents, the move is
recoverable from the same Trash tab, and a confirm on a restore would make the
common case (nothing to swap) noisier. If users report lost edits, compute the
swap candidates for the confirm the way `replaceable_drafts/1` does.

### NITPICK — The generation confirm is a hint, not a promise

`list_replaceable_drafts/1` runs when the form loads and without locks, so a
draft made in another tab afterwards is trashed without being named in the
dialog. The function's doc says exactly this, and the real decision is made
under the lock; recorded here so it is not mistaken for a bug.
