# Team Room — configurable app-building team

The lead can now be selected independently of the worker models. New rooms are
led by Gemini when its key is configured and by Claude otherwise, so a setup with
only Claude Code and Codex works without extra keys. Rooms saved before a lead was
chosen keep Gemini. Choose Codex, Claude or Gemini in Team setup.
The selected lead plans and synthesizes. `room ask --to Lead|Claude|Codex|Gemini`
can request help from any teammate; the default is Lead. A consultation is a
separate call with shared context, not an interrupt of a live peer session.
The per-round consultation limit defaults to six and is configurable (1–12).
Cheaper-model delegation and Git integration are covered in the team skill;
there is not yet automatic worktree merging or hard token-budget enforcement.

The widget's Team Room button opens a resizable native lobby. Create a room,
activate it, choose models in Team setup, optionally attach a specific app project,
and send a message (Command-Return). Auto asks the lead to route the request to
discussion, clarification, implementation or review. Discuss explicitly prohibits
project tasks. Stop round cancels pending work and rejects late responses.

## Roles, models and playbooks

Roles are stable; model IDs are not hardcoded into assignments:

| Role | Default | Configurable examples | Skill playbook |
|---|---|---|---|
| Gemini, coordinator | Existing Gemini configuration | Any model accepted by configured Google endpoint | `room-coordinator-v1.md` |
| Claude, frontend | Existing Claude model | Sonnet 5, Opus 5, Fable 5.1, custom ID | `room-frontend-v1.md` |
| Codex, backend | GPT-5.6 Luna | Terra, Sol, GPT-6 Astra, custom ID | `room-backend-v1.md` |
| Inspection / verification | Assigned worker's model | Same per-room model | `room-review-v1.md` |

The shared `skills/bridge-team/SKILL.md` adds ownership, shared context, peer
questions, progress and handoffs to the native harnesses. It is installed in both
`~/.codex/skills/bridge-team` and `~/.claude/skills/bridge-team`. The packaged
`bridge-team.md` is an exact copy checked during build, so Gemini and the native
workers also receive the same coordination instructions directly. Role playbooks
remain bundled, inspectable additions rather than replacements for native skills.

Claude and Codex now load their normal configuration, project/user instructions,
skills, plugins, MCP servers, memory and subagent settings. Room launches no
longer pass safe/restricted mode, ignore-config/rules, tool exclusion, ephemeral
session or developer-instruction replacement flags. They also no longer force a
separate sandbox, permission mode, child-model or child-concurrency policy. The
room still selects the explicitly configured main model/effort and captures
JSON output. Native permission requirements are not bypassed. Headless CLI
sessions cannot reproduce every desktop-only interaction; missing interactive
permissions or capabilities must be reported honestly.

Gemini remains the existing API coordinator, with shared skill context and
in-round advice. This does not install a separate native Gemini harness.

Model and effort changes are saved per room and apply to the next round; active
rounds cannot be reconfigured. Custom IDs are passed unchanged. No model fallback
is implemented by Bridge. Provider-side availability still depends on the account.
Advanced settings can override each CLI executable. Automatic Codex resolution
prefers the desktop bundled executable over an older PATH CLI, unless the global
Bridge config explicitly specifies another command.

## Work graph and visibility

Gemini returns validated JSON with a mode, user-facing message, shared interface
contract and up to six tasks. Tasks have an owner, kind, prompt and dependencies.
Unknown owners, cycles, writes in review, and any tasks in Discuss are rejected.
Missing projects produce clarification, not automatic filesystem selection.

Independent inspect tasks fan out to up to three child sessions. Implementation
and verification tasks run serially in the attached project. An in-runtime
project lock prevents other team rooms working in the same or nested project.
This is cooperative local execution, not isolated worktree merging.

Each child session appears in the build plan with queued/running/complete/failed/
blocked/interrupted state, native session ID, prompt, skill, selected model and
handoff. CLI events surface tool activity and native subagent activity where the
provider emits it. The most recent 80 activity events per work item are retained;
no hidden reasoning or raw tool arguments are forwarded to the room.

Native children may inspect or implement within the assigned user scope, using
the harness's own delegation/model settings. The parent coordinates file
ownership or native worktree isolation and returns child results to the room.
Worker completion means a process finished, not that the app is accepted. Gemini
must summarize evidence and limitations. Failed prerequisites block dependents.
Native tool availability does not by itself authorize deployment, publication or
other external actions; the user's actual request and native permissions govern.

## Live team communication

Each work item receives room/round/work UUIDs and the installed helper path in
`BRIDGE_TEAM_*` environment variables and its assignment context. Agents use:

```sh
"$BRIDGE_TEAM_CLI" room read
"$BRIDGE_TEAM_CLI" room post --kind ownership --to team --text "Owning server.cjs"
"$BRIDGE_TEAM_CLI" room ask --text "Should the existing cursor field stay?"
"$BRIDGE_TEAM_CLI" room post --kind handoff --to Claude --text "API ready; integration check pending"
```

The CLI authenticates locally without exposing the bearer token in the prompt.
Claude also receives an additive `bridge_team` stdio MCP server exposing
`room_read`, `room_post`, and `room_ask`. Only those three room operations are
pre-authorized for the assigned worker. Existing MCP servers remain loaded; no
general Bash grant, bypass mode or strict MCP replacement is applied. This
lets normal headless Claude permission policy coexist with team communication.
Identity is derived from the running work item, not an agent-supplied author.
Posts are persisted and visible in chat immediately. A synchronous ask persists
the question, invokes Gemini with the room context and contract, and persists its
reply. Peer-addressed posts are read by teammates when active; they do not create
unbounded automatic agent turns. Native children can inherit the same context or
receive explicit IDs from their parent. Finished/stopped workers cannot post.

## Persistence and delivery

- Runtime-owned actor serializes updates. Only one round per room is admitted.
- Authenticated GET `/rooms` returns room snapshots. UI polls once per second;
  messages appear on provider completion, not token-by-token.
- Authenticated POST `/rooms`, `/rooms/activate`, `/rooms/messages`, `/rooms/stop`
  accept `{roomID?, requestID, text, discussionOnly?}`. UUID request IDs deduplicate creation/send.
- POST `/rooms/configure` accepts `{roomID, requestID, text, settings?, projectPath?}`.
  Empty projectPath detaches. GET `/rooms/roles` exposes the bundled playbooks.
- GET `/rooms/context?room=UUID` returns scoped recent conversation/work context.
  POST `/rooms/post` and `/rooms/ask` accept `RoomTeamNote` with roomID, roundID,
  workID, requestID, kind, to and text. Duplicate request IDs do not duplicate posts.
- Each revision is appended and synchronized before acknowledgment in the
  private `Library/Application Support/ClaudeCodexBridge/TeamRooms/rooms.jsonl`.
- Restart preserves the transcript, marks unfinished replies interrupted, and
  never silently replays a provider request. A torn final line is preserved in a
  separate recovery file before truncating only that incomplete suffix.
- Conversation records intentionally contain chat text. They stay separate from
  the metadata-only orchestration trace. Only the room's recent conversation is
  sent to providers. An explicitly attached project's directory overview and root
  guidance are sent to the coordinator; workers receive its path and assignment.
- Each provider receives at most 24 recent messages / 24,000 characters. Full
  history remains on disk. User messages are capped at 8,000 characters; rooms
  close to new messages after 400 entries. CLI calls time out at 90 seconds and
  Gemini calls at 45 seconds. Worker timeouts are configurable up to 15 minutes;
  the entire round has a 30-minute deadline. Discussion uses four calls;
  implementation adds bounded worker sessions and any native child calls.

## Verification

`make check` runs the existing suite and room regression tests. Tests cover
authentication, activation, duplicate requests, identical parallel contexts,
Gemini receiving teammate replies, failure visibility, cancellation, restart,
torn-tail recovery and persistence.

`BRIDGE_ROOM_LIVE_PROOF=1 swift test --package-path apps/MenuBar --filter
TeamRoomTests.testLiveConversationAndReload` explicitly invokes real providers
in a temporary room. It verifies a first conversation, reopens the journal, and
asks everyone to recall a shared check word in a second round.

Future stages: token streaming, deployment adapters, durable structured acceptance
reports, worktree-isolated parallel writes and user acceptance automation.

### September 13, 2026 — original conversation milestone

- `make check`: 76 tests, one opt-in live test skipped, zero failures.
- Explicit live test: passed two real rounds with Claude (`sonnet`), Codex
  (`gpt-5.6-sol`) and configured Gemini (`gemini-3.5-flash`). All recalled the
  original check word after rebuilding the service from the persisted journal.
- Installed HTTP proof: unauthorized room read returned 401; repeated request ID
  produced one user message; all four provider replies completed.
- Installed app quit/relaunch preserved all six room messages and the exact
  journal SHA-256. No provider request was replayed.
- Release installed locally; signature verified. Installed and distribution
  executable SHA-256: `b08cd622a8ca3a601187eaf1f707a56828efacdf64b387fcd3dcaaa77a06931e`.
- Strict concurrency build with warnings as errors passed. Native in-process
  render inspected at 860 and 640 points wide. Desktop computer-use service was
  unavailable, so interactive click/keyboard acceptance was not automated.
