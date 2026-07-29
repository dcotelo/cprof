---
description: Show or change which Claude account this directory uses
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/claudeprofile:*)
---

Arguments: `$ARGUMENTS`

Run the matching command and report its output verbatim. Do not offer to switch
the current session's account — credentials are fixed at process start, so a
switch requires relaunching `claude`.

- No arguments: run `${CLAUDE_PLUGIN_ROOT}/scripts/claudeprofile status`, then
  `${CLAUDE_PLUGIN_ROOT}/scripts/claudeprofile which`, then
  `${CLAUDE_PLUGIN_ROOT}/scripts/claudeprofile list`. If `status` and `which`
  name different profiles, say so: this session is signed in as the former while
  the directory expects the latter, and only a relaunch closes the gap.
- `pin <name>`: run `${CLAUDE_PLUGIN_ROOT}/scripts/claudeprofile pin <name>`, then
  state that a relaunch is required for it to take effect.
- `rule <path> <name>`: run
  `${CLAUDE_PLUGIN_ROOT}/scripts/claudeprofile rule add <path> <name>`.
- `doctor`: run `${CLAUDE_PLUGIN_ROOT}/scripts/claudeprofile doctor`.
- Anything else: run `${CLAUDE_PLUGIN_ROOT}/scripts/claudeprofile help`.
