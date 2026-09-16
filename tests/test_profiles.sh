#!/usr/bin/env bash
set -u
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
CLI="$(cd "$(dirname "$0")/.." && pwd -P)/scripts/cprof"
cfg_get() { jq -r "$1" "$CPROF_CONFIG"; }
# For cp_keychain_service in the purge test below; everything else here
# drives the CLI.
# shellcheck source=/dev/null
. "$(dirname "$0")/../scripts/lib/config.sh"
# shellcheck source=/dev/null
. "$(dirname "$0")/../scripts/lib/auth.sh"

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
# a profile name is also a filename under ~/.cprof, so it can't be a path
assert_fail "$CLI" add '../escape' --dir "$CP_T_TMP/esc"
assert_fail "$CLI" add 'a/b' --dir "$CP_T_TMP/ab"
assert_fail "$CLI" add '..' --dir "$CP_T_TMP/dd"
# ... nor hold a control character: names are serialised one per line
assert_fail "$CLI" add "$(printf 'team\talpha')" --dir "$CP_T_TMP/tab"
assert_fail "$CLI" add "$(printf 'team\nalpha')" --dir "$CP_T_TMP/nl"
assert_eq '' "$(cfg_get '.profiles[] | select(.name | test("team")) | .name')" 'a name with a control character is not registered'
assert_eq '' "$(cfg_get '.profiles[] | select(.name == "a/b") | .name')" 'a name with a slash is not registered'

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

# pin reports what it did on stderr, leaving stdout clean and exiting 0
pin_run() { out="$( (cd "$CP_T_TMP/repo" && "$CLI" "$@" 2>"$CP_T_TMP/err") )"; rc=$?; err="$(cat "$CP_T_TMP/err")"; }
pin_run pin personal
assert_eq '0' "$rc" 'pin exits 0'
assert_eq '' "$out" 'pin keeps stdout clean'
assert_eq "cprof: pinned $CP_T_TMP/repo to personal" "$err" 'pin confirms on stderr'
pin_run pin --clear
assert_eq '0' "$rc" 'pin --clear exits 0'
assert_eq '' "$out" 'pin --clear keeps stdout clean'
assert_eq "cprof: unpinned $CP_T_TMP/repo" "$err" 'pin --clear confirms on stderr'
pin_run pin --clear
assert_eq '0' "$rc" 'clearing an absent pin still exits 0'
assert_eq '' "$out" 'clearing an absent pin keeps stdout clean'
assert_eq "cprof: no pin for $CP_T_TMP/repo" "$err" 'clearing an absent pin says so'

# a failed config write fails the command and never claims success
mkdir -p "$CP_T_TMP/ro"
cp "$CPROF_CONFIG" "$CP_T_TMP/ro/config.json"
chmod 500 "$CP_T_TMP/ro"
out="$( (cd "$CP_T_TMP/repo" && CPROF_CONFIG="$CP_T_TMP/ro/config.json" "$CLI" pin personal 2>"$CP_T_TMP/err") )"; rc=$?
case "$(cat "$CP_T_TMP/err")" in *pinned*) claimed=yes ;; *) claimed=no ;; esac
assert_eq '1' "$rc" 'pin fails when the config write fails'
assert_eq '' "$out" 'failed pin keeps stdout clean'
assert_eq 'no' "$claimed" 'failed pin does not claim success'
chmod 700 "$CP_T_TMP/ro"

# remove also scrubs the cached usage data, so a later profile that reuses
# the name never inherits stale numbers from a different account
mkdir -p "$CP_T_TMP/state/usage"
printf '{"five_hour":{"utilization":88},"seven_day":{"utilization":77}}' \
  > "$CP_T_TMP/state/usage/personal.json"
# ... and when that scrub fails, the profile stays registered rather than
# leaving stale state behind under a name the config no longer knows
chmod 500 "$CP_T_TMP/state/usage"
assert_fail "$CLI" remove personal
assert_eq 'personal' "$(cfg_get '.profiles[] | select(.name == "personal") | .name')" \
  'a failed cache scrub leaves the profile registered'
assert_eq 'true' "$([ -f "$CP_T_TMP/state/usage/personal.json" ] && echo true)" \
  'a failed cache scrub leaves the cache in place for the retry'
chmod 700 "$CP_T_TMP/state/usage"
assert_ok   "$CLI" remove personal
assert_fail "$CLI" remove personal
assert_eq 'true' "$([ -d "$CP_T_TMP/p" ] && echo true)" 'remove leaves the directory in place'
assert_eq '' "$([ -f "$CP_T_TMP/state/usage/personal.json" ] && echo present)" \
  'remove deletes the profile usage cache'

