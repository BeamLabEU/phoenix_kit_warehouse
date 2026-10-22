# PR #47 — Preview supplier orders before generating them from an internal order, and fill the existing draft

**Reviewed:** 2026-10-22 · **Author:** timujinne · **Verdict:** merged; one
query narrowed.

## What landed

`SupplierOrderPlan` (supplier of every line and why, the quantity still to
order = required − issued − on hand − already ordered for this order, a
fingerprint of it all, `assemble/2`, `merge_into/3`), `SupplierOrders.apply_plan/5`
and a rewritten `generate_from_internal_order/3` — one writing path, under the
internal order's advisory lock and the row locks of its live supplier orders,
that appends to the live draft a supplier already has for the order instead of
trashing and replacing it; `draft_version/1` and `expected_version:` on the
draft writes so a form opened before an append cannot wipe it; the preview
window (`Web.SupplierOrderPreview`, `SupplierOrderPreview` component); import
uses the same supplier rules. Four locales.

## Findings

### IMPROVEMENT - MEDIUM: the plan read every posted goods receipt, under the locks — fixed

`SupplierOrderPlan.in_transit_for/2` calls `SupplierOrders.received_summaries/1`
for the posted supplier orders of the internal order. That function loaded
*every* posted, live goods receipt (with its JSON lines) and filtered in Elixir.
Before this PR it ran when a page showed one order's receipts; now it runs each
time the preview opens and again inside `write_plan/3`, while the advisory lock
and the row locks are held — a table that only grows, read whole, on the
hot path that serialises the generation.

Fix: the query is narrowed in the database to the receipts that can count — the
primary `supplier_order_uuid`, or a `source_refs` entry `@>` the order — and
`matching_supplier_order_uuids/2` still decides what counts, so the result is
identical. Test: `supplier_orders_test.exs` ("counts a receipt by its primary
order and by a secondary supplier_order ref, and no other").

## Checked and found sound

- **Locking**: `write_plan/3` takes the advisory lock of the internal order,
  re-reads the order, locks its live supplier orders in uuid order, builds the
  plan from those locked rows and compares the fingerprint *there*; `import` takes
  the same advisory locks (uuid order) before the row, so the two never wait in
  a circle. A stale plan returns `{:stale, new_plan}` and writes nothing; a
  choice the plan does not allow returns `{:invalid_choice, key}` before any
  write.
- **The window shows what is written**: it is drawn from `assemble/2` of the
  same plan and choices that `apply_plan/5` re-assembles; `restale/2` keeps a
  choice only when its line still exists, can still be chosen and still allows
  that supplier, and marks the lines that moved.
- **Appending**: the target is the locked row the plan was built from;
  `shortfall_quantity` follows `ordered_quantity` as documented; a combined
  draft's ref without `"lines"` stands for the whole draft and is left as it is
  (`whole_document_ref?/3`, also applied in `import` and in the goods-issue
  import), so the next plan does not order the rest again.
- **Versions**: `draft_version/1` goes through JSON, so the struct a write
  returns and the row read back hash alike; the form keeps the version with the
  buffer (never from `@order`, which a tab switch re-reads) and refuses a
  versioned event on a form that has none; Post saves, then posts on *the
  version the save wrote*. Every order the form loads gets a version with its
  buffer, posted ones included, so Remove-link and the like keep working on them.
- **Supplier choice**: a primary link that does not resolve to an active
  supplier is not silently skipped (`primary_issue`), an ambiguous line is never
  auto-assigned (preselected from an existing draft only as a default a person
  can change), and the manufacturer's suppliers and CRM projections are
  deduplicated. A posted or trashed document is never a target.
- All four `.po` files updated; the removed confirmation text is gone from them.

## On record

- `list_replaceable_drafts/1` has no caller in `lib/` any more (generation does
  not trash). It is a public function with tests; left as it is.
- `generate_from_internal_order/3` still accepts `supersede_drafts:` and ignores
  it, documented in the moduledoc; a caller that relied on the trash must now
  restore with `swap: true` instead.
