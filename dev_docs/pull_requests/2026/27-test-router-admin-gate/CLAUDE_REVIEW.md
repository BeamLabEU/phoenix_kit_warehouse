# PR #27 — Fix the test router's admin gate and the fixture ordering it hid

**Reviewed:** 2026-09-11 · **Author:** timujinne · **Verdict:** merged, no
further changes needed.

## What actually landed

`test/support/test_router.ex`'s `live_session :warehouse_test` was wired to
`{PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}` — the public
on_mount that only resolves `phoenix_kit_current_scope` and denies nobody.
Every real deployment routes plugin admin tabs (this module's included,
via `PhoenixKit.ModuleDiscovery` + `PhoenixKitWeb.Integration.generate_admin_routes/1`)
through the single core `live_session :phoenix_kit_admin`, gated by
`{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}`. Confirmed against
`deps/phoenix_kit/lib/phoenix_kit_web/users/auth.ex` (lines ~583, ~709): the
two hooks are genuinely different — `:phoenix_kit_ensure_admin` redirects a
confirmed-but-permission-less scope before the LiveView mounts,
`:phoenix_kit_mount_current_scope` never denies. The old moduledoc's claim
that they were "the same real, production on_mount" was wrong; the PR
corrects both the code and the doc.

Fixing the router surfaced a latent fixture-ordering bug: several tests
called `create_regular_user()` (or `ship!/4`, which registers its own actor)
*before* `create_admin_user()`. `Auth.register_user/2` → `Roles.ensure_first_user_is_owner/1`
makes the first user ever registered in the sandboxed transaction an Owner,
and `Roles.promote_to_admin/1` (what `create_admin_user/0` calls) only
assigns the Admin role — it does not seed baseline permission rows. So a
"regular" user created first was silently an Owner, and an "admin" created
after the actor already took the Owner slot ended up with zero permissions.
Both bugs canceled out under the old, gate-less router; fixing the gate
alone would have made every one of these tests fail for the wrong reason.
The PR reorders `create_admin_user()` to run first in each affected test,
and rewrites the "non-admin sees an info banner" test (which asserted a
successful read-only render) to assert the real production behavior — a
redirect (`{:error, {:redirect, _}}`) — since the route is admin-gated with
no separate lower-bar live_session.

## Review

Read the diff against `deps/phoenix_kit`'s actual on_mount implementations
and `Roles` module rather than taking the commit message at face value; the
technical claims check out. No BUG or IMPROVEMENT findings — this is a
correctness fix to the test harness with no production code touched, and
the added comments correctly explain *why* the ordering matters (not just
that it does), which will save the next person from reintroducing the same
silent-Owner bug.
