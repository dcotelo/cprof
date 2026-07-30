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

# cp_color_menu_step <index> <key> <count> -> the new 0-based index.
#
# Pure arithmetic, deliberately separate from the key loop: the loop needs a real
# terminal and cannot be covered by the suite, so everything that can be tested
# without one lives here.
cp_color_menu_step() {
  local i="${1:-0}" key="${2:-}" n="${3:-1}"
  [ "$n" -gt 0 ] || n=1
  case "$key" in
    up)   i=$(( (i - 1 + n) % n )) ;;
    down) i=$(( (i + 1) % n )) ;;
  esac
  printf '%s\n' "$i"
}

# cp_color_pick <cfg> <name> — choose a colour interactively.
#
# Requires a terminal on both stdin and stdout. There is no silent fallback: a
# picker that quietly does nothing is worse than one that says why.
cp_color_pick() {
  local cfg="$1" name="$2" saved entries count idx=0 key chosen

  if [ ! -t 0 ] || [ ! -t 1 ]; then
    cp_warn "color: no terminal for the picker; pass a colour, e.g. cprof color $name red"
    return 2
  fi

  entries="auto $CP_COLOR_PALETTE"
  for c in $CP_COLOR_PALETTE; do entries="$entries bright-$c"; done
  # shellcheck disable=SC2086
  set -- $entries
  count=$#

  saved="$(stty -g)" || { cp_warn 'color: cannot read terminal state'; return 1; }
  # One trap for every way out: normal return, Ctrl-C, and being killed. Leaving
  # a terminal in raw mode with the cursor hidden is a worse bug than anything
  # this command could get wrong.
  trap 'stty "$saved" 2>/dev/null; printf "\033[?25h"; trap - EXIT INT TERM' EXIT INT TERM
  stty -echo -icanon min 1 time 0
  printf '\033[?25l'

  while :; do
    # shellcheck disable=SC2086 # entries is a space-joined list; splitting it into args is the point
    cp_color_menu_draw "$name" "$idx" $entries
    key="$(cp_color_read_key)"
    case "$key" in
      up|down) idx="$(cp_color_menu_step "$idx" "$key" "$count")" ;;
      select)  break ;;
      cancel)  cp_color_menu_erase "$count"; stty "$saved"; printf '\033[?25h'
               trap - EXIT INT TERM; return 0 ;;
    esac
    cp_color_menu_erase "$count"
  done

  cp_color_menu_erase "$count"
  stty "$saved"
  printf '\033[?25h'
  trap - EXIT INT TERM

  # shellcheck disable=SC2086
  set -- $entries
  while [ "$idx" -gt 0 ]; do shift; idx=$(( idx - 1 )); done
  chosen="$1"

  if [ "$chosen" = 'auto' ]; then
    printf '%s' "$cfg" | jq --arg n "$name" \
      '.profiles |= map(if .name == $n then del(.color) else . end)' | cp_config_write || return 1
    printf '%s -> auto\n' "$name"
    return 0
  fi
  printf '%s' "$cfg" | jq --arg n "$name" --arg c "$chosen" \
    '.profiles |= map(if .name == $n then .color = $c else . end)' | cp_config_write || return 1
  printf '%s -> %s\n' "$name" "$chosen"
}

# Draws one row per entry, each showing the badge as it will actually look, so
# the choice is made on the result rather than on the name of a colour.
cp_color_menu_draw() {
  local name="$1" idx="$2" i=0 marker code label
  shift 2
  printf 'Colour for %s    up/down move, enter select, q cancel\n' "$name"
  for label in "$@"; do
    if [ "$i" = "$idx" ]; then marker='>'; else marker=' '; fi
    if [ "$label" = 'auto' ]; then
      code="$(cp_color_code "$(cp_color_auto "$name")")"
      printf '  %s \033[%sm# %s\033[0m   auto\n' "$marker" "${code:-0}" "$name"
    else
      code="$(cp_color_code "$label")"
      printf '  %s \033[%sm# %s\033[0m   %s\n' "$marker" "${code:-0}" "$name" "$label"
    fi
    i=$(( i + 1 ))
  done
}

# Moves back over the menu so the next draw overwrites it: header plus one line
# per entry.
cp_color_menu_erase() {
  local n=$(( $1 + 1 ))
  while [ "$n" -gt 0 ]; do
    printf '\033[1A\033[2K'
    n=$(( n - 1 ))
  done
}

# Reads one keypress and names it.
#
# bash 3.2 has no fractional read -t — that arrived in bash 4, and the target is
# the macOS system shell. So the escape-sequence continuation is bounded at the
# terminal layer with `stty min 0 time 1` (a tenth of a second) instead. Without
# it, a bare ESC keypress blocks until the user presses something else.
cp_color_read_key() {
  local c rest
  IFS= read -r -n 1 c || { printf 'cancel\n'; return 0; }
  case "$c" in
    '') printf 'select\n'; return 0 ;;
    q|Q) printf 'cancel\n'; return 0 ;;
    k) printf 'up\n'; return 0 ;;
    j) printf 'down\n'; return 0 ;;
  esac
  if [ "$c" = "$(printf '\033')" ]; then
    stty min 0 time 1
    IFS= read -r -n 2 rest
    stty min 1 time 0
    case "$rest" in
      '[A') printf 'up\n'; return 0 ;;
      '[B') printf 'down\n'; return 0 ;;
      '')   printf 'cancel\n'; return 0 ;;
    esac
  fi
  printf 'none\n'
}
