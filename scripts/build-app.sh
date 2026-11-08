#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PACKAGE_PATH="$PROJECT_ROOT/apps/MenuBar"
DIST_DIR="$PROJECT_ROOT/dist"
APP_PATH="$DIST_DIR/ClaudeCodexBridge.app"
FINAL_APP_PATH="$APP_PATH"
. "$SCRIPT_DIR/packaging-common.sh"
ARCHIVE_RETAIN="${CLAUDE_CODEX_BRIDGE_BUILD_RETAIN:-3}"
hub_validate_retention CLAUDE_CODEX_BRIDGE_BUILD_RETAIN "$ARCHIVE_RETAIN"
mkdir -p "$DIST_DIR"
if [ "${1:-}" != --hub-lock-held ]; then
  exec /usr/bin/perl "$SCRIPT_DIR/packaging-lock.pl" "$DIST_DIR/.packaging.lock" /bin/sh "$0" --hub-lock-held "$@"
fi
shift
[ "$#" -eq 0 ] || hub_fail "Unexpected build arguments."
hub_verify_packaging_lock "$DIST_DIR/.packaging.lock"

STAGE_ROOT=$(mktemp -d "$DIST_DIR/.hub-build.XXXXXX")
APP_PATH="$STAGE_ROOT/ClaudeCodexBridge.app"
PREVIOUS_APP=""
PUBLISHED=0
cleanup_build() {
  result=$?
  trap - EXIT HUP INT TERM
  if [ "$result" -ne 0 ] && [ "$PUBLISHED" -eq 0 ] && [ -n "$PREVIOUS_APP" ] && [ ! -e "$FINAL_APP_PATH" ] && [ ! -L "$FINAL_APP_PATH" ]; then
    if mv "$PREVIOUS_APP" "$FINAL_APP_PATH"; then
      printf 'Restored the previous verified build: %s\n' "$FINAL_APP_PATH" >&2
    else
      printf 'Previous build is safe at %s; restore it manually before installing.\n' "$PREVIOUS_APP" >&2
    fi
  fi
  case "$STAGE_ROOT" in "$DIST_DIR"/.hub-build.*) rm -rf "$STAGE_ROOT" ;; esac
  exit "$result"
}
trap cleanup_build EXIT
trap 'exit 1' HUP INT TERM

swift build -c release --package-path "$PACKAGE_PATH"
BIN_DIR=$(swift build -c release --show-bin-path --package-path "$PACKAGE_PATH")

# Keep a short rollback window of earlier builds, but never as launchable
# bundles: every ".app" left in dist/ was registered with LaunchServices and
# indexed by Spotlight, so old builds showed up as extra "Playbasis AI Agent
# Hub" apps — and opening one ran old code that then held the single-instance
# lock. Archived builds live in a .noindex folder without an .app extension.
LSREGISTER="${CLAUDE_CODEX_BRIDGE_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
ARCHIVE_DIR="$DIST_DIR/previous-builds.noindex"

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Helpers" "$APP_PATH/Contents/Resources"
cp "$BIN_DIR/ClaudeCodexBridgeMenuBar" "$APP_PATH/Contents/MacOS/ClaudeCodexBridgeMenuBar"
cp "$BIN_DIR/bridge" "$APP_PATH/Contents/Helpers/bridge"
cp "$PROJECT_ROOT/packaging/Info.plist" "$APP_PATH/Contents/Info.plist"
cp \
  "$PROJECT_ROOT/prompts/meta_classifier_v1.txt" \
  "$APP_PATH/Contents/Resources/meta_classifier_v1.txt"
cmp \
  "$PROJECT_ROOT/prompts/meta_classifier_v1.txt" \
  "$APP_PATH/Contents/Resources/meta_classifier_v1.txt"

# Team role instructions ship with the app and helper; never depend on a
# developer-machine SwiftPM resource path at runtime.
cmp "$PROJECT_ROOT/skills/bridge-team/SKILL.md" "$PACKAGE_PATH/Sources/BridgeCore/Resources/bridge-team.md"
for playbook in room-coordinator-v1 room-frontend-v1 room-backend-v1 room-review-v1 bridge-team; do
  cp "$PACKAGE_PATH/Sources/BridgeCore/Resources/$playbook.md" "$APP_PATH/Contents/Resources/$playbook.md"
  cmp "$PACKAGE_PATH/Sources/BridgeCore/Resources/$playbook.md" "$APP_PATH/Contents/Resources/$playbook.md"
done

# Generate every native icon size from the original Playbasis P. The generator
# round-trips the ICNS container before codesign seals the application.
"$PROJECT_ROOT/scripts/generate-app-icon.sh" "$APP_PATH/Contents/Resources/AppIcon.icns"

# Versioned price catalog. Without it the orchestrator refuses to enforce a
# cost ceiling rather than guessing a price — that refusal is deliberate, so a
# silently-missing catalog must fail the build, not degrade at runtime.
cp "$PROJECT_ROOT/packaging/price-catalog.json" "$APP_PATH/Contents/Resources/price-catalog.json"
cmp "$PROJECT_ROOT/packaging/price-catalog.json" "$APP_PATH/Contents/Resources/price-catalog.json"
# plutil -lint only understands plists; parse it as JSON instead.
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' \
  "$APP_PATH/Contents/Resources/price-catalog.json"

chmod 755 \
  "$APP_PATH/Contents/MacOS/ClaudeCodexBridgeMenuBar" \
  "$APP_PATH/Contents/Helpers/bridge"

