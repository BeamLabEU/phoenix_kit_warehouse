# PR #31 — Media reorganizer source: plan legacy folder moves from the attachment hooks

**Reviewed:** 2026-09-16 · **Author:** timujinne · **Verdict:** merged after six
review rounds; one medium bug and two contract gaps fixed post-merge.

## What landed

`PhoenixKitWarehouse.MediaReorganizer.plan/2`: a media-reorganizer plan
source for core's `PhoenixKit.Modules.Storage.Reorganizer` engine, which
shipped in phoenix_kit 2.24.0 (the version locked here). It's registered
through `PhoenixKitWarehouse.media_reorganizer/0`. For all six document
kinds it plans a `:move` of each live document's current folder under the
parent returned by `:storage_parent_folder`, with a pointer back-fill through
`after_move`. It also returns `:report` actions for duplicates, relocated
stray copies, hook errors, hook-answered-root (`:hook_nil`), and orphaned
legacy folders. `StorageFolders.folder_name/3` is now public (`@doc false`)
so both modules use the same naming rule. 76 DataCase tests.

The source was checked against the `Reorganizer.Source` moduledoc in core
2.24.0 (the contract every module source follows) and against the catalogue
sibling. Hook handling, claims, the root-only scope when no hook is
configured, the explicit-`nil` guard, converging targets, deterministic
order, the light select, and the `counts` contract all match. No problems
found there.

## Findings

### BUG - MEDIUM — `after_move` overwrote a pointer changed between plan and apply (fixed)

`write_pointer/3` locked the row and ignored soft-deleted records. Its
comment said it "picks up a pointer `ensure_for_*` may have set concurrently".
In fact it wrote the planned folder over whatever pointer was there. Scenario:
the plan adopts a folder under a third-party parent (the U1 hook-nil path) or
a dangling pointer. Before `--apply`, a user opens the document form.
`ensure_for_*` doesn't find that folder where it looks, so it creates and
caches a fresh one, and the user uploads into it. Apply then points the
document back at the old folder, and the new uploads lose their folder link.

**Fix:** `write_pointer/3` compares the locked row's pointer to the one
selected at plan time:

- already equal to the target folder → `:ok`
- unchanged → write
- anything else → `{:error, :pointer_changed}`

The engine rolls that action back, and the next plan run sees the new state.
Three tests cover these branches (changed, already set, unchanged).

### IMPROVEMENT - MEDIUM — `:relocated` reason didn't name the third-party parent (fixed)

Core's contract says every `:relocated` reason names where the copy actually
is: at the root, as a twin under the target, or "under `<parent name>`". The
third-party case only said "under a different parent", so the operator had
to look the folder uuid up by hand. Catalogue already names the parent.

**Fix:** stray copies are gathered as `{entry, folder}` pairs first, and their
parent names are loaded in one batched query (`load_stray_parent_names/1`).
Root and target-parent copies are skipped because their wording already says
where they are. The reason now reads `… under a different parent,
"Some other container" (<uuid>) …`. The existing test also checks the name
and the uuid.

### NITPICK — Stale "2.23.x" comments (fixed)

The moduledoc and the comment on `media_reorganizer/0` said "today's hex core
(2.23.x) does not ship the engine". The lock is now 2.24.0, which ships both
the engine and the callback. Both comments now say "since core 2.24.0; the pin
floor `~> 2.0` predates it, so no `@behaviour`/`@impl`", matching catalogue.
`@behaviour`/`@impl` are **not** added: the floor stays `~> 2.0`, like
catalogue's, and the registry looks the function up by name. Raising the
floor only to silence a warning isn't worth it.

The moduledoc also pointed at an "Orphaned legacy folders" section "below"
that only exists as a code comment. It now points at `orphan_actions/3`.

### Noted, not changed

- **Every run re-reports `:hook_nil`** for a document whose folder sits under
  a real parent while the hook answers root, even with nothing to back-fill.
  The contract asks for this, and it is useful: the hook and reality disagree.
- **Orphan lookup by `number`** assumes numbers are unique per kind. They come
  from a per-table sequence, but no unique index enforces it. If a hand-edited
  duplicate number is shared by a live and a deleted document, a root folder
  could be reported as an orphan when it isn't. The folder is only reported,
  never moved or trashed, so no guard was added.
- **`live_prelim_records/0` is unbounded** (every live document of six kinds,
  four light columns). This is fine for an operator-run mix task and is what
  the contract's "one batched query per kind" asks for.

## Validation

`mix format`, `mix precommit` (compile with warnings as errors, deps unlock
check, hex.audit, format check, credo --strict, dialyzer), and the full
`mix test` suite.
