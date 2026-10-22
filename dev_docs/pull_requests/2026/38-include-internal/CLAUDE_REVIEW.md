# PR #38 — Show internal-category items in the warehouse item pickers

**Reviewed:** 2026-10-21 · **Author:** timujinne · **Verdict:** merged; no
bugs found, one stale comment fixed.

## What landed

`include_internal={true}` on the `ItemSelectorModal` of the inventory,
internal order and transfer forms, plus a test that traces
`ItemSelectorModal.update/2` and reads the assigns each LiveView hands over.

## Checked and found sound

- **All three modal call sites are covered**; `rg 'module={ItemSelectorModal}'`
  finds exactly those three in `lib/`; no other module uses the modal.
- **The attr is the right one.** Catalogue 0.49 (what `mix.lock` holds)
  declares `:include_internal` on the modal and turns it into
  `Browse.put_internal_rule/2`; on an older catalogue the key is ignored and
  nothing was ever hidden, so the `~> 0.18` floor in `mix.exs` needs no bump.
- The test does not depend on the catalogue version (it reads the assigns
  passed in, not the modal's state), so it keeps failing if an attr is
  deleted from a form.

## Findings

### NITPICK — The test's moduledoc said the lock was on 0.48.1 (fixed)

The comment claimed the locked catalogue has no such rule. `mix.lock` has been
on 0.49.0 since the `libs` commit, where the modal honours the attr. The
assertion is still the right one (version independent); only the explanation
was out of date, and now says so.
