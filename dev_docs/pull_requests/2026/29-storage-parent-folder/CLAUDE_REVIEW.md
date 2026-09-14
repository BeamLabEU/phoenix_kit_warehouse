# PR #29 — Document folders under a host-configured parent folder

**Reviewed:** 2026-09-14 · **Author:** timujinne · **Verdict:** merged; three
bugs fixed post-merge, shipped in 0.4.3.

## What landed

`PhoenixKitWarehouse.StorageFolders` gained an optional host hook:

```elixir
config :phoenix_kit_warehouse, :storage_parent_folder, {MyApp.Media, :for_warehouse}
```

called as `for_warehouse(resource, actor_uuid)` and returning
`{:ok, parent_folder_uuid}` or `nil`. Document folders (`<prefix>-<number>`)
are created under that parent instead of the storage root. A name lookup
checks the parent first, then the root, and "adopts" (moves) a root hit
under the parent so pre-hook folders keep their files. Without the config
the behaviour is unchanged. Four DataCase tests cover root default, parent
creation, root adoption, and a hook clause returning `nil`.

## Findings

### BUG - HIGH — Cached folders were never adopted (fixed)

The moduledoc promised that folders created before the hook existed get
moved under the parent. But five of the six resources (goods issue, goods
receipt, inventory, supplier order, transfer) cache `storage_folder_uuid`,
and `ensure_cached/5` returned the cached folder without ever consulting
the hook. Every folder those forms had already opened is cached, so in
practice adoption only ran for internal orders (no cache column) — every
existing document folder in a live host stayed at the root forever. The
PR's adoption test passed only because it created the legacy folder by hand
without linking it to the order.

**Fix:** `ensure_cached/5` now has a `%Folder{parent_uuid: nil}` clause that
resolves the parent and moves the folder (`adopt/2`, shared with
`adopt_from_root/2`). Only root-level folders are touched, so a folder an
admin moved elsewhere in /admin/media is left alone, and once moved the
fast path never calls the hook again. Test: *"a folder cached at root
before the hook existed is moved under the parent"*.

### BUG - MEDIUM — Trashed folders broke name lookup (fixed)

Core's unique index is
`(name, COALESCE(parent_uuid, 0)) WHERE trashed_at IS NULL`, so a trashed
and a live folder may share a name and parent. `find_by_name/2` did not
filter `trashed_at`, so `repo().one()` raised `Ecto.MultipleResultsError`.
Adoption could also pick up and move a trashed folder. (The root-only
lookup had the same latent bug before this PR; the PR doubled the lookups.)

**Fix:** `find_by_name/2` matches `is_nil(f.trashed_at)`. Test: *"a trashed
folder with the same name is ignored by lookup"* — it raised
`MultipleResultsError` against the PR code.

### BUG - MEDIUM — An unguarded host hook hung the Files panel (fixed)

`parent_uuid_for/2` `apply`'d host code with no guard. The form LiveViews
call `ensure_for_*` inside a `Task.Supervisor.start_child` and only handle
`{:files_folder_result, _}` — they don't monitor the task. So a hook that
raised, or returned `{:ok, "not-a-uuid"}` (which makes the
`f.parent_uuid == ^uuid` query raise `Ecto.Query.CastError`), killed the
task silently and left the Files panel spinning forever.

**Fix:** the hook call rescues/catches exits and `Ecto.UUID.cast/1`s the
returned value; failures log a `:warning` naming the hook and fall back to
the root. Because of the cached-adoption fix above, a folder created at the
root during a hook outage is moved once the hook works again. `{:ok, nil}`
is accepted as a silent `nil`. Test: *"a hook that raises or returns a
non-UUID falls back to root"*.

### IMPROVEMENT - LOW — Race fallback could return `{:ok, nil}` (fixed)

On a unique-constraint race `find_or_create` returned
`{:ok, find_by_name(...)}` unconditionally; a `nil` there would crash
`create_and_cache` on `folder.uuid`. The create branch is now its own
`create_folder/3` and returns `{:error, :create_folder_failed}` if the
re-lookup finds nothing. (This split also keeps `find_or_create` inside
credo's nesting limit.)

### Not changed (on record)

- **The cached fast path still returns a trashed folder.**
  `Storage.get_folder/1` doesn't filter `trashed_at`, so a document whose
  folder was trashed (not deleted) keeps opening it. That predates this PR
  and restoring from trash may be exactly what an admin expects, so it's
  left alone.
- **The form LiveViews don't monitor the folder task.** Any other crash in
  `ensure_for_*` (e.g. the `{:ok, _} = set_folder_fn.(doc, nil)` match)
  still leaves the spinner up. This predates the PR and affects six
  LiveViews; fixing the one host-controlled failure source was the
  proportionate change.
- **The hook is re-called on every open while a move keeps failing** (e.g.
  the parent is missing). It's bounded to root-level folders and the
  fallback is correct, so no memoization was added.
- **The config is documented in the moduledoc and CHANGELOG only** — the
  README has no configuration section to extend.

## Verification

- The three new regression tests fail against the PR's
  `storage_folders.ex` (stale root parent, `MultipleResultsError`,
  unguarded hook) and pass with the fixes; 7/7 in the file.
- `mix test`: 831 tests, 0 failures (exit code checked directly).
- `mix precommit`: exit 0 — compile with warnings-as-errors, deps.unlock
  check, `hex.audit`, format check, `credo --strict` (no issues), dialyzer
  (the 6 known `.dialyzer_ignore.exs` skips, nothing new).
