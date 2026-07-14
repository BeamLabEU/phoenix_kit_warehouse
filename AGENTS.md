# AGENTS.md

Guidance for AI agents (and humans) working in `phoenix_kit_warehouse`.

## Project Overview

`phoenix_kit_warehouse` is a **PhoenixKit module** — an independent Hex
package that implements the `PhoenixKit.Module` behaviour and is
auto-discovered by a host Phoenix app at startup. It has no endpoint,
router, or Ecto repo of its own; it borrows the host's via `phoenix_kit`.

The module is fully implemented (wave 1 scope, ~60 source files, 8 Ecto
schemas). Features:

- **Multi-warehouse stock scope** — stock balances per item per location,
  configurable default warehouse, warehouse location type.
- **Transfers** — inter-warehouse transfers with ship / receive workflow;
  cancel issues a reverse posting to restore source stock.
- **Deficit control** — min-stock settings per item/location; deficit
  dashboard surfaces items below threshold.
- **Turnover report** — aggregated goods movement over a date range.
- **Stocktakes (inventory documents)** — counted-quantity reconciliation.
- **Internal orders** and **supplier orders** — request and procurement
  documents linked to goods receipts.
- **Goods receipts** and **goods issues** — posting documents that move
  stock in and out.

Hard runtime dependencies: `phoenix_kit`, `phoenix_kit_billing`,
`phoenix_kit_catalogue`, `phoenix_kit_locations`. Comments integration via
`phoenix_kit_comments` is optional (guarded at call sites).

## Common Commands

```bash
mix deps.get                # Install dependencies
mix compile                 # Compile
mix test                    # Run tests (integration auto-excluded without a DB)
mix test.setup              # createdb for the test repo (needs PostgreSQL)
mix format                  # Format code (imports Phoenix LiveView rules)
mix credo --strict          # Lint / code quality
mix dialyzer                # Static type checking
mix quality                 # format + credo --strict + dialyzer
mix quality.ci              # format --check-formatted + credo --strict + dialyzer
mix precommit               # compile (warnings-as-errors) + deps.unlock check + hex.audit + quality.ci
```

## Local cross-repo development

`phoenix_kit` resolves from Hex by default. To build/test against a **local
checkout** of core (e.g. an unpublished change), export `PHOENIX_KIT_PATH`
and Mix swaps the Hex pin for a `path:` + `override: true` dep at resolve
time:

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix test
```

Unset ⇒ the published pin, so `mix hex.publish` and CI resolve exactly as
before. Implemented via `pk_dep/3` in `mix.exs` — never hand-edit a
`phoenix_kit` dep into a `path:` tuple; set the env var instead.

## Architecture

### How it works

1. The host app adds this package as a dependency.
2. PhoenixKit scans `.beam` files at startup and auto-discovers the module
   (zero config) via the persisted `@phoenix_kit_module` attribute set by
   `use PhoenixKit.Module`.
3. `admin_tabs/0` registers the admin pages; PhoenixKit generates routes at
   compile time from each tab's `live_view:` field.
4. Enable state is the `warehouse_enabled` boolean setting
   (`PhoenixKit.Settings`); permissions come from `permission_metadata/0`.
5. Tables are created by PhoenixKit core (V144); this module ships no
   migrations of its own.

### Key conventions

Follow these when adding module code (they hold across all PhoenixKit
modules — cf. `phoenix_kit_manufacturing`, `phoenix_kit_legal`):

- **Module key** is `"warehouse"` — keep it consistent across `module_key/0`,
  `permission_metadata/0`, activity-log `module:`, and the settings key.
- **UUIDv7 primary keys**: `@primary_key {:uuid, UUIDv7, autogenerate: true}`.
- **Repo access** is `PhoenixKit.RepoHelper.repo()` (wrapped in `defp repo`);
  never hardcode a repo.
- **Paths**: always via a centralized `PhoenixKitWarehouse.Paths` (which
  routes through `PhoenixKit.Utils.Routes.path/1`) — never hardcode
  `/admin/warehouse`. URL paths use hyphens/slashes, never underscores; tab
  IDs are atoms.
- **`enabled?/0`** rescues *and* `catch :exit`s, returning `false` — the DB
  may be unavailable.
- **Activity logging** is fire-and-forget: guarded by
  `Code.ensure_loaded?(PhoenixKit.Activity)`, rescues `Postgrex.Error`
  (`:undefined_table`) so a host that hasn't run core's activity migration
  never crashes. Changeset-error metadata records field *names* only (no PII).
- **LiveViews** wrap context reads in `rescue` and carry a defensive
  `handle_info/2` catch-all logging at `:debug`, so a not-yet-migrated host
  degrades instead of 500-ing.

### Database & migrations

This module ships **no production migrations** — all 8 runtime tables are
created by the parent
[phoenix_kit](https://github.com/BeamLabEU/phoenix_kit) core migrations:

- **V140** creates 6 tables: `phoenix_kit_warehouse_stock`,
  `phoenix_kit_warehouse_goods_receipts`, `phoenix_kit_warehouse_goods_issues`,
  `phoenix_kit_warehouse_internal_orders`,
  `phoenix_kit_warehouse_supplier_orders`, and
  `phoenix_kit_warehouse_inventory_documents`.
- **V144** creates 2 additional tables:
  `phoenix_kit_warehouse_transfers` and `phoenix_kit_warehouse_min_stock`.

This module only defines Ecto schemas that map to those tables. The
published `0.1.0` shipped no migrations at all (no `migrations/` directory),
so there is no upgrade path to account for — V140 and V144 are both
fresh-install-only DDL for this module's tables. For the full column/index
list see the respective migration moduledocs in core
(`lib/phoenix_kit/migrations/postgres/v140.ex` and `v144.ex`).

The test suite builds its schema by running core's versioned migrations
directly via `PhoenixKit.Migration.ensure_current/2` in
`test/test_helper.exs` — no module-owned DDL. V144 ships in phoenix_kit
≥ 1.7.190 on Hex (1.7.189 tops out at V142), so the plain pin is
sufficient:

```bash
mix test
```

To test against an unpublished local core checkout instead, use the
env-var swap from "Local cross-repo development" above:

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix test
```

## Testing

Intended two-level suite (see a sibling's `test/test_helper.exs` for the
pattern):

- **Unit** tests (schemas, changesets, `Paths`, behaviour compliance) always
  run — no DB needed.
- **Integration** tests are tagged `:integration` (via `DataCase` /
  `LiveCase`) and auto-excluded when PostgreSQL is unavailable. The helper
  applies core migrations via `PhoenixKit.Migration.ensure_current/2` (the
  module ships no migrations of its own — see "Database & migrations"
  above), then uses `Ecto.Adapters.SQL.Sandbox`.

## Versioning & Releases

Bump the version in these places:

1. `mix.exs` — `@version`
2. `lib/phoenix_kit_warehouse.ex` — `version/0` (reads `@version` from
   `mix.exs`, so this stays automatic once the module exists)
3. the `version/0` assertion in the module's test, if present

Tags are **bare version numbers** (no `v` prefix): `git tag 0.1.0 && git push
origin 0.1.0`. Add a `CHANGELOG.md` entry (`## X.Y.Z - YYYY-MM-DD`, newest
first) and run `mix precommit` clean before tagging. Publish to Hex *before*
tagging.

## Commit & PR conventions

- Commit messages start with an action verb: `Add`, `Update`, `Fix`,
  `Remove`, `Merge`.
- PR review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/`
  using `{AGENT}_REVIEW.md` naming.
