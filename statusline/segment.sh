#!/usr/bin/env bash
# One statusline line naming the Claude account this session is running as.
#
# Deliberately does not read stdin: Claude Code hands the statusline a JSON
# payload on stdin, and consuming it would starve whatever component runs next.
# The active profile comes from CLAUDE_CONFIG_DIR in the environment, which is
# also more truthful than resolution — it is the account actually in use.
#
# Never fails the statusline: any problem means printing nothing and exiting 0.
set -u

root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
cli="$root/scripts/cprof"
[ -x "$cli" ] || exit 0

name="$("$cli" status 2>/dev/null)" || exit 0
case "$name" in
  ''|stock) exit 0 ;;
esac

printf '\033[2m⚑ %s\033[0m\n' "$name"
exit 0
