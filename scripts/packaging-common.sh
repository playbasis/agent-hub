#!/bin/sh
# Shared, fail-closed checks. Sourced only by the two local packaging scripts.
hub_fail() { printf '%s\n' "$*" >&2; exit 1; }

hub_validate_retention() {
  case "$2" in ''|*[!0-9]*) hub_fail "$1 must be an integer from 0 to 1000." ;; esac
  [ "${#2}" -le 4 ] && [ "$2" -le 1000 ] || hub_fail "$1 must be an integer from 0 to 1000."
}

hub_verify_packaging_lock() {
  [ -n "${HUB_PACKAGING_LEASE_FD:-}" ] && [ -n "${HUB_PACKAGING_LEASE_PID:-}" ] || hub_fail "Packaging must be entered through its lock wrapper."
  /usr/bin/perl "$SCRIPT_DIR/packaging-lock.pl" --check "$1" "$HUB_PACKAGING_LEASE_FD" "$HUB_PACKAGING_LEASE_PID"
}

hub_canonical_path() {
  # Resolve existing ancestors without creating a directory inside a bundle
  # that is about to be validated. Missing tail components stay literal.
  /usr/bin/perl -MCwd=abs_path -MFile::Basename=dirname,basename -MFile::Spec -e '
    my $p = File::Spec->rel2abs(shift); my @tail;
    die "Parent traversal is not allowed in packaging paths\n" if $p =~ m{(?:^|/)\.\.(?:/|$)};
    die "Newlines are not allowed in packaging paths\n" if $p =~ /[\r\n]/;
    while (!-e $p && !-l $p) { unshift @tail, basename($p); $p = dirname($p); }
    my $base = abs_path($p); die "Cannot resolve packaging path\n" unless defined $base;
    print File::Spec->catfile($base, @tail);' "$1"
}

hub_validate_bundle() {
  [ -d "$1" ] && [ ! -L "$1" ] || hub_fail "Expected a real application bundle: $1"
  plutil -lint "$1/Contents/Info.plist" >/dev/null
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist")" = dev.claudecodexbridge.app ] || hub_fail "Unexpected application identity."
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$1/Contents/Info.plist")" = ClaudeCodexBridgeMenuBar ] || hub_fail "Unexpected application executable."
  [ -x "$1/Contents/MacOS/ClaudeCodexBridgeMenuBar" ] && [ -x "$1/Contents/Helpers/bridge" ] || hub_fail "Application executables are missing."
  [ -s "$1/Contents/Resources/AppIcon.icns" ] || hub_fail "Application icon is missing."
  codesign --verify --deep --strict -R='identifier "dev.claudecodexbridge.app"' "$1"
  codesign --verify --strict -R='identifier "dev.claudecodexbridge.bridge"' "$1/Contents/Helpers/bridge"
}

hub_register() {
  if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" "$1" "$2" >/dev/null 2>&1 || printf 'LaunchServices could not update %s; the verified app remains available at its exact path.\n' "$2" >&2
  fi
}

hub_prune_archives() {
  directory=$1
  # Retention has already been validated. Normalize leading zeros before
  # shell arithmetic, which can otherwise interpret 0008 as invalid octal.
  retain=$(expr "$2" + 0) || [ "$retain" = 0 ]
  # Only this generator's nonlaunchable archives are eligible. Historical .app
  # backups and arbitrary files are never swept or migrated automatically.
  list=$(mktemp "$directory/.retention.XXXXXX")
  for item in "$directory"/ClaudeCodexBridge-*.app-archived; do
    if [ -d "$item" ] && [ ! -L "$item" ]; then printf '%s\n' "$item"; fi
  done | sort > "$list"
  count=$(wc -l < "$list" | tr -d ' ')
  if [ "$count" -gt "$retain" ]; then
    head -n "$((count - retain))" "$list" | while IFS= read -r stale; do
      case "$stale" in "$directory"/ClaudeCodexBridge-*.app-archived) rm -rf "$stale" ;; *) hub_fail "Refusing an unexpected archive path." ;; esac
    done
  fi
  rm "$list"
}
