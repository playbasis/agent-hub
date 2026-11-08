# Contributing

Thanks for helping with Playbasis AI Agent Hub. Read [AGENTS.md](AGENTS.md)
first: it holds the product rules that reviews check against. The short
version is that the Hub stays local, never guesses (unknown numbers stay
visibly unknown), and never weakens the safety settings of the agents it runs.

## Set up

```bash
make doctor    # read-only: macOS, Swift, Claude Code, Codex, port 8742
make check     # build, all tests, and the repository hygiene check
make hooks     # optional: run the hygiene check and gitleaks before every push
```

`make check` should pass on a fresh clone before you change anything. If it
doesn't, open an issue with the output rather than working around it. There is
no hosted CI yet; your local `make check` output is the review gate, so paste
its last lines into the pull request.

## Day to day

| Task | Command |
| --- | --- |
| Debug build | `make build` |
| Tests only | `make test` (one suite: `swift test --package-path apps/MenuBar --filter RoomOrchestrationTests`) |
| Run the app from source | `make run` (quit the installed copy first; only one Agent Hub runs at a time) |
| Look at one Hub page without touching the installed app | `make preview PAGE=Models` |
| Build and install the signed app | `make install`, then `make open` |
| Remove it | `make uninstall` (`PURGE=1` also moves history and keys to the Trash) |
| Re-render the README screenshots | `make screenshots` (`make screenshots NAMES="models goals"` for some) |

`make preview` opens the Hub in a diagnostic window that runs beside an
installed copy and reads the same local history. Pages are the sidebar names:
Overview, Now, Goals, Team, Projects, Models, Skills, Journal, Accounts,
Credits, Logs and Settings. To time a page, add `BRIDGE_PERF_TRACE=1`; timing
lines go to the terminal.

## Rules that reviews enforce

1. **Tests with behaviour.** Any change in behaviour comes with a test. Logic
   lives in `BridgeCore` where it can be tested; views only present it.
2. **No new numbers in views.** Totals, ratios and money come from tested
   `BridgeCore` helpers. A view never re-adds tokens, time or cost, and a
   missing input shows as "—", never as zero.
3. **Providers stay behind adapters.** Claude Code and Codex are driven only
   through their CLIs (`claude`, `codex exec`, `codex app-server`). Never read
   their credential files and never add a permission-bypass flag.
4. **Contracts are public.** Files in `schemas/` are normative. If you change
   a receipt or report shape, update the schema, the Swift types and
   `scripts/check-workspace-contracts.py` together, and bump the version.
5. **One theme.** Colours, symbols and button styles come from
   `BridgeTheme.swift`, so light, dark, increased contrast and reduced motion
   keep working. The Hub must stay usable at narrow widths and by keyboard.
6. **Plain words.** Write for someone who isn't an engineer. Method notes go
   in an ⓘ popover, not under the number.

## Keep the repository clean

Never commit keys, real home-folder paths, customer names or details of other
projects. `make check` runs `scripts/check-clean.sh`. Pass extra terms that must
never appear at run time, so the terms themselves aren't written into the
repository:

```bash
HUB_EXTRA_FORBIDDEN='my-name|client-co|internal.example' make hygiene
```

Screenshots in `docs/screenshots` come only from `make screenshots`. It renders
invented demo activity inside a macOS sandbox that cannot read your home folder
or the network, so a real project name can't appear. Never commit a screenshot
of your own history; to add a page, add it to `scripts/screenshots.sh`.

Test fixtures use placeholder people and paths (`/Users/example/...`), never
real transcripts. Tests that read real local history are opt-in through an
environment variable and skip by default.

## Pull requests

Keep each pull request to one change, explain what it changes for the person
using the app, and include the last lines of `make check`. Commit messages are
short imperative sentences ("Add …", "Fix …").

Be kind: this project follows a [Code of Conduct](CODE_OF_CONDUCT.md).

Contributions are accepted under the project's [Apache License 2.0](LICENSE),
as section 5 of the licence describes. Don't add artwork, fonts or code you
can't license that way.

Report security problems privately: see [SECURITY.md](SECURITY.md).
