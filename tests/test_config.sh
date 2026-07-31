#!/usr/bin/env bash
set -u
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
# shellcheck source=/dev/null
. "$(dirname "$0")/../scripts/lib/config.sh"

# absent config yields the empty default
assert_eq '[]' "$(cp_config_read | jq -c '.profiles')" 'absent config: empty profiles'
assert_eq 'null' "$(cp_config_read | jq -c '.default')" 'absent config: null default'

# malformed config is rejected
printf 'not json' | cp_t_write_config
assert_fail cp_config_read 'malformed config returns non-zero'

# round trip
cp_t_write_config <<'JSON'
{"default":"personal","profiles":[{"name":"personal","dir":"~/.claude-profiles/personal"},{"name":"work","native":true}],"rules":[],"repos":{}}
JSON
cfg="$(cp_config_read)"
assert_eq 'personal' "$(printf '%s' "$cfg" | jq -r '.default')" 'round trip: default'

# profile helpers
assert_ok   cp_profile_exists "$cfg" personal
assert_fail cp_profile_exists "$cfg" nope
assert_ok   cp_profile_is_native "$cfg" work
assert_fail cp_profile_is_native "$cfg" personal
assert_eq "$HOME/.claude-profiles/personal" "$(cp_profile_dir "$cfg" personal)" 'dir is tilde-expanded'
assert_eq '' "$(cp_profile_dir "$cfg" work)" 'native profile has no dir'

# tilde expansion (tilde in a variable so the shell does not expand it here)
tilde='~'
assert_eq "$HOME/x"  "$(cp_expand "$tilde/x")" 'expand ~/x'
assert_eq "$HOME"    "$(cp_expand "$tilde")"   'expand ~'
assert_eq '/abs/x'   "$(cp_expand '/abs/x')" 'absolute path untouched'
assert_eq 'rel/x'    "$(cp_expand 'rel/x')"  'relative path untouched'

# atomic write refuses invalid JSON
assert_fail eval 'printf "nope" | cp_config_write'
assert_eq 'personal' "$(cp_config_read | jq -r '.default')" 'config intact after rejected write'

# atomic write refuses empty stdin rather than truncating the config: `jq -S .`
# exits 0 on empty input, so the earlier guard alone let a write like this
# through and clobbered the file.
assert_fail eval 'printf "" | cp_config_write'
assert_eq 'personal' "$(cp_config_read | jq -r '.default')" 'config intact after an empty write'

cp_t_summary
