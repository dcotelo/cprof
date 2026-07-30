#!/usr/bin/env bash
set -u
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
# shellcheck source=/dev/null
. "$(dirname "$0")/../scripts/lib/config.sh"
# shellcheck source=/dev/null
. "$(dirname "$0")/../scripts/lib/color.sh"

# Guard against an ambient NO_COLOR/CPROF_COLOR in the developer's shell or CI;
# assertions below that don't set these inline depend on them being absent.
unset NO_COLOR
unset CPROF_COLOR

# --- names map to SGR parameters --------------------------------------------
assert_eq '31' "$(cp_color_code red)"            'red is 31'
assert_eq '36' "$(cp_color_code cyan)"           'cyan is 36'
assert_eq '91' "$(cp_color_code bright-red)"     'bright-red is 91'
assert_eq ''   "$(cp_color_code chartreuse)"     'an unknown name has no code'
assert_eq ''   "$(cp_color_code '')"             'the empty name has no code'

# --- enabling ----------------------------------------------------------------
# NO_COLOR wins over everything, including an explicit always.
NO_COLOR='' CPROF_COLOR=always cp_color_enabled
assert_eq '1' "$?" 'empty-but-set NO_COLOR still disables'
NO_COLOR=1 CPROF_COLOR=always cp_color_enabled
assert_eq '1' "$?" 'NO_COLOR beats CPROF_COLOR=always'
CPROF_COLOR=always cp_color_enabled
assert_eq '0' "$?" 'CPROF_COLOR=always enables'
CPROF_COLOR=never cp_color_enabled
assert_eq '1' "$?" 'CPROF_COLOR=never disables'
# The suite runs with stdout on a pipe, so auto resolves to off here.
CPROF_COLOR=auto cp_color_enabled
assert_eq '1' "$?" 'auto is off when stdout is not a terminal'

# --- wrapping ----------------------------------------------------------------
assert_eq 'work' "$(CP_COLOR_ON=0 cp_colorize red work)"  'no wrap when colour is off'
assert_eq 'work' "$(CP_COLOR_ON=1 cp_colorize '' work)"   'no wrap without a colour'
assert_eq 'work' "$(CP_COLOR_ON=1 cp_colorize bogus work)" 'no wrap for an unknown colour'
assert_eq "$(printf '\033[31mwork\033[0m')" \
          "$(CP_COLOR_ON=1 cp_colorize red work)"         'wraps when on'

# --- auto assignment ---------------------------------------------------------
first="$(cp_color_auto work)"
assert_eq "$first" "$(cp_color_auto work)"        'auto is stable across calls'
case " $CP_COLOR_PALETTE " in
  *" $first "*) assert_eq ok ok 'auto returns a palette colour' ;;
  *) assert_eq 'a palette colour' "$first" 'auto returns a palette colour' ;;
esac
# Different names should generally differ; this pair is checked explicitly so a
# hash change that collapses everything to one colour fails loudly.
assert_eq 'false' \
  "$([ "$(cp_color_auto work)" = "$(cp_color_auto personal)" ] && echo true || echo false)" \
  'work and personal hash to different colours'

# --- explicit overrides ------------------------------------------------------
cfg='{"profiles":[{"name":"work","color":"red"},{"name":"personal"},
      {"name":"broken","color":"chartreuse"},{"name":"reset","color":"auto"}]}'
assert_eq 'red' "$(cp_color_for "$cfg" work)"     'an explicit colour wins'
assert_eq "$(cp_color_auto personal)" "$(cp_color_for "$cfg" personal)" \
  'no colour field falls back to auto'
assert_eq "$(cp_color_auto reset)" "$(cp_color_for "$cfg" reset)" \
  'the literal auto falls back to auto'
assert_eq '' "$(cp_color_for "$cfg" broken)" \
  'an unrecognised explicit colour yields no colour'
assert_eq "$(cp_color_auto ghost)" "$(cp_color_for "$cfg" ghost)" \
  'an unknown profile still gets a colour'

cp_t_summary
