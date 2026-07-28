#!/usr/bin/env bash
# SessionStart: warn when the live session's account no longer matches what this
# directory resolves to. Never fails a session.
set -u

root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
cli="$root/scripts/claudeprofile"
[ -x "$cli" ] || exit 0

want="$("$cli" env 2>/dev/null)"
have="${CLAUDE_CONFIG_DIR:+export CLAUDE_CONFIG_DIR=$(printf "'%s'" "$CLAUDE_CONFIG_DIR")}"
[ -n "$have" ] || have='unset CLAUDE_CONFIG_DIR'

if [ "$want" = "$have" ]; then
  exit 0
fi

detail="$("$cli" which 2>/dev/null | head -1)"
printf 'claudeprofile: this session does not match this directory. Expected: %s. Relaunch claude here to switch.\n' \
  "${detail:-unknown}"
exit 0
