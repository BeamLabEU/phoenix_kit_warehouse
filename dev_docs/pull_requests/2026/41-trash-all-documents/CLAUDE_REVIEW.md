# PR #41 — Move to trash for every warehouse document, and the trash for receipts, issues, stocktakes and transfers

**Reviewed:** 2026-10-22 · **Author:** timujinne · **Verdict:** merged; no
findings.

## What landed

`DraftTrash.trash_one/3`, `restore_one/2` and `lock_status_step/4` (the shared
locking step, which answers `:deleted` for a trashed draft); `soft_delete` /
`restore_*` and the `trashed: true` list option for goods receipts, goods
issues, stocktakes and transfers; `TrashActions` (the three events behind a
confirmation, restore, and what a form does while its document is in the
trash), the `TrashAction` / `TrashTabs` components, and a trash view on each
list and a banner on each form. Four locales.

## Checked and found sound

- **Draft-only is enforced twice**: on the locked row (to answer the right
  error) and again in the `trash_ids/3` update, so the move stays draft-only
  even if the first clause is lost. The status is read from the database, not
  from the caller's struct, so a draft posted or shipped in another tab is not
  trashed from a stale struct.
- **The kind comes from the LiveView, never from the browser**; only the uuid
  does, and it is cast first (a malformed one is "not found", not a query
  error).
- **A transfer in transit that sits in the trash** (older code) can still be
  received or cancelled: the form only refuses Cancel/Receive for a trashed
  *draft*, and `lock_status_step/4` does not check the trash for other
  statuses. Otherwise its goods would stay on the road.
- **Trashed documents stop counting**: the quantity readers filter on
  `deleted_at` (`CommittedQuantities.compute`, the supplier-order and
  goods-receipt readers). A restored goods issue that overcommits an internal
  order restores anyway and says which order.
- Every write that is not gated to drafts (`add_source_ref`,
  `remove_source_ref`) goes through `update_unless_trashed/3`, which reads the
  trash from the locked row.
- Activity entries are written after the commit; all four `.po` files carry
  the new strings with translations (no empty `msgstr`, nothing fuzzy).

## On record

- There is no separate permission for the trash: whoever may open a list or a
  form may move a draft to the trash and restore one (stated in the
  `TrashActions` moduledoc). That is now true of all six document kinds, not
  two; not changed here.