# Original provider marks are local resources, not generated approximations.
LOGO_SOURCE="$PACKAGE_PATH/Sources/ClaudeCodexBridgeMenuBar/Resources/ProviderLogos"
ditto "$LOGO_SOURCE" "$APP_PATH/Contents/Resources/ProviderLogos"
for logo in claude.svg openai.svg gemini.png grok.svg; do
  cmp "$LOGO_SOURCE/$logo" "$APP_PATH/Contents/Resources/ProviderLogos/$logo"
done

# WorkspaceOps persona portraits. A missing file falls back to the provider
# mark at runtime, so verify the whole set here instead of finding out later.
PERSONA_SOURCE="$PACKAGE_PATH/Sources/ClaudeCodexBridgeMenuBar/Resources/AgentPersonas"
"$BIN_DIR/bridge" validate-personas --directory "$PERSONA_SOURCE"
ditto "$PERSONA_SOURCE" "$APP_PATH/Contents/Resources/AgentPersonas"
PERSONA_EXPECTED=$(find "$PERSONA_SOURCE" -name '*.png' | wc -l | tr -d ' ')
PERSONA_COPIED=$(find "$APP_PATH/Contents/Resources/AgentPersonas" -name '*.png' | wc -l | tr -d ' ')
[ "$PERSONA_EXPECTED" -gt 0 ] && [ "$PERSONA_EXPECTED" = "$PERSONA_COPIED" ] || {
  echo "Persona portraits missing: expected $PERSONA_EXPECTED, copied $PERSONA_COPIED" >&2
  exit 1
}
"$BIN_DIR/bridge" validate-personas --directory "$APP_PATH/Contents/Resources/AgentPersonas"
for portrait in "$PERSONA_SOURCE"/*.png; do
  cmp "$portrait" "$APP_PATH/Contents/Resources/AgentPersonas/$(basename "$portrait")"
done

# Skill artwork is small, local, alpha-preserving and shared by every row.
SKILL_SOURCE="$PACKAGE_PATH/Sources/ClaudeCodexBridgeMenuBar/Resources/SkillPortraits"
ditto "$SKILL_SOURCE" "$APP_PATH/Contents/Resources/SkillPortraits"
for category in research build review design release knowledge; do
  cmp "$SKILL_SOURCE/$category.png" "$APP_PATH/Contents/Resources/SkillPortraits/$category.png"
done

# Product name for Finder, Launchpad and Spotlight, and the Playbasis mark the
# sidebar and panel show. Both are sealed by the signature below.
mkdir -p "$APP_PATH/Contents/Resources/en.lproj"
cp "$PROJECT_ROOT/packaging/en.lproj/InfoPlist.strings" "$APP_PATH/Contents/Resources/en.lproj/InfoPlist.strings"
plutil -lint "$APP_PATH/Contents/Resources/en.lproj/InfoPlist.strings" >/dev/null
# macOS ignores a localized name when the base name differs from the bundle's
# file name (it assumes the user renamed the app), so keep them identical.
BASE_DISPLAY_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP_PATH/Contents/Info.plist")
[ "$BASE_DISPLAY_NAME" = "$(basename "$APP_PATH" .app)" ] || {
  echo "CFBundleDisplayName must equal the bundle file name; put the product name in en.lproj/InfoPlist.strings" >&2
  exit 1
}
BRAND_SOURCE="$PACKAGE_PATH/Sources/ClaudeCodexBridgeMenuBar/Resources/Brand"
ditto "$BRAND_SOURCE" "$APP_PATH/Contents/Resources/Brand"
cmp "$BRAND_SOURCE/playbasis-mark.png" "$APP_PATH/Contents/Resources/Brand/playbasis-mark.png"

if command -v codesign >/dev/null 2>&1; then
  # Plain ad-hoc signing defaults the designated requirement to a changing
  # cdhash, which makes Keychain treat every local rebuild as a different app.
  # A stable bundle-identifier requirement preserves local development upgrade
  # identity. Public releases should replace this with Developer ID signing.
  codesign \
    --force \
    --sign - \
    --identifier dev.claudecodexbridge.bridge \
    --requirements '=designated => identifier "dev.claudecodexbridge.bridge"' \
    "$APP_PATH/Contents/Helpers/bridge"
  codesign \
    --force \
    --sign - \
    --identifier dev.claudecodexbridge.app \
    --requirements '=designated => identifier "dev.claudecodexbridge.app"' \
    "$APP_PATH"
fi

# Only a completely assembled and verified bundle may replace the last build.
hub_validate_bundle "$APP_PATH"
if [ -e "$FINAL_APP_PATH" ] || [ -L "$FINAL_APP_PATH" ]; then
  [ -d "$FINAL_APP_PATH" ] && [ ! -L "$FINAL_APP_PATH" ] || hub_fail "Refusing to replace an unexpected build path."
  [ ! -L "$ARCHIVE_DIR" ] || hub_fail "Refusing a linked archive directory."
  mkdir -p "$ARCHIVE_DIR"
  STAMP="$(date -u +%Y%m%dT%H%M%SZ)-$(uuidgen)"
  PREVIOUS_APP="$ARCHIVE_DIR/ClaudeCodexBridge-$STAMP.app-archived"
  [ ! -e "$PREVIOUS_APP" ] || hub_fail "Archive name collision; previous build was not moved."
  hub_register -u "$FINAL_APP_PATH"
  mv "$FINAL_APP_PATH" "$PREVIOUS_APP"
fi
mv "$APP_PATH" "$FINAL_APP_PATH"
PUBLISHED=1
if [ -d "$ARCHIVE_DIR" ]; then hub_prune_archives "$ARCHIVE_DIR" "$ARCHIVE_RETAIN"; fi
echo "$FINAL_APP_PATH"
