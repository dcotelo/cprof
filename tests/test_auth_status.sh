#!/usr/bin/env bash
set -u
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
CLI="$(cd "$(dirname "$0")/.." && pwd -P)/scripts/cprof"
CP_LIB_DIR="$(cd "$(dirname "$0")/../scripts/lib" && pwd -P)"
export CP_KEYCHAIN_SERVICE="Claude Code-credentials"
# shellcheck source=../scripts/lib/auth.sh
. "$CP_LIB_DIR/auth.sh"

# Stub keychain: one file per service name, mirroring Claude Code's per-config-dir
# items. Service for a config dir is "Claude Code-credentials-<sha256(dir)[0:8]>";
# the bare service is the native item.
KCD="$CP_T_TMP/keychain.d"
mkdir -p "$KCD"
export CP_T_KEYCHAIN_DIR="$KCD"
cat > "$CP_SECURITY_BIN" <<'STUB'
#!/usr/bin/env bash
cmd="$1"; shift
svc='' val=''
case "$cmd" in
  find-generic-password)
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -s) svc="$2"; shift 2 ;;
        -w) shift ;;
        *)  shift ;;
      esac
    done
    [ -n "$svc" ] && [ -f "$CP_T_KEYCHAIN_DIR/$svc" ] || exit 1
    cat "$CP_T_KEYCHAIN_DIR/$svc"
    ;;
  add-generic-password)
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -s) svc="$2"; shift 2 ;;
        -w) val="$2"; shift 2 ;;
        *)  shift ;;
      esac
    done
    [ -n "$svc" ] || exit 1
    printf '%s' "$val" > "$CP_T_KEYCHAIN_DIR/$svc"
    ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$CP_SECURITY_BIN"

# --- cp_keychain_write: bare service (existing caller, cp_cmd_login) -------
cp_keychain_write 'tok-native'
assert_eq 'tok-native' "$(cat "$CP_T_KEYCHAIN_DIR/Claude Code-credentials")" \
  'cp_keychain_write with no service writes the bare native item'

# --- cp_keychain_write: explicit service (new capability) -----------------
cp_keychain_write 'tok-work-bak' 'Claude Code-credentials-deadbeef-bak'
assert_eq 'tok-work-bak' "$(cat "$CP_T_KEYCHAIN_DIR/Claude Code-credentials-deadbeef-bak")" \
  'cp_keychain_write with an explicit service writes that service'

kc_service() { printf 'Claude Code-credentials-%s\n' \
  "$(printf '%s' "$1" | shasum -a 256 | cut -c1-8)"; }

# Stub claude: reports identity based on CLAUDE_CONFIG_DIR, and records whether
# the variable was set at all. Credentials count whether they sit in the config
# dir (Claude Code < 2.1) or in that dir's keychain item (2.1+).
cat > "$CP_CLAUDE_BIN" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  if [ -z "${CLAUDE_CONFIG_DIR+set}" ]; then
    printf '{"loggedIn":true,"email":"native@example.com","subscriptionType":"team"}\n'
  elif [ -f "$CLAUDE_CONFIG_DIR/.credentials.json" ]; then
    printf '{"loggedIn":true,"email":"file@example.com","subscriptionType":"max"}\n'
  elif [ -f "$CP_T_KEYCHAIN_DIR/Claude Code-credentials-$(printf '%s' "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)" ]; then
    printf '{"loggedIn":true,"email":"keychain@example.com","subscriptionType":"pro"}\n'
  else
    printf '{"loggedIn":false,"authMethod":"none"}\n'
  fi
  exit 0
fi
exit 1
STUB
chmod +x "$CP_CLAUDE_BIN"

mkdir -p "$CP_T_TMP/p" "$CP_T_TMP/empty" "$CP_T_TMP/k"
printf '{"claudeAiOauth":{"refreshTokenExpiresAt":99999999999999}}' > "$CP_T_TMP/p/.credentials.json"
printf '{"claudeAiOauth":{"refreshTokenExpiresAt":99999999999999}}' \
  > "$KCD/$(kc_service "$CP_T_TMP/k")"
printf '{"claudeAiOauth":{"refreshTokenExpiresAt":99999999999999}}' \
  > "$KCD/Claude Code-credentials"
cp_t_write_config <<JSON
{"default":"personal",
 "profiles":[{"name":"personal","dir":"$CP_T_TMP/p","note":"Max"},
             {"name":"work","native":true,"note":"team"},
             {"name":"kc","dir":"$CP_T_TMP/k","note":"keychain-backed"},
             {"name":"cold","dir":"$CP_T_TMP/empty"}],
 "rules":[],"repos":{}}
JSON

