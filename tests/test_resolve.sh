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
. "$(dirname "$0")/../scripts/lib/resolve.sh"

# --- lexical normalisation -------------------------------------------------
assert_eq '/a/b'   "$(cp_path_lexical '/a/b/')"      'strips trailing slash'
assert_eq '/a/b'   "$(cp_path_lexical '/a//b')"      'collapses double slash'
assert_eq '/a/b'   "$(cp_path_lexical '/a/./b')"     'drops dot segment'
assert_eq '/a'     "$(cp_path_lexical '/a/b/..')"    'resolves parent segment'
assert_eq '/'      "$(cp_path_lexical '/')"          'root stays root'

# --- containment, including the boundary case ------------------------------
assert_ok   cp_path_under /dev/work /dev/work
assert_ok   cp_path_under /dev/work /dev/work/a/b
assert_fail cp_path_under /dev/work /dev/workshop
assert_fail cp_path_under /dev/work /dev
assert_ok   cp_path_under / /anything

# --- resolution ladder ----------------------------------------------------
mkdir -p "$CP_T_TMP/dev/crowder/api" "$CP_T_TMP/dev/crowder/api/deep" \
         "$CP_T_TMP/dev/personal" "$CP_T_TMP/dev/workshop" "$CP_T_TMP/elsewhere"

cfg="$(cat <<JSON
{"default":"personal",
 "profiles":[{"name":"personal","dir":"$CP_T_TMP/p"},
             {"name":"work","native":true},
             {"name":"client","dir":"$CP_T_TMP/c"}],
 "rules":[{"path":"$CP_T_TMP/dev/crowder","profile":"work"},
          {"path":"$CP_T_TMP/dev/crowder/api","profile":"client"}],
 "repos":{"$CP_T_TMP/elsewhere":"client"}}
JSON
)"

resolve_in() { ( cd "$1" && printf '%s' "$cfg" | cp_resolve ); }
name_in()    { resolve_in "$1" | cut -f1; }
reason_in()  { resolve_in "$1" | cut -f2; }

assert_eq 'personal' "$(name_in "$CP_T_TMP/dev/personal")"      'falls back to default'
assert_eq 'default'  "$(reason_in "$CP_T_TMP/dev/personal")"    'reason is default'
assert_eq 'work'     "$(name_in "$CP_T_TMP/dev/crowder")"       'directory rule matches'
assert_eq 'client'   "$(name_in "$CP_T_TMP/dev/crowder/api")"   'longest prefix wins'
assert_eq 'client'   "$(name_in "$CP_T_TMP/dev/crowder/api/deep")" 'longest prefix wins deeper'
assert_eq 'personal' "$(name_in "$CP_T_TMP/dev/workshop")"      'workshop does not match crowder-style prefix'
assert_eq 'client'   "$(name_in "$CP_T_TMP/elsewhere")"         'repo pin beats default'

# unknown names are skipped, never fatal
bad="$(printf '%s' "$cfg" | jq '.rules += [{"path":"'"$CP_T_TMP"'/dev/personal","profile":"ghost"}]')"
assert_eq 'personal' "$(cd "$CP_T_TMP/dev/personal" && printf '%s' "$bad" | cp_resolve 2>/dev/null | cut -f1)" \
  'rule naming unknown profile is skipped'

empty="$(cp_config_default)"
assert_eq ''     "$(cd "$CP_T_TMP" && printf '%s' "$empty" | cp_resolve | cut -f1)" 'empty config: no name'
assert_eq 'none' "$(cd "$CP_T_TMP" && printf '%s' "$empty" | cp_resolve | cut -f2)" 'empty config: reason none'

cp_t_summary
