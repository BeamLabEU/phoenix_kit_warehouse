# Review: PR #9 — Declare the gettext backend for the warehouse permission label

- **Author**: timujinne (Timujeen)
- **Merged**: d492278 into main via e9be07a, 2026-07-20
- **Files touched**: `lib/phoenix_kit_warehouse.ex` (5 insertions, 1 deletion)

## Context

`permission_metadata/0` supplies the `"Warehouse"` label rendered in the
admin permissions matrix. Every `admin_tabs/0` entry already declares
`gettext_backend: PhoenixKitWarehouse.Gettext` / `gettext_domain: "default"`
so the sidebar tab renders translated; this PR added the same two keys to
`permission_metadata/0`'s map, on the premise that the permissions matrix
would then translate the label the same way.

## Verification (initial pass — later found to be wrong)

The first verification pass traced `gettext_backend`/`gettext_domain`
through `/workspace/phoenix_kit` — a **separate local checkout** of core
that happened to be on the filesystem — and found `permission_meta()`'s
typespec, `ModuleRegistry.permission_gettext/0`, and
`Permissions.localized_module_label/1` all wired up correctly, concluding
the PR was a correct, minimal, no-issue change.

That verification checked the wrong tree. `PHOENIX_KIT_PATH` is **not** set
in this environment (`env | grep PHOENIX_KIT_PATH` empty), so
`phoenix_kit_warehouse` compiles against the real Hex-pinned dependency in
`deps/phoenix_kit`, not `/workspace/phoenix_kit` — the same mistake this
repo's own `dev_docs/pull_requests/2026/6-junction-primary-fallback/CLAUDE_REVIEW.md`
warned about for a different dependency. Re-checked against the actual
pinned tree:

- `mix.lock` pins `phoenix_kit` to **1.7.205**, published to Hex
  **2026-07-19T20:51:16Z**.
- `deps/phoenix_kit/lib/phoenix_kit/module.ex`'s `permission_meta()`
  typespec has **no** `gettext_backend` / `gettext_domain` keys — only
  `key`, `label`, `icon`, `description`, `sub_permissions`.
- `deps/phoenix_kit/lib/phoenix_kit/users/permissions.ex` has **no**
  `localized_module_label/1` (`grep` returns nothing), and
  `deps/phoenix_kit/lib/phoenix_kit/module_registry.ex` has no
  `permission_gettext/0`. Every call site that renders a permission label
  in the pinned dependency
  (`phoenix_kit_web/live/users/permissions_matrix.{ex,html.heex}`,
  `phoenix_kit_web/live/users/roles.html.heex`,
  `phoenix_kit_web/users/auth.ex:1224`) calls the plain, untranslated
  `Permissions.module_label/1` — never a localized variant.
- The feature this PR is meant to activate was added to core in local
  commit `253e69c8` ("Add localized permission labels to the admin
  permissions matrix", 2026-07-20 06:43 UTC) — **after** Hex's 1.7.205 was
  published (2026-07-19 20:51 UTC) and still unpublished as of this
  review. (By contrast, `admin_tabs/0`'s pre-existing
  `gettext_backend`/`gettext_domain` pairs on `%Tab{}` *are* real and
  functional against 1.7.205 — `Dashboard.Tab.localized_label/1` exists in
  the pinned dependency. Only the `permission_metadata/0` map is affected;
  this review didn't need to touch `admin_tabs/0`.)
- Consequence: against the dependency actually resolved and compiled
  today, `permission_metadata/0`'s two new keys are **inert** — no code
  path reads them — and they also don't crash anything at runtime (Elixir
  map pattern matches against `%{...}` accept extra keys).
- They do, however, violate the *published* `@callback permission_metadata/0`
  contract: `mix dialyzer` reports a new
  `lib/phoenix_kit_warehouse.ex:114:7:callback_type_mismatch` — the actual
  returned map has 6 keys where the pinned behaviour's type only allows the
  5 listed above. This is a genuinely new finding, not baseline noise: the
  pre-PR baseline (see PR #6's review, run 2026-07-16) recorded 11 dialyzer
  findings; re-running against the merged tree here found 12, with the new
  one at exactly this line.

## Finding

**BUG - MEDIUM — the PR's premise doesn't hold against the dependency
actually pinned in `mix.lock`: `phoenix_kit` 1.7.205 has no code that reads
`permission_metadata/0`'s `gettext_backend`/`gettext_domain`, so the label
stays untranslated in production exactly as before, and the extra keys
introduce a new `mix dialyzer` `callback_type_mismatch` against the
published `permission_meta()` type.**

Fixed as part of this review: reverted `permission_metadata/0` in
`lib/phoenix_kit_warehouse.ex` to its original 4-key shape (matching the
published callback type), removing the two now-dead keys and the comment
describing what they were meant to do. `admin_tabs/0` and `settings_tabs/0`
are untouched — their `%Tab{gettext_backend: ..., gettext_domain: ...}`
entries are real, pre-existing, and already functional against the pinned
dependency.

Not fixed (deliberately, no further action here): re-adding
`gettext_backend`/`gettext_domain` to `permission_metadata/0` is the right
follow-up once `phoenix_kit` actually publishes a Hex release containing
commit `253e69c8` (or later) and this repo's `mix.lock` is bumped to pick
it up — at that point the same two lines removed here can be restored with
no other code changes, exactly mirroring PR #9's original intent.

## Verification of the fix

`mix compile --warnings-as-errors`, `mix format --check-formatted`,
`mix deps.unlock --check-unused`, `mix hex.audit` all clean. `mix dialyzer`
re-run after the revert: back to 11 findings, byte-identical to the PR #6
baseline (same file:line locations) — no new findings. Full combined gate
result recorded in PR #10's review doc.
