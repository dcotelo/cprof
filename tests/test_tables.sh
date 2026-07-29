#!/usr/bin/env bash
# A literal ~ is the expected output here, not a path to expand.
# shellcheck disable=SC2088
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
# shellcheck source=/dev/null
. "$(dirname "$0")/../scripts/lib/profiles.sh"
# shellcheck source=/dev/null
. "$(dirname "$0")/../scripts/lib/auth.sh"
# shellcheck source=/dev/null
. "$(dirname "$0")/../scripts/lib/output.sh"
CLI="$(cd "$(dirname "$0")/.." && pwd -P)/scripts/cprof"

# --- cp_path_display: home shortens to ~ -------------------------------------
assert_eq '~'          "$(cp_path_display "$HOME")"            'home alone is ~'
assert_eq '~/dev/api'  "$(cp_path_display "$HOME/dev/api")"    'home prefix shortens'
assert_eq '/opt/x'     "$(cp_path_display /opt/x)"             'other paths are untouched'
assert_eq '/homely/x'  "$(cp_path_display /homely/x)"          'prefix match respects boundary'

# Stored paths are physical while $HOME may be reached through a symlink; a
# symlinked home must still shorten, or half the output prints in full.
mkdir -p "$CP_T_TMP/real-home/dev"
ln -s "$CP_T_TMP/real-home" "$CP_T_TMP/link-home"
assert_eq '~/dev' "$(HOME="$CP_T_TMP/link-home" cp_path_display "$CP_T_TMP/real-home/dev")" \
  'symlinked home shortens a physical path'

# --- cp_table: columns sized to their widest cell ----------------------------
expected='NAME  PLAN
a     max
bbbb  team'
assert_eq "$expected" "$(printf 'NAME\tPLAN\na\tmax\nbbbb\tteam\n' | cp_table)" \
  'columns align to the widest cell'

# no trailing whitespace, so terminal selection and diffs stay clean
assert_eq 'a  b' "$(printf 'a\tb\t\n' | cp_table)" 'empty trailing cell leaves no padding'

# a ragged row must not shift the columns of the others
expected='one     two  three
x       y
longer  y    z'
assert_eq "$expected" "$(printf 'one\ttwo\tthree\nx\ty\nlonger\ty\tz\n' | cp_table)" \
  'short rows do not disturb column widths'

# --- rule list ---------------------------------------------------------------
mkdir -p "$CP_T_TMP/p"
cp_t_write_config <<JSON
{"default":"work",
 "profiles":[{"name":"work","native":true},{"name":"personal","dir":"$CP_T_TMP/p"}],
 "rules":[],"repos":{}}
JSON
assert_eq 'no rules' "$("$CLI" rule list 2>/dev/null)" 'empty rule set says so'

cp_t_write_config <<JSON
{"default":"work",
 "profiles":[{"name":"work","native":true},{"name":"personal","dir":"$CP_T_TMP/p"}],
 "rules":[{"path":"$HOME/dev","profile":"personal"},
          {"path":"$HOME/dev/acme/api","profile":"work"},
          {"path":"$HOME/gone","profile":"ghost"}],
 "repos":{}}
JSON
out="$("$CLI" rule list 2>/dev/null)"

case "$out" in PATH*PROFILE*) assert_eq ok ok 'rule list has a header' ;;
                *) assert_eq 'PATH PROFILE header' "$out" 'rule list has a header' ;; esac

# longest prefix first: that is the order resolution consults them in
assert_eq '~/dev/acme/api' "$(printf '%s' "$out" | sed -n '2p' | awk '{print $1}')" \
  'longest path is listed first'
assert_eq '~/dev' "$(printf '%s' "$out" | sed -n '4p' | awk '{print $1}')" \
  'shortest path is listed last'

# a rule naming a profile that no longer exists is skipped at resolution time,
# so listing it silently would hide a broken rule
case "$out" in *ghost*unknown*) assert_eq ok ok 'rule naming a missing profile is flagged' ;;
                *) assert_eq 'ghost ... unknown' "$out" 'rule naming a missing profile is flagged' ;; esac

# `rules` is the same listing without the subcommand
assert_eq "$out" "$("$CLI" rules 2>/dev/null)" 'rules is an alias for rule list'

# --- list and which reuse the same table -------------------------------------
out="$("$CLI" list 2>/dev/null)"
case "$out" in PROFILE*PLAN*ACCOUNT*) assert_eq ok ok 'list has a header' ;;
                *) assert_eq 'PROFILE PLAN ACCOUNT header' "$out" 'list has a header' ;; esac

# the header and the first row start their second column at the same offset
col2_header="$(printf '%s' "$out" | sed -n '1p' | awk '{print index($0, $2)}')"
col2_row="$(printf '%s' "$out" | sed -n '2p' | awk '{print index($0, $2)}')"
assert_eq "$col2_header" "$col2_row" 'header and rows share column offsets'

# a rule match puts a path in the reason column, which is where shortening shows
mkdir -p "$HOME/dev/acme/api"
out="$(cd "$HOME/dev/acme/api" && "$CLI" which 2>/dev/null)"
case "$out" in *'rule ~/dev/acme/api'*) assert_eq ok ok 'which shortens home in the reason' ;;
                *) assert_eq 'rule ~/dev/acme/api' "$out" 'which shortens home in the reason' ;; esac

# the profile directory column is shortened too
cp_t_write_config <<JSON
{"default":"personal","profiles":[{"name":"personal","dir":"$HOME/.claude-profiles/personal"}],
 "rules":[],"repos":{}}
JSON
out="$("$CLI" which 2>/dev/null)"
case "$out" in *'~/.claude-profiles/personal'*) assert_eq ok ok 'which shortens the profile directory' ;;
                *) assert_eq '~/.claude-profiles/personal' "$out" 'which shortens the profile directory' ;; esac

cp_t_summary
