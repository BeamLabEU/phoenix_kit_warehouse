# PR #15 — Update the phoenix_kit ceiling to `< 3.0.0`, matching the sibling modules

**Reviewed:** 2026-08-10 · **Author:** timujinne · **Verdict:** **not merged —
superseded.** Its intent is delivered in **0.3.0** by a different pin.

## Why it was not merged

The diagnosis is right and matches core's own 2.0.0 CHANGELOG: `~> 1.7.231`
expands to `>= 1.7.231 and < 1.8.0`, so no core 2.x satisfies it and a host on
`{:phoenix_kit, "~> 2.0"}` plus this module is an unsolvable dependency set.

Two things made merging the diff itself the wrong move:

1. **The umbrella-wide decision for this sweep is a 2.0-only `~> 2.0`**, not a
   range spanning both majors. Requiring core 2.0 rather than merely tolerating
   it is the point — this module is only verified against the squashed-migration
   baseline. The same call was made for the two sibling PRs proposing the same
   widening (`phoenix_kit_customer_support#6`, `phoenix_kit_emails#29`), both of
   which *were* merged because they carried other work; this one is a
   single-hunk pin change with nothing else to preserve.
2. **It conflicted.** By the time this repo came up in the release order, its
   sibling pins had already been raised to the tier-0/tier-1 minors, and PR #15
   edits the same `deps/0` region. Resolving the conflict would have meant
   discarding its hunk anyway.

## What landed instead

`pk_dep(:phoenix_kit, "~> 2.0")`, carrying the PR's reasoning forward in the
comment — including the trap it was written about, retargeted at the version
that now applies: keep it a **two-segment** `~> 2.0`, because `~> 2.0.x` expands
to `< 2.1.0` and reproduces against core 2.1 exactly the failure `~> 1.7.231`
had against core 2.0.0.
