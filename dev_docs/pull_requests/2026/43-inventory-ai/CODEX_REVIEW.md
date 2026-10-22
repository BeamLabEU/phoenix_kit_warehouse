# PR #43 — Photo stocktake: second review

Reviewed 2026-10-22 by Codex, against `a7d3e9a` including Claude's follow-up.
Author: timujinne. Merged 2026-10-22.

## BUG — HIGH: identical seed lines hide a warehouse change — fixed

`Inventories.fingerprint/2` hashed only `lines`. Switching a draft from warehouse
A to B with identical stock leaves identical seed lines (two empty warehouses
also reproduce it). A tab opened on A can then save its unsaved counts into B,
or conduct those counts against B's stock. Claude's save-to-post check does not
close this case because the fingerprint itself is unchanged. Opening a proposal
from B in the old tab can also persist A's unsaved buffer when Apply saves it.

Both fingerprint queries now hash the canonical database JSON array of
`location_uuid` and `lines`. The existing comparisons under the document lock
therefore refuse the old buffer for Save, Conduct, warehouse changes, and Apply.
The single-query read still returns the document and its corresponding base
together. No schema migration is needed; the field is virtual. Tabs holding
fingerprints from the old code must reload after a code upgrade.

Regression coverage:

- Context saves and posts after a warehouse change with unchanged empty lines.
- Two LiveViews on warehouses with identical nonempty stock: the old tab's Save
  and Conduct fail, and the new warehouse's draft/count remains intact.
- Applying a proposal from the new warehouse with the old warehouse's edit
  buffer fails without claiming the run or writing lines.

## BUG — MEDIUM: delayed warehouse cleanup can discard a new warehouse's run — fixed

The warehouse switch commits before the form closes the old photo runs. Another
tab can start a run for the new warehouse during that gap. The cleanup formerly
closed every running/proposed run of the document, including that new run: its
answer would be kept only as a discarded late result.

`close_open_runs/4` now supports `keep_location_uuid:`; the form passes its new
warehouse when cleaning up a warehouse change. Runs of the old warehouse close,
while running and proposed runs of the new one survive. Calls without that
option keep their original behavior, including closing every open run after
posting. `inventory_ai/lifecycle_test.exs` reproduces the interleaving through
the actual panel cleanup helper and checks all three statuses.

## Other checks

Rechecked run ownership, the compare-and-set transitions, retry and late-answer
handling, photo folder membership and conversion cleanup, proposal validation,
review merging and quantity rules, Apply's transaction and row checks, prompt
upgrade ownership, AI settings authorization, task declarations, and V3's
non-destructive migration behavior. Claude's posting fingerprint fix remains in
place. No additional issues found in these paths.

## Validation

The existing comment smoke test mentioned in the handoff reproduced its
load-sensitive failure in the isolated database: 266 ms against a 100 ms limit,
with all creation/count/removal assertions passing. Replaced the wall-clock
benchmark with explicit checks of the persisted resource, author, content, and
deletion, retaining the count assertions. ExUnit's normal timeout still catches
a hang. This is a pre-existing test reliability improvement, not a PR #43
production defect.

Five regression tests failed against `a7d3e9a` before the fixes, covering the
stocktake fingerprint and #47's omitted warehouse/source version fields. `mix precommit`
passes, including strict compilation, dependency audit, formatting, Credo, and
Dialyzer (the existing nine dependency warnings remain suppressed).

`MIX_TEST_PARTITION=_codex_review mix test` passed: **2,450 tests, zero failures**,
including database integration tests, in 410.9 seconds. Validation uses the
disposable `phoenix_kit_warehouse_test_codex_review` database to avoid fixture
locks from simultaneous sessions on the default test database.

The full-suite process started before the final cleanup change. Afterwards the
entire InventoryAI test directory and both photo-panel/stocktake-fingerprint
LiveView test files, plus the inventory context fingerprint tests, were rerun
against that final change: **363 tests, zero failures**, in 51.1 seconds. The
final `mix precommit` also passed after the cleanup change.
