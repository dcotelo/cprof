#!/usr/bin/env bash
# shellcheck shell=bash
# The `agents` statusline segment: a session's subagents, one line each. This
# file owns reading a session's subagent records and shortening what it finds
# for a narrow terminal. It never opens the parent transcript, which can run
# to megabytes and is re-read by Claude Code itself every few seconds.

# cp_agents_now: prints the current epoch seconds. $CP_AGENTS_NOW stands in for
# the clock when it is all digits, so tests can pin "now"; anything else is
# ignored rather than trusted.
cp_agents_now() {
  case "${CP_AGENTS_NOW:-}" in
    '' | *[!0-9]*) date +%s ;;
    *) printf '%s\n' "$CP_AGENTS_NOW" ;;
  esac
}

# cp_agents_model_short: a model id -> its short form, e.g.
# claude-haiku-4-5-20251001 -> haiku-4.5. Drops the claude- prefix and a
# trailing 8-digit date, takes the leading non-numeric parts as the family and
# joins the all-digit parts after it with dots. An id that does not fit that
# shape (an alias like "haiku", or a version before the family) prints as given.
cp_agents_model_short() {
  local id="${1:-}" rest family="" ver="" part last
  rest="${id#claude-}"
  [ -n "$rest" ] || { printf '%s\n' "$id"; return 0; }
  last="${rest##*-}"
  case "$last" in
    *[!0-9]*) ;;
    ????????) [ "$last" != "$rest" ] && rest="${rest%-*}" ;;
  esac
  local IFS=-
  # shellcheck disable=SC2086  # splitting on - is the point
  set -- $rest
  for part in "$@"; do
    case "$part" in
      '' | *[!0-9]*)
        # A word: part of the family only while no version digit has been seen.
        [ -z "$ver" ] || { printf '%s\n' "$id"; return 0; }
        family="${family:+$family-}$part"
        ;;
      *) ver="${ver:+$ver.}$part" ;;
    esac
  done
  # Without a family or without a version there is nothing to reshape.
  if [ -z "$family" ] || [ -z "$ver" ]; then
    printf '%s\n' "$id"
    return 0
  fi
  printf '%s-%s\n' "$family" "$ver"
}

# cp_agents_duration: whole seconds -> "Ns", "Mm Ss" or "Hh Mm" (seconds are
# noise once an hour is on the clock, and there is no day unit). Anything that
# is not all digits prints nothing and returns 1.
cp_agents_duration() {
  local s="${1:-}"
  case "$s" in
    '' | *[!0-9]*) return 1 ;;
  esac
  if [ "$s" -lt 60 ]; then
    printf '%ss\n' "$s"
  elif [ "$s" -lt 3600 ]; then
    printf '%sm %ss\n' $((s / 60)) $((s % 60))
  else
    printf '%sh %sm\n' $((s / 3600)) $((s % 3600 / 60))
  fi
}
