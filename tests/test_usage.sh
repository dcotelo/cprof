#!/usr/bin/env bash
set -u
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
# shellcheck source=/dev/null
. "$(dirname "$0")/../scripts/lib/config.sh"
# shellcheck source=/dev/null
. "$(dirname "$0")/../scripts/lib/resolve.sh"
# shellcheck source=/dev/null
. "$(dirname "$0")/../scripts/lib/profiles.sh"
# shellcheck source=/dev/null
. "$(dirname "$0")/../scripts/lib/auth.sh"
# shellcheck source=/dev/null
. "$(dirname "$0")/../scripts/lib/output.sh"
# shellcheck source=/dev/null
. "$(dirname "$0")/../scripts/lib/color.sh"
# shellcheck source=/dev/null
. "$(dirname "$0")/../scripts/lib/usage.sh"
CLI="$(cd "$(dirname "$0")/.." && pwd -P)/scripts/cprof"

mkdir -p "$CP_T_TMP/p"
cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","dir":"$CP_T_TMP/p"}],"rules":[],"repos":{}}
JSON
printf '{"claudeAiOauth":{"accessToken":"tok-work"}}' > "$CP_T_TMP/p/.credentials.json"
CFG="$(cp_config_read)"

# --- curl stub: success -------------------------------------------------
cat > "$CP_CURL_BIN" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"five_hour":{"utilization":42,"resets_at":"2026-09-14T18:30:00Z"},
 "seven_day":{"utilization":18,"resets_at":"2026-09-20T00:00:00Z"},
 "limits":[]}
JSON
STUB
chmod +x "$CP_CURL_BIN"

out="$(cp_usage_fetch "$CFG" work)"
assert_eq '42' "$(cp_usage_pct "$out" five_hour)" 'fetch returns five_hour utilization'
assert_eq '18' "$(cp_usage_pct "$out" seven_day)" 'fetch returns seven_day utilization'
assert_eq 'true' "$([ -f "$CP_T_TMP/state/usage/work.json" ] && echo true || echo false)" \
  'fetch writes the cache file'
perm="$(cd "$CP_T_TMP/state/usage" && ls -l work.json | cut -c1-10)"
assert_eq '-rw-------' "$perm" 'cache file is mode 600'

# --- TTL: a fresh cache is served without calling curl again -------------
rm -f "$CP_CURL_BIN"
out="$(cp_usage_read "$CFG" work)"
assert_eq '42' "$(cp_usage_pct "$out" five_hour)" 'fresh cache served without curl'

# --- TTL: an old cache triggers a refetch --------------------------------
cache="$CP_T_TMP/state/usage/work.json"
jq '.fetched_at = 1' "$cache" > "$cache.tmp" && mv "$cache.tmp" "$cache"
cat > "$CP_CURL_BIN" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"five_hour":{"utilization":91,"resets_at":"2026-09-14T20:00:00Z"},
 "seven_day":{"utilization":60,"resets_at":"2026-09-20T00:00:00Z"},
 "limits":[]}
JSON
STUB
chmod +x "$CP_CURL_BIN"
out="$(cp_usage_read "$CFG" work)"
assert_eq '91' "$(cp_usage_pct "$out" five_hour)" 'stale cache triggers a refetch'

# --- failure: curl fails, stale cache still served -----------------------
cat > "$CP_CURL_BIN" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$CP_CURL_BIN"
jq '.fetched_at = 1' "$cache" > "$cache.tmp" && mv "$cache.tmp" "$cache"
out="$(cp_usage_read "$CFG" work)"
assert_eq '91' "$(cp_usage_pct "$out" five_hour)" \
  'a failed refetch falls back to the stale cache'

# --- failure: curl fails, no cache at all --------------------------------
rm -f "$cache"
out="$(cp_usage_read "$CFG" work)"
assert_eq '' "$out" 'no network and no cache yields nothing'

# --- opt-out: CPROF_NO_USAGE never invokes curl --------------------------
cat > "$CP_CURL_BIN" <<'STUB'
#!/usr/bin/env bash
echo 'should not be called' >> "$CP_T_TMP/curl-called"
exit 1
STUB
chmod +x "$CP_CURL_BIN"
CPROF_NO_USAGE=1 out="$(CPROF_NO_USAGE=1 cp_usage_read "$CFG" work)"
assert_eq '' "$out" 'opt-out with no cache yields nothing'
assert_eq 'false' "$([ -f "$CP_T_TMP/curl-called" ] && echo true || echo false)" \
  'opt-out never invokes curl'

