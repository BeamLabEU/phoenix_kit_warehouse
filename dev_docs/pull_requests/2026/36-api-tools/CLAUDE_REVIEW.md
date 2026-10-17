# PR #36 — Warehouse admin API tools (stock lookup, receipts, stocktakes, issues)

**Reviewed:** 2026-10-17 · **Author:** timujinne · **Verdict:** merged; no
runtime bug found, but the gate was red (dialyzer) and is fixed; one small
duplication tidied, two limitations left on record.

## What landed

- **`PhoenixKitWarehouse.API`** — five tools returned by `api_tools/0`:
  `warehouse.list_locations`, `warehouse.get_stock` (read) and
  `warehouse.receive_stock`, `warehouse.set_stock`, `warehouse.issue_stock`
  (write). The write tools are offered only when core exports the
  confirmation-gate markers (`Keys.active?/1`, `Flow.gate/1`); otherwise only
  the read tools are.
- **`API.Write`** — one document per call, created and posted in one
  transaction through each context's `create_and_post/2`; `prepare/2` collects
  every problem before anything is written; a repeated `external_ref` is
  answered from the posted document and *compared* with the request
  (`external_ref_lines_differ` / `external_ref_basis_differs`), never blindly
  `skipped`.
- **`API.Refs` / `Lines` / `Quantity` / `Source` / `Warehouses`** — product
  refs (`id` / `sku` / `external_id`) resolved to live items of one catalogue,
  strict decimal parsing (cap, 6 places, no exponent), the `source` /
  `external_ref` basis of an issue, active-warehouse checks.
- **`API.Audit` + `ActivityLog.log_posted/2`** for receipts and issues, with
  `mode: "auto"` and API metadata.
- **Posting layer** — `:source_refs` accepted by `create_and_post`,
  `resulting_quantity` recorded on receipt lines, and an unlocked
  `PostingSupport.posted_by_external_ref/3` for the early retry lookup.

## Checked and found sound

- **Contract with core** (read against the local core checkout, `lib/phoenix_kit/api/`):
  `Tool.new!` fields and `{module, function}` handlers; ctx keys `:actor`,
  `:request_id`, `:dry_run?`, `:approved_by_uuid`; the dry-run answer
  `{:preview, map, binary}`; `retry_after` in the error context (core turns it
  into a header); `insufficient_stock`, `validation_failed` and
  `internal_error` are all known problem codes. `output_schema` is
  documentation only, so the `would_post` / `would_skip` previews (wrapped by
  core) do not conflict with the `status` enum.
- **No stock moves on the retry path**, and the lookup takes no advisory lock,
  so refused calls, previews and dry runs never wait for a posting in flight;
  a retry that races the first call still reaches the locked lookup inside the
  posting transaction and gets the same comparison (`finish(:skipped, ...)`).
- **Lock order** — the posting layer's stock locks are in item order for
  receipts, issues and inventories (PR #33 fix), so the API cannot form a
  lock cycle with the UI; the one remaining way to hit `40P01` is mapped to a
  retryable `500` with `posted: false`.
- **Quantities** — regex-gated strings (`\A\d{1,10}(\.\d{1,6})?\z`), ints and
  floats go through the same `check/2`; `-0.0` is normalised, exponent forms
  and `NaN`/`Infinity` never reach `Decimal`.
- **Refs** — `cast_uuid/1` only accepts the 36-character text form, so a
  16-byte string is not read as a raw UUID; trashed items and deleted
  catalogues are re-checked even when the catalogue's resolver answered.
- **Audit** — written after the commit and never fails the document; the
  rescue logs only the exception kind when API metadata is present.
- **Tests** — 1285 tests, 0 failures with the Hex-pinned core (25 `:core_api`
  tests excluded there); the 262 tests under `test/phoenix_kit_warehouse/api`,
  `test/readme_test.exs` and `create_and_post_test.exs` all pass against the
  local core checkout.

## Findings

### BUG - MEDIUM — `mix precommit` was red after the merge (fixed)

Against the Hex-pinned core, dialyzer failed with
`lib/phoenix_kit_warehouse/api.ex:169: Function PhoenixKit.API.Tool.new!/1 does
not exist` (exit 2). `@compile {:no_warn_undefined, ...}` silences the compiler
only; dialyzer still resolves the call. The code is correct (the tools are built
only behind `Code.ensure_loaded?(Tool)`), so the fix is a justified entry in
`.dialyzer_ignore.exs` limited to `api.ex` / `:unknown_function`, to be dropped
once the `phoenix_kit` floor is a release that ships `PhoenixKit.API.*`.
`mix precommit` is green again (exit 0, 9 warnings, 9 skipped).

### NITPICK — The catalogue scope was unwrapped twice in `API.Write` (fixed)

`prepare/2` and `requested_lines/3` each carried the same
`case Refs.catalogue_scope(...) do {:ok, uuid} -> uuid; {:error, _} -> nil end`.
Both now go through one private `scoped_uuid/1`; behaviour is unchanged (the
two paths must keep agreeing, because a retry reads its lines "as a first call
reads them").

### IMPROVEMENT - MEDIUM — The tool tests do not run under the published core (left)

The 25 `:core_api` tests are excluded unless `PhoenixKit.API.Executor` is
loaded, and the pinned core on Hex (2.62.2) ships none of `PhoenixKit.API.*`.
`mix test` and `mix precommit` therefore never exercise the executor-level
tests (scopes, confirmation, dry run, approvals) in CI. Running them needs
`PHOENIX_KIT_PATH=../phoenix_kit`, and today that checkout also needs newer
`beamlab_countries` / `fresco` / `etcher` than `mix.lock` pins, so it cannot be
run in place without a `mix deps.update` (this review ran it from a scratch
copy). Not changed here: it is a core-release question, not a defect of the
PR. Once core publishes the API, raise the `phoenix_kit` floor in `mix.exs`
and the exclusion can go.

### IMPROVEMENT - LOW — `PostingSupport` still does not compare a retry (left)

`GoodsIssues.create_and_post/2` documents that it answers `:already_posted`
without comparing lines; the comparison lives in `API.Write`. Another caller of
`create_and_post/2` has to make the same comparison itself. Moving it into the
posting layer would be a larger change to a shared path for no current caller,
so it stays as is, on record.

## Erratum (added after the Codex re-check, `22cbf2f`)

The verdict above ("no runtime bug found") was wrong. Two retry bugs in
`API.Write` were in code this review read and described as intended:

- `unreadable_lines/3` answered `:unknown` (skipped) whenever every error was a
  trashed product of the document and the line count matched, so a changed
  quantity, unit value or duplicate on any other line was never compared.
- `names_posted_product?/2` returned `true` for every `external_id`, so an ID
  that never existed passed for a stored product.

Both are fixed in `22cbf2f` (see `CODEX_REVIEW.md`). The "Checked and found
sound" list should not be read as covering the retry comparison for trashed
products. Re-verified here: `mix test` 1289 tests, 0 failures (25 `:core_api`
excluded); `mix precommit` exit 0.
