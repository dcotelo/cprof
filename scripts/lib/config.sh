#!/usr/bin/env bash
# shellcheck shell=bash
# Config file ownership: paths, read/validate/write, profile field lookups.

CP_CONFIG_PATH="${CLAUDEPROFILE_CONFIG:-$HOME/.claudeprofile.json}"
# CP_STATE_DIR and CP_KEYCHAIN_SERVICE are consumed by lib/auth.sh.
# shellcheck disable=SC2034
CP_STATE_DIR="${CLAUDEPROFILE_STATE_DIR:-$HOME/.claudeprofile}"
# shellcheck disable=SC2034
CP_KEYCHAIN_SERVICE="Claude Code-credentials"

cp_warn() {
  printf 'claudeprofile: %s\n' "$1" >&2
}

cp_have_jq() {
  command -v jq >/dev/null 2>&1
}

cp_config_default() {
  printf '%s\n' '{"default":null,"profiles":[],"rules":[],"repos":{}}'
}

# stdout: config JSON. Returns 1 when the config exists but is unusable.
cp_config_read() {
  if [ ! -f "$CP_CONFIG_PATH" ]; then
    cp_config_default
    return 0
  fi
  if ! cp_have_jq; then
    cp_warn "jq not found; ignoring $CP_CONFIG_PATH"
    return 1
  fi
  if ! jq -e . "$CP_CONFIG_PATH" >/dev/null 2>&1; then
    cp_warn "malformed config $CP_CONFIG_PATH; ignoring"
    return 1
  fi
  cat "$CP_CONFIG_PATH"
}

# stdin: config JSON. Writes atomically, refusing invalid JSON.
cp_config_write() {
  local tmp
  mkdir -p "$(dirname "$CP_CONFIG_PATH")" || return 1
  tmp="$CP_CONFIG_PATH.tmp.$$"
  if ! jq -S . > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    cp_warn 'refusing to write invalid JSON to config'
    return 1
  fi
  mv "$tmp" "$CP_CONFIG_PATH"
}

cp_expand() {
  # The tilde is held in a variable so it stays a literal pattern character
  # rather than something the shell (or shellcheck) reads as an expansion.
  local tilde='~'
  case "$1" in
    "$tilde")   printf '%s\n' "$HOME" ;;
    "$tilde"/*) printf '%s\n' "$HOME/${1#"$tilde"/}" ;;
    *)          printf '%s\n' "$1" ;;
  esac
}

# cp_profile_exists <cfg> <name>
cp_profile_exists() {
  printf '%s' "$1" | jq -e --arg n "$2" '.profiles[]? | select(.name == $n)' >/dev/null 2>&1
}

# cp_profile_field <cfg> <name> <field>
cp_profile_field() {
  printf '%s' "$1" | jq -r --arg n "$2" --arg f "$3" \
    '(.profiles[]? | select(.name == $n) | .[$f]) // empty' 2>/dev/null
}

cp_profile_is_native() {
  [ "$(cp_profile_field "$1" "$2" native)" = 'true' ]
}

# Expanded directory, or empty for a native profile.
cp_profile_dir() {
  local d
  d="$(cp_profile_field "$1" "$2" dir)"
  [ -n "$d" ] || return 0
  cp_expand "$d"
}
