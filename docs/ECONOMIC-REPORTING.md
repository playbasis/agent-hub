# Economic reporting (November 6)

The question v1 answers: **what did I spend, what usable work landed, and what
comparable human effort might that represent?** For a day, week, month or
year (or any window), one report says what was used, what was accepted, what a
comparable developer might have taken, and what's still unknown. A briefing
renders the same report as Markdown to paste into Codex or Claude for the
next work cycle.

Scope is reporting, not orchestration. Nothing here sends instructions to
running sessions, edits skills, spends credits or changes a repository.
Formal QA, security review, judge panels and business valuation are out of
scope for v1.

## Pipeline

```text
ActivityOverview (saved snapshot) ─► ActivityAccounting (accounting/1, same engine as every page and `bridge metrics`)
Scan projects (Git, read-only)   ─► ShippedCodeReport ─► OutcomeCandidates (suggestions)
EconomicLedger (append-only)     ─► accepted outcomes, effort assessments, assumptions
                                     │
                     EconomicReportBuilder ─► EconomicReport (economic-report/1, content-addressed)
                                     │
             CLI · local API · FeedbackBriefingBuilder · EconomicReportExchange (bundle)
```

The renderers never sum tokens, time or money themselves. Changing a rate,
an estimate or a subscription makes a new report (a new `reportID`); usage,
time and the accounting digest stay identical.

## What each section means

- **Usage**: known tokens, written tokens, model steps and sessions for the
  scope, from local saved history (`local_native_history`). Provider account
  and plan counters are other populations and never enter it. The share of
  tokens that were context re-sent from cache is shown, because it usually
  dominates.
- **Time**: wall-clock time when any agent worked (union of intervals) and
  agent-hours summed across parallel sessions. Neither is human effort.
  Hands-on time is only what the person records per outcome; it's never
  inferred from agent runtime. Local CPU and provider compute time stay
  unknown.
- **Delivered**: commits in the period, suggestions waiting for a decision,
  accepted outcomes (counted once, in the period holding `landedAt`, however
  many agents, branches and commits contributed), rejections, and
  corrections: accepted work withdrawn after a regression or revert. An
  accepted outcome whose commits a later commit reverts is flagged.
- **Effort**: per accepted outcome, the latest estimate by a person, else by
  a model, for the report's working baseline and the outcome's delivery
  standard. Other estimates stay visible as a spread; base estimates more
  than 1.5× apart are flagged as a disagreement; an estimate made before the
  outcome's last revision is stale.
- **Costs**: subscriptions the person set, spread over the period's days at
  365.2425 ÷ 12 days a month. With a project chosen, each plan is shared by
  the scope's share of that provider's known tokens (`token_share`).
- **Economics**: wage equivalent = estimated hours × rate; operator cost =
  hands-on hours × operator rate; net opportunity benefit = wage equivalent −
  operator cost − tooling, with the low end pairing the least estimated
  effort with the most hands-on time. Leverage = estimated hours ÷ hands-on
  hours. Net benefit and leverage stay unknown until every accepted outcome
  has an estimate and hands-on time, subscriptions are set and everything
  shares a currency; the report lists what's missing instead of filling it.
- **Friction**: sessions in scanned repositories with no linked commit,
  context re-reads, reverts, rejected suggestions and commits not linked to
  any session, each with its evidence.
- **Suggested next prompt**: one or two concrete instructions chosen from the
  report's gaps (decide suggestions, estimate outcomes with the skill, record
  hands-on time, cut context re-reads, run checks before committing).

## Working baseline, delivery standard and rate are separate choices

- **Working baseline**: a developer with 2021–2022 tools (default), a
  developer with 2025–2026 assistants, or measured comparable work.
- **Delivery standard** per outcome: prototype, useful internal tool
  (default) or production-oriented.
