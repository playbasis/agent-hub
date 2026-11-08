# Architecture

## Boundaries

```text
Claude hooks ─┐                         ┌─ Claude Code subprocess
              ├─> loopback API ─> core ┤
Codex MCP/CLI ┘       │          │      └─ Codex CLI subprocess
                     │          │
                 menu-bar   project-local state
```

The HTTP layer only authenticates and normalizes input. The `Orchestrator` actor owns
session lifecycle and serializes agent dispatch per session. Agent runners know
CLI syntax but do not decide routing. `DecisionEngine` owns provider selection,
schema validation, and deterministic fallback.

## Event flow

1. A canonical event or native Claude hook arrives.
2. The store deduplicates its event ID and appends it to `events.jsonl`.
3. Quota state is updated.
4. Tool-progress events are recorded without causing a hand-off.
5. A terminal event is classified into a strict `Decision`.
6. The decision and human-readable hand-off are appended.
7. When allowed by the session state, one agent subprocess is launched.
8. The subprocess result is normalized into a bridge-managed event and returns
   to step 2.

Events emitted by hooks while a bridge-managed subprocess is active are
recorded but cannot schedule another process. The runner's normalized terminal
event is the sole hand-off trigger, preventing duplicate or recursive launches.

## State

Project-local:

- `BRIDGE.md`: current goal, invariants, session state, and last decision
- `CHANGES.log`: append-only Markdown hand-off log
- `CONTEXT/events.jsonl`: canonical input events
- `CONTEXT/decisions.jsonl`: validated routing decisions
- `CONTEXT/runtime.json`: recoverable current session state
- `CONTEXT/trace.jsonl`: normalized, append-only provider receipts linked by SHA-256
- `CONTEXT/trace-summary.json`: derived verification, usage, and budget summary

User-local:

- `~/Library/Application Support/ClaudeCodexBridge/config.json`
- `~/Library/Application Support/ClaudeCodexBridge/coordinator-credentials.json`
- `~/Library/Application Support/ClaudeCodexBridge/active-session.json`
- `~/Library/Application Support/ClaudeCodexBridge/plan-usage.json`
- `~/Library/Logs/ClaudeCodexBridge/bridge.jsonl`

`runtime.json` and `active-session.json` are replaceable snapshots. The central
snapshot lets startup restore a paused session without opening a protected
project folder; the project store is attached lazily on explicit Resume. All
audit records are append-only.

## Trust boundaries

The coding agents, their output, and hook payloads are untrusted. Agent text is
never interpreted as shell syntax. Subprocesses are created with argument
arrays, prompts are written over stdin, and project paths are resolved before
use. Meta-model output is untrusted until strict `Codable` decoding and
decision-invariant validation succeed.

Completion is deliberately machine-readable: a runner must emit
`<bridge:complete>` or structured metadata must set `task_complete=true`.

## Adapter stability

CLI flags are isolated in the Swift `ClaudeRunner` and `CodexRunner` adapters.
Both adapters request explicit model/effort settings, retain persistent native
session IDs, and collect provider-reported usage and tool metadata. Claude
augments its result JSON from the matching native transcript; Codex combines
`exec --json` with the matching rollout transcript. The Gemini-compatible
adapter retains response ID, resolved model, usage, and latency with the
routing decision.

Trace values carry provenance (`provider_reported`, `derived`, `estimated`, or
`unavailable`). Cached and reasoning token fields are displayed as subsets and
are not added twice to provider totals. Completion is fail-closed when the
configured dual-provider proof or strict budget cannot be established.
The adapters record detected versions and return parse diagnostics. Changes to
a provider do not alter the core event contract.

Plan-usage adapters remain behind the provider process boundary and are invoked
only by an explicit refresh. Codex is read through `account/rateLimits/read` on
`codex app-server`. Claude Code is opened in a short-lived native PTY with
`--safe-mode --no-chrome` and asked to render `/usage`. Both probes use an
app-owned Application Support directory, never a recent project. The bridge
parses provider-rendered windows and never opens Claude's OAuth or Codex
credential files itself. The last successful snapshot is dated and cached.
Failed refreshes cannot overwrite a real snapshot with an estimate.

## Native process boundary

The shipped app, orchestrator, loopback server, and helper CLI are compiled
from Swift into native arm64 Mach-O executables. No Python runtime or
third-party web server is bundled. The JSON event/status contracts remain
language-neutral, so a Rust daemon can be introduced later if cross-platform
support or CPU-heavy processing justifies a second process boundary.
