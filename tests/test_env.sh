#!/usr/bin/env bash
set -u
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
CLI="$(cd "$(dirname "$0")/.." && pwd -P)/scripts/cprof"

mkdir -p "$CP_T_TMP/p" "$CP_T_TMP/dev/crowder" "$CP_T_TMP/gone-parent"
cp_t_write_config <<JSON
{"default":"personal",
 "profiles":[{"name":"personal","dir":"$CP_T_TMP/p"},
             {"name":"work","native":true},
             {"name":"broken","dir":"$CP_T_TMP/gone-parent/missing"}],
 "rules":[{"path":"$CP_T_TMP/dev/crowder","profile":"work"}],
 "repos":{}}
JSON

# directory-backed profile exports
out="$(cd "$CP_T_TMP" && "$CLI" env 2>/dev/null)"
assert_eq "export CLAUDE_CONFIG_DIR='$CP_T_TMP/p'" "$out" 'default profile exports its dir'

# native profile unsets
out="$(cd "$CP_T_TMP/dev/crowder" && "$CLI" env 2>/dev/null)"
assert_eq 'unset CLAUDE_CONFIG_DIR' "$out" 'native profile unsets'

# missing directory degrades to unset
out="$(cd "$CP_T_TMP" && CLAUDE_PROFILE=broken "$CLI" env 2>/dev/null)"
assert_eq 'unset CLAUDE_CONFIG_DIR' "$out" 'missing profile dir unsets'

# malformed config degrades to unset, still exit 0
printf 'not json' > "$CPROF_CONFIG"
out="$(cd "$CP_T_TMP" && "$CLI" env 2>/dev/null)"
assert_eq 'unset CLAUDE_CONFIG_DIR' "$out" 'malformed config unsets'
( cd "$CP_T_TMP" && "$CLI" env >/dev/null 2>&1 )
assert_eq '0' "$?" 'env exits 0 on malformed config'

# never silent
assert_eq '1' "$(cd "$CP_T_TMP" && "$CLI" env 2>/dev/null | grep -c 'CLAUDE_CONFIG_DIR')" \
  'env always prints exactly one CLAUDE_CONFIG_DIR line'

# quoting
mkdir -p "$CP_T_TMP/we'ird"
cp_t_write_config <<JSON
{"default":"q","profiles":[{"name":"q","dir":"$CP_T_TMP/we'ird"}],"rules":[],"repos":{}}
JSON
out="$(cd "$CP_T_TMP" && "$CLI" env 2>/dev/null)"
eval "$out"
assert_eq "$CP_T_TMP/we'ird" "$CLAUDE_CONFIG_DIR" 'single quote in dir survives eval'
unset CLAUDE_CONFIG_DIR

# which reports the reason
cp_t_write_config <<JSON
{"default":"personal","profiles":[{"name":"personal","dir":"$CP_T_TMP/p"},{"name":"work","native":true}],
 "rules":[{"path":"$CP_T_TMP/dev/crowder","profile":"work"}],"repos":{}}
JSON
out="$(cd "$CP_T_TMP/dev/crowder" && "$CLI" which 2>&1)"
case "$out" in
  *work*rule*) assert_eq 'ok' 'ok' 'which names profile and rule' ;;
  *)           assert_eq 'work + rule' "$out" 'which names profile and rule' ;;
esac

# Read the expected version rather than hardcoding it: a literal here went stale
# at the 0.2.0 bump and reported the old version as correct.
manifest_version="$(jq -r .version "$(dirname "$0")/../.claude-plugin/plugin.json")"
assert_eq "cprof $manifest_version" "$("$CLI" version)" 'version matches the manifest'

cp_t_summary
