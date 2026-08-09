# Review: PR #12 — Raise the core floor to 1.7.231, the release that ships UrlState

- **PR:** [#12](https://github.com/BeamLabEU/phoenix_kit_warehouse/pull/12)
  `timujinne/fix/core-version-floor`
- **Author:** Timujeen
- **Merge commit:** `cd0374b` (single commit `519683f`)
- **Reviewed at:** `9594ec3` (`main`)
- **Diff:** `mix.exs`, +5 / −1 — one requirement string and its comment.

## Summary

The PR is **correct, and correct for the reason it states.** Verified against
core's own history rather than the PR description:

- `PhoenixKitWeb.Live.UrlState` was added by core commit `ae9164c6`
  ("Add UrlState: URL-backed search, filter and page state for list LiveViews",
  2026-08-04). `git tag --contains` on that commit yields `v1.7.231` as the
  earliest release. The three follow-up UrlState commits (`851d5f17`,
  `e861d849`, `c9d78952` — decoder-rejection guard, plain-assign precedence,
  history mode) are **all** in `v1.7.231` too, so the floor needs no further
  raising to cover the behaviour these seven screens actually rely on.
- Seven files `use PhoenixKitWeb.Live.UrlState`, exactly as claimed:
  `stock_live`, `inventories_live`, `transfer_index_live`,
  `internal_order_index_live`, `supplier_order_index_live`,
  `goods_receipt_index_live`, `goods_issue_index_live`.
- The floor is not *too high* either: `v1.7.231..v1.7.232` is impersonation
  entry points, username transliteration and gettext churn — nothing this
  module touches — so 1.7.231 is the tightest true floor, not a round-up.
- A `use` is macro expansion at compile time. Unlike the `Code.ensure_loaded?` +
  `function_exported?` guards this module uses for optional catalogue exports,
  it **cannot** be guarded, so a version floor is the only available fix. The
  PR chose the right instrument.

Audited every other core module this package references
(`Activity`, `Dashboard.Tab`, `Module`, `Modules.Storage`, `RepoHelper`,
`SchemaPrefix`, `Settings`, `Users.Auth.Scope`, `Utils.Routes`,
`Components.Core.DraggableList`, `Components.Core.Icon`,
`Components.Core.Modal`, `Components.LayoutWrapper`, `Components.MediaBrowser`,
`Layouts`) — the highest first-release among them is `SchemaPrefix` /
`MediaBrowser` at **1.7.194**, well under the new floor. No second core bump is
owed.

One finding, of the same class the PR set out to fix, three lines below the line
it changed.

---

## BUG - HIGH — `phoenix_kit_comments` floor permits a release without `Embed`

**Where:** `mix.exs:104` (pre-fix: `pk_dep(:phoenix_kit_comments, "~> 0.2")`)

**What's wrong.** `~> 0.2` resolves to `>= 0.2.0 and < 1.0.0`. Six form
LiveViews — `goods_issue_form_live`, `goods_receipt_form_live`,
`internal_order_form_live`, `supplier_order_form_live`, `transfer_form_live`,
`inventory_form_live` — open with:

```elixir
use PhoenixKitComments.Embed
```

`PhoenixKitComments.Embed` (and its `__using__/1`) was added by comments commit
`e11a9b09` ("Add PhoenixKitComments.Embed macro for host Leaf-event
forwarding", 2026-06-06), first released in **0.2.6**. So the declared contract
admits comments 0.2.0–0.2.5, against which all six files raise
`CompileError: module PhoenixKitComments.Embed is not available` — the identical
failure mode, in the identical place (a consumer's build), that PR #12 removed
for core.

It doesn't stop at compile time. `PhoenixKitWarehouse.Comments` calls three
things that arrived later still, in comments commit `65e08aa6` ("Add PubSub live
updates, batch comment counts, rich-text opt-out"), first released in **0.2.8**:

| Call site | Function | First release |
|---|---|---|
| `comments.ex:77` | `PhoenixKitComments.subscribe/2` | 0.2.8 |
| `comments.ex:87` | `PhoenixKitComments.unsubscribe/2` | 0.2.8 |
| `comments.ex:64` | `count_comments/2` — **list** clause (batch counts) | 0.2.8 |

**The existing guard does not cover this.** `Comments.available?/0` is

```elixir
Code.ensure_loaded?(PhoenixKitComments) and PhoenixKitComments.enabled?()
```

which answers "is the module there at all", not "is it new enough". Against
comments 0.2.6 or 0.2.7 the module *is* loaded and `enabled?/0` *does* exist, so
`available?/0` returns `true` and the call proceeds into an
`UndefinedFunctionError` on `subscribe/2` — or, for `counts/2`, a
`FunctionClauseError`, since `count_comments/2` had no list clause before 0.2.8.
This is the same asymmetry the moduledoc in `phoenix_kit_warehouse.ex:12`
glosses over when it says `PhoenixKitComments` "stays optional (guarded via
`Code.ensure_loaded?/1`)": module-presence guards are version-blind.

**Failure scenario.** A host app whose `mix.lock` already pins
`phoenix_kit_comments` at, say, 0.2.4 adds `phoenix_kit_warehouse`. `mix
deps.get` honours the existing lock entry because `~> 0.2` is satisfied by it,
and the build dies on the first `use PhoenixKitComments.Embed`. Nothing in the
package's declared requirements told them otherwise.

**Fix applied.**

```elixir
pk_dep(:phoenix_kit_comments, "~> 0.2 and >= 0.2.8"),
```

with a comment recording which functions set the floor and why `available?/0`
isn't sufficient.

**Why the two-clause form and not `~> 0.2.8`.** `~> 0.2.8` means
`>= 0.2.8 and < 0.3.0` — it would fix the floor *and* silently drop the ceiling
from `< 1.0.0` to `< 0.3.0`, which the PR did not ask for and which this repo
demonstrably relies on: `phoenix_kit_locations` is pinned `~> 0.2` and `mix.lock`
resolves it to **0.3.0**. Had that pin been written `~> 0.2.0`, the current build
would not resolve. `"~> 0.2 and >= 0.2.8"` raises the floor and leaves the
ceiling where it was — and it is this repo's own prior idiom (`mix.exs` carried
`"~> 1.7 and >= 1.7.189"` for core before PR #4).

`mix deps.get` after the change leaves `mix.lock` byte-identical (comments is
locked at 0.2.15), confirming this corrects the contract without moving the
build — the same property PR #12 claimed for itself.

---

## Verified OK — sibling floors that look wrong but aren't

Applying the PR's lens to the other three sibling pins, to be sure the fix above
is the only one owed:

**`phoenix_kit_catalogue "~> 0.10"` — correct as-is, despite two 0.12.0 APIs.**
`Catalogue.Suppliers.active_info_for/2` and `revise_unit_cost/3` both first ship
in catalogue **0.12.0**, above the declared floor. That is *deliberate*, not
drift: `CostProposals.catalogue_resolver/0` and `apply_revision/2` guard both
with `Code.ensure_loaded?` + `function_exported?` and degrade to "no proposals" /
`{:error, :catalogue_unavailable}`, and `cost_proposals.ex` documents the
degradation under a "Degradation without catalogue exports" heading. Every
*unguarded* catalogue call clears the floor comfortably: `search_input/1` (an
`import`, so compile-time) 0.1.3, `category_summary_for_catalogue` 0.1.16,
`list_items_by_uuids` 0.1.16, and `get_translation`, `get_item!`,
`get_supplier`, `list_catalogues`, `list_categories_for_catalogue`,
`list_items_for_category`, `list_suppliers`, `list_suppliers_for_manufacturer`,
`list_uncategorized_items`, `search_items` all ≤ 0.1.3. **No change.**

**`phoenix_kit_locations "~> 0.2"` — correct.** All three functions used
(`get_location`, `list_locations`, `list_location_types`) date to 0.1.1.

**`phoenix_kit_billing "~> 0.5"` — correct, floor is generous.**
`CurrencyDisplay.currency_compact/1` — imported at compile time in three files —
dates to 0.1.0. The `~> 0.5` floor is far above what the code needs; harmless,
and left alone rather than loosened.

## Verified OK — no doc drift from the bump

`CLAUDE.md`'s migration section still reads "V144 ships in phoenix_kit ≥ 1.7.190
on Hex … so the plain pin is sufficient". That remains true after the bump — it
is a claim about the pin being *sufficient* for V144, not a restatement of the
pin's value — so it was left as written. (PR #4's review had to fix exactly this
kind of drift; this PR introduced none.)

## Not done, deliberately

**No test was added.** The natural candidate — assert in ExUnit that
`Mix.Project.config()[:deps]` declares `>= 1.7.231` / `>= 0.2.8` — would restate
the literal in `mix.exs` and pass unconditionally. It cannot fail for the reason
we care about, because the suite runs against `mix.lock`'s resolution (core
1.7.232, comments 0.2.15), never against the floor. Per the repo's own testing
stance, `mix precommit` is the bar here; a floor assertion would be tautological
and would need editing on every future bump. The floors are instead documented
inline at the requirement, where a future editor will read them.

## Validation

`mix precommit` — compile `--warnings-as-errors`, `deps.unlock --check-unused`,
`hex.audit`, `quality.ci` (`format --check-formatted` + `credo --strict` +
`dialyzer`): **passes**, matching the zero baseline established in `924ee92`.
`mix.lock` unchanged.
