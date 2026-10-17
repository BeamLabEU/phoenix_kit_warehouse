# PR #36 — Warehouse admin API tools

Reviewed 2026-10-17 by Codex. Author: timujinne. Merge: `c33841e`.

Scope: the latest merged PR and the follow-up in `1f5fa14`, with particular
attention to document retries, reference resolution, stock posting, and previews.

## BUG — MEDIUM: one missing product disabled comparison of every line (fixed)

After posting a receipt with A = 5 and B = 2, trashing A made a retry with
A = 5 and B = 3 answer `skipped`. The same happened with a changed quantity
on A itself, a replacement of B by a different live item, changed receipt
unit values, or a duplicate of the trashed product. Issues and stocktakes
had the same problem. `unreadable_lines/3` returned `:unknown` whenever the
reference errors concerned stored products and the line count matched;
that bypassed all quantity, identity, price, and duplicate comparisons.

The retry now recovers missing identities from the posted document and uses
the same quantity and duplicate checks as a new request. It then compares
all prepared lines against the posted document. Changed requests are refused;
unchanged requests retain the `external_ref_lines_unverified` effect to
disclose that the live products no longer resolve. Previews use the same
comparison. Recovery never supplies identities to a new posting.

Regression tests reproduced the failures before the fix and cover receipt,
issue, stocktake, duplicate, replacement, price, and dry-run behavior.

## BUG — MEDIUM: any unknown external ID passed for a stored product (fixed)

`names_posted_product?/2` returned `true` for every external ID, including one
that never existed. A request could therefore replace a valid line with an
unrelated external ID and receive `skipped` with an unverified-lines effect.

Missing refs must now identify a stored product: canonical UUID, a unique
stored SKU, or a unique stored external ID. New API documents preserve the
external ID used in a line in that line's JSON metadata, so a legitimate
external-ID retry still works after the product is trashed. No database
migration is needed. Ambiguous stored SKUs cannot establish an identity.

For older documents without an external-ID snapshot, a missing external ID
is refused; retry using the stored product UUID. README and tool descriptions
explain the updated comparison and compatibility behavior.

## Validation

- `mix test`: **1,289 tests, zero failures**, with the existing 25 `:core_api`
  tests excluded. PostgreSQL integration tests ran.
- `mix precommit`: **passed**, including compilation with warnings as errors,
  unused-lock checking, Hex audit, formatting, Credo, and Dialyzer. Dialyzer's
  nine existing warnings are covered by the existing ignore file.
- In an isolated scratch copy, used `PHOENIX_KIT_CATALOGUE_PATH` to select the
  catalogue API implementation in the local `phoenix_kit_catalogue-wt-api-tools`
  checkout. Ran the API directory, README tests, and create-and-post tests:
  **258 tests, zero failures**, with the same 25 core-executor exclusions.
  This exercised the SKU and external-ID regression tests that the published
  catalogue dependency cannot run. The repository's dependency lock is unchanged.

## Remaining limits

The published core dependency lacks `PhoenixKit.API.Executor`, so the existing
25 `:core_api` executor tests remain excluded on the ordinary dependency pin.
This review does not change the core floor or release any package. The posting
contexts still delegate retry-body comparison to API callers, as documented
in the earlier review.
