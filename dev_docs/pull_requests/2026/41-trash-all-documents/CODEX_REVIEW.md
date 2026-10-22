# PR #41 — Document trash: second review

Reviewed 2026-10-22 by Codex, against `a7d3e9a` including Claude's follow-up.
Author: timujinne. Merged 2026-10-21; included because it is the foundation of
today's photo inventory and part of the supplied review handoff.

No additional defects found in the trash changes. Checked the shared row locks
and draft-only predicates, restore behavior, source-reference writes, list
scopes, and the form's response to a document trashed from another tab. Legacy
in-transit transfers remain receivable/cancellable; posted documents cannot
be restored as drafts. The goods-issue overcommit warning retains its documented
legacy-reference approximation.

Shared validation results are recorded in
[`43-inventory-ai/CODEX_REVIEW.md`](../43-inventory-ai/CODEX_REVIEW.md).
