# PR #13 — Update to `can_access_admin_area?` and float the core lock

**Reviewed:** 2026-08-10 · **Author:** mdon · **Verdict:** merged, no changes
required. Released in **0.3.0**.

Stops calling `PhoenixKit.Users.Auth.Scope.admin?/1`, which core renamed to
`can_access_admin_area?/1` in 1.7.214 and kept only as a `@deprecated`
delegate. Pure rename — the old name delegates to the new one, so no behaviour
changes; it silences a deprecation warning host apps were eating on every
compile with no way to fix it themselves. `phoenix_kit_ai` made the identical
change in its 0.17.1, so this is the ecosystem catching up.

Verified: `mix precommit` passes against core 2.0.0; `mix test` 77 tests, 0
failures (701 excluded — no Postgres available).
