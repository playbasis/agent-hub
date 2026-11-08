#!/bin/sh
# Every process tool is stubbed; every source, install and archive is temporary.
# Never launches Swift, calls the live app, or touches LaunchServices.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
TASK_FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/hub-packaging-tests.XXXXXX")
TASK_FIXTURE=$(CDPATH= cd -- "$TASK_FIXTURE" && pwd -P)
trap 'rm -rf "$TASK_FIXTURE"' EXIT
trap 'exit 1' HUP INT TERM
mkdir "$TASK_FIXTURE/bin"
STUBS="$TASK_FIXTURE/bin"
printf '%s\n' '#!/bin/sh' 'if [ "${CASE_FAIL_VERIFY:-}" = all ]; then exit 12; fi' 'case "$*" in *--verify*\.hub-install*) [ "${CASE_FAIL_VERIFY:-}" != stage ] || exit 13 ;; esac' 'exit 0' > "$STUBS/codesign"
printf '%s\n' '#!/bin/sh' 'case " $* " in *" --show-bin-path "*) printf "%s\n" "$FIXTURE_BIN" ;; esac' > "$STUBS/swift"
printf '%s\n' '#!/bin/sh' 'case "$1" in */.hub-install.*/*|*/.hub-build.*/*) [ "${CASE_FAIL_PROMOTE:-0}" != 1 ] || exit 17 ;; esac' 'exec /bin/mv "$@"' > "$STUBS/mv"
printf '%s\n' '#!/bin/sh' '[ -s "$CASE_PROCESS_FILE" ] && printf "777777\n"' > "$STUBS/pgrep"
printf '%s\n' '#!/bin/sh' 'read kind < "$CASE_PROCESS_FILE" || exit 0' 'case "$kind" in foreign) printf "/fixture/other/ClaudeCodexBridgeMenuBar\n" ;; *) printf "%s/Contents/MacOS/ClaudeCodexBridgeMenuBar\n" "$FIXTURE_INSTALLED" ;; esac' > "$STUBS/ps"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" >> "$CASE_REGISTER_LOG"' > "$STUBS/lsregister"
chmod 755 "$STUBS"/*
export PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin"
export CLAUDE_CODEX_BRIDGE_LSREGISTER="$STUBS/lsregister"
passes=0

setup_case() {
  case_name=$1
  CURRENT="$TASK_FIXTURE/$case_name"
  export CURRENT
  PROJECT="$CURRENT/project"
  mkdir -p "$PROJECT" "$CURRENT/bin" "$CURRENT/Applications"
  cp -R "$REPO_ROOT/scripts" "$PROJECT/scripts"
  cp -R "$REPO_ROOT/packaging" "$PROJECT/packaging"
  mkdir -p "$PROJECT/apps/MenuBar/Sources" "$PROJECT/prompts" "$PROJECT/skills/bridge-team"
  cp "$REPO_ROOT/prompts/meta_classifier_v1.txt" "$PROJECT/prompts/"
  cp "$REPO_ROOT/skills/bridge-team/SKILL.md" "$PROJECT/skills/bridge-team/"
  mkdir -p "$PROJECT/apps/MenuBar/Sources/BridgeCore" "$PROJECT/apps/MenuBar/Sources/ClaudeCodexBridgeMenuBar"
  cp -R "$REPO_ROOT/apps/MenuBar/Sources/BridgeCore/Resources" "$PROJECT/apps/MenuBar/Sources/BridgeCore/"
  cp -R "$REPO_ROOT/apps/MenuBar/Sources/ClaudeCodexBridgeMenuBar/Resources" "$PROJECT/apps/MenuBar/Sources/ClaudeCodexBridgeMenuBar/"
  printf '%s\n' '#!/bin/sh' 'printf fixture-icon > "$1"' > "$PROJECT/scripts/generate-app-icon.sh"
  chmod 755 "$PROJECT/scripts/generate-app-icon.sh"
  export FIXTURE_BIN="$CURRENT/bin"
  export FIXTURE_INSTALLED="$CURRENT/Applications/ClaudeCodexBridge.app"
  export CASE_PROCESS_FILE="$CURRENT/process"
  export CASE_REGISTER_LOG="$CURRENT/registrations"
  export CASE_QUIT_LOG="$CURRENT/quit-requests"
  export CLAUDE_CODEX_BRIDGE_APPLICATIONS_DIR="$CURRENT/Applications"
  export CLAUDE_CODEX_BRIDGE_BACKUP_DIR="$CURRENT/backups"
  export CLAUDE_CODEX_BRIDGE_BACKUP_RETAIN=3
  export CLAUDE_CODEX_BRIDGE_BUILD_RETAIN=3
  export CLAUDE_CODEX_BRIDGE_SHUTDOWN_WAIT=1
  export CASE_FAIL_VERIFY="" CASE_FAIL_PROMOTE=0 CASE_STUCK=0
  printf '%s\n' '#!/bin/sh' 'exit 0' > "$FIXTURE_BIN/ClaudeCodexBridgeMenuBar"
  printf '%s\n' '#!/bin/sh' 'if [ "${1:-}" = app-quit ]; then printf quit >> "$CASE_QUIT_LOG"; [ "${CASE_STUCK:-0}" = 1 ] || rm -f "$CASE_PROCESS_FILE"; fi' 'exit 0' > "$FIXTURE_BIN/bridge"
  chmod 755 "$FIXTURE_BIN/ClaudeCodexBridgeMenuBar" "$FIXTURE_BIN/bridge"
  make_bundle "$PROJECT/dist/ClaudeCodexBridge.app" incoming
  make_bundle "$FIXTURE_INSTALLED" previous
}

make_bundle() {
  bundle=$1
  mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Helpers" "$bundle/Contents/Resources"
  cp "$PROJECT/packaging/Info.plist" "$bundle/Contents/Info.plist"
  cp "$FIXTURE_BIN/ClaudeCodexBridgeMenuBar" "$bundle/Contents/MacOS/"
  cp "$FIXTURE_BIN/bridge" "$bundle/Contents/Helpers/"
  cp "$PROJECT/packaging/AppIcon.icns" "$bundle/Contents/Resources/"
  printf '%s\n' "$2" > "$bundle/marker"
}
expect_failure() {
  if "$@" > "$CURRENT/output" 2>&1; then printf 'Expected failure: %s\n' "$case_name" >&2; exit 1; fi
}
assert_previous() { [ "$(head -n 1 "$FIXTURE_INSTALLED/marker")" = previous ] || { printf 'Previous app was not preserved: %s\n' "$case_name" >&2; exit 1; }; }
pass() { passes=$((passes + 1)); }

setup_case successful-install
mkdir -p "$CLAUDE_CODEX_BRIDGE_BACKUP_DIR/historical.app"
"$PROJECT/scripts/install-user.sh" > "$CURRENT/output" 2>&1
[ "$(head -n 1 "$FIXTURE_INSTALLED/marker")" = incoming ]
[ -d "$CLAUDE_CODEX_BRIDGE_BACKUP_DIR/historical.app" ]
[ "$(find "$CLAUDE_CODEX_BRIDGE_BACKUP_DIR/archives.noindex" -name '*.app-archived' -type d | wc -l | tr -d ' ')" = 1 ]
"$PROJECT/scripts/install-user.sh" > "$CURRENT/output" 2>&1
[ "$(find "$CLAUDE_CODEX_BRIDGE_BACKUP_DIR/archives.noindex" -name '*.app-archived' -type d | wc -l | tr -d ' ')" = 2 ]
export CLAUDE_CODEX_BRIDGE_BACKUP_RETAIN=0001
"$PROJECT/scripts/install-user.sh" > "$CURRENT/output" 2>&1
[ "$(find "$CLAUDE_CODEX_BRIDGE_BACKUP_DIR/archives.noindex" -name '*.app-archived' -type d | wc -l | tr -d ' ')" = 1 ]
[ -d "$CLAUDE_CODEX_BRIDGE_BACKUP_DIR/historical.app" ]
pass

setup_case invalid-retention
export CLAUDE_CODEX_BRIDGE_BACKUP_RETAIN=-1
expect_failure "$PROJECT/scripts/install-user.sh"
assert_previous
[ ! -e "$CASE_REGISTER_LOG" ]
export CLAUDE_CODEX_BRIDGE_BUILD_RETAIN=1001
expect_failure "$PROJECT/scripts/build-app.sh"
[ "$(head -n 1 "$PROJECT/dist/ClaudeCodexBridge.app/marker")" = incoming ]
pass

setup_case same-source-target
export CLAUDE_CODEX_BRIDGE_APPLICATIONS_DIR="$PROJECT/dist"
expect_failure "$PROJECT/scripts/install-user.sh"
[ ! -e "$CASE_REGISTER_LOG" ]
pass

setup_case source-validation-fails
export CASE_FAIL_VERIFY=all
expect_failure "$PROJECT/scripts/install-user.sh"
assert_previous
[ ! -e "$CASE_QUIT_LOG" ]
pass

setup_case stage-validation-fails
export CASE_FAIL_VERIFY=stage
expect_failure "$PROJECT/scripts/install-user.sh"
assert_previous
[ ! -e "$CASE_QUIT_LOG" ]
pass

setup_case install-rollback
export CASE_FAIL_PROMOTE=1
expect_failure "$PROJECT/scripts/install-user.sh"
assert_previous
pass

setup_case foreign-instance
printf 'foreign\n' > "$CASE_PROCESS_FILE"
expect_failure "$PROJECT/scripts/install-user.sh"
assert_previous
[ ! -e "$CASE_QUIT_LOG" ]
pass

setup_case shutdown-timeout
printf 'installed\n' > "$CASE_PROCESS_FILE"
export CASE_STUCK=1
expect_failure "$PROJECT/scripts/install-user.sh"
assert_previous
[ -s "$CASE_QUIT_LOG" ] && [ -s "$CASE_PROCESS_FILE" ]
pass

setup_case graceful-shutdown
printf 'installed\n' > "$CASE_PROCESS_FILE"
export CLAUDE_CODEX_BRIDGE_SHUTDOWN_WAIT=0008
"$PROJECT/scripts/install-user.sh" > "$CURRENT/output" 2>&1
[ -s "$CASE_QUIT_LOG" ] && [ ! -e "$CASE_PROCESS_FILE" ]
[ "$(head -n 1 "$FIXTURE_INSTALLED/marker")" = incoming ]
pass

setup_case build-validation-fails
export CASE_FAIL_VERIFY=all
expect_failure "$PROJECT/scripts/build-app.sh"
[ "$(head -n 1 "$PROJECT/dist/ClaudeCodexBridge.app/marker")" = incoming ]
[ ! -e "$PROJECT/dist/previous-builds.noindex" ]
pass

setup_case build-rollback
export CASE_FAIL_PROMOTE=1
expect_failure "$PROJECT/scripts/build-app.sh"
[ "$(head -n 1 "$PROJECT/dist/ClaudeCodexBridge.app/marker")" = incoming ]
pass

setup_case kernel-serialization
expect_failure "$PROJECT/scripts/install-user.sh" --hub-lock-held
assert_previous
printf preserve > "$CURRENT/protected"
ln -s "$CURRENT/protected" "$PROJECT/dist/.packaging.lock"
expect_failure "$PROJECT/scripts/install-user.sh"
[ "$(head -n 1 "$CURRENT/protected")" = preserve ]
rm "$PROJECT/dist/.packaging.lock"
/usr/bin/perl "$PROJECT/scripts/packaging-lock.pl" "$PROJECT/dist/.packaging.lock" /bin/sh -c 'touch "$CURRENT/ready"; sleep 2' &
holder=$!
attempt=0
while [ ! -e "$CURRENT/ready" ] && [ "$attempt" -lt 100 ]; do sleep 0.01; attempt=$((attempt + 1)); done
expect_failure "$PROJECT/scripts/install-user.sh"
wait "$holder"
"$PROJECT/scripts/install-user.sh" > "$CURRENT/output" 2>&1
pass

setup_case wrapper-death-with-child-active
/usr/bin/perl "$PROJECT/scripts/packaging-lock.pl" "$PROJECT/dist/.packaging.lock" /bin/sh -c 'sleep 2 & child=$!; printf "%s\n" "$child" > "$CURRENT/child"; touch "$CURRENT/ready"; wait "$child"' &
holder=$!
attempt=0
while [ ! -e "$CURRENT/ready" ] && [ "$attempt" -lt 100 ]; do sleep 0.01; attempt=$((attempt + 1)); done
[ -s "$CURRENT/child" ] && [ -e "$CURRENT/ready" ]
# This PID is the exact process just created above, proven ready by its private
# temporary fixture marker. No running Hub, provider or unrelated PID is used.
kill -KILL "$holder"
wait "$holder" 2>/dev/null || true
expect_failure "$PROJECT/scripts/install-user.sh"
assert_previous
sleep 2.1
"$PROJECT/scripts/install-user.sh" > "$CURRENT/output" 2>&1
pass

printf 'Packaging fixtures passed: %s (all paths temporary; process, compiler, signing and LaunchServices tools stubbed).\n' "$passes"
