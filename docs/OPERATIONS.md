# Operations

## Installing the menu-bar app

```bash
make install
open -a "$HOME/Applications/ClaudeCodexBridge.app"
```

`make install` builds a release bundle, validates its property list and
signature, stages it in the user Applications directory, and retains an older
installation as a timestamped backup. The app is an `LSUIElement` and therefore
appears in the menu bar without a Dock icon.

## Configuration

Run `bridge init` once. The command creates a private bearer token and a
configuration file under Application Support. Use `bridge config` to print the
resolved path and redacted settings.

Important defaults:

- loopback only: `127.0.0.1:8742`
- four-hour session
- 45-minute agent subprocess timeout
- deterministic local routing
- Codex `workspace-write` sandbox
- Claude isolated `auto` permission mode
- no provider CLI or project-folder probes during app startup

Set `meta.provider` to `ollama` for a local classifier or
`openai_compatible` for an explicitly configured remote endpoint.

For Gemini, keep the menu-bar runtime running and use the authenticated
configuration command so the secret is stored in the app's private
mode-`0600` Application Support credential file:

```bash
read -s "GEMINI_KEY?Gemini API key: "
printf '%s' "$GEMINI_KEY" | bridge coordinator gemini --key-stdin
unset GEMINI_KEY
bridge app-quit
open -a "$HOME/Applications/ClaudeCodexBridge.app"
bridge coordinator status
```

The Gemini endpoint and model are stored in `config.json`; the key is not. The
key is stored in `coordinator-credentials.json` alongside the config with file
mode `0600`. Ad-hoc development builds deliberately avoid Keychain because
macOS can require the login password again whenever their code identity
changes. A Developer ID-signed release can restore a no-prompt Keychain adapter.
Environment variable `CCB_META_API_KEY` still takes precedence for ephemeral
CI or isolated runs.

## Installing hooks

```bash
bridge install-hooks --project /absolute/project/path
```

The installer:

1. Resolves and validates the project.
2. Creates a timestamped backup when local settings already exist.
3. Merges bridge hook groups without replacing unrelated configuration.
4. Writes `.claude/settings.local.json` with mode `0600`.

Use `--dry-run` to inspect the merged JSON. HTTP hooks send the native Claude
payload to the event-specific bridge endpoint.

## Starting and stopping

```bash
bridge serve
bridge start --project /path --goal "..."
bridge pause
bridge resume
bridge handoff --agent codex --reason "Use the test specialist"
bridge stop
```

Only one active session is supported in the v1 UI, while the service and state
model are session-keyed for future concurrency.

## Completion protocol

The bridge prompt asks agents to finish with one of:

- `<bridge:continue>` — verified work remains
- `<bridge:complete>` — the goal is complete and verification passed
- `<bridge:blocked>reason</bridge:blocked>` — user action is required

If no marker is present, the session continues or pauses according to routing.

## Three-agent proof

```bash
bridge prove-coordination --project /absolute/path/to/new-proof-directory
```

This uses the running app and its real Claude, Codex, and Gemini adapters. The
canonical task requires Claude architecture, Codex implementation and tests,
then Claude independent verification. The command exits unsuccessfully unless
the proof report confirms:

1. terminal completion;
2. successful turns from both agents;
3. validated Gemini decisions with zero rules fallbacks;
4. Gemini decisions responding to events from both agents;
5. at least one cross-agent hand-off; and
6. at least three managed turns;
7. `Package.swift`, `DESIGN.md`, `IMPLEMENTATION.md`, and `REVIEW.md`;
8. an explicit review verdict of `PASS`; and
9. an independent, post-session `swift test` with exit status zero.

The authoritative evidence is the proof project's `BRIDGE.md`, `CHANGES.log`,
`CONTEXT/events.jsonl`, `CONTEXT/decisions.jsonl`, and
`CONTEXT/coordination-proof.json`.

Normal app startup validates the Gemini credential and configured model with a
non-generating model lookup, so relaunching the menu-bar app does not consume a
generation request. `prove-coordination` first requires tiny successful live
responses from Claude and Codex, then intentionally performs one schema-valid
Gemini generation probe, all before creating its proof directory. Authentication,
model, quota, or billing failures therefore fail early without leaving a
partial project or spending downstream provider quota unnecessarily.

## Recovery

The daemon mirrors the one active session to private
`~/Library/Application Support/ClaudeCodexBridge/active-session.json`. On
restart it reads only that app-owned snapshot and presents unfinished work as
paused. It does not scan the recent-project list or open any project folder.
The project-local `CONTEXT/runtime.json` is attached only after the user presses
Resume. An in-flight subprocess is never presumed alive; manual resume
re-enters through the decision engine.

The menu-bar UI immediately hydrates the last authenticated status snapshot,
then reconnects with bounded exponential backoff. Cached state remains visible
but session controls remain disabled until the local service is authenticated.
Provider reachability is tracked separately: a failed Ollama or compatible API
shows a degraded banner and routes through deterministic rules, so provider
failure does not prevent starting or continuing a session.

If both agents are rate-limited, the session enters `parked` and schedules a
wake-up for the earliest known reset. Unknown resets use the configured
cooldown.

## macOS Files & Folders permissions

Launching the app is folder-silent. Plan usage hydrates from cache and refreshes
only when the user presses the refresh button; the explicit probe runs from the
app's own Application Support directory with Claude customizations disabled.
Choosing, starting, resuming, opening, or installing hooks for a project is an
explicit request to access that one project. If the selected project itself is
inside Desktop, Documents, or Downloads, macOS may show one legitimate
Files & Folders prompt for that action. The bridge does not request Full Disk
Access and does not need access to unrelated protected folders.

## Troubleshooting

- `bridge doctor` checks the two CLIs, versions, config permissions, port, and
  project state.
- `bridge logs` reads structured daemon logs.
- Claude: use `/hooks` to confirm local hook registration.
- Codex: run `codex exec --help` to verify `--json` and sandbox support.
- Never resolve an automation problem by enabling either CLI's dangerous
  bypass flag.
