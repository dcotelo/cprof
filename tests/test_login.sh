#!/usr/bin/env bash
set -u
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
CLI="$(cd "$(dirname "$0")/.." && pwd -P)/scripts/claudeprofile"

# Stub keychain backed by a plain file.
KC="$CP_T_TMP/keychain.store"
printf 'ORIGINAL-BLOB' > "$KC"
cat > "$CP_SECURITY_BIN" <<'STUB'
#!/usr/bin/env bash
store="$CP_T_KEYCHAIN_STORE"
case "$1" in
  find-generic-password) cat "$store" 2>/dev/null; [ -s "$store" ] ;;
  add-generic-password)
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in -w) printf '%s' "$2" > "$store"; shift 2 ;; *) shift ;; esac
    done
    ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$CP_SECURITY_BIN"
export CP_T_KEYCHAIN_STORE="$KC"

mkdir -p "$CP_T_TMP/p"
cp_t_write_config <<JSON
{"default":"personal","profiles":[{"name":"personal","dir":"$CP_T_TMP/p"},{"name":"work","native":true}],
 "rules":[],"repos":{}}
JSON

# --- well-behaved login: writes the credentials file, leaves keychain alone ---
cat > "$CP_CLAUDE_BIN" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = login ]; then
  printf '{"claudeAiOauth":{"accessToken":"x"}}' > "$CLAUDE_CONFIG_DIR/.credentials.json"
  exit 0
fi
exit 1
STUB
chmod +x "$CP_CLAUDE_BIN"

assert_ok "$CLI" login personal
assert_eq 'true' "$([ -f "$CP_T_TMP/p/.credentials.json" ] && echo true)" 'credentials file created'
assert_eq 'ORIGINAL-BLOB' "$(cat "$KC")" 'keychain untouched by a well-behaved login'
assert_eq '600' "$(stat -f '%Lp' "$CLAUDEPROFILE_STATE_DIR/keychain.bak")" 'keychain backup is mode 600'

# --- misbehaving login: clobbers the keychain -> detected and restored --------
rm -f "$CP_T_TMP/p/.credentials.json"
cat > "$CP_CLAUDE_BIN" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = login ]; then
  printf 'CLOBBERED' > "$CP_T_KEYCHAIN_STORE"
  exit 0
fi
exit 1
STUB
chmod +x "$CP_CLAUDE_BIN"

out="$("$CLI" login personal 2>&1)"
rc=$?
assert_eq '1' "$rc" 'login fails when the keychain was clobbered'
assert_eq 'ORIGINAL-BLOB' "$(cat "$KC")" 'keychain restored from backup'
case "$out" in *keychain*) assert_eq ok ok 'clobber is reported' ;;
                *) assert_eq 'keychain' "$out" 'clobber is reported' ;; esac

# --- native profile cannot be logged in through a profile dir ----------------
assert_fail "$CLI" login work

# --- unknown profile ---------------------------------------------------------
assert_fail "$CLI" login ghost

cp_t_summary
