# PR #14 — Add gettext keys to `permission_metadata` for the permissions-matrix label

**Reviewed:** 2026-08-10 · **Author:** timujinne · **Verdict:** merged, no
changes required. Released in **0.3.0**.

Adds the gettext keys core's permissions matrix reads for its label, so the
warehouse rows are translated rather than falling back to a raw key.
`test/phoenix_kit_warehouse/gettext_test.exs` (+28 lines) pins the metadata
shape — worth having, since a missing key here degrades silently into an
untranslated label rather than an error.

Verified: `mix precommit` passes against core 2.0.0; `mix test` 77 tests, 0
failures.
