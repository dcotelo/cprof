#!/usr/bin/env bash
set -u
# The rename to cprof moved the config and state paths. Anyone already running
# the tool has the old ones, so they must keep working without a manual step.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
CLI="$(cd "$(dirname "$0")/.." && pwd -P)/scripts/cprof"

# cp_t_setup pins the config path; these tests are about path defaults, so they
# drive the real ones inside the sandboxed HOME instead.
unset CPROF_CONFIG
unset CLAUDEPROFILE_CONFIG
NEW="$HOME/.cprof.json"
OLD="$HOME/.claudeprofile.json"

mkdir -p "$HOME/.claude-profiles/personal"
config_json() {
  printf '{"default":"personal","profiles":[{"name":"personal","dir":"%s"}],"rules":[],"repos":{}}\n' \
    "$HOME/.claude-profiles/personal"
}

# --- an old config is adopted, not ignored -----------------------------------
config_json > "$OLD"
assert_eq 'personal' "$("$CLI" which 2>/dev/null | awk '{print $1}')" \
  'a claudeprofile.json config still resolves'

# adopting it means moving it: one file, at the new path, so later writes cannot
# land in a file the tool no longer reads
assert_ok test -f "$NEW"
if [ -e "$OLD" ]; then
  assert_eq 'moved' "still there: $OLD" 'the old path is left behind'
else
  assert_eq ok ok 'the old path is left behind'
fi
assert_eq 'personal' "$(jq -r .default "$NEW")" 'the migrated config keeps its contents'

# --- migration says so, once -------------------------------------------------
rm -f "$NEW"
config_json > "$OLD"
out="$("$CLI" which 2>&1 >/dev/null)"
case "$out" in *.cprof.json*) assert_eq ok ok 'migration names the new path' ;;
                *) assert_eq '.cprof.json' "$out" 'migration names the new path' ;; esac
assert_eq '' "$("$CLI" which 2>&1 >/dev/null)" 'a migrated config is quiet on the next run'

# --- the new path wins when both exist ---------------------------------------
printf '{"default":"fromnew","profiles":[{"name":"fromnew","dir":"%s"}],"rules":[],"repos":{}}\n' \
  "$HOME/.claude-profiles/personal" > "$NEW"
printf '{"default":"fromold","profiles":[{"name":"fromold","dir":"%s"}],"rules":[],"repos":{}}\n' \
  "$HOME/.claude-profiles/personal" > "$OLD"
assert_eq 'fromnew' "$("$CLI" which 2>/dev/null | awk '{print $1}')" 'the new path takes precedence'
assert_ok test -f "$OLD"   # nothing is touched when there is nothing to migrate

# --- env overrides: new name preferred, old name still honoured --------------
alt="$CP_T_TMP/alt.json"
config_json > "$alt"
assert_eq 'personal' "$(CPROF_CONFIG="$alt" "$CLI" which 2>/dev/null | awk '{print $1}')" \
  'CPROF_CONFIG selects the config'
assert_eq 'personal' "$(CLAUDEPROFILE_CONFIG="$alt" "$CLI" which 2>/dev/null | awk '{print $1}')" \
  'CLAUDEPROFILE_CONFIG still works'
assert_eq 'fromnew' "$(CPROF_CONFIG="$NEW" CLAUDEPROFILE_CONFIG="$alt" "$CLI" which 2>/dev/null | awk '{print $1}')" \
  'CPROF_CONFIG wins over the old variable'

# --- env override skips migration entirely -----------------------------------
rm -f "$NEW"
config_json > "$OLD"
assert_eq 'personal' "$(CPROF_CONFIG="$alt" "$CLI" which 2>/dev/null | awk '{print $1}')" \
  'an explicit config path is used as given'
if [ -e "$NEW" ]; then
  assert_eq 'no migration' 'migrated anyway' 'an explicit path suppresses migration'
else
  assert_eq ok ok 'an explicit path suppresses migration'
fi

cp_t_summary
