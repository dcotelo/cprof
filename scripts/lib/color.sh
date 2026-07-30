#!/usr/bin/env bash
# shellcheck shell=bash
# Colour for profile names: the palette, and when to emit it.

# The auto palette. Black and white are excluded deliberately: each disappears
# against one terminal theme or the other, and an indicator you cannot see is
# worse than no indicator.
# shellcheck disable=SC2034
CP_COLOR_PALETTE='red green yellow blue magenta cyan'

# cp_color_code <name> -> SGR parameter, or nothing when the name is unknown.
# Named ANSI only: these respect the terminal's own theme, work everywhere, and
# read plainly in the config file.
cp_color_code() {
  case "${1:-}" in
    red)            printf '31\n' ;;
    green)          printf '32\n' ;;
    yellow)         printf '33\n' ;;
    blue)           printf '34\n' ;;
    magenta)        printf '35\n' ;;
    cyan)           printf '36\n' ;;
    bright-red)     printf '91\n' ;;
    bright-green)   printf '92\n' ;;
    bright-yellow)  printf '93\n' ;;
    bright-blue)    printf '94\n' ;;
    bright-magenta) printf '95\n' ;;
    bright-cyan)    printf '96\n' ;;
    *)              return 0 ;;
  esac
}

# Whether colour should be emitted at all. NO_COLOR set to any value, empty
# included, disables it — that is the published contract, not an oversight.
cp_color_enabled() {
  [ -z "${NO_COLOR+set}" ] || return 1
  case "${CPROF_COLOR:-auto}" in
    never)  return 1 ;;
    always) return 0 ;;
  esac
  [ -t 1 ]
}

# cp_colorize <colour> <text>
#
# Reads CP_COLOR_ON rather than calling cp_color_enabled itself. Commands pipe
# their rows into cp_table, and inside a pipeline stdout is never a terminal, so
# the decision has to be made once by the caller and carried down.
cp_colorize() {
  local code
  code="$(cp_color_code "${1:-}")"
  if [ "${CP_COLOR_ON:-0}" != '1' ] || [ -z "$code" ]; then
    printf '%s\n' "${2:-}"
    return 0
  fi
  printf '\033[%sm%s\033[0m\n' "$code" "${2:-}"
}
