# PR #37 — Do not post a stocktake document when every counted line is unchanged

**Reviewed:** 2026-10-21 · **Author:** timujinne · **Verdict:** merged; no
bugs found, one nitpick left on record.

## What landed

`Inventories.create_and_post/3` takes `skip_unchanged: true`: inside the
posting transaction, under the stock row locks and before the document number
is drawn, a stocktake whose lines all equal the stock already held answers
`{:error, :unchanged}` and writes nothing. `warehouse.set_stock` passes the
option and answers `status: "unchanged"` (per-line `results`, no `document`);
its dry run answers the same status. README and tool descriptions say that
the `external_ref` is not recorded, so a later call with it is a new stocktake.

## Checked and found sound

- **Preview and real call agree.** The preview calls a line `unchanged` when
  `from == to`; the guard compares `counted_quantity` with the locked stock
  row (a missing row counts as 0, as `from_of/2` does). API lines carry no
  `unit_value` (`@kinds[:inventory].unit_value == false`), so the guard's
  valued-document branch is unreachable from the API and cannot disagree.
- **Quantities have at most 6 places** (`API.Quantity`), so `Decimal.eq?`
  cannot see a difference the `numeric(_, 6)` column would round away.
- **Nothing leaks on the unchanged path.** `locked_prior_stock/3` claims
  missing stock rows with `ON CONFLICT DO NOTHING`; the `{:error, :unchanged}`
  from the Multi step rolls that back, so no zero rows are created and no
  number is burned. The `external_ref` retry check runs before the guard, so a
  posted reference is still answered `skipped`.
- **`{:error, :unchanged}` is matched before the generic `refuse/2`** in
  `Write`, and the confirm-token flow needs nothing: an `unchanged` preview
  gets a token like any preview, and the confirmed call ends in the same reply.
- `create_and_post/2` keeps working (`opts \\ []`), and the default guard is a
  no-op.

## Findings

### NITPICK — The stock rows are read and locked twice (left as is)

On the posting path `unchanged_guard/1` calls `locked_prior_stock/3` and the
post step calls it again for the same lines. The second claim insert is a
no-op and the locks are already held, so it costs one extra select per
stocktake. Sharing the result would mean threading the guard's output through
`PostingSupport.create_and_post_multi/2` into the `:post` callback for every
document kind; not worth it for a select on rows already locked.
