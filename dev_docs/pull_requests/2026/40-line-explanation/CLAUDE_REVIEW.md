# PR #40 — Carry and show a line's explanation (internal → supplier orders)

**Reviewed:** 2026-10-21 · **Author:** timujinne · **Verdict:** merged; no
findings.

## What landed

`PhoenixKitWarehouse.LineExplanation` (get / merge / put / carry / merge_into
for the optional `"explanation"` key of a line), used when internal-order lines
are merged on import, when supplier-order lines are built from an internal
order (`build_enriched_line/4`) and merged (`merge_enriched_lines/2`), and a
collapsible "Why" block (`LineExplanations`) on both forms. Strings in four
locales.

## Checked and found sound

- **Every place that builds or rewrites a line was checked** for dropping the
  key: `set_required_qty`, `set_ordered_qty`, `add_reserve` and `save_draft`
  only `Map.put` onto the existing line map, so the explanation survives edits
  and saves. The two literal-map builders (`build_enriched_line`,
  `merge_enriched_lines`) were the ones that would have lost it and are the
  ones changed.
- **Merging is idempotent.** Paragraphs are de-duplicated, so importing the
  same source twice does not repeat text; a non-binary value is treated as
  "none" and never crashes a render.
- **Rendering escapes the text** (HEEx) and only uses `whitespace-pre-line`
  for the paragraphs; the block renders nothing without an explanation, so a
  host that never sets one sees no change.
- The "quantity logic" text matches the generation it describes (requirement
  minus on-hand, `build_enriched_line/4`); the import-side sentence of that
  text was not traced.
- All four `.po` files carry the new entries with translations (no empty
  `msgstr`).
