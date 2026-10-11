# PR #34 — Setup notice while the module is not configured

**Reviewed:** 2026-10-11 · **Author:** timujinne · **Verdict:** merged; one
medium robustness bug fixed post-merge, one convention deviation left on
record.

## What landed

`StockLedger.setup_status/0` (`:ready | {:needs, :location_type | :locations
| :default_location}`) and a `SetupNotice` component shown on the eight list
and report pages (stock, inventories, internal / supplier orders, goods
receipts / issues, transfers, turnover). The Locations buttons show only
while Locations is enabled; the Warehouse settings button is always there.
The test router gained the settings route the buttons point at.

## Checked and found sound

- The three step checks are ordered correctly and an empty list is told apart
  from "type deleted" (`empty_warehouses_status/0`).
- The paths exist: `/admin/settings/warehouse` (`SettingsLive` tab),
  `/admin/locations/types` and `/admin/locations/new` (Locations tabs).
- Every page that renders `WarehouseHeader` also renders the notice; the
  settings page itself does not (tested).

## Findings

### BUG - MEDIUM — A banner could take every Warehouse page down (fixed)

`assign_setup_status/1` runs in `mount/3` of eight LiveViews and called
`StockLedger.setup_status/0` unguarded. `warehouse_location_type_uuid` is a
free-text setting: with anything that is not a UUID in it, `list_warehouses/0`
raises `Ecto.Query.CastError`, and so does an unmigrated Locations table or an
unreachable database. Before this PR only the pages that needed the list
failed; now *all eight* 500 on mount, including the settings-adjacent pages
the operator needs to fix the problem. The project convention is that
LiveViews degrade rather than 500 on a not-yet-ready host.

**Fix:** `assign_setup_status/1` rescues errors and catches exits, logs at
`:debug` and falls back to `:ready` (no notice). New test: a
`"not-a-uuid"` type setting renders the goods issue list without a notice
(fails with the `CastError` without the fix).

### NITPICK — The status is read in `mount/3` (left as is)

The Iron Law says no queries in `mount`, and this one runs twice (dead render
+ socket). It is one `Locations.list_locations` select plus settings reads,
and the notice has to be in the first paint to avoid a layout jump, so it was
left. If it ever grows, move it to `handle_params` behind `connected?/1`.

### NITPICK — Paths are string literals

`"/admin/settings/warehouse"` and the Locations paths are written inline in
the component, where AGENTS.md asks for paths through a central module. The
rest of the web layer does the same (`Routes.path("/admin/warehouse")` is
inlined in several LiveViews), so this is not new drift; consolidating is a
separate cleanup.
