# Work economics briefing: Custom period

Report `sha256:cf1c1fbd6ff70e3da14923ac945834fff38172e9cd083b702c1586a5bb82f7aa` · 2026-01-05 09:00 to 2026-01-12 09:00 (GMT) · from the activity snapshot of 2026-01-12 09:00
Scope: acme-billing · 5 sessions · all agents

## Delivered
- 1 accepted outcome, 3 waiting for a decision, 0 rejected.
- 6 commits in the period (+2,247 / −257 lines), 2 of them in accepted outcomes.
- **Billing export** · useful internal tool · landed 2026-01-06 11:00 · 2 commits (+430 / −25) · acme-billing · estimated 16–48 h (base 28 h), size m, by a person · hands-on 2–3 h · 1 of its commits later reverted
  Evidence: c1000001, c2000002
  Outcome ID: `5b6c7d8e-9f0a-4b1c-8d2e-3f4a5b6c7d8e`
- Waiting for a decision:
  - `cand-4e693aba368d751c` Update README · 1 commit (+12 / −2) · acme-billing
  - `cand-4af04e79aed2e092` Add audit log · 1 commit (+900 / −100) · acme-billing
  - `cand-d6684ee23fa9c112` Revert "Fix export rounding" · 1 commit (+5 / −30) · acme-billing

## Economics
- Usage (this Mac's saved history): 7,500 tokens, 420 written, 74.7% re-read context; 5 model steps.
  - claude: 1,300 tokens, 2 steps, 2 sessions
  - codex: 6,200 tokens, 3 steps, 3 sessions
- Agents worked 3.7 h of wall-clock time, 4.0 h summed across parallel sessions. Agent time isn't human effort.
- Hands-on time: 2–3 h across 1 accepted outcome.
- Tooling: 92.00 USD (ChatGPT Pro: 46.00 USD = 200 USD a month × 7 of 30.44 days; Claude Max: 46.00 USD = 200 USD a month × 7 of 30.44 days)
- Estimated human effort (developer with 2021–2022 tools): 16–48 h (base 28 h) = 2–6 (base 3.5) person-days at 8 h a day.
- Wage equivalent at US software developer median wage, May 2025 (65.38 USD/h): 1,046.08–3,138.24 USD (base 1,830.64). Not revenue, market value or cash saved.
- Net opportunity benefit after hands-on time at 65.38 USD/h and tooling: 757.94–2,915.48 USD (base 1,575.19).
- Leverage: 5.3–24× (base 11.2×) estimated human hours per hands-on hour.

## Friction
- 2 of 4 agent sessions in scanned repositories have no linked commit. Research, reviews, planning and uncommitted work land here too. (1,200 tokens)
- 74.7% of known tokens were context re-sent from cache on each step.
- 1 commit reverts earlier work. Evidence: c3000003
- 2 commits aren't linked to any agent session in view. Evidence: c6000006, c3000003

## Uncertainty
- 3 suggested outcomes are waiting for a decision; only accepted work counts.
- 1 accepted outcome includes commits that were later reverted; revise or withdraw it if the work didn't stick.
- Wage equivalents are what comparable hours would cost at the chosen rate: not revenue, market value or cash saved.

## Suggested next prompt

> Go through the 3 suggested outcomes with me. For each, I'll say whether it's accepted work, its delivery standard (prototype, internal tool or production) and roughly how many hands-on hours I spent; record them with `bridge economics accept --candidate <id>` or `bridge economics reject --candidate <id>`.
> 1 commit was reverted. Before committing, run the project's checks and say which ones passed.

---
Every figure above comes from report `sha256:cf1c1fbd6ff70e3da14923ac945834fff38172e9cd083b702c1586a5bb82f7aa` (economic-report/1). Usage is from accounting result `118554eb4089c396…`; estimates follow hub-size-rubric/1. Formulas: estimated hours × rate = wage equivalent; minus hands-on time × operator rate and tooling = net benefit.
