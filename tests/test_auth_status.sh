#!/usr/bin/env bash
set -u
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
CLI="$(cd "$(dirname "$0")/.." && pwd -P)/scripts/cprof"

# Stub claude: reports identity based on CLAUDE_CONFIG_DIR, and records whether
# the variable was set at all.
cat > "$CP_CLAUDE_BIN" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  if [ -z "${CLAUDE_CONFIG_DIR+set}" ]; then
    printf '{"loggedIn":true,"email":"native@example.com","subscriptionType":"team"}\n'
  elif [ -f "$CLAUDE_CONFIG_DIR/.credentials.json" ]; then
    printf '{"loggedIn":true,"email":"file@example.com","subscriptionType":"max"}\n'
  else
    printf '{"loggedIn":false,"authMethod":"none"}\n'
  fi
  exit 0
fi
exit 1
STUB
chmod +x "$CP_CLAUDE_BIN"

mkdir -p "$CP_T_TMP/p" "$CP_T_TMP/empty"
printf '{"claudeAiOauth":{"refreshTokenExpiresAt":99999999999999}}' > "$CP_T_TMP/p/.credentials.json"
cp_t_write_config <<JSON
{"default":"personal",
 "profiles":[{"name":"personal","dir":"$CP_T_TMP/p","note":"Max"},
             {"name":"work","native":true,"note":"team"},
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

# expiring refresh token is reported
printf '{"claudeAiOauth":{"refreshTokenExpiresAt":1}}' > "$CP_T_TMP/p/.credentials.json"
out="$(cd "$CP_T_TMP" && "$CLI" doctor 2>&1)"
case "$out" in *expir*) assert_eq ok ok 'doctor reports an expiring refresh token' ;;
                *) assert_eq 'expiring' "$out" 'doctor reports an expiring refresh token' ;; esac

cp_t_summary