# purge needs confirmation and honours it
assert_ok "$CLI" add tmpp --dir "$CP_T_TMP/tp"
printf 'n\n' | "$CLI" remove tmpp --purge >/dev/null 2>&1
assert_eq 'true' "$([ -d "$CP_T_TMP/tp" ] && echo true)" 'declined purge keeps the directory'
# ... and takes the profile's live keychain item with it (Claude Code 2.1+
# keeps credentials there, not in the directory)
KCD="$CP_T_TMP/keychain.d"
mkdir -p "$KCD"
export CP_T_KEYCHAIN_DIR="$KCD"
cat > "$CP_SECURITY_BIN" <<'STUB'
#!/usr/bin/env bash
cmd="$1"; shift
svc=''
while [ "$#" -gt 0 ]; do case "$1" in -s) svc="$2"; shift 2 ;; *) shift ;; esac; done
case "$cmd" in
  find-generic-password)   [ -f "$CP_T_KEYCHAIN_DIR/$svc.readfail" ] && exit 1; [ -f "$CP_T_KEYCHAIN_DIR/$svc" ] || exit 44; cat "$CP_T_KEYCHAIN_DIR/$svc" ;;
  delete-generic-password) [ -f "$CP_T_KEYCHAIN_DIR/$svc" ] || exit 1; [ -f "$CP_T_KEYCHAIN_DIR/$svc.nodelete" ] && exit 1; rm -f "$CP_T_KEYCHAIN_DIR/$svc" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$CP_SECURITY_BIN"
service="$(cp_keychain_service "$CP_T_TMP/tp")"
printf 'live' > "$KCD/$service"
printf 'y\n' | "$CLI" remove tmpp --purge >/dev/null 2>&1
assert_eq '' "$([ -d "$CP_T_TMP/tp" ] && echo true)" 'confirmed purge deletes the directory'
assert_eq 'false' "$([ -f "$KCD/$service" ] && echo true || echo false)" 'purge deletes the live keychain item'
# ... and a keychain item that refuses to go fails the purge with the profile
# still registered, until it can be deleted
assert_ok "$CLI" add tmpk --dir "$CP_T_TMP/tk" --isolated
printf 'session data' > "$CP_T_TMP/tk/history.jsonl"
service="$(cp_keychain_service "$CP_T_TMP/tk")"
printf 'live' > "$KCD/$service"
: > "$KCD/$service.nodelete"
rc=0; printf 'y\n' | "$CLI" remove tmpk --purge >/dev/null 2>&1 || rc=$?
assert_eq '1' "$rc" 'purge fails when a keychain item cannot be deleted'
assert_eq 'tmpk' "$(cfg_get '.profiles[] | select(.name == "tmpk") | .name')" \
  'a failed keychain delete leaves the profile registered'
assert_eq 'true' "$([ -f "$KCD/$service" ] && echo true || echo false)" 'a failed keychain delete leaves the item'
assert_eq 'session data' "$(cat "$CP_T_TMP/tk/history.jsonl" 2>/dev/null)" \
  'a failed keychain delete leaves the directory and its contents intact'
