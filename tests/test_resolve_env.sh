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

mkdir -p "$CP_T_TMP/elsewhere"
cfg="$(cat <<JSON
{"default":"personal",
 "profiles":[{"name":"personal","dir":"$CP_T_TMP/p"},{"name":"work","native":true}],
 "rules":[],
 "repos":{"$CP_T_TMP/elsewhere":"personal"}}
JSON
)"

export CLAUDE_PROFILE=work
out="$(cd "$CP_T_TMP/elsewhere" && printf '%s' "$cfg" | cp_resolve)"
assert_eq 'work'               "$(printf '%s' "$out" | cut -f1)" 'CLAUDE_PROFILE outranks a pin'
assert_eq 'env CLAUDE_PROFILE' "$(printf '%s' "$out" | cut -f2)" 'reason names the env var'

# an unknown CLAUDE_PROFILE is ignored, not fatal
export CLAUDE_PROFILE=ghost
out="$(cd "$CP_T_TMP/elsewhere" && printf '%s' "$cfg" | cp_resolve 2>/dev/null)"
assert_eq 'personal' "$(printf '%s' "$out" | cut -f1)" 'unknown CLAUDE_PROFILE falls through to the pin'
unset CLAUDE_PROFILE

cp_t_summary
