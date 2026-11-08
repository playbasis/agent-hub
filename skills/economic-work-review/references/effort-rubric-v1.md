# Effort rubric (hub-size-rubric/1)

Pick the size from **what was delivered and how much it had to integrate**, not from lines changed or tokens used. Then read the hours for the outcome's delivery standard and the report's working baseline.

| Size | What it looks like |
|---|---|
| xs · Small change | A well-understood change in one place: a fix, a copy or configuration change, a small refactor. |
| s · Contained capability | One capability inside a single component, with its tests. |
| m · Feature across components | A feature spanning a few components (interface, logic, storage) or one contained integration. |
| l · Subsystem or integration | A subsystem or cross-cutting capability: several components, new contracts or data formats, a migration or an external integration. |
| xl · Major capability | A major product capability or a new application area with its own architecture. |

## Hours (low – base – high)

The table below is generated from the Hub's built-in rubric (`EconomicCatalog.rubric`); a test keeps it in sync.

<!-- rubric-table:start -->
| Size | Delivery standard | Developer with 2021–2022 tools | Developer with 2025–2026 assistants |
|---|---|---|---|
| xs | Prototype | 0.6 – 1.2 – 2.4 h | 0.3 – 1 – 2.6 h |
| xs | Useful internal tool | 1 – 2 – 4 h | 0.5 – 1.6 – 4.4 h |
| xs | Production-oriented | 1.8 – 3.5 – 7 h | 0.9 – 2.8 – 7.7 h |
| s | Prototype | 2.4 – 4.8 – 9.6 h | 1.2 – 3.8 – 10.6 h |
| s | Useful internal tool | 4 – 8 – 16 h | 2 – 6.4 – 17.6 h |
| s | Production-oriented | 7 – 14 – 28 h | 3.5 – 11.2 – 30.8 h |
| m | Prototype | 9.6 – 16.8 – 28.8 h | 4.8 – 13.4 – 31.7 h |
| m | Useful internal tool | 16 – 28 – 48 h | 8 – 22.4 – 52.8 h |
| m | Production-oriented | 28 – 49 – 84 h | 14 – 39.2 – 92.4 h |
| l | Prototype | 28.8 – 54 – 96 h | 14.4 – 43.2 – 105.6 h |
| l | Useful internal tool | 48 – 90 – 160 h | 24 – 72 – 176 h |
| l | Production-oriented | 84 – 157.5 – 280 h | 42 – 126 – 308 h |
| xl | Prototype | 96 – 168 – 288 h | 48 – 134.4 – 316.8 h |
| xl | Useful internal tool | 160 – 280 – 480 h | 80 – 224 – 528 h |
| xl | Production-oriented | 280 – 490 – 840 h | 140 – 392 – 924 h |
<!-- rubric-table:end -->

## How the numbers are built

- Base hours are for a competent developer with 2021–2022 tools building a **useful internal tool**.
- A **prototype** is ×0.6: it skips most hardening, documentation and edge cases.
- **Production-oriented** work is ×1.75: hardening, documentation, security review and operational readiness.
- A developer with **2025–2026 assistants** scales low, base and high by 0.5, 0.8 and 1.1. Measured uplift from assistants is uncertain and can be negative (METR's 2025 randomized study of experienced open-source developers found them 19% slower with AI tools), so the range is deliberately wide rather than a single discount.
- **Measured comparable work** has no table: give hours from the comparable work you measured, with `method: "comparable_work"`.

These are starting points for calibration, not measurements. When the person corrects an estimate, the correction is a new assessment and the old one is kept, so the rubric can be recalibrated from real disagreements.
