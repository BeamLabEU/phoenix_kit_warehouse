# PR #42 — Fix the Estonian spelling of sisetellimus

**Reviewed:** 2026-10-22 · **Author:** timujinne · **Verdict:** merged; no
findings.

Three `msgstr` lines in `priv/gettext/et/LC_MESSAGES/default.po` changed to
the one-word `sisetellimus`; no `msgid` moved, so the `.pot` and the other
locales are untouched. #46 later changed the one remaining
`sisemise tellimuse` string, so the term is now spelled one way throughout.
