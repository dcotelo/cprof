#!/usr/bin/env bash
# shellcheck shell=bash
# Per-profile usage: fetch from the OAuth usage endpoint, cache, read.

# CP_CURL_BIN follows the CP_CLAUDE_BIN / CP_SECURITY_BIN convention: a hook
# for the test suite's stubs. CP_USAGE_URL is likewise overridable, but a
# bearer token only ever goes to an https:// URL — see cp_usage_url_ok.
CP_CURL_BIN="${CP_CURL_BIN:-curl}"
CP_USAGE_URL="${CP_USAGE_URL:-https://api.anthropic.com/api/oauth/usage}"

cp_usage_url_ok() {
  case "$CP_USAGE_URL" in https://*) return 0 ;; *) return 1 ;; esac
}
CP_USAGE_TTL=300

# cp_usage_cache_file <name> -> path (may not exist)
cp_usage_cache_file() {
  printf '%s/usage/%s.json\n' "$CP_STATE_DIR" "$(cp_state_key "${1:-}")"
}

# cp_usage_valid <body> -> 0 when the body is a usage response worth caching:
# five_hour must be an object, and seven_day / limits — both optional, some
# plans return null — must be an object / an array when present. Anything
# else (an HTML error page, a 2xx with the wrong shape) is a fetch failure,
# so it can never replace a good cached value with one the renderers can't
# read.
cp_usage_valid() {
  printf '%s' "${1:-}" | jq -e '
    (.five_hour | type) == "object"
    and ((.seven_day == null) or ((.seven_day | type) == "object"))
    and ((.limits == null) or ((.limits | type) == "array"))
  ' >/dev/null 2>&1
}

# cp_usage_fetch <cfg> <name> -> usage JSON (with fetched_at merged in) on
# stdout and written to cache, or nothing with return 1. Never touches an
# existing cache on failure, so a blip never clobbers a good value with
# silence.
cp_usage_fetch() {
  local cfg="$1" name="$2" token body
  [ "${CPROF_NO_USAGE:-0}" = '1' ] && return 1
  cp_usage_url_ok || return 1
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
  cp_usage_valid "$body" || return 1
  cp_usage_cache_write "$name" "$body" || return 1
  cat "$(cp_usage_cache_file "$name")"
}

# cp_usage_cache_write <name> <body> -> stamps fetched_at on an already
# validated usage body and installs it atomically as <name>'s cache. Return 1
# leaves whatever cache was there untouched.
cp_usage_cache_write() {
  local name="$1" body="$2" file dir
  file="$(cp_usage_cache_file "$name")"
  dir="$(dirname "$file")"
  mkdir -p "$dir" 2>/dev/null || return 1
  chmod 700 "$CP_STATE_DIR" "$dir" 2>/dev/null
  printf '%s' "$body" | jq --argjson now "$(date +%s)" '. + {fetched_at: $now}' \
    > "$file.tmp.$$" 2>/dev/null || { rm -f "$file.tmp.$$"; return 1; }
  chmod 600 "$file.tmp.$$" 2>/dev/null || { rm -f "$file.tmp.$$"; return 1; }
  mv "$file.tmp.$$" "$file" 2>/dev/null || { rm -f "$file.tmp.$$"; return 1; }
}

# cp_usage_fetch_raw <token> -> usage JSON on stdout (fresh, from the live
# endpoint), or nothing with return 1. Unlike cp_usage_fetch, this takes an
# explicit token instead of resolving one via a profile, and never touches
# any cache file — for the fallback feature's confirming fetch, which must
# check a specific account's usage without conflating it with whatever
# profile name happens to be asking (during an active swap, the profile's
# own live credentials are the fallback's, not the account being checked).
cp_usage_fetch_raw() {
  local token="${1:-}" body
  # The opt-out means no token leaves this machine for usage data, whichever
  # path asks — including the fallback's confirming fetch.
  [ "${CPROF_NO_USAGE:-0}" = '1' ] && return 1
  cp_usage_url_ok || return 1
  [ -n "$token" ] || return 1
  body="$(printf 'header = "Authorization: Bearer %s"\nheader = "anthropic-beta: oauth-2025-04-20"\n' "$token" \
    | "$CP_CURL_BIN" -sS --max-time 2 -K - "$CP_USAGE_URL" 2>/dev/null)"
  [ -n "$body" ] || return 1
  cp_usage_valid "$body" || return 1
  printf '%s' "$body"
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
  printf '%s' "${1:-}" | jq -r --arg w "${2:-}" \
    '.[$w].utilization // empty | if type == "number" then (floor | tostring) else empty end' \
    2>/dev/null
}

