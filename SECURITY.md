# Security policy

## Reporting a vulnerability

Please report suspected vulnerabilities privately through **GitHub Security
Advisories** ("Report a vulnerability" on the repository's Security tab). Do
not open a public issue for anything that could expose credentials, private
data or a way to make agents act without the user's say-so.

We aim to acknowledge reports within 5 business days. Include the steps to
reproduce, your macOS version, and the Agent Hub, Claude Code and Codex CLI
versions (`make doctor` prints all of them).

## What we especially want to hear about

Each of these breaks a promise the project makes:

- the control service answering anyone other than this Mac, or any route
  other than `/health` working without the bearer token;
- Agent Hub reading or writing a provider's credential files (it must go
  through each provider's own CLI);
- keys appearing in `config.json`, logs, saved activity records, trace
  exports, agent prompts or crash output;
- full prompts or tool output being saved to activity records (they keep
  titles, goals, counts, models and token totals only);
- Agent Hub adding a permission-bypass flag to Claude Code or Codex, or
  running an agent without a deadline and timeout;
- shell injection through prompts, project paths or hook payloads.

## How it is built to resist

The design notes are in [docs/SECURITY.md](docs/SECURITY.md). In short: the
control service binds to loopback only and refuses to start on any other
address; every route but `/health` needs a random bearer token compared in
constant time; data files are owner-only (`0600` in a `0700` folder); agents
are launched with argument arrays, never a shell; and there are no third-party
Swift dependencies.

Agents themselves can still change files inside the project you give them.
Start with a disposable project, use version control and review diffs.
