#!/usr/bin/env bash
# shellcheck shell=bash
# Config file ownership: paths, read/validate/write, profile field lookups.

# The tool was called claudeprofile before 0.4.0. An explicit path always wins,
# under either variable name, so an existing setup keeps working; otherwise the
# default is the new path and anything at the old one is adopted below.
CP_CONFIG_PATH="${CPROF_CONFIG:-${CLAUDEPROFILE_CONFIG:-$HOME/.cprof.json}}"
CP_CONFIG_LEGACY="$HOME/.claudeprofile.json"
# CP_STATE_DIR and CP_KEYCHAIN_SERVICE are consumed by lib/auth.sh.
# shellcheck disable=SC2034
CP_STATE_DIR="${CPROF_STATE_DIR:-${CLAUDEPROFILE_STATE_DIR:-$HOME/.cprof}}"

# Moves a pre-rename config to the current path, once. Moving rather than copying:
# two files would drift, and a write landing in the one the tool no longer reads
# is a silently lost change. Only ever runs for the default path — an explicit
# CPROF_CONFIG is taken literally.
cp_config_migrate() {
  [ "$CP_CONFIG_PATH" = "$HOME/.cprof.json" ] || return 0
  [ ! -e "$CP_CONFIG_PATH" ] || return 0
  [ -f "$CP_CONFIG_LEGACY" ] || return 0
  if mv "$CP_CONFIG_LEGACY" "$CP_CONFIG_PATH" 2>/dev/null; then
    cp_warn "moved $CP_CONFIG_LEGACY to $CP_CONFIG_PATH (claudeprofile is now cprof)"
  else
    cp_warn "could not move $CP_CONFIG_LEGACY to $CP_CONFIG_PATH; still reading the old path"
    CP_CONFIG_PATH="$CP_CONFIG_LEGACY"
  fi
}
# shellcheck disable=SC2034
CP_KEYCHAIN_SERVICE="Claude Code-credentials"

cp_warn() {
  printf 'cprof: %s\n' "$1" >&2
}

cp_have_jq() {
  command -v jq >/dev/null 2>&1
}

cp_config_default() {
  printf '%s\n' '{"default":null,"profiles":[],"rules":[],"repos":{}}'
}

# stdout: config JSON. Returns 1 when the config exists but is unusable.
cp_config_read() {
  cp_config_migrate
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
