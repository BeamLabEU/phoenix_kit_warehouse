# PR #35 — Add Ukrainian (uk) translation

**Reviewed:** 2026-10-11 · **Author:** timujinne · **Verdict:** merged; the
catalogue was 15 entries short, fixed post-merge.

## What landed

`priv/gettext/uk/LC_MESSAGES/default.po` (313 entries), a `uk_locale_test.exs`
(no extra msgids, no empty / fuzzy msgstr, placeholders preserved, plural rule
of the header, live lookups) and the locale list in `gettext_test.exs`.

## Findings

### BUG - MEDIUM — 15 msgids of #33 and #34 were never translated (fixed)

The catalogue was cut before the two PRs merged the same day: 313 of the
328 `default.pot` msgids. Those 15 are the setup notice, the goods issue
reason / external ref strings and the "set the default warehouse" flash, so a
Ukrainian user saw the new Warehouse pages half in English. The new test
suite could not notice, because it only checked the *subset* direction
(`uk ⊆ pot`) and "no empty msgstr" — a missing entry is neither.

**Fix:** the 15 entries are added, with the catalogue's existing wording
(«розташування» for locations, «склад за замовчуванням», «проведено»). New
test `translates every msgid of default.pot` pins the other direction.

### NITPICK — Not run through `gettext.merge`

The new entries were appended by hand rather than via `mix gettext.extract
--merge`, because that rewrites the reference comments of every catalogue
(about 1,900 lines of churn). `mix gettext.extract --check-up-to-date`
already reports `default.pot` as stale for that reason alone (line-number
references), which predates this PR.