- Changes are local and uncommitted, alongside pre-existing accounting changes.

### September 13, 2026 — routing and configuration milestone

- Live Gemini plan dispatched two concurrent inspect sessions, a Codex/Luna
  backend implementation, a Claude frontend implementation and an integration
  verification session. Each native session ID and tool activity was captured.
- Independent host-side verification started the generated Node server and
  confirmed both the HTML route and exact `/api/health` JSON. The Codex sandbox
  blocked socket binding during its own check; the room reported that limitation.
  Browser click/visual acceptance of the generated fixture was not tested.
- Real model-selection calls succeeded for `gpt-5.6-terra`, `gpt-6-astra` and
  `claude-fable-5-1`. Astra initially failed with PATH Codex 0.145.0 and succeeded
  using the desktop bundled Codex 0.153.4. No global CLI upgrade was performed.
- Regression tests cover persisted per-room settings, command/model forwarding,
  immutable settings during rounds, invalid plans, dependencies, scout concurrency,
  serial writes, failed prerequisites and metadata-only activity parsing.
- Actual native subagent proof passed for both Claude and Codex: each delegated
  a read-only fixture inspection and returned the child's result. Claude emitted
  start/progress/completion metadata and parent references; Codex emitted native
  collaboration wait events. Event references are not presented as guaranteed
  native child-session IDs when the provider only supplies tool-call IDs.
- Final full suite: 86 tests, four opt-in live tests skipped, zero failures
  (82 automated checks passed). App-build, model-selection and native-child
  opt-in proofs were also run separately and passed as described above.
- Installed executable matches distribution SHA-256
  `567c968bbe3b3d8c03ebffdf82c74456d9821b8f7382094c4ea7e4bfbab18ba5`.
  Packaged playbooks match sources and app signature verifies. HTTP readback
  after restart retained the test room's Fable 5.1 / Astra choices and exposed
  all four role playbooks. Native setup rendering was inspected; interactive
  desktop automation remains unavailable in this environment.

Primary documentation used for implementation: [Codex JSON events](https://learn.chatgpt.com/docs/non-interactive-mode),
[Codex subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents),
[GPT-5.6 Luna](https://developers.openai.com/api/docs/models/gpt-5.6-luna),
[Fable 5.1 model IDs](https://platform.claude.com/docs/en/models/fable-5-1/overview).

### September 13, 2026 — native harness preservation and communication

- Removed room-specific native configuration/tool/skill suppression and replaced
  role restrictions with the additive bridge-team skill. Native delegation
  capabilities and configuration remain available; inspection scope comes from
  the assignment, not a reduced tool surface.
- Skill frontmatter validated; repository, resource, Codex and Claude skill
  copies match. Packaged app signature verifies. Full suite: 88 tests,
  four opt-in tests skipped, zero failures (84 automated checks passed).
- Added scoped communication tests for worker identity, ownership, peer routing,
  question/advice persistence, duplicate requests and stopped-worker rejection.
  MCP initialization/tool discovery returned exactly the three room tools.
- Real proof room `BEBCCA54-8CB5-49CD-A955-01BB1CD4147C`: Codex posted ownership,
  asked Gemini about the shared check word, received saved advice and handed it
  to Claude. Claude used native room MCP read/post tools to verify and confirm;
  Gemini consolidated the team result. The read-only fixture remained unchanged.
- First attempt exposed native Claude Bash approval denial. The correction added
  only room MCP permissions, preserving native shell policy. A later incomplete
  Gemini route was rejected; structured JSON Schema now constrains routing.
- Installed executable SHA-256:
  `5e4018bfe154e96d44958ee1c764e4cc13b6d55013abd0c212ce249a524952df`.
  Matches the local distribution. This is a local install; source changes remain
  uncommitted. The earlier app-build proof used the earlier launch policy; this
  milestone independently proves native-harness team communication, not a new
  full application build or deployment.

### Closing checkpoint — September 13, 2026

- Full suite: 90 tests, five opt-in tests skipped, zero failures (85 automated
  checks passed). The added tests cover lead/worker model separation, persisted
  lead settings, peer consultation and the consultation limit.
- Real planning calls passed for `gpt-6-astra`, `gpt-5.6-sol` and
  `claude-fable-5-1`; all returned valid discussion plans without dispatching work.
- The shared skill now includes blocker escalation, economical delegation,
  worktree/base-SHA ownership, one integration owner and combined-tree checks.
- Continuation work is checkpointed on `work/team-room-continuation-20260913`.
  Earlier notes saying changes are uncommitted describe their historical state.
