#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
DIST_DIR="$PROJECT_ROOT/dist"
SOURCE_APP="$DIST_DIR/ClaudeCodexBridge.app"
USER_APPLICATIONS="${CLAUDE_CODEX_BRIDGE_APPLICATIONS_DIR:-$HOME/Applications}"
BACKUP_DIR="${CLAUDE_CODEX_BRIDGE_BACKUP_DIR:-$HOME/Library/Application Support/ClaudeCodexBridge/previous-installs}"
BACKUP_RETAIN="${CLAUDE_CODEX_BRIDGE_BACKUP_RETAIN:-3}"
SHUTDOWN_WAIT="${CLAUDE_CODEX_BRIDGE_SHUTDOWN_WAIT:-30}"
LSREGISTER="${CLAUDE_CODEX_BRIDGE_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
. "$SCRIPT_DIR/packaging-common.sh"
hub_validate_retention CLAUDE_CODEX_BRIDGE_BACKUP_RETAIN "$BACKUP_RETAIN"
hub_validate_retention CLAUDE_CODEX_BRIDGE_SHUTDOWN_WAIT "$SHUTDOWN_WAIT"
[ "$SHUTDOWN_WAIT" -ge 1 ] && [ "$SHUTDOWN_WAIT" -le 120 ] || hub_fail "Shutdown wait must be from 1 to 120 seconds."
[ -d "$DIST_DIR" ] || hub_fail "Missing build output. Run make app first."
if [ "${1:-}" != --hub-lock-held ]; then
  exec /usr/bin/perl "$SCRIPT_DIR/packaging-lock.pl" "$DIST_DIR/.packaging.lock" /bin/sh "$0" --hub-lock-held "$@"
fi
shift
[ "$#" -eq 0 ] || hub_fail "Unexpected install arguments."
hub_verify_packaging_lock "$DIST_DIR/.packaging.lock"

hub_validate_bundle "$SOURCE_APP"
SOURCE_APP=$(hub_canonical_path "$SOURCE_APP")
USER_APPLICATIONS=$(hub_canonical_path "$USER_APPLICATIONS")
BACKUP_DIR=$(hub_canonical_path "$BACKUP_DIR")
INSTALLED_APP="$USER_APPLICATIONS/ClaudeCodexBridge.app"
[ "$SOURCE_APP" != "$INSTALLED_APP" ] || hub_fail "Build source and installed destination must be different paths."
case "$USER_APPLICATIONS/" in "$SOURCE_APP/"*) hub_fail "The install destination cannot be inside the source bundle." ;; esac
case "$BACKUP_DIR/" in "$SOURCE_APP/"*|"$INSTALLED_APP/"*) hub_fail "The backup folder cannot be inside an application bundle." ;; esac
[ ! -L "$INSTALLED_APP" ] || hub_fail "Refusing to replace a linked application path."
if [ -e "$INSTALLED_APP" ]; then
  [ -d "$INSTALLED_APP" ] || hub_fail "The installed path is not an application directory."
fi
ARCHIVE_DIR="$BACKUP_DIR/archives.noindex"
[ ! -L "$ARCHIVE_DIR" ] || hub_fail "Refusing a linked archive directory."
INSTALLED_EXECUTABLE="$INSTALLED_APP/Contents/MacOS/ClaudeCodexBridgeMenuBar"

