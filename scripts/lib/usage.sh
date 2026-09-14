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

# cp_usage_bar <pct> -> a 10-block bar, or nothing with return 1 when pct
# isn't a plain integer.
cp_usage_bar() {
  local pct="${1:-}" filled empty bar
  case "$pct" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pct" -gt 100 ] && pct=100
  filled=$(( (pct + 5) / 10 ))
  [ "$filled" -gt 10 ] && filled=10
  empty=$(( 10 - filled ))
  bar=''
  while [ "$filled" -gt 0 ]; do bar="${bar}▓"; filled=$(( filled - 1 )); done
  while [ "$empty" -gt 0 ]; do bar="${bar}░"; empty=$(( empty - 1 )); done
  printf '%s\n' "$bar"
}

# cp_usage_severity_colour <pct> -> red|yellow|green, or nothing/return 1.
cp_usage_severity_colour() {
  local pct="${1:-}"
  case "$pct" in ''|*[!0-9]*) return 1 ;; esac
  if   [ "$pct" -ge 90 ]; then printf 'red\n'
  elif [ "$pct" -ge 70 ]; then printf 'yellow\n'
  else printf 'green\n'
  fi
}

# cp_usage_render <pct> -> "<bar> <pct>%", colored when CP_COLOR_ON=1, "-"
# when pct is invalid or empty. Reads CP_COLOR_ON the same way cp_colorize
# does: callers building table rows decide it once, up front.
cp_usage_render() {
  local pct="${1:-}" bar colour code
  bar="$(cp_usage_bar "$pct")" || { printf -- '-\n'; return 0; }
  colour="$(cp_usage_severity_colour "$pct")"
  code="$(cp_color_code "$colour")"
  if [ "${CP_COLOR_ON:-0}" = '1' ] && [ -n "$code" ]; then
    printf '\033[%sm%s %s%%\033[0m\n' "$code" "$bar" "$pct"
  else
    printf '%s %s%%\n' "$bar" "$pct"
  fi
}

cp_usage_list_all() {
  local cfg="$1" names name data
  names="$(printf '%s' "$cfg" | jq -r '.profiles[]?.name')"
  if [ -z "$names" ]; then
    printf 'no profiles saved\n'
    return 0
  fi
  {
    printf 'PROFILE\t5H\t7D\n'
    for name in $names; do
      data="$(cp_usage_read "$cfg" "$name")"
      printf '%s\t%s\t%s\n' \
        "$(cp_colorize "$(cp_color_for "$cfg" "$name")" "$name")" \
        "$(cp_usage_render "$(cp_usage_pct "$data" five_hour)")" \
        "$(cp_usage_render "$(cp_usage_pct "$data" seven_day)")"
    done
  } | cp_table
}

# One line per five_hour/seven_day window, then one per weekly_scoped limit.
cp_usage_detail() {
  local cfg="$1" name="$2" data pct resets count i display sc_pct sc_resets
  data="$(cp_usage_read "$cfg" "$name")"
  if [ -z "$data" ]; then
    printf '%s: no usage data (not logged in, offline, or CPROF_NO_USAGE set)\n' "$name"
    return 1
  fi
  pct="$(cp_usage_pct "$data" five_hour)"
  resets="$(cp_usage_resets_at "$data" five_hour)"
  printf '5h    %s  resets %s\n' "$(cp_usage_render "$pct")" "${resets:-unknown}"
  pct="$(cp_usage_pct "$data" seven_day)"
  resets="$(cp_usage_resets_at "$data" seven_day)"
  printf '7d    %s  resets %s\n' "$(cp_usage_render "$pct")" "${resets:-unknown}"
  count="$(printf '%s' "$data" | jq '[.limits[]? | select(.kind == "weekly_scoped")] | length' 2>/dev/null)"
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  i=0
  while [ "$i" -lt "$count" ]; do
    display="$(printf '%s' "$data" | jq -r --argjson i "$i" \
      '[.limits[]? | select(.kind == "weekly_scoped")][$i].scope.model.display_name // "unknown model"')"
    sc_pct="$(printf '%s' "$data" | jq -r --argjson i "$i" \
      '[.limits[]? | select(.kind == "weekly_scoped")][$i].utilization // empty')"
    sc_resets="$(printf '%s' "$data" | jq -r --argjson i "$i" \
      '[.limits[]? | select(.kind == "weekly_scoped")][$i].resets_at // empty')"
    printf '%-22s %s  resets %s\n' "$display" "$(cp_usage_render "$sc_pct")" "${sc_resets:-unknown}"
    i=$(( i + 1 ))
  done
  return 0
}

cp_usage_render_fields() { :; }

cp_cmd_usage() {
  local cfg name CP_COLOR_ON=0
  case "${1:-}" in
    --render) cp_usage_render_fields "${2:-}"; return 0 ;;
  esac
  cfg="$(cp_config_read)" || return 1
  # shellcheck disable=SC2034
  cp_color_enabled && CP_COLOR_ON=1
  name="${1:-}"
  if [ -z "$name" ]; then
    cp_usage_list_all "$cfg"
    return $?
  fi
  cp_profile_exists "$cfg" "$name" || { cp_warn "unknown profile $name"; return 1; }
  cp_usage_detail "$cfg" "$name"
}
