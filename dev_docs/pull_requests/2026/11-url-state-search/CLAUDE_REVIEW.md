# Review: PR #11 — Put warehouse list search and sort in the URL

- **Author**: timujinne (Timujeen)
- **Merged**: 65bcfdf into main via 253a53c, 2026-08-05
- **Files touched**: `goods_issue_index_live.ex`, `goods_receipt_index_live.ex`,
  `internal_order_index_live.ex`, `inventories_live.ex`, `stock_live.ex`,
  `supplier_order_index_live.ex`, `transfer_index_live.ex`
  (+289 / −171, no tests)

## Context

All seven warehouse index screens kept `:search`, `:sort_by` and `:sort_dir`
as plain socket assigns seeded in `mount/3`. A filtered list was therefore not
addressable: it could not be shared, a reload dropped it, and Back left the
page instead of returning to the previous query.

The PR adopts core's `PhoenixKitWeb.Live.UrlState`
(`deps/phoenix_kit/lib/phoenix_kit_web/live/url_state.ex`) in `:patch` mode on
each screen:

- The three assigns are declared with `url_key: "q" / "sort" / "dir"`, a
  `sortable` whitelist on `sort_by`, and `cast: :atom, in: [:asc, :desc]` on
  `sort_dir`.
- Data loading moves from `handle_params/3` into the `handle_url_state/2`
  callback, so one code path serves the first render, a shared link and Back.
- The four state-changing events (`search`, `set_sort`, `toggle_sort`,
  `flip_sort_dir`) now `push_url_state/3` instead of `assign/3` + re-query;
  `search` passes `replace: true` so a debounced box leaves one history entry.
- `StockLive` additionally gains a `:stock_items_loaded?` flag so search and
  sort re-slice the cached ledger snapshot instead of re-running
  `build_stock_items/1` on every keystroke.

Both commits are in scope: 5c4bc8f did the conversion, 65bcfdf followed up on
the sort reset and the stock cache.

## Verification

Everything below was checked against the producing code, not the PR
description.

- **The `sort_by` whitelists are correct as merged.** Each `in: ~w(...)` list
  is a hand-written copy of the `sortable?: true` columns in the screen's
  `ColumnConfig` — the classic "two lists that must stay in sync" hazard, and
  the one thing that would silently break sorting if wrong. Enumerated all
  seven configs and compared: all seven match exactly, and every declared
  default (`"number"`, `"item"`) is itself sortable. Correctly *excluded* are
  the non-sortable columns — `sub_order`, `internal_order`, `location`,
  `supplier_order`, `source_location`, `destination_location`. Now pinned by a
  test (below) rather than left to the next person adding a column.
- **`cast: :atom` cannot mint atoms from user input.** `UrlState.cast_value/2`
  for `:atom` does `Enum.find(spec.allowed, spec.default, &(to_string(&1) ==
  raw))` — comparison against pre-existing atoms, never `String.to_atom/1`. A
  crafted `?dir=` is a fallback, not an atom-table leak.
- **`@impl`/`handle_params` contract is honoured.** These LiveViews annotate
  their callbacks, so per the module docs each one defines an explicit
  `@impl true def handle_params(_params, _uri, socket), do: {:noreply, socket}`
  rather than letting `__before_compile__` inject the un-annotated stub. All
  seven do. `mix compile --warnings-as-errors` is clean.
- **No `mount/3` query regression.** Query counts per page load are unchanged:
  work moved from `handle_params/3` (called once per mount) to `mount/3` plus
  `handle_url_state/2` under the default `dead_render: :call` (also once per
  mount). `StockLive` in particular now reads `ViewConfigs.get_view_config/2`
  and `StockLedger.list_warehouses/0` in `mount/3` — same total, and it lets
  `handle_url_state/2` see `warehouse_scope` when it builds the item list.
