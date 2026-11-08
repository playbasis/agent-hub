# Safe local build and install

The installed bundle stays at `~/Applications/ClaudeCodexBridge.app`; its
user-facing name is **Playbasis AI Agent Hub**. Bundle identifiers, provider
credentials, settings and saved activity do not move when it is updated.

## What the scripts guarantee

- Builds and installs share a kernel lock in `dist/.packaging.lock`. A crash
  releases ownership automatically once all active packaging tools have exited;
  stale text in that file is harmless. The lease is inherited intentionally by
  packaging tools so a dead wrapper cannot allow a second install to overlap
  an unfinished child operation. The production app lock remains close-on-exec.
- A new bundle is assembled in a unique temporary directory, checked for the
  expected application and helper identities, and signature-verified before
  it can replace a working copy.
- Installation asks the existing, installed app to close gracefully. It waits
  up to 30 seconds by default and fails with the old install unchanged if
  cleanup is still running. It does not send SIGTERM or kill provider apps.
- A running copy from another location is reported, not silently stopped or
  mistaken for the newly installed version. Quit that copy explicitly first.
- Failed promotion restores the previous bundle when possible. If rollback
  itself fails, the error prints the exact recoverable archive path.
- New backups use unique names ending in `.app-archived` inside a `.noindex`
  directory, so they are not offered as additional launchable applications.
  Existing historical `.app` backups are never swept or migrated.
- LaunchServices updates only the two validated, distinct build/install paths;
  there is no global reset or scan of the user's Applications folder.

`CLAUDE_CODEX_BRIDGE_BACKUP_RETAIN` and
`CLAUDE_CODEX_BRIDGE_BUILD_RETAIN` accept integers from 0 to 1000 (default 3).
Pruning happens only after a successful promotion and only touches generated
`.app-archived` directories. Zero explicitly opts out of retaining new backups.
Use a large value, such as 999, to preserve the rollout's rollback copies.
`CLAUDE_CODEX_BRIDGE_SHUTDOWN_WAIT` accepts 1–120 seconds (default 30).

## Recovery

Do not delete `menubar.lock` to get around a running instance. The lock belongs
to an inode: deleting a held file could allow two instances. The Hub refuses
unsafe lock paths (including links, directories and files owned by someone
else) instead of starting an unprotected second instance. An unresponsive or
older running version must be closed explicitly before reopening.

Installed rollback copies are now stored under
`~/Library/Application Support/ClaudeCodexBridge/previous-installs/archives.noindex/`.
Build rollback copies are under `dist/previous-builds.noindex/`. To restore one,
first quit the Hub, preserve the current bundle separately, and copy the chosen
archive back to the original `ClaudeCodexBridge.app` path. Restore the whole
bundle, not individual binaries; its existing signature covers its resources.
The archive suffix is for storage only—the restored bundle must again end in
`.app`. No provider login or credential-file changes are required.

## Tests

`scripts/tests/packaging-fixtures.sh` exercises failure, rollback, timeout,
alias rejection, repeated installs, and kernel serialization entirely under
temporary directories. Compiler, signing, process detection, app-quit and
LaunchServices calls are stubs. The normal test suite includes this fixture;
it does not quit or launch the live app.