- **Rate**: built-in US BLS median wages for software developers (SOC
  15-1252): May 2021 $58.05/h and May 2022 $61.18/h as published, and May 2025
  $65.38/h derived from $135,980 a year ÷ 2,080 hours (default). These are
  wage benchmarks, not billing rates or loaded employer costs. Add your own
  rate in any currency.

Rate vintage doesn't imply a working baseline: a 2021 wage says nothing about
how long 2021 tools took.

## Suggested outcomes

`OutcomeCandidates` groups the period's commits: commits tied to the same root
agent session by a co-author trailer or shared files stay together; anything
else groups by repository; a gap of more than four hours starts a new
suggestion, so a weeks-long thread isn't one outcome. Equivalent commits
(same repository, subject, line counts and files: cherry-picks, rebased
copies) fold into one. `Revert "…"` commits name what they revert. A
suggestion's ID is a digest of its commits, so it's stable while membership
is.

## Ledger

`EconomicLedger` keeps every decision as its own owner-only JSON file in
`~/Library/Application Support/ClaudeCodexBridge/Economics/{outcomes,
assessments,assumptions}`, published by atomic rename under a process-wide
lock. Nothing is edited or deleted: a revision names the record it replaces.
A commit can belong to one accepted outcome; a suggestion is decided once;
revising an older revision is refused as stale; importing the same
assessment twice changes nothing.

## Command line

```sh
bridge economics briefing --period week
bridge economics view --period month --previous
bridge economics candidates --period 7d
bridge economics accept --candidate cand-1943e52a65eb712a --standard internal_tool --hands-on 1.5-3
bridge economics accept --commits a26e5a7,8872288 --repository ClaudeCodexBridge --title "Shipped code linking"
bridge economics reject --candidate cand-7b8d0f38dc392bcb
bridge economics revise --outcome <id> --hands-on 2-4
bridge economics withdraw --outcome <id> --reason regression --note "Rolled back after review"
bridge economics assess --outcome <id> --size m
bridge economics assess --file assessments.json
bridge economics assumptions --subscription "claude-max|claude|Claude Max|200|USD"
bridge economics assumptions --add-rate "me|My contract rate|95|USD|contractor_rate" --rate me
bridge economics export --output ~/Desktop/economics-week --sanitized
```

Selectors: `--period 24h|7d|30d|day|week|month|year|all`, `--previous` for
the calendar period before, `--from`/`--to` (ISO 8601), `--provider`,
`--project` (a repository folder: sessions in it, below it, or started in a
parent folder that edited it).

Local API (token-authenticated like the rest): `GET /economics/report`,
`GET /economics/briefing` (Markdown) and `GET /economics/candidates`, with
`period`, `previous`, `from`, `to`, `provider` and `project` query items.

## Export

`export` writes a new owner-only folder: `report.json`, `outcomes.json`,
`assessments.json`, `assumptions.json` (choices, every rate, the rubric and
the formulas), `evidence-index.json`, `briefing.md`, optionally
`receipts.jsonl` (`--receipts`, the accounting receipts as workspace-receipt/1)
and a checksummed `manifest.json`. `--sanitized` replaces titles, summaries,
commit subjects, repository names, paths and session and commit identifiers
with salted stand-ins (the salt stays out of the bundle), and drops
free-text rationale; numbers, models and assumptions stay.

## Estimating with Codex or Claude

`skills/economic-work-review` tells a coding agent how to estimate accepted
outcomes from their commits with the size rubric and return
effort-assessment/1 JSON, which `bridge economics assess --file` imports. A
person's estimate always takes precedence; the model's stays in the spread.
The Hub itself makes no model calls.

## Not built yet

- The Economics page in Reports (read report, copy briefing, export), and a
  one-click way to decide suggestions and record hands-on time.
- Importing WorkspaceOps or a friend's receipt bundle into an immutable
  receipt journal beneath accounting, and opening imported reports in their
  own namespace.
- An opt-in assessment runner that asks a model directly, with explicit
  approval before any evidence leaves the Mac.
- API list-price scenarios: the price catalog doesn't cover the models in
  recent history yet.