out="$(cd "$CP_T_TMP" && "$CLI" list 2>/dev/null)"
case "$out" in *file@example.com*)   assert_eq ok ok 'list shows file-backed identity' ;;
                *) assert_eq 'file@example.com' "$out" 'list shows file-backed identity' ;; esac
case "$out" in *native@example.com*) assert_eq ok ok 'list shows native identity via unset env' ;;
                *) assert_eq 'native@example.com' "$out" 'list shows native identity via unset env' ;; esac
case "$out" in *'(default)'*)        assert_eq ok ok 'list marks default' ;;
                *) assert_eq '(default)' "$out" 'list marks default' ;; esac
case "$out" in *native*)             assert_eq ok ok 'list marks native' ;;
                *) assert_eq 'native' "$out" 'list marks native' ;; esac
case "$out" in *'not logged in'*)    assert_eq ok ok 'list flags unauthenticated profile' ;;
                *) assert_eq 'not logged in' "$out" 'list flags unauthenticated profile' ;; esac

# doctor exits non-zero while any profile is unauthenticated
( cd "$CP_T_TMP" && "$CLI" doctor >/dev/null 2>&1 )
assert_eq '1' "$?" 'doctor fails when a profile is not logged in'

# ... and zero once the cold profile is gone
"$CLI" remove cold >/dev/null 2>&1
( cd "$CP_T_TMP" && "$CLI" doctor >/dev/null 2>&1 )
assert_eq '0' "$?" 'doctor passes when every profile is logged in'

# expiring refresh token is reported, file-backed
printf '{"claudeAiOauth":{"refreshTokenExpiresAt":1}}' > "$CP_T_TMP/p/.credentials.json"
out="$(cd "$CP_T_TMP" && "$CLI" doctor 2>&1)"
case "$out" in *'personal: refresh token expir'*) assert_eq ok ok 'doctor reports an expiring file-backed token' ;;
                *) assert_eq 'personal: refresh token expiring' "$out" 'doctor reports an expiring file-backed token' ;; esac
printf '{"claudeAiOauth":{"refreshTokenExpiresAt":99999999999999}}' > "$CP_T_TMP/p/.credentials.json"

# ... and keychain-backed, where no .credentials.json exists at all
printf '{"claudeAiOauth":{"refreshTokenExpiresAt":1}}' > "$KCD/$(kc_service "$CP_T_TMP/k")"
out="$(cd "$CP_T_TMP" && "$CLI" doctor 2>&1)"
assert_eq 'false' "$([ -f "$CP_T_TMP/k/.credentials.json" ] && echo true || echo false)" \
  'keychain-backed profile has no credentials file'
case "$out" in *'kc: refresh token expir'*) assert_eq ok ok 'doctor reports an expiring keychain-backed token' ;;
                *) assert_eq 'kc: refresh token expiring' "$out" 'doctor reports an expiring keychain-backed token' ;; esac
printf '{"claudeAiOauth":{"refreshTokenExpiresAt":99999999999999}}' > "$KCD/$(kc_service "$CP_T_TMP/k")"

# ... and for the native profile, which reads the unsuffixed keychain item
printf '{"claudeAiOauth":{"refreshTokenExpiresAt":1}}' > "$KCD/Claude Code-credentials"
out="$(cd "$CP_T_TMP" && "$CLI" doctor 2>&1)"
case "$out" in *'work: refresh token expir'*) assert_eq ok ok 'doctor reports an expiring native token' ;;
                *) assert_eq 'work: refresh token expiring' "$out" 'doctor reports an expiring native token' ;; esac
printf '{"claudeAiOauth":{"refreshTokenExpiresAt":99999999999999}}' > "$KCD/Claude Code-credentials"

# a credential blob without an expiry degrades to silence, not a spurious warning
printf '{"claudeAiOauth":{}}' > "$KCD/$(kc_service "$CP_T_TMP/k")"
out="$(cd "$CP_T_TMP" && "$CLI" doctor 2>&1)"
rc=$?
assert_eq '0' "$rc" 'doctor passes when an expiry is simply unknown'
case "$out" in *'kc: ok'*) assert_eq ok ok 'unknown expiry reports ok, not expiring' ;;
                *) assert_eq 'kc: ok' "$out" 'unknown expiry reports ok, not expiring' ;; esac

# --- doctor: usage warning at >=90%, silent otherwise ---------------------
export CP_CURL_BIN="$CP_T_TMP/bin/curl"
cat > "$CP_CURL_BIN" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"five_hour":{"utilization":92,"resets_at":"2030-01-01T18:30:00Z"},
 "seven_day":{"utilization":10,"resets_at":"2030-01-05T00:00:00Z"},"limits":[]}
