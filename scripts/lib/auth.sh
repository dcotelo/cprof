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

# cp_keychain_service <dir> -> the keychain service Claude Code uses for <dir>.
# It derives the name as "Claude Code-credentials-<sha256(CLAUDE_CONFIG_DIR)[0:8]>"
# whenever CLAUDE_CONFIG_DIR is set, and the bare service when it is not, so a
# native profile and each config dir get their own item. The hash covers the
# directory string as exported, not its resolved target.
cp_keychain_service() {
  local dir="${1:-}"
  if [ -z "$dir" ]; then
    printf '%s\n' "$CP_KEYCHAIN_SERVICE"
    return 0
  fi
  printf '%s-%s\n' "$CP_KEYCHAIN_SERVICE" \
    "$(printf '%s' "$dir" | shasum -a 256 | cut -c1-8)"
}

cp_keychain_read() {
  "$CP_SECURITY_BIN" find-generic-password -s "${1:-$CP_KEYCHAIN_SERVICE}" -a "${USER:-$(id -un)}" -w 2>/dev/null
}

# cp_creds_read <cfg> <name> -> the profile's credential JSON, or nothing.
# Claude Code before 2.1 wrote $CLAUDE_CONFIG_DIR/.credentials.json; 2.1 keeps
# the blob in a per-config-dir keychain item instead. Prefer the file, fall back
# to the keychain. Callers must pipe this straight into jq: letting the blob
# reach a variable would put a live OAuth token in the shell's environment.
cp_creds_read() {
  local file
  file="$(cp_creds_file "$1" "$2")"
  if [ -n "$file" ] && [ -f "$file" ]; then
    cat "$file"
    return 0
  fi
  if cp_profile_is_native "$1" "$2"; then
    cp_keychain_read
  else
    cp_keychain_read "$(cp_keychain_service "$(cp_profile_dir "$1" "$2")")"
  fi
}

# Milliseconds until the refresh token expires, or empty when unknown. An
# unreadable store is indistinguishable from one with no expiry recorded, and
# both stay silent rather than inventing a warning.
cp_refresh_ms_left() {
  local exp now
  exp="$(cp_creds_read "$1" "$2" | jq -r '.claudeAiOauth.refreshTokenExpiresAt // empty' 2>/dev/null)"
  case "$exp" in ''|*[!0-9]*) return 0 ;; esac
  now="$(( $(date +%s) * 1000 ))"
  printf '%s\n' "$(( exp - now ))"
}

cp_keychain_write() {
  "$CP_SECURITY_BIN" add-generic-password -U \
    -a "${USER:-$(id -un)}" -s "${2:-$CP_KEYCHAIN_SERVICE}" -w "$1" >/dev/null 2>&1
}

# cp_keychain_create <value> <service>: like cp_keychain_write but without -U,
# so an item that already exists makes the call fail (errSecDuplicateItem)
# instead of being overwritten. For the fallback backup: a recovery item must
# never be clobbered.
cp_keychain_create() {
  "$CP_SECURITY_BIN" add-generic-password \
    -a "${USER:-$(id -un)}" -s "${2:-$CP_KEYCHAIN_SERVICE}" -w "$1" >/dev/null 2>&1
}

# cp_keychain_status <service> -> 0 present, 1 absent, 2 could not tell. An
# empty cp_keychain_read is ambiguous — absent or failed — so callers that
# must know the difference (is there a backup or not?) use this: `security`
# exits 44 (errSecItemNotFound) for absent and something else for trouble.
cp_keychain_status() {
  "$CP_SECURITY_BIN" find-generic-password -s "${1:-$CP_KEYCHAIN_SERVICE}" \
    -a "${USER:-$(id -un)}" >/dev/null 2>&1
  case $? in
    0)  return 0 ;;
    44) return 1 ;;
    *)  return 2 ;;
  esac
}

