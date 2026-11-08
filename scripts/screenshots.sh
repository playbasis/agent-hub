#!/bin/sh
# Renders the README screenshots in docs/screenshots from invented demo
# activity (apps/MenuBar/Tests/BridgeCoreTests/DemoFixtureTests.swift).
#
# Every render runs under a macOS sandbox that cannot read your home folder
# (apart from this repository) or reach the network, so a real project name,
# session title or the installed app's data cannot end up in an image. If the
# sandbox can't be proven to work, nothing is rendered.
#
# usage: scripts/screenshots.sh [name ...]     names: overview activity agents projects models goals
set -eu

unset CDPATH
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
PACKAGE="$ROOT/apps/MenuBar"
OUT_DIR="$ROOT/docs/screenshots"
DELAY="${HUB_SHOT_DELAY:-14}"
# The bottom strip (35 points) shows the connection state, which means nothing
# without a live runtime, so it is cropped away.
STRIP_POINTS="${HUB_SHOT_STRIP_POINTS:-35}"
WIDTH="${HUB_SHOT_WIDTH:-2000}"

fail() { printf 'screenshots: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "macOS only."
for tool in swift swiftc sandbox-exec perl; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool was not found."
done
newline='
'
case "$ROOT$HOME" in *\"*|*\\*|*"$newline"*) fail "Quotes, backslashes and newlines in the repository or home path are not supported." ;; esac

WORK=$(mktemp -d "${TMPDIR:-/tmp}/hub-screenshots.XXXXXX")
cleanup() { case "$WORK" in */hub-screenshots.*) rm -rf "$WORK" ;; esac; }
trap cleanup EXIT HUP INT TERM

# --- Isolation: prove the sandbox blocks the home folder before rendering. ---
PROFILE="$WORK/render.sb"
cat > "$PROFILE" <<EOF
(version 1)
(allow default)
(deny file-read* (subpath "$HOME"))
(allow file-read* (literal "$HOME"))
(allow file-read* (subpath "$ROOT"))
(allow file-read* (subpath "$WORK"))
(deny network*)
EOF
if sandbox-exec -f "$PROFILE" /bin/ls "$HOME/Library" >/dev/null 2>&1; then
  fail "the sandbox did not block reading $HOME/Library, so real data could appear. Nothing was rendered."
fi
sandbox-exec -f "$PROFILE" /bin/ls "$ROOT" >/dev/null 2>&1 || fail "the sandbox cannot read this repository."

# --- Build, then write the invented activity. ---
swift build --package-path "$PACKAGE" >/dev/null
BIN="$(swift build --package-path "$PACKAGE" --show-bin-path)/ClaudeCodexBridgeMenuBar"
[ -x "$BIN" ] || fail "the app was not built."
NOW=$(date +%s)
BRIDGE_DEMO_NOW="$NOW" BRIDGE_DEMO_FIXTURE_OUT="$WORK/demo.json" \
  swift test --package-path "$PACKAGE" --filter DemoFixtureTests/testWriteDemoFixture >/dev/null 2>&1
[ -s "$WORK/demo.json" ] || fail "the demo activity was not written."

swiftc -O "$SCRIPT_DIR/crop-screenshot.swift" -o "$WORK/crop" || fail "the crop tool did not build."
mkdir -p "$OUT_DIR"

# shot NAME SECTION SCROLL_POINTS [SIZE]
shot() {
  name=$1; section=$2; scroll=$3; size=${4:-1400x1000}
  raw="$WORK/$name.png"
  env TZ=UTC BRIDGE_UI_PREVIEW=1 BRIDGE_GOAL_REPLAY_PREVIEW=1 BRIDGE_REFRESH_FIXTURE="$WORK/demo.json" \
    BRIDGE_REPORTS_PREVIEW=1 BRIDGE_REPORTS_SECTION="$section" BRIDGE_REPORTS_PERIOD="7 days" \
    BRIDGE_REPORTS_SIZE="$size" BRIDGE_REPORTS_SCROLL="$scroll" BRIDGE_REPORTS_SNAPSHOT="$raw" \
    BRIDGE_UI_SNAPSHOT_DELAY="$DELAY" \
    /usr/bin/perl -e 'alarm shift; exec @ARGV' 180 \
    sandbox-exec -f "$PROFILE" "$BIN" -AppleLocale en_US -AppleLanguages "(en)" >/dev/null 2>&1 || true
  [ -s "$raw" ] || fail "no image was produced for $name."
  "$WORK/crop" "$raw" "$OUT_DIR/$name.png" "$STRIP_POINTS" "$WIDTH"
  printf '  %s.png\n' "$name"
}

selected() {
  [ -z "${SELECTION:-}" ] && return 0
  case " $SELECTION " in *" $1 "*) return 0 ;; esac
  return 1
}
SELECTION="$*"

printf 'Rendering from invented data in a sandbox:\n'
selected overview && shot overview Overview 0
selected activity && shot activity Overview 690 1400x720
selected agents && shot agents Team 0
selected projects && shot projects Projects 0
selected models && shot models Models 0
selected goals && shot goals Goals 0
printf 'Done: %s\n' "$OUT_DIR"
