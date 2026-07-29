#!/usr/bin/env bash
set -u
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
CLI="$(cd "$(dirname "$0")/.." && pwd -P)/scripts/cprof"
SEG="$(cd "$(dirname "$0")/.." && pwd -P)/statusline/segment.sh"

mkdir -p "$CP_T_TMP/p" "$CP_T_TMP/c"
cp_t_write_config <<JSON
{"default":"work",
 "profiles":[{"name":"work","native":true,"note":"team"},
             {"name":"personal","dir":"$CP_T_TMP/p"},
             {"name":"client","dir":"$CP_T_TMP/c"}],
 "rules":[],"repos":{}}
JSON

# --- status names the profile the process is actually running as -------------
assert_eq 'personal' "$(CLAUDE_CONFIG_DIR="$CP_T_TMP/p" "$CLI" status 2>/dev/null)" \
  'status maps CLAUDE_CONFIG_DIR to its profile'
assert_eq 'client' "$(CLAUDE_CONFIG_DIR="$CP_T_TMP/c" "$CLI" status 2>/dev/null)" \
  'status distinguishes profiles by dir'

# unset env means the native profile is in play
assert_eq 'work' "$(env -u CLAUDE_CONFIG_DIR "$CLI" status 2>/dev/null)" \
  'unset CLAUDE_CONFIG_DIR reports the native profile'

# a dir belonging to no profile is reported as unknown, not silently blank
assert_eq 'unknown' "$(CLAUDE_CONFIG_DIR="$CP_T_TMP/nowhere" "$CLI" status 2>/dev/null)" \
  'unrecognised config dir reports unknown'

# with no native profile and no env, nothing is claimed
cp_t_write_config <<JSON
{"default":"personal","profiles":[{"name":"personal","dir":"$CP_T_TMP/p"}],"rules":[],"repos":{}}
JSON
assert_eq 'stock' "$(env -u CLAUDE_CONFIG_DIR "$CLI" status 2>/dev/null)" \
  'no native profile and no env reports stock'

# --- statusline segment ------------------------------------------------------
cp_t_write_config <<JSON
{"default":"work",
 "profiles":[{"name":"work","native":true},{"name":"personal","dir":"$CP_T_TMP/p"}],
 "rules":[],"repos":{}}
JSON

out="$(CLAUDE_CONFIG_DIR="$CP_T_TMP/p" bash "$SEG" </dev/null 2>/dev/null)"
case "$out" in *personal*) assert_eq ok ok 'segment names the active profile' ;;
                *) assert_eq 'personal' "$out" 'segment names the active profile' ;; esac

# Every profile is named, native included: an indicator that goes blank in the
# common case trains you to ignore it.
out="$(env -u CLAUDE_CONFIG_DIR bash "$SEG" </dev/null 2>/dev/null)"
case "$out" in *work*) assert_eq ok ok 'segment names the native profile too' ;;
                *) assert_eq 'work' "$out" 'segment names the native profile too' ;; esac

# exactly one line, so the statusline layout stays predictable
assert_eq '1' "$(CLAUDE_CONFIG_DIR="$CP_T_TMP/p" bash "$SEG" </dev/null 2>/dev/null | wc -l | tr -d ' ')" \
  'segment prints exactly one line'

# the segment must not read stdin: whatever it is handed stays unconsumed for
# the next statusline component
payload='{"cwd":"/tmp"}'
leftover="$(printf '%s' "$payload" | { bash "$SEG" >/dev/null 2>&1; cat; })"
assert_eq "$payload" "$leftover" 'segment leaves stdin unconsumed'

# never fails the statusline
( CPROF_CONFIG=/dev/null bash "$SEG" </dev/null >/dev/null 2>&1 )
assert_eq '0' "$?" 'segment exits 0 on unusable config'

# and prints nothing rather than noise when there is no config at all
rm -f "$CPROF_CONFIG"
assert_eq '' "$(env -u CLAUDE_CONFIG_DIR bash "$SEG" </dev/null 2>/dev/null)" \
  'segment is silent when no profiles are configured'

cp_t_summary
