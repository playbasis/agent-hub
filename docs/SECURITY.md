# Security notes

## Protected assets

- Source code and uncommitted work in the selected project
- Claude and Codex credentials managed by their own CLIs
- Prompts, tool traces, decision logs, and the bridge bearer token

## Primary threats

- A local process forging events or control requests
- Prompt injection causing unsafe tool behavior
- A malformed meta-model decision causing uncontrolled execution
- Shell injection through prompts, paths, or hook payloads
- Infinite agent ping-pong consuming quota
- Secrets copied into logs or a remote meta-model request

## Controls

- Loopback binding plus bearer authentication; the server refuses to start if
  `server.host` names anything but `127.0.0.1`, `::1` or `localhost`
- `0600` configuration and local hook settings
- Argument-array subprocess execution; prompts use stdin
- Strict event/decision validation and bounded payload sizes
- Workspace-scoped default agent permissions
- Managed Claude safe mode and managed Codex user-config isolation
- Folder-silent startup with lazy, explicit project attachment on Resume
- Session deadline, subprocess timeout, dispatch lock, and event deduplication
- Local deterministic classifier by default
- Redaction of bearer tokens and common credential-shaped fields in logs
- Plan usage is obtained by invoking the signed-in provider CLIs; the bridge
  never reads `~/.codex/auth.json` or Claude OAuth files.
  Refresh is user-initiated and runs from app-owned Application Support
- Remote coordinator keys are accepted only by the authenticated loopback
  control plane or an explicit environment variable. Durable keys are stored
  in a separate mode-`0600` Application Support credential file, never in
  `config.json`, logs, decision records, proof artifacts, or agent prompts.
  This avoids recurring login-Keychain dialogs for ad-hoc development
  signatures; a Developer ID build should restore a stable Keychain adapter
- Every routing record includes coordinator identity and fallback state, so a
  rules fallback cannot be misrepresented as a Gemini-coordinated decision

## Residual risk

Workspace-scoped agents can still damage files inside the selected repository.
Use version control, review diffs, and begin with a disposable project. Local
malware running as the same macOS user can usually read user-owned configuration
and should be considered outside the protection offered by a loopback token.
A project intentionally located in Desktop, Documents, or Downloads can still
produce a legitimate macOS Files & Folders prompt when the user starts or
resumes work in that project.
