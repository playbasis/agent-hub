# Playbasis AI Agent Hub

**Claude Code and Codex, working as one team on your Mac.**

Agent Hub is a native macOS menu-bar app for developers who use Anthropic's
Claude Code, OpenAI's Codex, or both. It lets the two agents hand work to each
other, and shows you plainly what they did, how long it took and how much of
your plan it used. Everything runs and stays on your Mac: no account to create,
no server, and no API key needed to start.

> **Status: private preview (0.1).** Built from source, ad-hoc signed, not yet
> notarized. Open source under the [Apache License 2.0](LICENSE).

## Built for Claude Code and Codex

Agent Hub drives each agent through its own official CLI, the same way you
would in a terminal. It never touches their credential files.

| | Claude Code (`claude`) | Codex (`codex`) |
| --- | --- | --- |
| **Sign in** | Runs `claude auth login` for you | Uses Codex's own `codex app-server` sign-in (ChatGPT plans) |
| **Plan limits** | Reads Claude Code's own `/usage` | Asks `codex app-server` for your rate limits |
| **Session history** | Reads your Claude Code transcripts in `~/.claude/projects` | Asks `codex app-server` for your threads |
| **Runs work** | `claude -p`, resuming the same session between turns | `codex exec`, resuming the same thread between turns |
| **Team Room** | Lead or worker, with room tools over MCP | Lead or worker |
| **Live events** | Optional Claude Code hooks (`bridge install-hooks`) | From `codex exec --json` |

Either agent works alone; Team Room is at its best with both. Tested with
Claude Code 2.1.258 and Codex CLI 0.145 on macOS 14.

## Who it is for

- **Developers who use Claude Code, Codex, or both** and want one place to run
  them, see their sessions and stop juggling terminals.
- **Founders and small teams** who want to know what their agents actually
  shipped and what it cost in time and plan usage, without a hosted dashboard.
- **Anyone careful about privacy.** Agent Hub signs in through each provider's
  own CLI, never reads their credential files, and keeps its records local.

It is not a hosted service, it does not run on Windows or Linux, and it is not
a promise that unattended agents are risk-free. You stay in charge of what they
are allowed to touch.

## What it does

- **Team Room.** Describe what you want built. A lead you choose plans the
  work, Claude and Codex build it, and either can ask the other for help. Every
  hand-off and decision is recorded.
- **Accounts.** Sign in with your existing Claude and ChatGPT subscriptions from
  inside the app. Plan limits and reset times show as gauges.
- **Reports.** Activity by day and hour, models, skills and instruction files
  in use, shipped commits, a daily brief, and economics that keep unknowns
  visibly unknown instead of guessing.
- **Logs and proof.** A searchable live log, and per-turn receipts (model,
  effort, tokens, tools), hash-chained so a later edit shows.
- **Optional extras**, off until you add them: a Gemini coordinator, a local
  Ollama router, and GLM Chat through your own DigitalOcean inference key.

## What you need

- A Mac on **macOS 13** or newer.
- **Xcode** or the **Xcode Command Line Tools** with Swift 5.9 or newer
  (`xcode-select --install`).
