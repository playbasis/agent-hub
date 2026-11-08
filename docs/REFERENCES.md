# Integration references

The adapter flags and hook payload assumptions were checked against current
official documentation and the locally installed CLI help on 2026-07-24.

- [Codex CLI command reference](https://developers.openai.com/codex/cli/reference)
  - `codex exec` for non-interactive work
  - `--json` for JSONL events
  - `--output-last-message` for a stable final result
  - `--sandbox workspace-write` for bounded unattended edits
- [Claude Code hooks guide](https://code.claude.com/docs/en/hooks-guide)
  - native HTTP hooks receive the same JSON as command-hook stdin
  - lifecycle events include session, prompt, tool, stop, failure, compaction,
    and session-end events
- [Claude Code CLI reference](https://code.claude.com/docs/en/cli-reference)
  - `-p` for non-interactive mode
  - `--output-format json` and `--input-format text`
  - `--resume` for session continuation

Local versions used for verification:

- Claude Code `2.1.119`
- Codex CLI `0.145.0`
- Apple Swift `5.9.2`, arm64 macOS target