cp_usage_resets_at() {
  printf '%s' "${1:-}" | jq -r --arg w "${2:-}" '.[$w].resets_at // empty' 2>/dev/null
}

# cp_usage_window_open <usage-json> <window> -> that window's resets_at on
# stdout when it parses AND lies in the future; nothing with return 1
# otherwise. Cached usage is served regardless of age, so a high number in
# it may describe a window that has since reset — not something to warn
# about or swap for. Shared by doctor, swap-out, and `which`.
cp_usage_window_open() {
  local resets_at epoch
  resets_at="$(cp_usage_resets_at "${1:-}" "${2:-five_hour}")"
  epoch="$(cp_time_epoch "$resets_at")" || return 1
  [ "$epoch" -gt "$(date +%s)" ] || return 1
  printf '%s\n' "$resets_at"
}

# cp_time_epoch <rfc3339> -> seconds since the epoch, or nothing with return
# 1. Accepts every RFC 3339 spelling a resets_at may come in: ...Z, a numeric
# offset (+HH:MM / -HH:MM), fractional seconds (2026-04-11T07:00:00.528743
# +00:00), or a bare UTC wall clock. macOS `date -j -f` handles neither the
# fraction nor the colon in the offset, so: drop the fraction, parse the
# wall-clock part as UTC, then apply the offset by hand.
cp_time_epoch() {
  local s="${1:-}" base off epoch hh mm
  case "$s" in
    '') return 1 ;;
    *Z) base="${s%Z}"; off='+00:00' ;;
    *[+-][0-9][0-9]:[0-9][0-9]) off="${s#"${s%??????}"}"; base="${s%??????}" ;;
    *) base="$s"; off='+00:00' ;;
  esac
  base="${base%%.*}"
  epoch="$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%S' "$base" +%s 2>/dev/null)" || return 1
  case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
  hh="${off:1:2}"; mm="${off:4:2}"
  case "$hh" in [01][0-9]|2[0-3]) ;; *) return 1 ;; esac
  case "$mm" in [0-5][0-9]) ;; *) return 1 ;; esac
  case "$off" in
    +*) epoch=$(( epoch - (10#$hh * 3600 + 10#$mm * 60) )) ;;
    -*) epoch=$(( epoch + (10#$hh * 3600 + 10#$mm * 60) )) ;;
  esac
  printf '%s\n' "$epoch"
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
    # One line, one name: a for-loop over $names would split "team alpha"
    # in two and expand "work*" against the cwd. Read from fd 3 so a
    # command in the body that touches stdin can't eat the next name.
    while IFS= read -r -u 3 name; do
      data="$(cp_usage_read "$cfg" "$name")"
      printf '%s\t%s\t%s\n' \
        "$(cp_colorize "$(cp_color_for "$cfg" "$name")" "$name")" \
        "$(cp_usage_render "$(cp_usage_pct "$data" five_hour)")" \
        "$(cp_usage_render "$(cp_usage_pct "$data" seven_day)")"
    done 3<<< "$names"
  } | cp_table
}

# One line per five_hour/seven_day window, then one per weekly_scoped limit.
cp_usage_detail() {
  local cfg="$1" name="$2" data pct resets count i display sc_pct sc_resets
  data="$(cp_usage_read "$cfg" "$name")"
  if [ -z "$data" ]; then
    cp_warn "$name: no usage data (not logged in, offline, or CPROF_NO_USAGE set)"
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
    # Same normalisation as cp_usage_pct: floor a fractional utilization, so
    # it reaches cp_usage_bar's plain-integer check as a number, not a "-".
    # The endpoint reports a scoped limit's usage as `percent` (the top-level
    # windows use `utilization`); accept either, floored like cp_usage_pct.
    sc_pct="$(printf '%s' "$data" | jq -r --argjson i "$i" \
      '[.limits[]? | select(.kind == "weekly_scoped")][$i] | (.percent // .utilization // empty)
       | if type == "number" then (floor | tostring) else empty end')"
    sc_resets="$(printf '%s' "$data" | jq -r --argjson i "$i" \
      '[.limits[]? | select(.kind == "weekly_scoped")][$i].resets_at // empty')"
    printf '%-22s %s  resets %s\n' "$display" "$(cp_usage_render "$sc_pct")" "${sc_resets:-unknown}"
    i=$(( i + 1 ))
  done
  return 0
}

# cp_usage_reset_in <reset-epoch> [<now-epoch>] -> "4h 37m", "37m" or "<1m";
# nothing, return 1, when the reset is not a future epoch.
cp_usage_reset_in() {
  local at="${1:-}" now="${2:-}" left h m
  case "$at" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$now" ] || now="$(date +%s)"
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  left=$(( at - now ))
  [ "$left" -gt 0 ] || return 1
  h=$(( left / 3600 )); m=$(( (left % 3600) / 60 ))
  if   [ "$h" -gt 0 ]; then printf '%sh %sm\n' "$h" "$m"
  elif [ "$m" -gt 0 ]; then printf '%sm\n' "$m"
  else printf '<1m\n'
  fi
}

# cp_usage_payload_fields: a Claude Code statusline payload on stdin ->
# "<context-pct>\t<five-hour-pct>\t<resets-at>". Context is the native
# used_percentage when Claude Code sends one (2.1.6+), else the current
# tokens over the window size; the 5-hour figure and its reset come from
# rate_limits.five_hour, resets_at as an epoch or an RFC 3339 string.
# Anything malformed yields empty fields, never an error.
cp_usage_payload_fields() {
  local payload
  payload="$(cat 2>/dev/null)"
  [ -n "$payload" ] || return 0
  printf '%s' "$payload" | jq -r '
    def pct(v): if (v|type) == "number" and v >= 0
                then (if v > 100 then 100 else v end | floor | tostring) else "" end;
    def ctx:
      (.context_window // {}) as $c
      | if ($c.used_percentage|type) == "number" and $c.used_percentage > 0
        then pct($c.used_percentage)
        elif ($c.context_window_size|type) == "number" and $c.context_window_size > 0
        then (($c.current_usage // {}) as $u
              | (($u.input_tokens // 0) + ($u.cache_creation_input_tokens // 0)
                 + ($u.cache_read_input_tokens // 0)) as $t
              | if $t > 0 then pct($t * 100 / $c.context_window_size) else "" end)
        else "" end;
    def reset:
      (.rate_limits.five_hour.resets_at // "") as $r
      | if ($r|type) == "number" then ($r|floor|tostring)
        elif ($r|type) == "string" then $r else "" end;
    [ctx, pct(.rate_limits.five_hour.used_percentage), reset] | @tsv
  ' 2>/dev/null
}

# cp_usage_render_fields <name> [--stdin] -> seven tab-separated fields, the
# statusline's rendering entry point via `cprof usage --render`:
#   1 five-hour pct  2 its bar  3 its SGR code  4 "resets in" text
#   5 context pct    6 its bar  7 its SGR code
# With --stdin, a Claude Code statusline payload on stdin supplies the live
# figures — context, and the 5-hour window of the account the session is
# actually running as, refreshed every tick. Stdin is read only on request:
# a caller whose stdin is an open pipe with nothing coming (a test runner, a
# script) must never block here. Without the flag, or with an empty or
# malformed payload, the 5-hour figure falls back to this profile's cache,
# cache-only (never fetches — see cp_usage_read_cached_only), so this never
# adds latency. Nothing at all when there is nothing to show; empty fields
# otherwise.
cp_usage_render_fields() {
  local name="${1:-}" cached pf pct='' bar='' code='' reset='' at='' c_pct='' c_bar='' c_code='' colour
  pf=''
  [ "${2:-}" = '--stdin' ] && [ ! -t 0 ] && pf="$(cp_usage_payload_fields)"
  c_pct="$(printf '%s' "$pf" | cut -f1)"
  pct="$(printf '%s' "$pf" | cut -f2)"
  at="$(printf '%s' "$pf" | cut -f3)"
  if [ -n "$pct" ]; then
    case "$at" in
      '') ;;
      *[!0-9]*) at="$(cp_time_epoch "$at")" || at='' ;;
    esac
    [ -z "$at" ] || reset="$(cp_usage_reset_in "$at")" || reset=''
  else
    cached="$(cp_usage_read_cached_only "$name")"
    [ -z "$cached" ] || pct="$(cp_usage_pct "$cached" five_hour)"
  fi
  if bar="$(cp_usage_bar "$pct")"; then
    colour="$(cp_usage_severity_colour "$pct")"
    code="$(cp_color_code "$colour")"
  else
    pct=''; bar=''; reset=''
  fi
  if c_bar="$(cp_usage_bar "$c_pct")"; then
    colour="$(cp_usage_severity_colour "$c_pct")"
    c_code="$(cp_color_code "$colour")"
  else
    c_pct=''; c_bar=''
  fi
  [ -n "$pct" ] || [ -n "$c_pct" ] || return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pct" "$bar" "$code" "$reset" "$c_pct" "$c_bar" "$c_code"
}

cp_cmd_usage() {
  local cfg name CP_COLOR_ON=0
  case "${1:-}" in
    --render) cp_usage_render_fields "${2:-}" "${3:-}"; return 0 ;;
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
