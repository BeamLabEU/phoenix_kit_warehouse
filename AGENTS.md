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

Hard dependencies (all of them — none is declared `optional:` in `mix.exs`):
`phoenix_kit`, `phoenix_kit_billing`, `phoenix_kit_catalogue`,
`phoenix_kit_locations`, `phoenix_kit_comments`. Comments is a hard dep despite
the runtime guards, because six form LiveViews `use PhoenixKitComments.Embed`
and a `use` cannot be guarded. What is optional is the comments *module* being
**enabled** in the host: `PhoenixKitWarehouse.Comments.available?/0` gates the
call sites, so a disabled module means no threads rather than a crash. Only
`"catalogue"` and `"locations"` appear in `required_modules/0`.

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
5. Tables are created by PhoenixKit core (V140/V144); this module's own
   migration chain (`PhoenixKitWarehouse.Migrations`, via `migration_module/0`)
   now owns their future shape — see "Database & migrations" below.

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

All 8 runtime tables were originally created by the parent
[phoenix_kit](https://github.com/BeamLabEU/phoenix_kit) core migrations:

- **V140** creates 6 tables: `phoenix_kit_warehouse_stock`,
  `phoenix_kit_warehouse_goods_receipts`, `phoenix_kit_warehouse_goods_issues`,
  `phoenix_kit_warehouse_internal_orders`,
  `phoenix_kit_warehouse_supplier_orders`, and
  `phoenix_kit_warehouse_inventory_documents`.
- **V144** creates 2 additional tables:
  `phoenix_kit_warehouse_transfers` and `phoenix_kit_warehouse_min_stock`.

Their FUTURE shape is now owned by this module's own migration chain,
`PhoenixKitWarehouse.Migrations` (`migration_module/0`), following the
canonical dual-reader protocol `phoenix_kit_hello_world` documents —
`migrated_version/1` (migration context, via `Ecto.Migration`'s `repo()`, no
rescue) and `migrated_version_runtime/1` (the one `mix phoenix_kit.update`
calls, via `PhoenixKit.RepoHelper.repo()`, rescues to `0` except an invalid
prefix, which re-raises); `up/1` re-reads the version through
`migrated_version/1` before changing anything. The chain anchors its
version marker on a single table, `phoenix_kit_warehouse_stock` (core's
first-created, FK-free table), as a `pkw_schema:<N>` `COMMENT ON TABLE` —
none of the other 7 tables carry a marker of their own. A marker-less
anchor table, or one carrying a foreign (non-`pkw_schema:`) comment, reads
as version 0. Varchar widths are sourced from each of the six document
schemas' own `column_widths/0` (`GoodsReceipt`, `GoodsIssue`,
`InternalOrder`, `SupplierOrder`, `InventoryDocument`, `Transfer` —
`Stock`/`MinStock` have no varchar column) — never a second hard-coded
number in the migration DDL.

Ownership unfolds in three phases: **Phase 0** (the current `V1`) is a pure
**adoption** — it reproduces core's V140/V144 shape under core's exact
object names (idempotent `CREATE TABLE IF NOT EXISTS` / guarded `DO $$ ...
$$` constraint blocks), so on every existing install it changes nothing
except stamping the marker; because it changes no shape, core's
`ExpectedSchema` manifest stays accurate and no core release was required
to ship it. **Phase 1** is the first real shape change (a future V2+) — it
requires first adding the altered objects to core's manifest generator's
`@excluded_exact` and regenerating `ExpectedSchema`, then raising this
package's core floor. **Phase 2** is a future core baseline squash that
drops these tables from core's own chain entirely — V1's `CREATE TABLE`
statements are therefore already fully self-sufficient definitions (calling
`Helpers.ensure_extension!/1` + `Helpers.ensure_uuid_v7_function/1` rather
than assuming core's chain provided them), not merely shape-matching no-ops
for already-existing tables.

**A table-shape change to any of the 8 tables is a new version in this
chain from now on — never a new core migration.** `down/1` NEVER drops a
table or its data, for any target including `0`; rolling this chain back
only unstamps (or re-stamps) the marker on the anchor table. There is
deliberately no automated uninstall path — see README.md's "Removing this
module" for the manual operator SQL. A host picks up a pending version the
next time it runs `mix phoenix_kit.update`, which generates its own
migration file in the host app.

For the full column/index list of the shape being adopted, see the
respective migration moduledocs in core
(`lib/phoenix_kit/migrations/postgres/v140.ex` and `v144.ex`).

The test suite bootstraps its schema by running core's versioned migrations
via `PhoenixKit.Migration.ensure_current/2`, then running this module's own
`PhoenixKitWarehouse.Migrations.up_statements/2` directly against the test
repo (see `test/test_helper.exs`) — both are needed since core alone no
longer carries the full picture of what this module's tables look like once
a V2+ ships. V144 ships in phoenix_kit ≥ 1.7.190 on Hex (1.7.189 tops out at
V142), so the plain pin is sufficient:

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
  applies core migrations via `PhoenixKit.Migration.ensure_current/2`, then
  this module's own migration chain via `PhoenixKitWarehouse.Migrations`
  (see "Database & migrations" above), then uses `Ecto.Adapters.SQL.Sandbox`.

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
