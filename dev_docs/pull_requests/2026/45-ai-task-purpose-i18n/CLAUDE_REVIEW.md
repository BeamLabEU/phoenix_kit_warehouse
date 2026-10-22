# PR #45 — Translate the inventory AI task's purpose on the AI Tasks page

**Reviewed:** 2026-10-22 · **Author:** timujinne · **Verdict:** merged; no
findings.

## What landed

`Guard.purpose/0` returns the purpose text through `dgettext_noop/2` (a msgid,
like `label/0` beside it), and the `TaskSpec` takes it from there instead of an
inline concatenated string. The text is in the `.pot` and all four locales.

## Checked and found sound

- The `TaskSpec` already carries `gettext_backend: PhoenixKitWarehouse.Gettext`,
  so the AI Tasks page translates the msgid with this package's backend;
  prompts keep the English text, as the comment says.
- `purpose/0` sits outside the compile-time `if Code.ensure_loaded?(...)`, so
  extraction keeps the msgid whatever `phoenix_kit_ai` this is built against.
- The string is now one literal (the inline version was joined with `<>`), so
  extraction sees the msgid whole; the new `guard_test` asserts that the label
  and the purpose each have a translation in `et`, `ru` and `uk`.