cp_keychain_delete() {
  "$CP_SECURITY_BIN" delete-generic-password \
    -a "${USER:-$(id -un)}" -s "${1:-$CP_KEYCHAIN_SERVICE}" >/dev/null 2>&1
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

  # Where the credentials land depends on the Claude Code version: older ones
  # write $CLAUDE_CONFIG_DIR/.credentials.json, 2.1+ writes a keychain item
  # keyed by a hash of the config dir. Ask claude instead of guessing storage.
  if [ "$(cp_auth_status "$cfg" "$name" | jq -r '.loggedIn // false')" != 'true' ]; then
    cp_warn "login did not authenticate profile $name (claude exited $rc)"
    return 1
  fi
  [ -f "$dir/.credentials.json" ] && chmod 600 "$dir/.credentials.json" 2>/dev/null
  printf 'logged in: %s\n' "$name"
  return 0
}

cp_cmd_doctor() {
  local cfg names name st logged active ms left_days status=0 usage_data pct CP_COLOR_ON=0 resets problems skew sl_dir
  cfg="$(cp_config_read)" || return 1
  # cp_usage_render (usage.sh) reads CP_COLOR_ON through bash's dynamic
  # scoping, the same cross-file pattern cp_colorize already relies on.
  # shellcheck disable=SC2034
  cp_color_enabled && CP_COLOR_ON=1
  active="$(printf '%s' "$cfg" | cp_resolve 2>/dev/null | cut -f1)"
  names="$(printf '%s' "$cfg" | jq -r '.profiles[]?.name')"
  if [ -z "$names" ]; then
    printf 'no profiles configured\n'
    return 1
  fi
  # One line, one name (see cp_usage_list_all); fd 3 keeps `claude auth
  # status` and friends from reading the next name off stdin.
  while IFS= read -r -u 3 name; do
    st="$(cp_auth_status "$cfg" "$name")"
    logged="$(printf '%s' "$st" | jq -r '.loggedIn // false')"
    if [ "$logged" != 'true' ]; then
      printf '%s: not logged in - run: cprof login %s\n' "$name" "$name"
      cp_fallback_doctor_line "$name"
      status=1
      continue
    fi
    ms="$(cp_refresh_ms_left "$cfg" "$name")"
    if [ -n "$ms" ] && [ "$ms" -lt 1209600000 ]; then
      left_days="$(( ms / 86400000 ))"
      printf '%s: refresh token expires in %s day(s) - re-run: cprof login %s\n' \
        "$name" "$left_days" "$name"
      status=1
    else
      printf '%s: ok\n' "$name"
    fi
    usage_data="$(cp_usage_read "$cfg" "$name")"
    if [ -n "$usage_data" ]; then
      pct="$(cp_usage_pct "$usage_data" five_hour)"
      case "$pct" in
        ''|*[!0-9]*) : ;;
        *)
          # A stale cache (refetch failed) may describe a window that has
          # already reset; only an open window is worth an alarm.
          if [ "$pct" -ge 90 ] && resets="$(cp_usage_window_open "$usage_data" five_hour)"; then
            printf '%s: 5h window at %s (resets %s)\n' \
              "$name" "$(cp_usage_render "$pct")" "$resets"
            status=1
          fi
          ;;
      esac
    fi
    cp_fallback_doctor_line "$name"
  done 3<<< "$names"
  problems="$(cp_sl_config_problems "$cfg")"
  if [ -n "$problems" ]; then
    printf '%s\n' "$problems"
    status=1
  fi
  # Either half being the older one is a real defect in the install, not a
  # preference: each carries behaviour the other cannot supply — subcommands on
  # the CLI side, the hooks and statusline segment on the plugin side — so a
  # non-zero status means skew in either direction. A version it could not read
  # still prints but does not fail; a dev build is not a broken install.
  if ! skew="$(cp_skew_problems)"; then
    status=1
  fi
  [ -n "$skew" ] && printf '%s\n' "$skew"
  # Claude Code reads settings from the config directory of the profile a
  # session here would use, so that is the file worth reporting on.
  sl_dir="$(cp_profile_dir "$cfg" "${active:-}")"
  cp_sl_wiring_problems "${sl_dir:-$HOME/.claude}/settings.json"
  printf 'active profile here: %s\n' "${active:-none}"
  return "$status"
}
