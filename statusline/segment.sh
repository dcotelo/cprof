#!/usr/bin/env bash
# One statusline line naming the Claude account this session is running as,
# with a context bar and a 5-hour usage bar when it is given the figures.
#
# `--full` prints the complete statusline instead: the account, the model, the
# directory and its branch, then the context and usage bars. It reads stdin
# for the same reason --stdin does.
#
# Reads stdin only when told to. Claude Code hands the statusline a JSON
# payload on stdin, and consuming it would starve whatever component runs
# next — so `--stdin` is the caller saying "this payload is yours": pass it
# when the segment is the only consumer, or after capturing the payload and
# piping a copy (see the README). Without the flag stdin stays untouched and
# the usage bar comes from this profile's cache, if any.
#
# The active profile comes from CLAUDE_CONFIG_DIR in the environment, which is
# also more truthful than resolution — it is the account actually in use.
#
# Never fails the statusline: any problem means printing nothing and exiting 0.
set -u

read_stdin=0
full=0
for arg in "$@"; do
  case "$arg" in
    --stdin) read_stdin=1 ;;
    --full)  full=1; read_stdin=1 ;;
    *) exit 0 ;;
  esac
done

root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
cli="$root/scripts/cprof"
[ -x "$cli" ] || exit 0

# --full hands the whole line off to the CLI, which renders every field cprof
# has in one process instead of the three this file would otherwise spawn.
# Failures stay invisible: a statusline that exits non-zero is a statusline
# Claude Code reports as broken.
if [ "$full" -eq 1 ]; then
  if [ ! -t 0 ]; then
    "$cli" statusline --stdin 2>/dev/null
  else
    "$cli" statusline 2>/dev/null
  fi
  exit 0
fi

# CPROF_COLOR=never: `status` runs with the caller's environment, and a caller
# who exports CPROF_COLOR=always (a value the CHANGELOG documents as
# supported) would otherwise get an escape-laden name back — which then both
# hashes to the wrong colour below and stops matching the ''|stock guard, so
# the stock profile would grow a badge instead of staying silent.
name="$(CPROF_COLOR=never "$cli" status 2>/dev/null </dev/null)" || exit 0
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
render="$("$cli" color --render "$name" 2>/dev/null </dev/null)"
code="${render%%	*}"
text="${render##*	}"

# Bars: seven tab-separated fields (see cp_usage_render_fields). With --stdin
# the payload flows straight through to the CLI, told to read the live
# figures out of it; otherwise the CLI is handed no input and answers from
# the cache. Empty fields mean nothing to show for that bar.
if [ "$read_stdin" -eq 1 ] && [ ! -t 0 ]; then
  fields="$("$cli" usage --render "$name" --stdin 2>/dev/null)"
else
  fields="$("$cli" usage --render "$name" 2>/dev/null </dev/null)"
fi
u_pct="$(printf '%s' "$fields" | cut -f1)"
u_bar="$(printf '%s' "$fields" | cut -f2)"
u_code="$(printf '%s' "$fields" | cut -f3)"
u_reset="$(printf '%s' "$fields" | cut -f4)"
c_pct="$(printf '%s' "$fields" | cut -f5)"
c_bar="$(printf '%s' "$fields" | cut -f6)"
c_code="$(printf '%s' "$fields" | cut -f7)"

esc=$'\033'
suffix=''

# The reader asked for no colour: plain text, no SGR sequences at all —
# NO_COLOR means no escapes, not "escapes that happen to be grey".
if [ -n "${NO_COLOR+set}" ]; then
  badge="⚑ $name"
  [ -z "$c_pct" ] || suffix="$suffix │ Context $c_bar $c_pct%"
  if [ -n "$u_pct" ]; then
    suffix="$suffix │ Usage $u_bar $u_pct%"
    [ -z "$u_reset" ] || suffix="$suffix (resets in $u_reset)"
  fi
  printf '%s%s\n' "$badge" "$suffix"
  exit 0
fi

# The badge: the profile's colour on flag and name, on the flag alone, or —
# no colour resolved — the original dim badge.
if [ -z "$code" ]; then
  badge="${esc}[2m⚑ ${name}${esc}[0m"
elif [ "$text" = 'on' ]; then
  badge="${esc}[${code}m⚑ ${name}${esc}[0m"
else
  badge="${esc}[${code}m⚑${esc}[0m ${esc}[2m${name}${esc}[0m"
fi

# Labels and separators dim; each bar in its own severity colour.
sep="${esc}[2m │${esc}[0m"
if [ -n "$c_pct" ]; then
  suffix="$suffix$sep ${esc}[2mContext${esc}[0m ${esc}[${c_code}m${c_bar} ${c_pct}%${esc}[0m"
fi
if [ -n "$u_pct" ]; then
  suffix="$suffix$sep ${esc}[2mUsage${esc}[0m ${esc}[${u_code}m${u_bar} ${u_pct}%${esc}[0m"
  [ -z "$u_reset" ] || suffix="$suffix ${esc}[2m(resets in ${u_reset})${esc}[0m"
fi
printf '%s%s\n' "$badge" "$suffix"
exit 0
