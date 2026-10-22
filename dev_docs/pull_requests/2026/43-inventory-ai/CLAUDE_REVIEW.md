# PR #43 — Count a stocktake from photos with an AI proposal

**Reviewed:** 2026-10-22 · **Author:** timujinne · **Verdict:** merged; one
race closed, one doc fixed.

## What landed

The photo inventory: `InventoryAI` (run lifecycle), `Runner` (the task that asks
the AI and writes the answer itself), `Photos`, `CatalogueList`, `Prompt`,
`Response`, `Counting`, `Proposal`, `Review`, `Lines`, `Apply`, `Guard` (the
`phoenix_kit_ai` task-guard seams), `Settings`, the `InventoryAIRun` schema and
migration chain **V3**, the `InventoryAIPanel` on the stocktake form, the AI
block on the settings page, `Inventories.fingerprint/2` and the `base_fingerprint:`
check on `update_draft/3`, and `phoenix_kit_ai` as a hard dependency. Four
locales.

## Findings

### IMPROVEMENT - MEDIUM: Conduct saved and posted in two transactions, the post compared nothing — fixed

`InventoryFormLive` "post" saves the buffer with `base_fingerprint:` (refused
when another tab changed the lines) and then calls `Inventories.post_document/2`
in a separate transaction. `post_document` posts the lines of the row it locks,
not the struct, and compared no fingerprint. An Apply (or a save) from another
tab landing between the two statements was therefore posted unseen — the
exact case the fingerprint exists to stop, on the write that moves stock. #47
closed the same window for supplier orders with `expected_version:`.

Fix: `post_document/3` takes `base_fingerprint:` (same semantics as
`update_draft/3`: compared under the row lock, `nil` refused as `:stale`,
absent option compares nothing), and the form passes the fingerprint its save
just returned. The form already maps `{:error, :stale}` to the "changed in
another tab" message. Tests: `inventories_fingerprint_test.exs`
("post_document/3 with base_fingerprint:").

### IMPROVEMENT - MEDIUM: `mix precommit` was red on dialyzer — fixed

`Review.new/1` was specced as a closed map (`%{uuid, place_label, result}`), but
the panel passes it the whole `InventoryAIRun` struct in three places, so
dialyzer reported the calls (and the anonymous functions around them) as
breaking the contract. Specced as `InventoryAIRun.t()` now. The two
`call_without_opaque` reports on `gettext.ex` are the generated plural calls
against `Expo.PluralForms`' `@opaque` type, the same kind of dependency
artefact as the `Ecto.Multi` entries already in `.dialyzer_ignore.exs`; ignored
the same way, with the reason written down.

### NITPICK: AGENTS.md listed five hard dependencies — fixed

`phoenix_kit_ai` is in `extra_applications` and `pk_dep`, none `optional:`, but
the "Hard dependencies" paragraph of AGENTS.md (CLAUDE.md is a symlink) still
named five. It now names it and says what is optional (the `"ai"` module being
on and an endpoint chosen), as it does for comments.

## Checked and found sound

- **One running run per document**: the document row is locked, stale runs are
  closed, the caller's step (photos checked against the document's folder, or
  the failed run closed by a retry) runs, then the insert — with the partial
  unique index behind it, mapped to `:already_running`. `discard`, `retry`,
  `show_late_result` and `apply_run` all re-read the run *through the
  document* (`:wrong_document`), and every transition is a compare-and-set on
  the status.
- **The task writes its own result** and cannot leave a run `running`: the
  whole body is under `rescue` + `catch :exit`, a failed write retries once as
  `interrupt_run`, and the page also monitors the task. A run closed meanwhile
  keeps the answer in `late_result` without touching the status. Log lines
  carry the kind and place of a failure, never its values (the arguments of a
  failed AI call hold the key and the photos).
- **Apply is one transaction**: row lock, live draft, fingerprint equal to the
  tab's base, warehouse unchanged, run claimed `proposed -> applied`, every row
  checked (a row of this proposal, an active item, a finite quantity below
  10^12 via `Number.parse_decimal/2`, one row and one item once, an action the
  line allows), stock read in the transaction, lines written, document read back
  with its new fingerprint. A row touching an item that has two lines is refused.
- **Photos**: only files of the document's own Storage folder (home or link, not
  trashed) may be sent to the third-party model, checked under the lock;
  `Storage.retrieve_file/1` returns a temporary copy (read in `phoenix_kit`),
  which is the file `Photos.convert/2` removes — not the stored original. A
  browser-supplied content type only labels the stored file; the bytes go through
  `ImageProcessor.preview_jpeg/3` and a non-image is skipped and reported.
- **Nothing the model writes is trusted**: `Response.check/2` maps a catalogue
  number outside the list to `nil`, bounds every count and fill, and names,
  units and categories come from the catalogue only. Text shown from the answer
  is escaped by HEEx.
- **Settings** are gated on the `"ai"` module or an administrator in `render/1`
  *and* in the event handler (a single warehouse permission opens the admin
  area, so `can_access_admin_area?` would not do); the endpoint must be one the
  page offers or the one already saved; the limits are bounded.
- **The prompt upgrade** (`Prompt.ensure/1`) only rewrites a prompt that is the
  module's own, enabled, and still holding a shipped template, rechecked under
  the row lock — an edit by a person is never overwritten.
- **V3** is `CREATE ... IF NOT EXISTS`, cascades only on a hard delete of the
  document, adds nothing to core's manifest, and `down/1` keeps the table.
- All four `.po` files carry the new strings translated.

## On record

- `list_runs/1` closes runs stuck `running` for more than ten minutes before it
  lists them — a write on a read path, by design (the page that started the run
  may be gone). A provider slower than ten minutes would be closed as
  interrupted and its answer would land in `late_result`, which a person can
  still show.
