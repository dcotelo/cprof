#!/usr/bin/env bash
# shellcheck shell=bash
# Test harness. Sourced by tests/test_*.sh.

CP_T_PASS=0
CP_T_FAIL=0
CP_T_NAME="$(basename "${0}")"

cp_t_setup() {
  CP_T_TMP="$(mktemp -d "${TMPDIR:-/tmp}/cptest.XXXXXX")"
  CP_T_HOME="$CP_T_TMP/home"
  mkdir -p "$CP_T_HOME" "$CP_T_TMP/bin"
  export HOME="$CP_T_HOME"
  export CLAUDEPROFILE_CONFIG="$CP_T_TMP/config.json"
  export CLAUDEPROFILE_STATE_DIR="$CP_T_TMP/state"
  export CP_CLAUDE_BIN="$CP_T_TMP/bin/claude"
  export CP_SECURITY_BIN="$CP_T_TMP/bin/security"
  unset CLAUDE_PROFILE
  unset CLAUDE_CONFIG_DIR
}

cp_t_teardown() {
  case "$CP_T_TMP" in
    /*/cptest.*) rm -rf "$CP_T_TMP" ;;
    *) printf 'refusing to remove suspicious tmp: %s\n' "$CP_T_TMP" >&2 ;;
  esac
}

cp_t_write_config() {
  mkdir -p "$(dirname "$CLAUDEPROFILE_CONFIG")"
  cat > "$CLAUDEPROFILE_CONFIG"
}

assert_eq() {
  if [ "$1" = "$2" ]; then
    CP_T_PASS=$((CP_T_PASS + 1))
    printf '  ok   %s\n' "$3"
  else
    CP_T_FAIL=$((CP_T_FAIL + 1))
    printf '  FAIL %s\n    expected: [%s]\n    actual:   [%s]\n' "$3" "$1" "$2"
  fi
}

assert_ok() {
  if "$@" >/dev/null 2>&1; then
    CP_T_PASS=$((CP_T_PASS + 1))
    printf '  ok   %s\n' "$*"
  else
    CP_T_FAIL=$((CP_T_FAIL + 1))
    printf '  FAIL %s (expected success)\n' "$*"
  fi
}

assert_fail() {
  if "$@" >/dev/null 2>&1; then
    CP_T_FAIL=$((CP_T_FAIL + 1))
    printf '  FAIL %s (expected failure)\n' "$*"
  else
    CP_T_PASS=$((CP_T_PASS + 1))
    printf '  ok   %s (failed as expected)\n' "$*"
  fi
}

cp_t_summary() {
  printf '%s: %d passed, %d failed\n' "$CP_T_NAME" "$CP_T_PASS" "$CP_T_FAIL"
  [ "$CP_T_FAIL" -eq 0 ]
}
