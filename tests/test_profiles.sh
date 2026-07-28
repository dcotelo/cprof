#!/usr/bin/env bash
set -u
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
CLI="$(cd "$(dirname "$0")/.." && pwd -P)/scripts/claudeprofile"
cfg_get() { jq -r "$1" "$CLAUDEPROFILE_CONFIG"; }

# add creates the directory and becomes default when first
assert_ok "$CLI" add personal --dir "$CP_T_TMP/p" --note 'Max'
assert_eq 'personal' "$(cfg_get '.default')" 'first profile becomes default'
assert_eq 'true' "$([ -d "$CP_T_TMP/p" ] && echo true)" 'add creates the directory'
assert_eq '700'  "$(stat -f '%Lp' "$CP_T_TMP/p")" 'profile dir is mode 700'

# duplicate names rejected
assert_fail "$CLI" add personal --dir "$CP_T_TMP/p2"

# native profile
assert_ok "$CLI" add work --native --note 'Crowder team'
assert_eq 'true' "$(cfg_get '.profiles[] | select(.name=="work") | .native')" 'native flag stored'
assert_eq 'null' "$(cfg_get '.profiles[] | select(.name=="work") | .dir // "null"')" 'native has no dir'

# only one native
assert_fail "$CLI" add second --native

# ~/.claude is refused outright
assert_fail "$CLI" add danger --dir "$HOME/.claude"

# default
assert_ok   "$CLI" default work
assert_eq   'work' "$(cfg_get '.default')" 'default updated'
assert_fail "$CLI" default ghost

# rules
assert_ok "$CLI" rule add "$CP_T_TMP/dev/crowder" work
assert_eq "$CP_T_TMP/dev/crowder" "$(cfg_get '.rules[0].path')" 'rule path stored normalised'
assert_fail "$CLI" rule add "$CP_T_TMP/dev/x" ghost
assert_ok "$CLI" rule add "$CP_T_TMP/dev/crowder" personal
assert_eq '1' "$(cfg_get '[.rules[] | select(.path=="'"$CP_T_TMP"'/dev/crowder")] | length')" \
  'repeat rule for same path replaces rather than duplicates'
assert_ok "$CLI" rule rm "$CP_T_TMP/dev/crowder"
assert_eq '0' "$(cfg_get '.rules | length')" 'rule rm removes it'

# pin uses the repo root when inside a git repo
mkdir -p "$CP_T_TMP/repo/sub"
( cd "$CP_T_TMP/repo" && git init -q )
( cd "$CP_T_TMP/repo/sub" && "$CLI" pin personal >/dev/null 2>&1 )
assert_eq 'personal' "$(cfg_get '.repos["'"$CP_T_TMP"'/repo"]')" 'pin keys on git top level, not cwd'
( cd "$CP_T_TMP/repo/sub" && "$CLI" pin --clear >/dev/null 2>&1 )
assert_eq 'null' "$(cfg_get '.repos["'"$CP_T_TMP"'/repo"] // "null"')" 'pin --clear removes the pin'

# pin with no argument uses the resolved profile
( cd "$CP_T_TMP/repo" && "$CLI" pin >/dev/null 2>&1 )
assert_eq 'work' "$(cfg_get '.repos["'"$CP_T_TMP"'/repo"]')" 'bare pin stores the resolved profile'

# remove
assert_ok   "$CLI" remove personal
assert_fail "$CLI" remove personal
assert_eq 'true' "$([ -d "$CP_T_TMP/p" ] && echo true)" 'remove leaves the directory in place'

# purge needs confirmation and honours it
assert_ok "$CLI" add tmpp --dir "$CP_T_TMP/tp"
printf 'n\n' | "$CLI" remove tmpp --purge >/dev/null 2>&1
assert_eq 'true' "$([ -d "$CP_T_TMP/tp" ] && echo true)" 'declined purge keeps the directory'
printf 'y\n' | "$CLI" remove tmpp --purge >/dev/null 2>&1
assert_eq '' "$([ -d "$CP_T_TMP/tp" ] && echo true)" 'confirmed purge deletes the directory'

cp_t_summary
