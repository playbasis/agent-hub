---
name: economic-work-review
description: Estimate the human effort behind accepted outcomes in a Playbasis AI Agent Hub economic report, and return effort-assessment/1 JSON the Hub can import. Use when the user pastes an Agent Hub economics briefing, asks what their AI-assisted work would have cost a developer, or asks you to estimate effort for outcome IDs. Read-only: never edits the repository, the Hub's data or any skill.
---

# Economic work review

The Hub has already measured usage, linked commits to sessions and recorded which outcomes the person accepted. Your job is narrow: estimate how long a comparable developer would have taken to deliver each accepted outcome, so the Hub can turn that into a wage equivalent and a leverage figure. You don't recompute usage, costs or money, and you don't decide what counts as accepted.

## Inputs

- The briefing (`bridge economics briefing`), or the outcome IDs it names.
- `bridge economics outcomes` for each outcome's title, delivery standard and evidence (commit hashes, sessions).
- The evidence itself: `git show --stat <hash>` and the diff, read-only.
- The working baseline in the briefing: `historical_2021_2022` (a competent developer with 2021–2022 tools) unless the person chose otherwise.

## How to estimate

1. Read the commits for one outcome. Work out what was delivered: the capabilities, the components they touch and what they had to integrate with. Ignore line counts and token usage; generated files, lock files and churn say little about effort.
2. Pick a size class from `references/effort-rubric-v1.md` by capability and integration complexity. If the delivery standard in the record doesn't match what you see (a "production" outcome with no tests or docs, say), keep the record's standard and say so in `assumptions`.
3. Take the hours for that size, standard and baseline from the rubric table. Use `method: "size_class"`. If the work clearly falls outside the table, use `task_breakdown` with `components` (discovery, implementation, testing, review, integration) and explain why.
4. Write one or two short assumptions (what the comparable developer is assumed to know) and a rationale that cites commit hashes.
5. Set `confidence` to how sure you are, separately from how much evidence there was. Low is fine and honest.

Follow `references/evidence-policy.md`: cite only what you read, never infer hands-on time, and don't treat "done" or "works" in a message as proof.

## Output

Return a JSON array of effort-assessment/1 records and nothing else, one per outcome, shaped like `examples/model-assessment.json`:

- `id`: a new lowercase UUID per record.
- `outcomeID` and `outcomeRevisionID`: the outcome ID and the `id` of its latest revision from `bridge economics outcomes`.
- `createdAt`: now, in UTC with milliseconds (`2026-11-06T10:00:00.000Z`).
- `assessor`: `{"kind": "model", "identity": "<your exact model ID>", "rubricVersion": "hub-size-rubric/1"}`.
- `baseline` and `deliveryStandard`: from the briefing and the outcome record.
- `hours`: `{"low", "base", "high"}` as decimal strings, low ≤ base ≤ high.
- Explicit `null` for fields that don't apply (`sizeClass` unless `size_class`, `components` unless `task_breakdown`).

The person imports it with:

```sh
bridge economics assess --file assessments.json
```

Importing the same file twice changes nothing. A person's own estimate always takes precedence over yours; yours stays visible in the spread, and large disagreements are flagged.

## Don't

- Don't edit the repository, run its code, change the Hub's ledger directly or modify any skill.
- Don't estimate outcomes that aren't accepted, or invent outcomes.
- Don't convert estimates to money; the Hub does that with the person's chosen rate.
- Don't send evidence to any other service.
