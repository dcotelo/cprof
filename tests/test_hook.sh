#!/usr/bin/env bash
set -u
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
HOOK="$ROOT/hooks/session-start.sh"
export CLAUDE_PLUGIN_ROOT="$ROOT"

mkdir -p "$CP_T_TMP/p" "$CP_T_TMP/dev/crowder"
cp_t_write_config <<JSON
{"default":"personal","profiles":[{"name":"personal","dir":"$CP_T_TMP/p"},{"name":"work","native":true}],
 "rules":[{"path":"$CP_T_TMP/dev/crowder","profile":"work"}],"repos":{}}
JSON

# match: session already on the expected profile -> silent
out="$(cd "$CP_T_TMP" && CLAUDE_CONFIG_DIR="$CP_T_TMP/p" bash "$HOOK" 2>&1)"
assert_eq '' "$out" 'no output when the session matches'

# mismatch: expected native, session is on a profile dir -> warn
out="$(cd "$CP_T_TMP/dev/crowder" && CLAUDE_CONFIG_DIR="$CP_T_TMP/p" bash "$HOOK" 2>&1)"
case "$out" in *work*) assert_eq ok ok 'mismatch names the expected profile' ;;
                *) assert_eq 'work' "$out" 'mismatch names the expected profile' ;; esac
case "$out" in *Relaunch*) assert_eq ok ok 'mismatch says to relaunch' ;;
                *) assert_eq 'Relaunch' "$out" 'mismatch says to relaunch' ;; esac

# hook must never fail a session
( cd "$CP_T_TMP/dev/crowder" && CLAUDE_CONFIG_DIR="$CP_T_TMP/p" bash "$HOOK" >/dev/null 2>&1 )
assert_eq '0' "$?" 'hook exits 0 on mismatch'
printf 'not json' > "$CLAUDEPROFILE_CONFIG"
( cd "$CP_T_TMP" && bash "$HOOK" >/dev/null 2>&1 )
assert_eq '0' "$?" 'hook exits 0 on malformed config'

cp_t_summary
