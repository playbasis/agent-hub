# Workspace contracts (v1)

Portable, versioned wire formats for evidence of agent work and for the
economics built on it. The JSON Schemas in `schemas/` are normative; the Swift
types in `packages/WorkspaceContracts` (Foundation only, no AppKit, providers,
credentials or databases) and `scripts/check-workspace-contracts.py` (Python
standard library only) are two independent readers that must agree on the
shared fixtures in `tests/fixtures/workspace-economics/v1`.

| Contract | Schema | Swift type |
|---|---|---|
| workspace-receipt/1 | `workspace-receipt-v1.schema.json` | `WorkspaceReceipt`, folded by `WorkspaceReceiptLedger` |
| accepted-outcome/1 | `accepted-outcome-v1.schema.json` | `AcceptedOutcomeRecord` |
| effort-assessment/1 | `effort-assessment-v1.schema.json` | `EffortAssessmentRecord` |
| economic-report/1 | `economic-report-v1.schema.json` | `EconomicReport` (+ `$defs` for assumptions, rubric, rates) |
| report-bundle/1 | `report-bundle-v1.schema.json` | `ReportBundleManifest`, `EvidenceIndex` |
| shared definitions | `workspace-common-v1.schema.json` | `ContractPrimitives.swift` |

## Wire rules

- **Timestamps**: RFC 3339 with a zone, written in UTC at millisecond
  precision (`2026-11-06T10:00:00.000Z`). Compare dates only after
  normalising to that precision (`ContractTime.normalized`), so a value and
  its decoded copy fall on the same side of every boundary.
- **Windows** are half-open `[from, to)`. Calendar periods name their IANA
  zone and use the Gregorian calendar (weeks start Monday).
- **Token quantities** are canonical base-10 strings, `0` to
  `9223372036854775807`. JavaScript and other readers that parse JSON numbers
  as doubles would silently round large integers; strings can't be rounded.
- **Money, hours and ratios** are decimal strings: at most 18 integer and 6
  fraction digits, no exponent. Producers write the canonical form (no
  trailing fraction zeros, no `-0`); readers accept any valid decimal.
  Arithmetic stays decimal; money is rounded to cents, halves to even, after
  each total.
- **Small counts** (commits, lines, model steps) are JSON integers up to
  2^53−1.
- **Unknown is null**, never zero. Records write explicit nulls; in the
  economic report an absent optional field means the same.
- **Extensions**: objects reject unknown properties except `x-` fields.
  Readers ignore them; digests exclude them. Readers also ignore unknown
  fields from newer minor revisions.

## Receipt identity and replay

| Field | Meaning |
|---|---|
| `eventID` | Stable logical identity, namespaced by the producer. |
| `revision` | Observation revision. A higher revision with different content supersedes a lower one. |
| `contentDigest` | `sha256:` over RFC 8785 canonical JSON of the receipt without `revision`, `observedAt`, `contentDigest` and `x-` fields. |

Folding (`WorkspaceReceiptLedger.ingest`): the same digest again is a
duplicate; the same revision with a different digest is a conflict (the first
is kept and the conflict reported); a lower revision is stale; a receipt that
fails validation, including a wrong digest, is rejected. Replaying any file
any number of times leaves totals unchanged.

## Measurement distinctions

- **Units**: `model_step`, `conversation_turn`, `request_attempt` and
  `session` are different things and are never counted as each other.
- **Accumulation**: `incremental` receipts count as they are; `cumulative`
  receipts are running totals for the session's series of that unit, ordered
  by `time.at` and differenced from zero. A decrease starts a new series
  (`seriesResets`).
- **Scope**: `local_native_history`, `provider_account`,
  `provider_plan_window`, `native_goal`, `bridge_session`,
  `direct_provider_response`, `repository_history` describe different
  populations and are never added together.
- **Usage**: `total` and `output` are the canonical sums. `input` follows the
  provider's convention, stated in `inputIncludesCachedInput` (Codex includes
  cache reads, Claude doesn't). `cachedInput` and `reasoning` are subsets.
  Only `provider_reported` and `derived` values enter known totals;
  `completeness` and provenance make a total partial.
- **Time**: `provider_event` (with `at`), `native_interval` (`start`/`end`)
  or `unplaced` (never in windowed totals). Folding reports wall-clock span,
  the union of intervals (overlap-adjusted: when any agent worked) and
  per-session unions summed (summed worker time: parallel agents add up).
  Local CPU time and provider compute time aren't observable and stay
  unknown.
- **Aggregates** (`toolCalls`, prompts) belong to the whole unit and are
  never expanded into individual executions.

## Bundles

A report folder holds `manifest.json` plus any of `report.json`,
`outcomes.json`, `assessments.json`, `assumptions.json`,
`evidence-index.json`, `receipts.jsonl` and `briefing.md`.
`ReportBundleManifest.verify` accepts only listed plain files (no links, no
extra files, bounded sizes) with matching sizes and checksums. Checksums
establish integrity, not truth. An imported report belongs in its own
namespace; it is never merged into live data, executed, or used to open the
paths and links it mentions.

## Checking the contract

```sh
swift test --package-path packages/WorkspaceContracts
python3 scripts/check-workspace-contracts.py
```

`make check` runs both. Regenerate fixtures and the golden report bundle
after an intended contract change with `WORKSPACE_CONTRACTS_WRITE_FIXTURES=1`
on the Swift tests, then review the diff.
