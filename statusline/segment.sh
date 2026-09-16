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

# CPROF_COLOR=never: `status` runs with the caller's environment, and a caller
# who exports CPROF_COLOR=always (a value the CHANGELOG documents as
# supported) would otherwise get an escape-laden name back — which then both
# hashes to the wrong colour below and stops matching the ''|stock guard, so
# the stock profile would grow a badge instead of staying silent.
name="$(CPROF_COLOR=never "$cli" status 2>/dev/null)" || exit 0
case "$name" in
  ''|stock) exit 0 ;;
esac

# One call, two tab-separated fields: this profile's SGR parameter, and whether
# the name text is coloured as well as the flag. One subprocess rather than
# three, on something that re-runs every few seconds.
#
# --render never calls cp_color_enabled itself: it returns the raw SGR
# parameter unconditionally and leaves the on/off decision to this segment (the
# NO_COLOR check just below), so no CPROF_COLOR override belongs on this call.
render="$("$cli" color --render "$name" 2>/dev/null)"
code="${render%%	*}"
text="${render##*	}"

# Usage badge: cache-only (never fetches — see cp_usage_read_cached_only),
# so this never adds latency. Empty fields mean no cache yet; the statusline
# looks exactly like it did before this feature in that case.
usage_render="$("$cli" usage --render "$name" 2>/dev/null)"
u_pct="$(printf '%s' "$usage_render" | cut -f1)"
u_bar="$(printf '%s' "$usage_render" | cut -f2)"
u_code="$(printf '%s' "$usage_render" | cut -f3)"

# The reader asked for no colour: plain text, no SGR sequences at all —
# NO_COLOR means no escapes, not "escapes that happen to be grey".
if [ -n "${NO_COLOR+set}" ]; then
  if [ -n "$u_pct" ]; then
    printf '⚑ %s %s %s%%\n' "$name" "$u_bar" "$u_pct"
  else
    printf '⚑ %s\n' "$name"
  fi
  exit 0
fi

# No colour resolved for this profile: the original dim badge, plus a plain
# usage suffix if a cache exists.
if [ -z "$code" ]; then
  if [ -n "$u_pct" ]; then
    printf '\033[2m⚑ %s\033[0m %s %s%%\n' "$name" "$u_bar" "$u_pct"
  else
    printf '\033[2m⚑ %s\033[0m\n' "$name"
  fi
  exit 0
fi

if [ "$text" = 'on' ]; then
  if [ -n "$u_pct" ]; then
    printf '\033[%sm⚑ %s\033[0m \033[%sm%s %s%%\033[0m\n' "$code" "$name" "$u_code" "$u_bar" "$u_pct"
  else
    printf '\033[%sm⚑ %s\033[0m\n' "$code" "$name"
  fi
else
  if [ -n "$u_pct" ]; then
    printf '\033[%sm⚑\033[0m \033[2m%s\033[0m \033[%sm%s %s%%\033[0m\n' "$code" "$name" "$u_code" "$u_bar" "$u_pct"
  else
    printf '\033[%sm⚑\033[0m \033[2m%s\033[0m\n' "$code" "$name"
  fi
fi
exit 0