hub_pids() { pgrep -f '(^|/)ClaudeCodexBridgeMenuBar([[:space:]]|$)' 2>/dev/null || true; }
running_pids() {
  for pid in $(hub_pids); do
    command=$(ps -ww -p "$pid" -o command= 2>/dev/null || true)
    case "$command" in "$INSTALLED_EXECUTABLE"|"$INSTALLED_EXECUTABLE "*) printf '%s\n' "$pid" ;; esac
  done
}
refuse_foreign_instances() {
  for pid in $(hub_pids); do
    command=$(ps -ww -p "$pid" -o command= 2>/dev/null || true)
    case "$command" in
      ''|"$INSTALLED_EXECUTABLE"|"$INSTALLED_EXECUTABLE "*) ;;
      *) hub_fail "Another Agent Hub copy is running from a different location (PID $pid). Quit that copy before installing; it was not stopped." ;;
    esac
  done
}
wait_for_exit() {
  # expr treats validated decimal input consistently, including leading zeros.
  attempts=$(expr "$SHUTDOWN_WAIT" \* 10)
  while [ "$attempts" -gt 0 ]; do
    [ -n "$(running_pids)" ] || return 0
    sleep 0.1
    attempts=$((attempts - 1))
  done
  [ -z "$(running_pids)" ]
}

mkdir -p "$USER_APPLICATIONS"
STAGE_ROOT=$(mktemp -d "$USER_APPLICATIONS/.hub-install.XXXXXX")
STAGED_APP="$STAGE_ROOT/ClaudeCodexBridge.app"
PREVIOUS_APP=""
PUBLISHED=0
cleanup_install() {
  result=$?
  trap - EXIT HUP INT TERM
  if [ "$result" -ne 0 ] && [ "$PUBLISHED" -eq 0 ] && [ -n "$PREVIOUS_APP" ] && [ ! -e "$INSTALLED_APP" ] && [ ! -L "$INSTALLED_APP" ]; then
    if mv "$PREVIOUS_APP" "$INSTALLED_APP"; then
      hub_register -f "$INSTALLED_APP"
      printf 'Restored the previous installed app: %s\n' "$INSTALLED_APP" >&2
    else
      printf 'The previous app remains safe at %s. Restore that bundle to %s.\n' "$PREVIOUS_APP" "$INSTALLED_APP" >&2
    fi
  fi
  case "$STAGE_ROOT" in "$USER_APPLICATIONS"/.hub-install.*) rm -rf "$STAGE_ROOT" ;; esac
  exit "$result"
}
trap cleanup_install EXIT
trap 'exit 1' HUP INT TERM

ditto "$SOURCE_APP" "$STAGED_APP"
hub_validate_bundle "$STAGED_APP"
refuse_foreign_instances
if [ -n "$(running_pids)" ]; then
  "$STAGED_APP/Contents/Helpers/bridge" app-quit
  if ! wait_for_exit; then
    hub_fail "Agent Hub hasn't finished closing after ${SHUTDOWN_WAIT}s. The installed app is unchanged; wait for cleanup to finish and retry. No process was forcibly stopped."
  fi
fi
# Check again after waiting: a concurrently reopened old copy must not be
# silently replaced while it still owns the production lock.
refuse_foreign_instances
[ -z "$(running_pids)" ] || hub_fail "Agent Hub reopened during installation. Quit it and retry."
if [ -e "$INSTALLED_APP" ]; then
  mkdir -p "$ARCHIVE_DIR"
  STAMP="$(date -u +%Y%m%dT%H%M%SZ)-$(uuidgen)"
  PREVIOUS_APP="$ARCHIVE_DIR/ClaudeCodexBridge-$STAMP.app-archived"
  [ ! -e "$PREVIOUS_APP" ] || hub_fail "Archive name collision; installed app is unchanged."
  hub_register -u "$INSTALLED_APP"
  mv "$INSTALLED_APP" "$PREVIOUS_APP"
fi
mv "$STAGED_APP" "$INSTALLED_APP"
PUBLISHED=1
hub_register -f "$INSTALLED_APP"
# Never unregister by bundle ID, scan the user's Applications folder, or sweep
# historical backups. The build and install paths were proven distinct above.
hub_register -u "$SOURCE_APP"
if [ -d "$ARCHIVE_DIR" ]; then hub_prune_archives "$ARCHIVE_DIR" "$BACKUP_RETAIN"; fi
echo "$INSTALLED_APP"
