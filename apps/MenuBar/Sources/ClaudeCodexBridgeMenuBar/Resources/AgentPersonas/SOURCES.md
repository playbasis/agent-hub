# Agent persona portraits

From the Playbasis WorkspaceOps agent roster, downscaled to 160 px PNG with
`sips -s format png -Z 160`.

Bridge uses them as decorative personas for observed agent sessions. A persona
never claims a human did the work: the agent's own title, model and provider
stay primary, and portraits can be turned off in Settings.

File names are `[team-]role-first-last.png`; `AgentPersonaCatalog` in
BridgeCore derives role and display name from them.
