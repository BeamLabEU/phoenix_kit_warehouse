# PR #30 — Module-owned migration chain V1 (adopts all 8 warehouse tables)

**Reviewed:** 2026-09-15 · **Author:** timujinne · **Verdict:** merged; sound.
One documentation bug and three doc nitpicks fixed post-merge, shipped in
0.5.0.

## What landed

`PhoenixKitWarehouse.Migrations` (`migration_module/0`) — a decentralized
chain whose V1 re-asserts core's V140/V144 shape for all 8
`phoenix_kit_warehouse_*` tables idempotently and stamps `pkw_schema:1` on
`phoenix_kit_warehouse_stock`. Dual readers (`migrated_version/1` in
migration context, `migrated_version_runtime/1` for `mix phoenix_kit.update`),
`down/1` only touches the marker. The six document schemas gained
`column_widths/0` as the single source of the `status` varchar width.
`test_helper.exs` applies the chain after core's migrations.

## Verification beyond the PR's own tests

- **Fresh-install claim (Phase 2) checked against a real database.** Built
  all 8 tables from `up_statements("pkw_probe")` alone in an empty schema
  (stub `phoenix_kit_users` + `uuid_generate_v7()`), ran the statements a
  second time, then diffed `pg_dump -s` of the probe schema against core's
  `public` tables. Identical — columns and their order, defaults, pkeys,
  checks, every index, every FK name (including the truncated singular
  `..._inventory_document_performed_by_uuid_fkey`), sequences, and the
  marker comment. The second pass was a no-op.
- **Protocol matches core's generator.** `mix phoenix_kit.update` writes
  `up(prefix:, version: target)` / `down(prefix:, version: current)` and
  reads `migrated_version_runtime(prefix:)` — all shapes this chain accepts.
- **Core floor is sufficient.** `~> 2.0` — phoenix_kit 2.0.0 (fetched from
  Hex) already exports `ensure_extension!/1`, `ensure_uuid_v7_function/1`,
  `uuid_v7_call/1`, `qualify_table/2`, `validate_prefix!/1`, and the
  `migration_module/0` callback, so no host on the floor can hit an
  `UndefinedFunctionError` inside the generated migration.
- The PR's 30 migration tests pass.

## Findings

### IMPROVEMENT - MEDIUM — README removal SQL left six sequences behind (fixed)

"Removing this module" dropped the 8 tables for an operator who wants
"every stock balance and document gone for good", but the six
`*_number_seq` sequences are created standalone (`CREATE SEQUENCE`, never
`OWNED BY` the `number` column — confirmed in `pg_dump`), so `DROP TABLE`
does not take them along. They survived as orphans, and a later reinstall
would silently resume document numbering from the old values.

**Fix:** the SQL block now also drops the six sequences. New test in
`migrations_data_safety_test.exs` parses README's SQL block, runs it inside
the sandbox, and asserts no `phoenix_kit_warehouse_*` table or sequence
remains (with a precondition of exactly 14 relations beforehand so the
assertion cannot pass vacuously). This also catches a future FK from
another table into a warehouse table that would make the documented order
fail.

### BUG - HIGH — `mix test` was red on main, from the dep bump after this PR (fixed)

Not from PR #30, but it blocked this release and is the same class the
project has hit before. The commit after the merge (`eef5afd`, "lib
upgrades") bumped `phoenix_kit_locations` 0.4.2 → 0.5.1. 0.5.0 added
`owner_uuid` to `phoenix_kit_locations` via that package's own
`PhoenixKitLocations.Migrations` chain, which core's
`PhoenixKit.Migration.ensure_current/2` does not carry, and
`test_helper.exs` never ran it. Every LiveView test that loaded a warehouse
location failed: `column p0.owner_uuid does not exist` — 181 errors,
`mix test` exit 2, while `mix precommit` stayed green (it runs no tests).

**Fix:** `test_helper.exs` now applies `PhoenixKitLocations.Migrations`
alongside catalogue's and this module's, executing `up_statements/2`
directly (its `up/1` only pipes those into `execute/1`, and every statement
is idempotent, so no migration runner is needed). Runtime code was never
affected — a real host runs `mix phoenix_kit.update`, which applies the
chain. 862 tests, 0 failures after the fix.

**Known gap left open:** `phoenix_kit_entities` and `phoenix_kit_billing`
also declare `migration_module/0` chains the suite does not apply. Nothing
in the suite needs their tables today, so they are left alone rather than
wired in blind; a future failure naming an entities/billing column is this
same cause.

### NITPICK — CHANGELOG inaccuracies (fixed)

- `## Unreleased` → `## 0.5.0 - 2026-09-15`.
- Said V1 re-asserts "unique constraints"; V1 creates unique *indexes* and
  CHECK constraints. Reworded.
- Claimed this was "the second of a planned series … the first was
  `phoenix_kit_dashboards`", contradicting the chain's own moduledoc, which
  cites `phoenix_kit_billing`'s V4 (ten adopted tables) as the precedent.
  Replaced with a plain reference to both siblings.

### NITPICK — stale "Conflict B" label (fixed)

The FK comment in `v1_statements/2` said "Conflict B", but the moduledoc
numbers the two reconciled discrepancies 1 and 2. Now points at
"discrepancy 2 (moduledoc)".

### NITPICK — `table_exists?/2` is privilege-filtered and redundant (not fixed)

It queries `information_schema.tables`, which only lists tables the current
role holds some privilege on, and the following `pg_class` comment query
already returns no row for a missing table. A role with no privilege on the
anchor table would read `0`. Left alone: migrations run as the owning role,
and a wrong `0` only replays V1's idempotent statements (the dual-reader
design's stated safety net). Not worth churn in a heavily test-pinned file.

### NITPICK — V1 builder stamps `target` (not fixed, note for V2)

`v1_statements(prefix, target)` appends the marker with the caller's
`target`. Correct while `@current_version` is 1; V2 must split into
per-version builders (as catalogue/billing do) so V1's statements stay
frozen and the marker is stamped once, at the end of the last applied
version. The frozen-statements drift test will force this.

## Gate

`mix precommit` — see commit.
