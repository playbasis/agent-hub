#!/bin/sh
# Read-only setup check for building and running Agent Hub. It changes
# nothing, reads no credential files and asks each CLI for its own status.
set -u

PORT="${HUB_DOCTOR_PORT:-8742}"
failures=0
warnings=0

ok() { printf '  \342\234\223 %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; warnings=$((warnings + 1)); }
fail() { printf '  \342\234\227 %s\n' "$*"; failures=$((failures + 1)); }
section() { printf '\n%s\n' "$*"; }

# Bounded run so a CLI waiting on input can never hang the check.
bounded() { /usr/bin/perl -e 'alarm shift; exec @ARGV or exit 127' 20 "$@" 2>/dev/null; }

# Same places the app searches (ExecutableLocator), so the answer matches what
# a Finder-launched Agent Hub will find.
locate() {
  for directory in $(printf '%s' "${PATH:-}" | tr ':' ' ') \
    "$HOME/.local/bin" "$HOME/.volta/bin" "$HOME/.asdf/shims" "$HOME/.bun/bin" \
    "$HOME/.local/share/mise/shims" /opt/homebrew/bin /usr/local/bin /usr/bin /bin; do
    if [ -x "$directory/$1" ] && [ ! -d "$directory/$1" ]; then printf '%s\n' "$directory/$1"; return 0; fi
  done
  if [ -d "$HOME/.nvm/versions/node" ]; then
    newest=$(for version in "$HOME"/.nvm/versions/node/*/; do basename "$version"; done | sort -V | tail -n 1)
    if [ -n "$newest" ] && [ -x "$HOME/.nvm/versions/node/$newest/bin/$1" ]; then
      printf '%s\n' "$HOME/.nvm/versions/node/$newest/bin/$1"; return 0
    fi
  fi
  return 1
}

section "Build tools"
macos=$(sw_vers -productVersion 2>/dev/null || echo 0)
if [ "${macos%%.*}" -ge 13 ] 2>/dev/null; then ok "macOS $macos"; else fail "macOS $macos: Agent Hub needs macOS 13 or newer."; fi
if xcode-select -p >/dev/null 2>&1; then ok "Xcode tools at $(xcode-select -p)"; else fail "Xcode Command Line Tools are missing: run xcode-select --install"; fi
swift_version=$(swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1)
if [ -z "$swift_version" ]; then
  fail "Swift was not found."
else
  major=${swift_version%%.*}; minor=${swift_version#*.}
  if [ "$major" -gt 5 ] || { [ "$major" -eq 5 ] && [ "$minor" -ge 9 ]; }; then ok "Swift $swift_version"; else fail "Swift $swift_version: 5.9 or newer is needed."; fi
fi

section "Coding agents (at least one; Team Room works best with both)"
agents=0
if claude=$(locate claude); then
  agents=$((agents + 1))
  ok "Claude Code $(bounded "$claude" --version | head -n 1) at $claude"
  if bounded "$claude" auth status --json | grep -q '"loggedIn"[[:space:]]*:[[:space:]]*true'; then
    ok "Claude Code is signed in"
  else
    warn "Claude Code is not signed in. Use Link Claude in Agent Hub, or run: claude auth login"
  fi
else
  warn "Claude Code was not found. Install it from https://code.claude.com/docs/en/overview, or set agents.claude_command in config.json."
fi
if codex=$(locate codex); then
  agents=$((agents + 1))
  ok "Codex CLI $(bounded "$codex" --version | head -n 1) at $codex"
  if bounded "$codex" login status >/dev/null; then
    ok "Codex is signed in"
  else
    warn "Codex is not signed in. Use Link ChatGPT in Agent Hub, or run: codex login"
  fi
else
  warn "Codex CLI was not found. Install it from https://github.com/openai/codex, or set agents.codex_command in config.json."
fi
[ "$agents" -gt 0 ] || fail "Neither Claude Code nor Codex CLI was found."

section "Runtime"
if health=$(curl -fsS --max-time 2 "http://127.0.0.1:$PORT/health" 2>/dev/null); then
  ok "Agent Hub is running on 127.0.0.1:$PORT ($health)"
elif lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  fail "Another program is listening on port $PORT. Quit it, or change server.port in config.json."
else
  ok "Port $PORT is free"
fi
app="$HOME/Applications/ClaudeCodexBridge.app"
if [ -d "$app" ]; then
  ok "Installed: $app ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null))"
else
  ok "Not installed yet: run make install"
fi

section "Optional"
if command -v python3 >/dev/null 2>&1; then ok "python3 (workspace contract cross-check)"; else warn "python3 not found: make test skips the contract cross-check."; fi
if command -v gitleaks >/dev/null 2>&1; then ok "gitleaks (secret scan before push)"; else warn "gitleaks not found: the pre-push hook will run only the hygiene check (brew install gitleaks)."; fi

printf '\n'
if [ "$failures" -gt 0 ]; then
  printf '%s problem(s) to fix.\n' "$failures"
  exit 1
fi
printf 'Ready. %s note(s) above.\n' "$warnings"
