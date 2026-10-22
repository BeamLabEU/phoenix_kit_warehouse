# PR #47 — Supplier-order preview: second review

Reviewed 2026-10-22 by Codex, against `a7d3e9a` including Claude's follow-up.
Author: timujinne. Merged 2026-10-22.

## BUG — MEDIUM: warehouse and primary source changes bypass draft versions — fixed

`draft_version/1` omitted `location_uuid` and `internal_order_uuid`, although the
draft changeset accepts both and the form shows them. Updating only the delivery
warehouse left the version unchanged. An old form could therefore post the
supplier order for a warehouse it had never displayed. The primary source had
the same omission. Both fields now participate in the version compared under
the row lock.

The plan fingerprint also omitted these fields on existing supplier orders and
relied on `updated_at` to notice them. That timestamp has second precision, so a
warehouse change within the same second could pass preview confirmation and
append to an order whose destination had changed. Both fields now participate
directly in the plan fingerprint as well.

Regression coverage extends the draft-version field checks, refuses a versioned
post after the delivery warehouse changes, and refuses preview confirmation
after a target's warehouse changes while its timestamp stays identical. No
schema migration is needed.

## Other checks

Traced supplier resolution and active CRM projections, issued/on-hand/in-transit
allocation, duplicate internal-order lines, target selection and append merging,
whole-document source refs, choice validation, preview reassembly and stale-plan
handling, advisory/row lock ordering, and the form's buffer version across tab
switches. Rechecked Claude's database narrowing of `received_summaries/1` against
primary and secondary references. No additional defects found in those changes.

The documented legacy whole-document reference attribution remains approximate;
this review does not introduce a new receipt-allocation policy.

Shared validation results are recorded in
[`43-inventory-ai/CODEX_REVIEW.md`](../43-inventory-ai/CODEX_REVIEW.md).
