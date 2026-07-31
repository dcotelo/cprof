#!/usr/bin/env bash
set -u
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
CLI="$(cd "$(dirname "$0")/.." && pwd -P)/scripts/cprof"

export CP_T_CALL_LOG="$CP_T_TMP/claude-calls.log"

# --- both subcommands succeed, in order, without leaking CLAUDE_CONFIG_DIR --
cat > "$CP_CLAUDE_BIN" <<'STUB'
#!/usr/bin/env bash
printf '%s\t%s\n' "${CLAUDE_CONFIG_DIR:-unset}" "$*" >> "$CP_T_CALL_LOG"
exit 0
STUB
chmod +x "$CP_CLAUDE_BIN"

export CLAUDE_CONFIG_DIR="$CP_T_TMP/should-not-leak"
out="$("$CLI" update 2>&1)"
rc=$?
unset CLAUDE_CONFIG_DIR

assert_eq '0' "$rc" 'update succeeds when both subcommands succeed'
assert_eq "$(printf 'unset\tplugin marketplace update dcotelo')" "$(sed -n 1p "$CP_T_CALL_LOG")" \
  'marketplace update runs first, without CLAUDE_CONFIG_DIR'
assert_eq "$(printf 'unset\tplugin update cprof@dcotelo')" "$(sed -n 2p "$CP_T_CALL_LOG")" \
  'plugin update runs second, without CLAUDE_CONFIG_DIR'
case "$out" in
  *restart*) assert_eq ok ok 'reminds to restart' ;;
  *)         assert_eq '*restart*' "$out" 'reminds to restart' ;;
esac

# --- marketplace update fails: plugin update still runs, overall failure ----
: > "$CP_T_CALL_LOG"
cat > "$CP_CLAUDE_BIN" <<'STUB'
#!/usr/bin/env bash
printf '%s\t%s\n' "${CLAUDE_CONFIG_DIR:-unset}" "$*" >> "$CP_T_CALL_LOG"
[ "$1 $2" = 'plugin marketplace' ] && exit 1
exit 0
STUB
chmod +x "$CP_CLAUDE_BIN"

assert_fail "$CLI" update
assert_eq '2' "$(wc -l < "$CP_T_CALL_LOG" | tr -d ' ')" \
  'plugin update still runs after a marketplace-update failure'

cp_t_summary
