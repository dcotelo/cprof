#!/usr/bin/env bash
set -u
# The CLI entry point finding its own library directory. Worth its own file
# because the failure mode is silent and severe: when lib cannot be located,
# `cprof` prints `unset CLAUDE_CONFIG_DIR` on stdout and exits 0, so the shell
# function evals it and the session quietly runs the native account instead of
# the profile the directory asked for.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
CLI="$(cd "$(dirname "$0")/.." && pwd -P)/scripts/cprof"

# --- invoked directly ---------------------------------------------------------
assert_eq "cprof $(jq -r .version "$(dirname "$CLI")/../.claude-plugin/plugin.json")" \
  "$("$CLI" version 2>/dev/null)" 'reports its version when run in place'

# --- invoked through a symlink ------------------------------------------------
# Homebrew installs to libexec and links into bin, and people run `ln -s` by
# hand. Both make $0 a path whose directory holds no lib/.
mkdir -p "$CP_T_TMP/bin"
ln -s "$CLI" "$CP_T_TMP/bin/cprof"

out="$("$CP_T_TMP/bin/cprof" version 2>/dev/null)"
assert_eq "cprof $(jq -r .version "$(dirname "$CLI")/../.claude-plugin/plugin.json")" "$out" \
  'reports its version through a symlink'

err="$("$CP_T_TMP/bin/cprof" version 2>&1 >/dev/null)"
assert_eq '' "$err" 'a symlinked run says nothing about a missing lib directory'

# The dangerous half: a broken resolution emits an unset on stdout, which the
# shell function evals. A config with a resolving default is required to tell
# that apart from the legitimate unset, which is what `env` prints when nothing
# matches — the same bytes for opposite reasons.
mkdir -p "$CP_T_TMP/p"
cp_t_write_config <<JSON
{"default":"personal","profiles":[{"name":"personal","dir":"$CP_T_TMP/p"}],
 "rules":[],"repos":{}}
JSON
out="$("$CP_T_TMP/bin/cprof" env 2>/dev/null)"
case "$out" in
  *'unset CLAUDE_CONFIG_DIR'*)
    assert_eq 'an export, not an unset' "$out" 'a symlinked env does not unset the config dir' ;;
  *) assert_eq ok ok 'a symlinked env does not unset the config dir' ;;
esac

# --- invoked through a symlinked parent directory ------------------------------
# The other shape of the same problem: the file is reached through a link to the
# directory holding it, so dirname resolves somewhere with no lib/ beside it.
ln -s "$(dirname "$CLI")" "$CP_T_TMP/scripts-link"
assert_eq "cprof $(jq -r .version "$(dirname "$CLI")/../.claude-plugin/plugin.json")" \
  "$("$CP_T_TMP/scripts-link/cprof" version 2>/dev/null)" \
  'reports its version through a symlinked parent directory'

cp_t_summary