- **The `StockLive` cache flag is sound.** `:stock_items_loaded?` is seeded
  `false` in `mount/3`, so each of the two mounts rebuilds once; the three
  events that genuinely invalidate the ledger (`set_warehouse_scope`,
  `set_min_quantity`, `create_supplier_order_from_deficit`) call
  `assign_stock_items/1` themselves. Using an explicit flag rather than
  `stock_items == []` is right — an empty warehouse would otherwise re-query
  on every keystroke forever.
- **Unrelated query keys survive.** `UrlState.extra_params/2` preserves
  unknown keys across patches, so the media-selector `?return_to=` pattern
  used by the form LiveViews is not clobbered when a filter changes.

## Findings

### BUG - MEDIUM — hiding the sort column can push a non-sortable one, leaving the list stale

`__view_config_changed__/1` (all seven screens) re-picked the sort column with:

```elixir
push_url_state(socket, sort_by: List.first(socket.assigns.selected_columns) || "number")
```

`List.first/1` returns the first *visible* column, which need not be
**sortable** — column order is user-controlled through the column modal's
reorder, and every screen except Stock and Inventories has non-sortable
columns that can sit first (`sub_order`, `supplier_order`, `location`,
`source_location`, `destination_location`).

`push_url_state/3` then routes through `UrlState.sanitize/2`, which replaces
any value outside the declared `in:` whitelist with the **default**. So the
pushed re-pick silently becomes `"number"` / `"item"`, and two things follow:

1. If the current sort column *was* the default (the common case — nothing
   else has been clicked) the state does not move at all. `UrlState.apply_state/3`
   guards on `reload?/3`, which returns `false` for an unchanged state, so
   **`handle_url_state/2` never runs**. The column save or filter change that
   invoked `__view_config_changed__/1` is therefore never applied to the list:
   the table keeps rendering the rows it had before, and `?sort=` still names
   the column that was just hidden.
2. If it was not the default, the list does reload but lands on the default
   column, which is itself hidden — so the next column change repeats the
   dance.

The pre-PR code did not have this failure mode: its `else` branch assigned the
new `sort_by` and then unconditionally called `assign_*(socket)`, so the list
always refreshed. The regression is a direct consequence of routing the
re-pick through the URL without accounting for `sanitize/2`.

**Fixed** in all seven files by picking the first visible column that is
actually sortable, and by comparing against the current value so an unchanged
re-pick refreshes the list locally instead of pushing a no-op patch:

```elixir
def __view_config_changed__(socket) do
  next = next_sort_by(socket)

  if next == socket.assigns.sort_by do
    assign_issues(socket)
  else
    push_url_state(socket, sort_by: next)
  end
end

defp next_sort_by(socket) do
  %{sort_by: sort_by, selected_columns: selected} = socket.assigns

  if sort_by in selected,
    do: sort_by,
    else: selected |> Enum.find(&sortable_column?/1) |> parse_sort_by()
end

defp sortable_column?(column_id) do
  match?(%{sortable?: true}, Map.get(GoodsIssueColumnConfig.column_metadata_map(), column_id))
end
```

Reusing the existing `parse_sort_by/1` gives the per-screen default for free
when no visible column is sortable (`Enum.find/2` returns `nil`, which its
`is_atom` clause funnels to the default). The helper is kept private per
LiveView rather than extracted, matching how `parse_sort_by/1`, `flip_dir/1`
and `default_dir/1` are already duplicated across these seven modules.

### IMPROVEMENT - HIGH — the sort whitelist duplicated the ColumnConfig with nothing pinning them together

The `in:` list and `sortable?: true` are the same fact written twice, one of
them by hand, in seven files. Drift is silent in the worst way: add a sortable
column and forget the whitelist, and clicking its header sorts by the default
column instead — no error, no warning, nothing in the logs. That the seven
lists happen to be right today is luck that the next column change spends.

**Fixed** with `test/phoenix_kit_warehouse/web/url_state_sort_columns_test.exs`
— a pure unit test (no repo, no mount) that reads each LiveView's
`__phoenix_kit_url_state__/0` config and asserts, per screen:

- `?sort=` accepts exactly the `sortable?: true` columns of its `ColumnConfig`;
- the declared default sort column is itself sortable;
- `?dir=` is `cast: :atom` restricted to `[:asc, :desc]` — the constraint
  `UrlState` requires precisely so no atom is created from user input.

21 tests, and they run in the DB-less default suite.

### NITPICK — `TurnoverReportLive` was left behind

`turnover_report_live.ex` is the eighth list-ish screen and still keeps its
date-range state in bare assigns with a `handle_params/3` that ignores its
params. Its state is a date range rather than search/sort, so it is not a
mechanical copy of this PR's pattern, and widening the PR's scope
post-merge is not the right call — recorded here as the obvious follow-up.

### Not changed, deliberately

- **`ViewConfig` preferences stay out of the URL.** `stock_view` and
  `warehouse_scope` are per-user persisted settings, so a shared Stock link
  does not carry the sender's warehouse scope. The PR documents this as
  intentional and it is the right call — they are preferences, not query
  state.
- **`mount/3` still does DB work** (`assign_column_state/2` on every screen,
  `get_view_config/2` + `list_warehouses/0` on Stock). This is against the
  usual "no queries in mount" rule, but it is not a regression — the work ran
  twice per page load before this PR too, just from `handle_params/3` — and
  gating it on `connected?/1` would change what the disconnected render paints.
  Out of scope for a post-merge fix.

## Validation

`mix precommit` **passes** (exit 0). It did not when this review started — see
"Clearing the gate" below for what was wrong and what was done about it.

| Step | Result |
| --- | --- |
| `mix compile --force --warnings-as-errors` | clean |
| `mix deps.unlock --check-unused` | clean **after** the `mix.lock` fix below |
| `mix hex.audit` | no retired or advisory packages |
| `mix format --check-formatted` | clean |
| `mix credo --strict` | no issues (1734 mods/funs, 110 files) |
| `mix dialyzer` | passed — 6 warnings, all 6 matched by `.dialyzer_ignore.exs`, 0 unnecessary skips |
| `mix test` | 75 tests, 0 failures (701 excluded) |

- **`mix test` cannot cover the sort-reset fix here.** PostgreSQL is unavailable
  in this environment, so the 701 `:integration` tests — including every
  `*_index_live_test.exs` LiveView test — were auto-excluded exactly as
  CLAUDE.md describes. The new whitelist test runs in the DB-less set and
  passes (21 assertions across the 7 screens). The `__view_config_changed__/1`
  fix itself is verified by reading `UrlState.sanitize/2` + `reload?/3` and by
  compile/dialyzer only, **not** by an executed integration test — worth a run
  on a machine with a database before this is relied on.
- **`mix.lock` carried eight unused entries** (`igniter`, `sourceror`,
  `spitfire`, `rewrite`, `owl`, `text_diff`, `ex_ast`, `glob_ex`) left over from
  the dependency bump in 0.2.5, which `mix deps.unlock --check-unused` rejects.
  Cleaned with `mix deps.unlock --unused`.

## Clearing the gate

CLAUDE.md names `mix precommit` as the gate, but it had not passed on `main` for
a long time — `.credo.exs` has been unchanged since the scaffolding commit and
the findings sat in files across the whole codebase, not in anything PR #11
touched. Before changing anything it was confirmed that this review's own edits
added **zero** new credo findings (the per-file issue set was byte-identical
before and after). The backlog was then cleared in full.

### credo: 291 → 0

