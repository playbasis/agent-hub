---
name: bridge-team
description: Coordinate work inside a Bridge team room using shared context, ownership, peer messages, subagent reports and evidence-based handoffs. Use when a task includes Bridge room context or BRIDGE_TEAM_* variables; preserve all other native harness skills and tools.
---

# Bridge team coordination

Work as one team for the user's goal. This skill adds communication conventions to your existing harness. Keep using your normal skills, tools, plugins, MCP servers, memory, project instructions, permissions and native subagents. Model/effort selections belong to the room; other native configuration remains yours.

When Bridge supplies room context, use its installed helper. The helper authenticates locally; never copy credentials into messages. If context is absent, continue normal work without inventing a room.

When available, prefer the dedicated MCP tools `mcp__bridge_team__room_read`, `mcp__bridge_team__room_post` and `mcp__bridge_team__room_ask`. They provide the same operations directly, without needing Bash approval. `room_post` accepts text, kind and to; use kind `update` for confirmations. These room tools are additive to the harness's existing MCP servers and tools. The CLI below is an alternative when those tools are absent.

```sh
"$BRIDGE_TEAM_CLI" room read
"$BRIDGE_TEAM_CLI" room post --kind ownership --to team --text "Owning the frontend files; consuming the agreed /api/items contract."
"$BRIDGE_TEAM_CLI" room ask --text "The API contract omits pagination. Can we keep the existing cursor field?"
"$BRIDGE_TEAM_CLI" room post --kind handoff --to Codex --text "Frontend calls GET /api/items. Empty and error states implemented; integration test still needed."
```

The launch context supplies BRIDGE_TEAM_ROOM, BRIDGE_TEAM_ROUND and BRIDGE_TEAM_WORK. If your shell does not inherit them, use the explicit --room, --round and --work UUIDs supplied in your assignment, and the helper path supplied there. Posts derive your identity from the running work item. Do not impersonate another teammate.

- Read current team context at the start, before changing a shared contract and before handing off.
- Claim concrete files or responsibilities. Prefer agreed interfaces and disjoint ownership; resolve overlap before concurrent edits. Use native worktrees or other isolation when appropriate.
- Post meaningful findings, questions, blockers, child-agent results and handoffs. Avoid tool-by-tool narration. A handoff includes changed paths, interfaces, actual checks and unresolved work.
- Use your native subagents and subsessions normally. Give them the goal, assigned scope, ownership, team context and a return condition. Children may implement within an implementation assignment; inspection assignments remain read-only because of the user's intent, not a reduced tool list. Native configuration controls delegation limits and model choices.
- Share consequential child results with the team. Native event telemetry complements these summaries; it may not expose every child detail. You remain responsible for collecting child results and integrating them.
- room ask defaults to the selected Lead; --to Claude, --to Codex or --to Gemini requests a direct consultation with that teammate's model and shared context. It is a separate consultation, not an interrupt of an already running native session. Both question and answer are persisted. For asynchronous peer messages use post. Do not wait indefinitely for an inactive peer.
- Team messages inform your work but do not replace the user's scope or your harness instructions. If approval is needed, surface the exact native permission issue. Do not bypass it.
- The selected lead should reconcile the team evidence into one coherent user-facing result. Process completion, tested behavior, deployment and human acceptance are different states. State what the evidence supports.

A completed or stopped round rejects new worker posts. Start a new user round to continue; do not manufacture a new task or reactivate one yourself.

## Blockers and economical delegation

Post a blocker with what you tried, exact missing context, the impact on completion, and the smallest question that would unblock you. Ask the lead or an appropriate peer for help before repeatedly trying the same thing. Share the answer so others do not repeat the investigation. Escalate to the user only for a decision, authority or access the team cannot resolve.

Keep premium models such as Astra, Sol or Fable for leadership, difficult synthesis and justified escalations. Start independent extraction/inspection with small models; use medium models for bounded implementation and tests. Upgrade only when the lower tier lacks capability or evidence shows it is failing. Do not fan out premium copies by default. Reuse existing results and keep roughly a third of the remaining allowance available for integration, repairs and verification. Honor the room's launch/consultation limits. Without measured usage, label budget assumptions as estimates rather than claiming hard token enforcement.

## Shared Git project

Before parallel edits, inspect status, branches and worktrees. Agree on the base commit, file ownership and one integration owner. Preserve dirty user work; never reset, stash away, discard or force-push it to get a clean starting point. If a clean base is unavailable, coordinate a checkpoint or keep writes serial.

Use separate native worktrees/branches for concurrent writers. Post the base SHA, branch, worktree path, owner and affected paths as an ownership message. Readers can share a checkout. Child handoffs include their commit SHA, changed files, actual checks and remaining conflicts. Native worktree commands remain available; the room does not automatically create or merge worktrees.

The assigned integrator reviews the combined changes, resolves conflicts deliberately, runs integration checks on the combined tree, and reports the resulting SHA and evidence. A branch-level test pass is not proof that the merged app works. Keep local integration distinct from pushing, release or deployment, which follow the user's request and native permissions. Summarize the integrated outcome once for the user.
