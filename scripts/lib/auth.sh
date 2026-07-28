#!/usr/bin/env bash
# shellcheck shell=bash
# Per-profile authentication: status, credential files, login, doctor.

CP_CLAUDE_BIN="${CP_CLAUDE_BIN:-claude}"
CP_SECURITY_BIN="${CP_SECURITY_BIN:-security}"

# cp_creds_file <cfg> <name> -> path, or empty for a native profile
cp_creds_file() {
  local dir
  dir="$(cp_profile_dir "$1" "$2")"
  [ -n "$dir" ] || return 0
  printf '%s/.credentials.json\n' "$dir"
}

# cp_auth_status <cfg> <name> -> JSON on stdout, {} on failure
cp_auth_status() {
  local cfg="$1" name="$2" dir out
  if cp_profile_is_native "$cfg" "$name"; then
    out="$(env -u CLAUDE_CONFIG_DIR "$CP_CLAUDE_BIN" auth status --json 2>/dev/null)"
  else
    dir="$(cp_profile_dir "$cfg" "$name")"
    if [ -z "$dir" ] || [ ! -d "$dir" ]; then
      printf '{}\n'
      return 0
    fi
    out="$(CLAUDE_CONFIG_DIR="$dir" "$CP_CLAUDE_BIN" auth status --json 2>/dev/null)"
  fi
  if [ -z "$out" ] || ! printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
    printf '{}\n'
    return 0
  fi
  printf '%s\n' "$out"
}

# Milliseconds until the refresh token expires, or empty when unknown.
cp_refresh_ms_left() {
  local file="$1" exp now
  [ -n "$file" ] && [ -f "$file" ] || return 0
  exp="$(jq -r '.claudeAiOauth.refreshTokenExpiresAt // empty' "$file" 2>/dev/null)"
  [ -n "$exp" ] || return 0
  now="$(( $(date +%s) * 1000 ))"
  printf '%s\n' "$(( exp - now ))"
}

cp_cmd_doctor() {
  local cfg names name st logged active ms left_days status=0
  cfg="$(cp_config_read)" || return 1
  active="$(printf '%s' "$cfg" | cp_resolve 2>/dev/null | cut -f1)"
  names="$(printf '%s' "$cfg" | jq -r '.profiles[]?.name')"
  if [ -z "$names" ]; then
    printf 'no profiles configured\n'
    return 1
  fi
  for name in $names; do
    st="$(cp_auth_status "$cfg" "$name")"
    logged="$(printf '%s' "$st" | jq -r '.loggedIn // false')"
    if [ "$logged" != 'true' ]; then
      printf '%s: not logged in - run: claudeprofile login %s\n' "$name" "$name"
      status=1
      continue
    fi
    ms="$(cp_refresh_ms_left "$(cp_creds_file "$cfg" "$name")")"
    if [ -n "$ms" ] && [ "$ms" -lt 1209600000 ]; then
      left_days="$(( ms / 86400000 ))"
      printf '%s: refresh token expires in %s day(s) - re-run: claudeprofile login %s\n' \
        "$name" "$left_days" "$name"
      status=1
    else
      printf '%s: ok\n' "$name"
    fi
  done
  printf 'active profile here: %s\n' "${active:-none}"
  return "$status"
}