| Check | Count | How |
| --- | --- | --- |
| `Design.AliasUsage` | 248 | Aliased the 8 distinct modules being called fully-qualified (`PhoenixKit.Users.Auth`, `…Auth.Scope`, `…Users.Roles`, `PhoenixKit.Utils.Routes`, `PhoenixKitWarehouse.Test.Repo`, `…Test.Fixtures`, `…Web.ColumnManagement`, `PhoenixKitWeb.Components.MediaBrowser`) across 42 files and rewrote the call sites |
| `Readability.AliasOrder` | 37 | Sorted every run of consecutive alias statements, including the members inside `Base.{A, B}` groups |
| `Readability.WithSingleClause` | 2 | `with`/`else` with a single `<-` → `case`, in the two `set_location` handlers |
| `Readability.PreferImplicitTry` | 1 | `activity_log.ex` `log_responsibility_changed/3` now uses a function-level `rescue` |
| `Readability.StringSigils` | 1 | `@doc` with four escaped quotes → `~S"""` heredoc |
| `Refactor.CyclomaticComplexity` + `Refactor.Nesting` | 2 | Split `SupplierOrders.import_from_internal_orders/3` (complexity 16, nesting depth 5) |

Two of these are worth calling out because they were not purely cosmetic:

- **`ColumnManagement.save_view_config/6` could not simply be aliased.** The
  call sits inside the `__using__` quote, so the alias would have had to exist
  in every *host* LiveView. Replaced with `unquote(__MODULE__)`, which binds the
  defining module at expansion time and is correct regardless of the caller.
- **`import_from_internal_orders/3` was split, not merely reindented.** The
  134-line body now delegates to `load_posted_internal_orders/1`,
  `load_items_by_uuid/1`, `collect_import_lines/2`, `import_line/6`,
  `sole_supplier?/2` and `merge_import_lines/2`. Behaviour is preserved
  exactly: the old `cond` (shortfall zero → skip, nil item → skip, otherwise
  match the supplier) becomes one short-circuiting `if`, evaluated in the same
  order, and the `[%{uuid: ^target_supplier_uuid}]` single-supplier match is now
  `sole_supplier?/2`. **This path is exercised only by `:integration` tests,
  which could not run here** — it is covered by compile and dialyzer alone and
  deserves a run against a database.

### dialyzer: 11 → 0 actionable

The first dialyzer run appeared to report a single warning; that was a
truncated `tail` of the log, and the real count was **11**. Four were genuine
dead or unreachable code:

- `warehouse_browser.ex` and `inventories.ex` each carried a
  `defp pick_name(_), do: nil` fallback under a `when is_map(translation)`
  clause. The caller is `safe_get_translation/2`, which already rescues to
  `%{}` — that rescue is the defensive layer, and the extra clause was dead.
- `storage_folders.ex` threaded a `parent_uuid` through `find_or_create/3` and
  `find_by_name/2` that both call sites passed as `nil`, so
  `where_parent(query, uuid)` was unreachable. The parameter is gone and the
  lookup is explicitly root-scoped.
- **`warehouse_browser.ex:590` and `:611` were a real (cosmetic) bug.** The
  read-only price and sum cells rendered
  `format_input_decimal(value) || "—"`, but `format_input_decimal/1` returns
  `""` — never `nil` — for a missing value, and `""` is truthy in Elixir. The
  `—` placeholder could therefore never appear; the cell just went blank.
  Replaced with an explicit `blank_to_dash/1`. Dialyzer flagged this as
  `guard_fail`; nothing else would have.

The remaining six are one repeated artefact of Ecto's types, not defects here:
each context's `lock_status_step/3` builds a multi with `Ecto.Multi.new()` and
passes it to `Ecto.Multi.run/3`. `Ecto.Multi.t()` is `@opaque`, but dialyzer
sees through `new/0` to the concrete struct and reports an opaqueness mismatch.
Rewriting the call as `Ecto.Multi.new() |> Ecto.Multi.run(...)` was tried and
only moves the column the warning points at, so there is no code-level fix.
They are listed with that justification in a new `.dialyzer_ignore.exs`, wired
up in `mix.exs` together with `list_unused_filters: true` so a filter that stops
matching is reported rather than silently rotting.
