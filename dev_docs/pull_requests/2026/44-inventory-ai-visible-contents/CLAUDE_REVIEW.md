# PR #44 — Count the pieces seen through a bag, and items kept in packs in packs

**Reviewed:** 2026-10-22 · **Author:** timujinne · **Verdict:** merged; no
findings.

## What landed

`Counting`: `pack` leaves the piece units — an item kept in packs is counted in
packs (`closed + open × fill`, floored to 0.1) and never turned into pieces, and
a `pack` object with no packages needs the quantity typed; new `Counting.seen/1`
so a row that cannot be counted yet still shows what the model saw
(`Proposal.waiting_for_item/1`, `Review` and the panel use it); the prompt
template tells the model to count pieces seen through a bag and to give a
mixed bag one entry per kind; "Also possible:" lists the alternatives under a row.

## Checked and found sound

- The `pack` clause comes before the piece-unit clause, and `@piece_units` no
  longer holds `pack`, so no object reaches `by_package/5` with a pack unit;
  `count_all/3`'s "needs" ordering is unchanged.
- **Stored objects read back from jsonb** hold Decimals as text: `Counting.seen/1`
  goes through the same `number/1` coercion as `count/3`.
- **The changed template does not overwrite an edited prompt**: its previous
  text's sha is added to `@previous_templates`, and `Prompt.ensure/1` only
  rewrites a prompt of the module's own that still holds a shipped template.
- `Apply.basis/3` uses `Proposal.recount/3`, so the "how it was counted" text of
  an applied pack row follows the new rule.
- Tests cover the pack rows, `seen/1`, the proposal rows that wait for an item
  or a quantity, the prompt text and the panel; four `.po` files updated.