JSON
STUB
chmod +x "$CP_CURL_BIN"
printf '{"claudeAiOauth":{"refreshTokenExpiresAt":99999999999999,"accessToken":"tok"}}' \
  > "$CP_T_TMP/p/.credentials.json"
out="$(cd "$CP_T_TMP" && "$CLI" doctor 2>&1)"
rc=$?
case "$out" in *'personal: 5h window at'*'92%'*) assert_eq ok ok 'doctor warns at 92% usage' ;;
                *) assert_eq 'personal: 5h window at 92%' "$out" 'doctor warns at 92% usage' ;; esac
assert_eq '1' "$rc" 'doctor fails when a profile is at 92% usage'

cat > "$CP_CURL_BIN" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"five_hour":{"utilization":42,"resets_at":"2030-01-01T18:30:00Z"},
 "seven_day":{"utilization":10,"resets_at":"2030-01-05T00:00:00Z"},"limits":[]}
JSON
STUB
chmod +x "$CP_CURL_BIN"
rm -f "$CP_T_TMP/state/usage/personal.json"
out="$(cd "$CP_T_TMP" && "$CLI" doctor 2>&1)"
rc=$?
case "$out" in *'5h window'*) assert_eq 'no usage warning' "$out" 'doctor stays silent under 90%' ;;
                *) assert_eq ok ok 'doctor stays silent under 90%' ;; esac
assert_eq '0' "$rc" 'doctor passes when usage is under 90%'

# --- doctor: a stale cache whose window already reset is not an alarm ----
rm -f "$CP_CURL_BIN"
mkdir -p "$CP_T_TMP/state/usage"
cat > "$CP_T_TMP/state/usage/personal.json" <<'JSON'
{"fetched_at":1,"five_hour":{"utilization":92,"resets_at":"2020-01-01T00:00:00Z"},"seven_day":{"utilization":10},"limits":[]}
JSON
out="$(cd "$CP_T_TMP" && "$CLI" doctor 2>&1)"
rc=$?
case "$out" in *'5h window'*) assert_eq 'no usage warning' "$out" 'doctor ignores a 92% cache whose window has reset' ;;
                *) assert_eq ok ok 'doctor ignores a 92% cache whose window has reset' ;; esac
assert_eq '0' "$rc" 'doctor passes on a stale, already-reset cache'

# --- doctor: no network, no cache -> usage check never fails the run -----
rm -f "$CP_CURL_BIN" "$CP_T_TMP/state/usage/personal.json"
out="$(cd "$CP_T_TMP" && "$CLI" doctor 2>&1)"
rc=$?
assert_eq '0' "$rc" 'doctor passes when usage data is simply unavailable'

# --- doctor: active-swap line ----------------------------------------------
mkdir -p "$CP_T_TMP/state/fallback-active"
cat > "$CP_T_TMP/state/fallback-active/personal.json" <<'JSON'
{"fallback":"work","backup":"/tmp/whatever.bak","backup_kind":"file","swapped_at":1,"resets_at":"2026-09-14T18:30:00Z"}
JSON
out="$(cd "$CP_T_TMP" && "$CLI" doctor 2>&1)"
case "$out" in *'personal: fallback active (using work'*'2026-09-14T18:30:00Z'*) assert_eq ok ok 'doctor shows the active-swap line' ;;
                *) assert_eq 'personal: fallback active (using work ... 2026-09-14T18:30:00Z)' "$out" 'doctor shows the active-swap line' ;; esac
rc=0
( cd "$CP_T_TMP" && "$CLI" doctor >/dev/null 2>&1 ) || rc=$?
assert_eq '0' "$rc" 'doctor does not fail just because a fallback swap is active'
rm -f "$CP_T_TMP/state/fallback-active/personal.json"

# --- doctor reports a statusline setting that did not take -----------------
cp_t_write_config <<JSON
{"default":"personal",
 "profiles":[{"name":"personal","dir":"$CP_T_TMP/p","note":"Max"},
             {"name":"work","native":true,"note":"team"},
             {"name":"kc","dir":"$CP_T_TMP/k","note":"keychain-backed"}],
 "rules":[],"repos":{},
 "statusline":{"bar":{"width":99}}}
JSON
out="$(NO_COLOR=1 "$CLI" doctor 2>&1)"
case "$out" in *'statusline.bar.width'*) assert_eq ok ok 'doctor reports a bad statusline config' ;;
                *) assert_eq 'statusline.bar.width ...' "$out" 'doctor reports a bad statusline config' ;; esac
rc=0; NO_COLOR=1 "$CLI" doctor >/dev/null 2>&1 || rc=$?
assert_eq '1' "$rc" 'a bad statusline config makes doctor exit non-zero'

cp_t_summary
