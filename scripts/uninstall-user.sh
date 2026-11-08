#!/bin/sh
# Remove the installed app. Everything moves to the Trash, so nothing is
# permanently deleted. Your activity history and keys stay unless --purge.
set -eu

USER_APPLICATIONS="${CLAUDE_CODEX_BRIDGE_APPLICATIONS_DIR:-$HOME/Applications}"
INSTALLED_APP="$USER_APPLICATIONS/ClaudeCodexBridge.app"
DATA_DIR="$HOME/Library/Application Support/ClaudeCodexBridge"
LOG_DIR="$HOME/Library/Logs/ClaudeCodexBridge"
PREFERENCES="$HOME/Library/Preferences/dev.claudecodexbridge.app.plist"
TRASH="$HOME/.Trash"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
STAMP=$(date +%Y%m%d-%H%M%S)

purge=0
dry_run=0
for argument in "$@"; do
  case "$argument" in
    --purge) purge=1 ;;
    --dry-run) dry_run=1 ;;
    *) printf 'usage: %s [--purge] [--dry-run]\n' "$0" >&2; exit 64 ;;
  esac
done

run() { if [ "$dry_run" -eq 1 ]; then printf 'would run: %s\n' "$*"; else "$@"; fi; }

# to_trash PATH [NAME]: NAME keeps same-named folders apart in the Trash.
to_trash() {
  [ -e "$1" ] || [ -L "$1" ] || return 0
  name=${2:-$(basename "$1")}
  target="$TRASH/$name"
  [ ! -e "$target" ] || target="$TRASH/$name $STAMP"
  run mv "$1" "$target"
  [ "$dry_run" -eq 1 ] || printf 'Moved to Trash: %s\n' "$1"
}

running() {
  pgrep -f "$INSTALLED_APP/Contents/MacOS/ClaudeCodexBridgeMenuBar" >/dev/null 2>&1
}

if running; then
  run "$INSTALLED_APP/Contents/Helpers/bridge" app-quit
  if [ "$dry_run" -eq 0 ]; then
    attempts=300
    while running && [ "$attempts" -gt 0 ]; do sleep 0.1; attempts=$((attempts - 1)); done
    ! running || { printf 'Agent Hub is still closing. Quit it from the menu bar and run this again; nothing was removed.\n' >&2; exit 1; }
  fi
fi

mkdir -p "$TRASH"
if [ -d "$INSTALLED_APP" ]; then
  [ -x "$LSREGISTER" ] && run "$LSREGISTER" -u "$INSTALLED_APP" >/dev/null 2>&1 || true
  to_trash "$INSTALLED_APP"
else
  printf 'No app at %s\n' "$INSTALLED_APP"
fi

if [ "$purge" -eq 1 ]; then
  to_trash "$DATA_DIR" "ClaudeCodexBridge data"
  to_trash "$LOG_DIR" "ClaudeCodexBridge logs"
  # Move the file rather than `defaults delete`: it stays recoverable and
  # follows $HOME, which the preferences daemon does not.
  to_trash "$PREFERENCES"
else
  printf 'Kept your history, settings and saved keys in %s (add --purge to move them to the Trash too).\n' "$DATA_DIR"
fi

cat <<'NOTE'

Not touched: Claude Code and Codex themselves, and their sign-ins.
If you ran `bridge install-hooks` for a project, remove the Agent Hub entries
from that project's .claude/settings.local.json (a backup was saved beside it).
NOTE