- **[Claude Code](https://code.claude.com/docs/en/overview)** and/or
  **[Codex CLI](https://github.com/openai/codex)**, installed.

## Install

```bash
gh repo clone playbasis/agent-hub     # private for now: ask a maintainer for access
cd agent-hub
make doctor                           # checks the list above; changes nothing
make install                          # builds the app and installs it in ~/Applications
make open
```

Its icon appears in the menu bar. Afterwards you can also open
**Playbasis AI Agent Hub** from Launchpad or Spotlight.

`make install` replaces an older copy only after checking the new one, and keeps
the old one as a backup. Because you build it yourself, macOS opens it without
a Gatekeeper warning.

## First five minutes

1. **Accounts:** press **Link Claude** and/or **Link ChatGPT** and finish the
   sign-in in your browser. Skip this if your CLIs are already signed in.
2. **Team:** start a team, choose a project folder and say what you want built.
   Claude leads unless you add a Gemini key; you can pick Codex as lead in
   Team setup.
3. **Reports:** your existing Claude Code and Codex sessions appear, and new
   work arrives as it happens.

## Your keys and your data

- **No keys are shipped or required.** Claude and ChatGPT sign-in is handled by
  each provider's own CLI.
- **Optional keys** (Gemini, GLM, an OpenAI-compatible router) are saved in an
  owner-only file in Agent Hub's Application Support folder, or read from an
  environment variable you name. They are never written to `config.json`.
- **What it reads.** Nothing at startup. When you open the panel or the Hub, it
  reads your Claude Code transcripts in `~/.claude/projects` and asks Codex for
  its session list. It reads a project's Git history only when you press
  **Scan projects**, and works inside a project only after you choose it.
- **What it keeps.** Everything stays in
  `~/Library/Application Support/ClaudeCodexBridge`, readable only by you.
  Saved records hold session titles, goals, timings, models, token counts and
  changed file names, not your full prompts or tool output. Home-folder paths
  are redacted.
- **The local control service listens on this Mac only** (it refuses to start
  on any other address), and everything except a health check needs a token the
  app generates.
- **Agents keep their safety settings.** Agent Hub never adds either CLI's
  permission-bypass flags. Sessions it starts itself run Claude Code in safe
  mode and Codex with a workspace-write sandbox; Team Room uses the permission
  and sandbox settings you already chose for each CLI. Every run has a deadline
  and a timeout.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| "Claude Code (or Codex CLI) is not installed or not on PATH" | Apps opened from Finder don't see your shell's PATH. Agent Hub looks in `~/.local/bin`, Homebrew, nvm, Volta, asdf, mise and Bun. For anywhere else, set the full path as `agents.claude_command` or `agents.codex_command` in `~/Library/Application Support/ClaudeCodexBridge/config.json` and reopen the app. |
| A Codex model isn't available on your plan | Change the Codex model in **Settings**, or per room in **Team setup**. |
| Port 8742 is already in use | Quit the other program, or change `server.port` in `config.json`. |
| Nothing happens when you open a second copy | Only one Agent Hub runs at a time. Quit the menu-bar copy first. |
| Anything else | Run `make doctor`, and look in **Logs** or `~/Library/Logs/ClaudeCodexBridge`. |

## Uninstall

```bash
make uninstall            # moves the app to the Trash; keeps your history and keys
make uninstall PURGE=1    # also moves history, keys, logs and preferences to the Trash
```

Claude Code, Codex and their sign-ins are left alone.

## For power users: the `bridge` command

The app ships a command-line helper at
`~/Applications/ClaudeCodexBridge.app/Contents/Helpers/bridge` (or
`apps/MenuBar/.build/debug/bridge` after `make build`).

```bash
bridge status                                   # what is running
bridge metrics view --window 24h                # saved activity, without the app
bridge install-hooks --project /path/to/project # send Claude Code hook events to the Hub
bridge start --project /path/to/project --goal "Build it, test it, stop when verified"
```

## Develop

```bash
make help      # every target
make check     # build + tests + the repository hygiene check
make preview PAGE=Models   # one Hub page in a window beside the installed app
make hooks     # run the hygiene check and gitleaks before every push
```

Read [CONTRIBUTING.md](CONTRIBUTING.md) and [AGENTS.md](AGENTS.md) before
changing behaviour. More detail:

- [Architecture](docs/ARCHITECTURE.md) and [why native Swift](docs/ADR-001-swift-native-core.md)
- [Team Room](docs/TEAM-ROOM.md)
- [Operations](docs/OPERATIONS.md) and [build recovery](docs/BUILD-RECOVERY.md)
- [Security model](docs/SECURITY.md); to report a problem, see [SECURITY.md](SECURITY.md)
- [Economic reporting](docs/ECONOMIC-REPORTING.md),
  [workspace receipt contract](docs/WORKSPACE-RECEIPT-CONTRACT.md) and
  [token allocation](docs/TOKEN-ALLOCATION-STRATEGY.md)

## Licence

Agent Hub is released under the [Apache License 2.0](LICENSE). The Playbasis
marks, the agent persona portraits and the provider logos are not covered; see
[NOTICE](NOTICE).

## Names

The product is **Playbasis AI Agent Hub**. Inside the code you will see its
codename, `ClaudeCodexBridge`. It is kept for the bundle identifier, data
folder and file names so existing installs upgrade in place.

Claude, Claude Code, Codex, ChatGPT, Gemini and the provider logos in this
repository belong to their owners and are used only to identify those services.
The Playbasis name and marks belong to Playbasis.
