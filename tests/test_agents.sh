#!/usr/bin/env bash
set -u
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
for lib in config resolve profiles auth output color usage statusline fallback share agents; do
  # shellcheck source=/dev/null
  . "$(dirname "$0")/../scripts/lib/$lib.sh"
done
# shellcheck disable=SC2034  # render tests added later use it
ESC="$(printf '\033')"

# --- model short form ------------------------------------------------------
assert_eq 'haiku-4.5' "$(cp_agents_model_short claude-haiku-4-5-20251001)" 'dated id: date dropped, version dotted'
assert_eq 'opus-5.5'  "$(cp_agents_model_short claude-opus-5-5)"  'undated id'
assert_eq 'fable-5.1' "$(cp_agents_model_short claude-fable-5-1)" 'fable'
assert_eq 'sonnet-5'  "$(cp_agents_model_short claude-sonnet-5)"  'single version part'
assert_eq 'haiku'     "$(cp_agents_model_short haiku)"            'an alias renders as-is'
assert_eq 'claude-3-5-sonnet-20241022' "$(cp_agents_model_short claude-3-5-sonnet-20241022)" \
  'version before family does not fit the shape: as-is'
assert_eq '' "$(cp_agents_model_short '')" 'empty in, empty out'
# --- duration ---------------------------------------------------------------
assert_eq '0s'     "$(cp_agents_duration 0)"    'zero'
assert_eq '59s'    "$(cp_agents_duration 59)"   'under a minute'
assert_eq '1m 0s'  "$(cp_agents_duration 60)"   'exactly a minute'
assert_eq '1m 12s' "$(cp_agents_duration 72)"   'minutes and seconds'
assert_eq '1h 0m'  "$(cp_agents_duration 3600)" 'exactly an hour drops seconds'
assert_eq '1h 4m'  "$(cp_agents_duration 3840)" 'hours and minutes'
assert_eq '25h 0m' "$(cp_agents_duration 90000)" 'no day unit'
assert_fail cp_agents_duration abc
# --- clock seam -------------------------------------------------------------
assert_eq '1700000000' "$(CP_AGENTS_NOW=1700000000 cp_agents_now)" 'the seam wins'
assert_eq "$(date +%s)" "$(CP_AGENTS_NOW=junk cp_agents_now)" 'a non-numeric seam is ignored'
cp_t_summary
