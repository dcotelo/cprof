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

# cp_color_auto <name> -> a palette colour derived from the name.
#
# cksum is POSIX and gives the same number on every machine, so a profile keeps
# its colour across runs, shells, and checkouts without storing anything.
cp_color_auto() {
  local sum idx
  sum="$(printf '%s' "${1:-}" | cksum | cut -d' ' -f1)"
  # shellcheck disable=SC2086
  set -- $CP_COLOR_PALETTE
  idx=$(( sum % $# ))
  while [ "$idx" -gt 0 ]; do
    shift
    idx=$(( idx - 1 ))
  done
  printf '%s\n' "$1"
}

# cp_color_for <cfg> <name> -> the colour for a profile.
#
# An explicit field wins. The literal "auto" means the same as no field at all,
# so `cprof color <name> auto` reads naturally even though it stores nothing.
# An explicit value nobody recognises yields no colour rather than a guess.
cp_color_for() {
  local explicit
  explicit="$(printf '%s' "${1:-}" | jq -r --arg n "${2:-}" \
    'first(.profiles[]? | select(.name == $n) | .color // empty) // empty' 2>/dev/null)"
  if [ -n "$explicit" ] && [ "$explicit" != 'auto' ]; then
    [ -n "$(cp_color_code "$explicit")" ] && printf '%s\n' "$explicit"
    return 0
  fi
  cp_color_auto "${2:-}"
}

# cp_cmd_color — set a profile's colour, toggle text colouring, or answer the
# statusline segment.
cp_cmd_color() {
  local cfg name colour sgr flag

  case "${1:-}" in
    '')
      cp_warn 'color: missing profile name'
      return 2
      ;;
    --text)
      cfg="$(cp_config_read)" || return 1
      case "${2:-}" in
        on)  printf '%s' "$cfg" | jq '.colorText = true'  | cp_config_write ;;
        off) printf '%s' "$cfg" | jq '.colorText = false' | cp_config_write ;;
        *)   cp_warn 'color --text: expected on or off'; return 2 ;;
      esac
      return $?
      ;;
    --render)
      # One call, two tab-separated fields, so the statusline spawns one process
      # rather than three. Never fails: an unreadable config prints a blank
      # colour and the segment falls back to its dim style.
      #
      # jq exits 0 even when given no input at all (an unreadable config
      # leaves cfg empty): with zero JSON values on stdin the filter runs
      # zero times and jq prints nothing, so `|| fallback` never fires. Guard
      # on the resulting value instead of the exit status for both fields.
      cfg="$(cp_config_read 2>/dev/null)" || cfg=''
      name="${2:-}"
      sgr="$(cp_color_code "$(cp_color_for "$cfg" "$name")" 2>/dev/null)"
      flag="$(printf '%s' "$cfg" | jq -r 'if .colorText then "on" else "off" end' 2>/dev/null)"
      [ -n "$flag" ] || flag='off'
      printf '%s\t%s\n' "$sgr" "$flag"
      return 0
      ;;
  esac

  name="$1"
  colour="${2:-}"
  cfg="$(cp_config_read)" || return 1
  cp_profile_exists "$cfg" "$name" || { cp_warn "unknown profile $name"; return 1; }

  if [ -z "$colour" ]; then
    cp_color_pick "$cfg" "$name"
    return $?
  fi

  if [ "$colour" = 'auto' ]; then
    printf '%s' "$cfg" | jq --arg n "$name" \
      '.profiles |= map(if .name == $n then del(.color) else . end)' | cp_config_write
    return $?
  fi

  if [ -z "$(cp_color_code "$colour")" ]; then
    cp_warn "color: unknown colour $colour (try: $CP_COLOR_PALETTE, or a bright- variant)"
    return 2
  fi
  printf '%s' "$cfg" | jq --arg n "$name" --arg c "$colour" \
    '.profiles |= map(if .name == $n then .color = $c else . end)' | cp_config_write
}

# Replaced in full by the picker. Kept separate so Task 5 is committable on its
# own and the command surface can be tested before the terminal handling exists.
cp_color_pick() {
  cp_warn 'color: picker not implemented'
  return 2
}
