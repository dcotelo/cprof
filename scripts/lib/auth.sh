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
  if [ -z "$file" ] || [ ! -f "$file" ]; then
    return 0
  fi
  exp="$(jq -r '.claudeAiOauth.refreshTokenExpiresAt // empty' "$file" 2>/dev/null)"
  [ -n "$exp" ] || return 0
  now="$(( $(date +%s) * 1000 ))"
  printf '%s\n' "$(( exp - now ))"
}

cp_keychain_read() {
  "$CP_SECURITY_BIN" find-generic-password -s "$CP_KEYCHAIN_SERVICE" -a "${USER:-$(id -un)}" -w 2>/dev/null
}

cp_keychain_write() {
  "$CP_SECURITY_BIN" add-generic-password -U \
    -a "${USER:-$(id -un)}" -s "$CP_KEYCHAIN_SERVICE" -w "$1" >/dev/null 2>&1
}

cp_cmd_login() {
  local name="${1:-}" cfg dir backup before after rc
  [ -n "$name" ] || { cp_warn 'login: missing profile name'; return 2; }
  cfg="$(cp_config_read)" || return 1
  cp_profile_exists "$cfg" "$name" || { cp_warn "unknown profile $name"; return 1; }
  if cp_profile_is_native "$cfg" "$name"; then
    cp_warn "profile $name is native; log in with a plain 'claude auth login' (no CLAUDE_CONFIG_DIR)"
    return 1
  fi
  dir="$(cp_profile_dir "$cfg" "$name")"
  [ -n "$dir" ] || { cp_warn "profile $name has no directory"; return 1; }
  mkdir -p "$dir" || return 1
  chmod 700 "$dir" || return 1

  mkdir -p "$CP_STATE_DIR" || return 1
  chmod 700 "$CP_STATE_DIR" || return 1
  backup="$CP_STATE_DIR/keychain.bak"
  before="$(cp_keychain_read)"
  if [ -n "$before" ]; then
    ( umask 077; printf '%s' "$before" > "$backup" ) || return 1
    chmod 600 "$backup" || return 1
  fi

  CLAUDE_CONFIG_DIR="$dir" "$CP_CLAUDE_BIN" auth login --claudeai
  rc=$?

  after="$(cp_keychain_read)"
  if [ -n "$before" ] && [ "$after" != "$before" ]; then
    cp_warn 'login wrote to the shared keychain item instead of the profile directory'
    if cp_keychain_write "$before"; then
      cp_warn "keychain restored from $backup"
    else
      cp_warn "COULD NOT RESTORE THE KEYCHAIN. Recover manually from $backup"
    fi
    cp_warn 'per-profile logins are unsafe on this Claude Code version; aborting'
    return 1
  fi

  if [ ! -f "$dir/.credentials.json" ]; then
    cp_warn "login did not produce $dir/.credentials.json (claude exited $rc)"
    return 1
  fi
  chmod 600 "$dir/.credentials.json" 2>/dev/null
  printf 'logged in: %s\n' "$name"
  return 0
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
      printf '%s: not logged in - run: cprof login %s\n' "$name" "$name"
      status=1
      continue
    fi
    ms="$(cp_refresh_ms_left "$(cp_creds_file "$cfg" "$name")")"
    if [ -n "$ms" ] && [ "$ms" -lt 1209600000 ]; then
      left_days="$(( ms / 86400000 ))"
      printf '%s: refresh token expires in %s day(s) - re-run: cprof login %s\n' \
        "$name" "$left_days" "$name"
      status=1
    else
      printf '%s: ok\n' "$name"
    fi
  done
  printf 'active profile here: %s\n' "${active:-none}"
  return "$status"
}