rm -f "$KCD/$service.nodelete"
printf 'y\n' | "$CLI" remove tmpk --purge >/dev/null 2>&1
assert_eq 'false' "$([ -d "$CP_T_TMP/tk" ] && echo true || echo false)" 'the retried purge deletes the directory'
assert_eq '' "$(cfg_get '.profiles[] | select(.name == "tmpk") | .name')" 'the retried purge unregisters the profile'
assert_eq 'false' "$([ -f "$KCD/$service" ] && echo true || echo false)" 'the retried purge deletes the keychain item'
# ... and the cached-state scrub runs before anything destructive: if it
# fails, directory, keychain items, and registration are all still there
assert_ok "$CLI" add tmps --dir "$CP_T_TMP/ts" --isolated
printf 'session data' > "$CP_T_TMP/ts/history.jsonl"
service="$(cp_keychain_service "$CP_T_TMP/ts")"
printf 'live' > "$KCD/$service"
mkdir -p "$CP_T_TMP/state/usage"
printf '{"five_hour":{"utilization":1}}' > "$CP_T_TMP/state/usage/tmps.json"
chmod 500 "$CP_T_TMP/state/usage"
rc=0; printf 'y\n' | "$CLI" remove tmps --purge >/dev/null 2>&1 || rc=$?
assert_eq '1' "$rc" 'purge fails when the cached state cannot be scrubbed'
assert_eq 'tmps' "$(cfg_get '.profiles[] | select(.name == "tmps") | .name')" 'a failed scrub during purge leaves the profile registered'
assert_eq 'session data' "$(cat "$CP_T_TMP/ts/history.jsonl" 2>/dev/null)" 'a failed scrub during purge leaves the directory intact'
assert_eq 'true' "$([ -f "$KCD/$service" ] && echo true || echo false)" 'a failed scrub during purge leaves the keychain item'
chmod 700 "$CP_T_TMP/state/usage"
printf 'y\n' | "$CLI" remove tmps --purge >/dev/null 2>&1
assert_eq '' "$(cfg_get '.profiles[] | select(.name == "tmps") | .name')" 'the retried purge after a scrub failure unregisters the profile'
assert_eq 'false' "$([ -d "$CP_T_TMP/ts" ] && echo true || echo false)" 'the retried purge after a scrub failure deletes the directory'
# ... and a keychain that cannot be read is not the same as no item: purge
# refuses rather than leaving live credentials behind
assert_ok "$CLI" add tmpr --dir "$CP_T_TMP/tr" --isolated
printf 'session data' > "$CP_T_TMP/tr/history.jsonl"
service="$(cp_keychain_service "$CP_T_TMP/tr")"
printf 'live' > "$KCD/$service"
: > "$KCD/$service.readfail"
rc=0; printf 'y\n' | "$CLI" remove tmpr --purge >/dev/null 2>&1 || rc=$?
assert_eq '1' "$rc" 'purge fails when the keychain cannot be read'
assert_eq 'tmpr' "$(cfg_get '.profiles[] | select(.name == "tmpr") | .name')" 'an unreadable keychain leaves the profile registered'
assert_eq 'session data' "$(cat "$CP_T_TMP/tr/history.jsonl" 2>/dev/null)" 'an unreadable keychain leaves the directory intact'
assert_eq 'true' "$([ -f "$KCD/$service" ] && echo true || echo false)" 'an unreadable keychain leaves the item'
rm -f "$KCD/$service.readfail"
printf 'y\n' | "$CLI" remove tmpr --purge >/dev/null 2>&1
assert_eq '' "$(cfg_get '.profiles[] | select(.name == "tmpr") | .name')" 'the retried purge unregisters the profile once the keychain reads'
assert_eq 'false' "$([ -f "$KCD/$service" ] && echo true || echo false)" 'the retried purge deletes the item once the keychain reads'

# ... and when the directory cannot be deleted, the profile stays registered
# rather than being forgotten with its sessions still on disk. The keychain
# item goes first and is already gone at that point: the confirmed purge
# asked for it, and the retry finds it absent and finishes.
mkdir -p "$CP_T_TMP/lp"
assert_ok "$CLI" add held --dir "$CP_T_TMP/lp/held" --isolated
service="$(cp_keychain_service "$CP_T_TMP/lp/held")"
printf 'live' > "$KCD/$service"
chmod 500 "$CP_T_TMP/lp"
rc=0; out="$(printf 'y\n' | "$CLI" remove held --purge 2>&1)" || rc=$?
assert_eq '1' "$rc" 'purge fails when the directory cannot be deleted'
assert_eq 'held' "$(cfg_get '.profiles[] | select(.name == "held") | .name')" \
  'a failed purge leaves the profile registered'
# (a read-only parent lets rm -rf empty the directory before failing on the
# entry itself, so only the directory's survival is asserted here)
assert_eq 'true' "$([ -d "$CP_T_TMP/lp/held" ] && echo true || echo false)" 'a failed purge leaves the directory'
assert_eq 'false' "$([ -f "$KCD/$service" ] && echo true || echo false)" 'a failed directory delete comes after the keychain item is gone'
case "$out" in *'keychain credentials are already removed'*) assert_eq ok ok 'a failed directory delete says the credentials are already gone' ;;
                *) assert_eq '... keychain credentials are already removed ...' "$out" 'a failed directory delete says the credentials are already gone' ;; esac
chmod 700 "$CP_T_TMP/lp"
printf 'y\n' | "$CLI" remove held --purge >/dev/null 2>&1
assert_eq '' "$(cfg_get '.profiles[] | select(.name == "held") | .name')" 'the retried purge unregisters the profile'
assert_eq 'false' "$([ -d "$CP_T_TMP/lp/held" ] && echo true || echo false)" 'the retried purge deletes the directory'

cp_t_summary
