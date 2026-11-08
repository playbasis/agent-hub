# Repository guidance

## Product principles

- Keep the bridge local-first and deny unsafe automation by default.
- Treat event and decision schemas as public, versioned contracts.
- Preserve append-only audit history. Never silently rewrite hand-off records.
- Keep agent-specific behavior behind adapters.
- Economic reports render one frozen accounting/1 result plus the append-only
  economics ledger. Never re-sum tokens, time or money in a view, prompt or
  export, never infer hands-on time from agent runtime, and keep missing
  inputs visibly unknown (`docs/ECONOMIC-REPORTING.md`).
- Any autonomous execution must have declared project scope, a session deadline
  and a per-turn timeout. Team Room preserves the user's native harness
  permissions and sandbox settings; do not suppress skills/tools or introduce
  permission-bypass flags.

## Development

- Swift: 5.9+, `swift build --package-path apps/MenuBar`.
- Tests: `swift test --package-path apps/MenuBar`.
- Run `make check` before handing off a change.
- Add or update tests whenever behavior changes.
- `packages/WorkspaceContracts` stays Foundation-only. The schemas in
  `schemas/` are normative; the Swift types and
  `scripts/check-workspace-contracts.py` must agree on
  `tests/fixtures/workspace-economics/v1` (`docs/WORKSPACE-RECEIPT-CONTRACT.md`).
- Do not commit local credentials, generated context, or Claude local settings.

## Interface quality

- The menu-bar UI must remain useful at narrow widths and with keyboard-only
  navigation.
- Use semantic system colors and SF Symbols so light, dark, increased-contrast,
  and reduced-motion settings work without special cases.
- Always surface the active agent, session state, elapsed/remaining time, and
  the reason for the latest routing decision.
- Colours, glyphs, avatars, gauges and button styles live in
  `apps/MenuBar/Sources/ClaudeCodexBridgeMenuBar/BridgeTheme.swift`. Claude is
  coral, Codex is teal, Gemini is blue, the Playbasis brand is cyan
  (`BridgeTheme.brand`), and highlight tones map through `BridgeTheme.tone`;
  do not introduce ad-hoc colours.
- The user-facing product name is "Playbasis AI Agent Hub" (`BridgeBrand`).
  Keep the `ClaudeCodexBridge` codename for bundle paths, identifiers and data
  directories. Write for a knowledge worker: plain words first, methodology in
  an ⓘ popover or a disclosure, never as a caption.
- Account sign-in is driven through each provider's own CLI
  (`BridgeCore/AccountLinking.swift`). Never read or write provider credential
  files from the app.
- Direct provider process launches must use `SubprocessEnvironment` so an npm
  CLI can find its paired Node runtime under Finder's sparse PATH. Do not
  source shell profiles or add a project's working directory to PATH.
