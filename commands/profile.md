---
description: Show or change which Claude account this directory uses
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/cprof:*)
---

Arguments: `$ARGUMENTS`

Run the matching command and report its output verbatim. Do not offer to switch
the current session's account — credentials are fixed at process start, so a
switch requires relaunching `claude`.

- No arguments: run `${CLAUDE_PLUGIN_ROOT}/scripts/cprof status`, then
  `${CLAUDE_PLUGIN_ROOT}/scripts/cprof which`, then
  `${CLAUDE_PLUGIN_ROOT}/scripts/cprof list`. If `status` and `which`
  name different profiles, say so: this session is signed in as the former while
  the directory expects the latter, and only a relaunch closes the gap.
- `pin <name>`: run `${CLAUDE_PLUGIN_ROOT}/scripts/cprof pin <name>`, then
  state that a relaunch is required for it to take effect.
- `rule <path> <name>`: run
  `${CLAUDE_PLUGIN_ROOT}/scripts/cprof rule add <path> <name>`.
- `rules`: run `${CLAUDE_PLUGIN_ROOT}/scripts/cprof rules`. Rules are
  listed longest-path-first, which is the order resolution consults them; a rule
  marked `(unknown profile)` never matches anything.
- `doctor`: run `${CLAUDE_PLUGIN_ROOT}/scripts/cprof doctor`.
- Anything else: run `${CLAUDE_PLUGIN_ROOT}/scripts/cprof help`.