# --- no token: native/never-logged-in profile fails fast, no crash -------
cp_t_write_config <<JSON
{"default":"native","profiles":[{"name":"native","native":true}],"rules":[],"repos":{}}
JSON
CFG="$(cp_config_read)"
assert_fail cp_usage_fetch "$CFG" native

# --- cp_usage_bar: rounding and bounds ------------------------------------
assert_eq '▓▓▓▓░░░░░░' "$(cp_usage_bar 42)" 'bar rounds down under half'
assert_eq '▓▓▓▓▓░░░░░' "$(cp_usage_bar 45)" 'bar rounds half up at the boundary'
assert_eq '░░░░░░░░░░' "$(cp_usage_bar 0)"  'bar at 0%'
assert_eq '▓▓▓▓▓▓▓▓▓▓' "$(cp_usage_bar 100)" 'bar at 100%'
assert_eq '▓▓▓▓▓▓▓▓▓▓' "$(cp_usage_bar 250)" 'bar clamps above 100%'
assert_fail cp_usage_bar ''
assert_fail cp_usage_bar 'nope'

# --- cp_usage_severity_colour ----------------------------------------------
assert_eq 'green'  "$(cp_usage_severity_colour 42)" 'severity: green under 70'
assert_eq 'yellow' "$(cp_usage_severity_colour 70)" 'severity: yellow at 70'
assert_eq 'yellow' "$(cp_usage_severity_colour 89)" 'severity: yellow just under 90'
assert_eq 'red'    "$(cp_usage_severity_colour 90)" 'severity: red at 90'

# --- cp_usage_render: plain (CP_COLOR_ON unset/0) --------------------------
assert_eq '▓▓▓▓░░░░░░ 42%' "$(cp_usage_render 42)" 'render is plain text without CP_COLOR_ON'
assert_eq '-' "$(cp_usage_render '')" 'render shows a dash for empty input'

# --- cp_usage_render: colored ----------------------------------------------
CP_COLOR_ON=1 assert_eq "$(printf '\033[32m▓▓▓▓░░░░░░ 42%%\033[0m')" \
  "$(CP_COLOR_ON=1 cp_usage_render 42)" 'render colors green under 70'
assert_eq "$(printf '\033[31m▓▓▓▓▓▓▓▓▓▓ 95%%\033[0m')" \
  "$(CP_COLOR_ON=1 cp_usage_render 95)" 'render colors red at 95'

# --- cprof usage: no profiles --------------------------------------------
cp_t_write_config <<JSON
{"default":null,"profiles":[],"rules":[],"repos":{}}
JSON
assert_eq 'no profiles saved' "$("$CLI" usage 2>/dev/null)" 'usage with no profiles saved'

# --- cprof usage: table of all profiles ----------------------------------
mkdir -p "$CP_T_TMP/p"
cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","dir":"$CP_T_TMP/p"}],"rules":[],"repos":{}}
JSON
printf '{"claudeAiOauth":{"accessToken":"tok-work"}}' > "$CP_T_TMP/p/.credentials.json"
cat > "$CP_CURL_BIN" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"five_hour":{"utilization":42,"resets_at":"2026-09-14T18:30:00Z"},
 "seven_day":{"utilization":18,"resets_at":"2026-09-20T00:00:00Z"},
 "limits":[{"kind":"weekly_scoped","utilization":55,
            "resets_at":"2026-09-20T00:00:00Z",
            "scope":{"model":{"display_name":"Claude Opus 4.5"}}}]}
JSON
STUB
chmod +x "$CP_CURL_BIN"
out="$(NO_COLOR=1 "$CLI" usage 2>/dev/null)"
case "$out" in
  *'work'*'42%'*'18%'*) assert_eq ok ok 'usage table shows both windows' ;;
  *) assert_eq 'work ... 42% ... 18%' "$out" 'usage table shows both windows' ;;
esac

# --- cprof usage <name>: full breakdown ----------------------------------
out="$(NO_COLOR=1 "$CLI" usage work 2>/dev/null)"
case "$out" in *'42%'*) assert_eq ok ok 'usage detail shows 5h' ;;
                *) assert_eq '42%' "$out" 'usage detail shows 5h' ;; esac
case "$out" in *'18%'*) assert_eq ok ok 'usage detail shows 7d' ;;
                *) assert_eq '18%' "$out" 'usage detail shows 7d' ;; esac
case "$out" in *'Claude Opus 4.5'*'55%'*) assert_eq ok ok 'usage detail shows weekly_scoped model' ;;
                *) assert_eq 'Claude Opus 4.5 ... 55%' "$out" 'usage detail shows weekly_scoped model' ;; esac

# --- cprof usage <unknown> -------------------------------------------------
assert_fail "$CLI" usage nope

cp_t_summary
