# Review: PR #5 — Junction-based supplier resolution + receipt unit_value posting

- **Author**: timujinne (Tymofii Shapovalov)
- **Merged**: c16580f (+ 1c82c58) into main via af21aa3, 2026-07-15
- **Files touched**: `lib/phoenix_kit_warehouse/goods_receipts.ex`,
  `lib/phoenix_kit_warehouse/supplier_orders.ex`, `mix.lock`,
  `test/phoenix_kit_warehouse/goods_receipts_test.exs`,
  `test/phoenix_kit_warehouse/supplier_orders_test.exs`

## Context

Two independent changes bundled in one PR:

1. **Receipt `unit_value` posting** (`goods_receipts.ex`): each receipt line may
   carry a `"unit_value"`; when present it's threaded through to
   `StockLedger.receive_quantity/3`'s existing `:unit_value` option so posting a
   receipt can set the item's stock unit_value, not just its quantity.
2. **`resolve_suppliers/1` rewrite** (`supplier_orders.ex`): replaces the
   `item.primary_supplier_uuid` scalar check with a guarded call to a
   `PhoenixKitCatalogue.Catalogue.Suppliers.primary_for_item/1` function, justified
   by a comment claiming "The `primary_supplier_uuid` scalar was removed in V149."

## Verification

**(1) unit_value posting** — checked clean. `StockLedger.receive_quantity/3`
already supported an `:unit_value` option before this PR (pre-existing code); this
PR only wires goods-receipt lines' `"unit_value"` field through to it via
`StockLedger.to_decimal_or_nil/1` (also pre-existing). No new StockLedger logic,
no regression risk. Tests added in `goods_receipts_test.exs` exercise present/absent/
nil unit_value correctly.

**(2) `resolve_suppliers/1` rewrite** — **the core claim is factually wrong, and
the rewrite silently drops working functionality.** Checked against the actual
dependency, not just the PR description:

- `deps/phoenix_kit_catalogue` is Hex-pinned to **0.10.0** (`mix.lock`,
  `mix.exs: pk_dep(:phoenix_kit_catalogue, "~> 0.10")`) — this is what actually
  ships. `PhoenixKitCatalogue.Catalogue.Suppliers.primary_for_item/1` does **not
  exist** in that version (confirmed by reading `deps/phoenix_kit_catalogue/lib/
  phoenix_kit_catalogue/catalogue/suppliers.ex` and grepping the full package).
  So `function_exported?(suppliers_mod, :primary_for_item, 1)` is `false` in
  production **today**, and `resolve_suppliers/1` unconditionally falls through
  to `resolve_via_manufacturer/1` for every item.
- `item.primary_supplier_uuid` was **not** removed by core's V149 migration. Read
  the actual migration (`phoenix_kit/lib/phoenix_kit/migrations/postgres/v149.ex`)
  — its moduledoc states explicitly: *"The item's scalar `primary_supplier_uuid`
  is **not** created here — it ships upstream in V146... There is no 'primary'
  among these [junction] rows — the item's default supplier is the V146
  `primary_supplier_uuid` scalar."* V149 is a purely additive per-supplier-pricing
  junction table alongside the scalar, not a replacement for it. The field is
  still live on the catalogue `Item` schema in the pinned 0.10.0 dependency
  (`schemas/item.ex`: `belongs_to`/FK + changeset cast + form field).
- Net effect: any item that relies on `primary_supplier_uuid` to resolve a
  supplier — generic/unbranded materials with no `manufacturer_uuid` (the exact
  case the original code's comment called out), or a manufacturer with more than
  one linked supplier where the primary breaks the tie — now resolves to **zero
  suppliers** and lands in the "unassigned" bucket during
  `generate_from_internal_order/2`, instead of being auto-assigned as before. This
  is a live regression in supplier-order generation, not just a no-op guard.
- The added test suite doesn't catch this: the only "no `primary_for_item`" test
  (`"without new catalogue export: routes via manufacturer"`) only covers an item
  *with* a `manufacturer_uuid`; no test exercised an item with
  `primary_supplier_uuid` set and no manufacturer, so the dropped path had no
  coverage either before or after.
- Aside: a sibling checkout of `phoenix_kit_catalogue` (`../phoenix_kit_catalogue`,
  used for local cross-repo dev) does have an in-progress, unreleased branch
  (`feature/parties-supplier-info`, merged to that repo's `main` but **not yet
  published to Hex** — `curl https://hex.pm/api/packages/phoenix_kit_catalogue`
  still reports `0.10.0` latest) that adds exactly this `primary_for_item/1` API
  and *does* eventually drop the `primary_supplier_uuid` scalar in favor of an
  `is_primary` flag on the junction. So the PR's design was directionally
  accurate about where the ecosystem is heading, but it shipped against a
  dependency version where none of that exists yet, on the strength of a comment
  asserting the removal had already happened in a migration (V149) that,
  read directly, says the opposite.

## Finding

**BUG - CRITICAL — `resolve_suppliers/1` silently stopped honoring
`item.primary_supplier_uuid`, the field's only consumer, against the currently
pinned catalogue dependency.**

Fixed as part of this review: reverted `resolve_suppliers/1` in
`lib/phoenix_kit_warehouse/supplier_orders.ex` to check
`item.primary_supplier_uuid` first (still a real, live field in Hex 0.10.0), then
fall back to `manufacturer_uuid` — restoring the original pre-PR behavior and
comment. Dropped the dead `primary_for_item/1` guard, the `apply/3` dynamic
dispatch, the `Code.ensure_loaded?`/`function_exported?` check, the now-unused
`require Logger`, and the three tests that only exercised that dead path (one of
which required a struct field, `is_primary`, that doesn't exist in the pinned
dependency either). Replaced them with two tests that lock in the restored
behavior against the actual regression gap: a primary supplier with no
manufacturer, and a primary supplier breaking a manufacturer tie.

Note for a future PR: once `phoenix_kit_catalogue` actually publishes the
`primary_for_item/1` release and drops the scalar, `resolve_suppliers/1`'s first
clause (`%{primary_supplier_uuid: ...}`) will simply stop matching (the key won't
exist on the struct) and fall through harmlessly to the manufacturer path — so
this fix doesn't need to be revisited defensively, only extended when that
release is actually pinned here.
