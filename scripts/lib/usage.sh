#!/usr/bin/env bash
# shellcheck shell=bash
# Per-profile usage: fetch from the OAuth usage endpoint, cache, read.

CP_CURL_BIN="${CP_CURL_BIN:-curl}"
CP_USAGE_URL="${CP_USAGE_URL:-https://api.anthropic.com/api/oauth/usage}"
CP_USAGE_TTL=300

# cp_usage_cache_file <name> -> path (may not exist)
cp_usage_cache_file() {
  printf '%s/usage/%s.json\n' "$CP_STATE_DIR" "${1:-}"
}

# cp_usage_fetch <cfg> <name> -> usage JSON (with fetched_at merged in) on
# stdout and written to cache, or nothing with return 1. Never touches an
# existing cache on failure, so a blip never clobbers a good value with
# silence.
cp_usage_fetch() {
  local cfg="$1" name="$2" token body file dir
  token="$(cp_creds_read "$cfg" "$name" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)"
  [ -n "$token" ] || return 1
  # The token has to sit in this local variable to build curl's stdin config
  # block; that is still far better than argv (invisible to `ps`), but it is
  # not the "pipe straight into jq" discipline cp_creds_read normally keeps.
  # See docs/security-assessment.md.
  body="$(printf 'header = "Authorization: Bearer %s"\nheader = "anthropic-beta: oauth-2025-04-20"\n' "$token" \
    | "$CP_CURL_BIN" -sS --max-time 2 -K - "$CP_USAGE_URL" 2>/dev/null)"
  unset token
  [ -n "$body" ] || return 1
  printf '%s' "$body" | jq -e '.five_hour' >/dev/null 2>&1 || return 1
  file="$(cp_usage_cache_file "$name")"
  dir="$(dirname "$file")"
  mkdir -p "$dir" || return 1
  chmod 700 "$CP_STATE_DIR" "$dir" 2>/dev/null
  printf '%s' "$body" | jq --argjson now "$(date +%s)" '. + {fetched_at: $now}' \
    > "$file.tmp.$$" 2>/dev/null || { rm -f "$file.tmp.$$"; return 1; }
  chmod 600 "$file.tmp.$$" && mv "$file.tmp.$$" "$file" || { rm -f "$file.tmp.$$"; return 1; }
  cat "$file"
}

# cp_usage_read <cfg> <name> -> cached JSON if fresh, else refetches, else
# falls back to a stale cache, else nothing (return 1).
cp_usage_read() {
  local cfg="$1" name="$2" file fetched_at age
  if [ "${CPROF_NO_USAGE:-0}" = '1' ]; then
    cp_usage_read_cached_only "$name"
    return $?
  fi
  file="$(cp_usage_cache_file "$name")"
  if [ -f "$file" ]; then
    fetched_at="$(jq -r '.fetched_at // 0' "$file" 2>/dev/null)"
    case "$fetched_at" in ''|*[!0-9]*) fetched_at=0 ;; esac
    age=$(( $(date +%s) - fetched_at ))
    if [ "$age" -lt "$CP_USAGE_TTL" ]; then
      cat "$file"
      return 0
    fi
  fi
  if cp_usage_fetch "$cfg" "$name"; then
    return 0
  fi
  [ -f "$file" ] && cat "$file"
}

# cp_usage_read_cached_only <name> -> cached JSON regardless of age, or
# nothing. Never fetches. This is the statusline's only entry point.
cp_usage_read_cached_only() {
  local file
  file="$(cp_usage_cache_file "${1:-}")"
  [ -f "$file" ] && cat "$file"
}

cp_usage_pct() {
  printf '%s' "${1:-}" | jq -r --arg w "${2:-}" '.[$w].utilization // empty' 2>/dev/null
}

cp_usage_resets_at() {
  printf '%s' "${1:-}" | jq -r --arg w "${2:-}" '.[$w].resets_at // empty' 2>/dev/null
}
