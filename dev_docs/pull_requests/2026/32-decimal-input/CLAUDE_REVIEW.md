# PR #32 — Migrate free-decimal form controls to the new core decimal input

**Reviewed:** 2026-09-16 · **Author:** timujinne · **Verdict:** merged; one
medium bug, one medium layout regression and a missing core floor fixed
post-merge.

## What landed

The quantity, price and sum inputs in six places now use core's
`<.decimal_input>` (`type="text" inputmode="decimal"`) instead of
`<input type="number">`: the five document forms, the stock sheet's min
quantity, the inventory browser (counted, price, sum) and the numeric-range
filter chips. The warehouse's four hand-rolled comma parsers
(`StockLedger.to_decimal/1`, `to_decimal_or_nil/1`,
`CostProposals.parse_decimal/1`, `ColumnConfig.parse_number/1`,
`WarehouseBrowser.trim_scale/2`) now go through
`PhoenixKit.Utils.Number.parse_decimal/2`.

## Parser behaviour checked

The switch to `parse_decimal/2` was checked against the old parsers:

- A single comma is still the decimal point: `"1,234"` → `1.234` and
  `"0,125"` → `0.125`. Grouping applies only to a repeated separator or a
  mix of dot and comma.
- Stricter: trailing junk (`"1.5abc"`) used to become `1.5` and now becomes
  `0` or `nil`. Exponent text (`"1E+1"`), anything of 10¹² or more, and text
  over 64 bytes are now rejected too. Stored JSONB line values can't hit
  this: Jason encodes a `Decimal` in plain form (`"10"`, `"0.0000001"`), and
  a full-precision division result is 36 characters. No change.

## Findings

### BUG - MEDIUM — Internal order quantities were stored as typed (fixed)

`InternalOrderFormLive`'s `set_required_qty` put the raw text straight into
the line. The PR's own test locked that in (`== "2,5"`). A browser number
control used to hide this, because it never submitted non-numeric text. The
new text control sends anything, so `"abc"` or `"2,5"` ended up in the JSONB
line as typed. A negative quantity was never stopped either: `min="0"` does
not block `phx-change`, and the PR removed it. That negative then reaches
`GoodsIssues.create_from_internal_order/2` as `issued_quantity`, and
`StockLedger.issue_quantity`'s `WHERE quantity >= qty` guard is trivially
true for a negative number, so posting the issue *adds* stock. This is the
same failure `TransferFormLive` already documents and guards against.

**Fix:** normalise the same way `set_transfer_qty` does: `to_decimal` →
`clamp_non_negative` → `format_quantity`. The comma test now expects `"2.5"`.
A new test covers `"-3"` → `"0"` and `"abc"` → `"0"`.

**Not done:** there is still no context-level guard against a non-positive
`issued_quantity` in `GoodsIssues`/`StockLedger.issue_quantity`, so a line
with a negative issued quantity written by code outside the form handlers
could still add stock. Changing the ledger primitive's contract is out of
scope for this PR. It's worth a separate change.

### BUG - MEDIUM — Every input width was silently overridden (fixed)

`<.decimal_input>` always puts `input w-full` on the control and appends the
caller's `class` after it. Class order in HTML doesn't decide which rule
wins; stylesheet order does. A compiled Tailwind v4 bundle in the workspace
emits `.w-20{` and `.w-24{` *before* `.w-full{`, so every `w-20`/`w-24` the
PR passed was lost. The controls stretched to fill their table cell or flex
item instead of staying 5–6rem wide.

**Fix:** move the width to `wrapper_class`. In table cells use
`wrapper_class="inline-block w-24"`: the component's wrapper is a block
`<div>`, and `inline-block` keeps it following the cell's
`text-right`/`text-center` the way the old inline `<input>` did. Filter chips
already sit in a flex row, so they use `w-20` alone. A new
GoodsReceiptFormLive test checks that the width is on the wrapper and not on
the control.

**Upstream note:** core's own moduledoc example and the catalogue's
`class="input-sm w-24"` have the same problem. Core should document widths
as `wrapper_class`, or stop hard-coding `w-full`.

### IMPROVEMENT - HIGH — Core floor not raised (fixed)

The `:phoenix_kit` requirement was still `~> 2.0`, but
`PhoenixKitWeb.Components.Core.DecimalInput` and `Number.parse_decimal/2`
first shipped in 2.26.0. A host locked to an older 2.x core would resolve
this release and fail to compile. The floor is now `~> 2.26 and >= 2.26.1`.
2.26.1 rather than 2.26.0 because on 2.26.0 `"10"` parses to `1E+1`, which
Jason stores as `"1E+1"`, and `parse_decimal/2` then rejects that text,
reading it back as `0`.

`CorePinConformanceTest` enforced "keep it `~> 2.0`". Its purpose is to stop
a three-segment pin that locks out newer core minors, and a raised floor
still admits every 2.x from the floor up to 3.0. The admit/reject lists and
the message now reflect that; the ceiling check is unchanged.

### NITPICK — not changed

- Dropping `min="0"` removes the only client-side hint. The server clamps in
  every handler that posts stock, so there is no functional change.
- The filter chips no longer get native number validation. `parse_number`
  returns `nil` for garbage, which means "no bound", same as before.
