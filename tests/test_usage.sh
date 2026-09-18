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

# --- curl stub: success, only if invoked with -K - and both headers ------
cat > "$CP_CURL_BIN" <<'STUB'
#!/usr/bin/env bash
config="$(cat)"
case " $* " in *' -K - '*) : ;; *) exit 1 ;; esac
case " $* " in *' https://api.anthropic.com/api/oauth/usage '*) : ;; *) exit 1 ;; esac
case "$config" in *'Authorization: Bearer '*) : ;; *) exit 1 ;; esac
case "$config" in *'anthropic-beta: oauth-2025-04-20'*) : ;; *) exit 1 ;; esac
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
perm="$(stat -f '%Lp' "$CP_T_TMP/state/usage/work.json")"
assert_eq '600' "$perm" 'cache file is mode 600'

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

# --- failure: malformed (non-JSON) body, stale cache untouched -----------
cat > "$CP_CURL_BIN" <<'STUB'
#!/usr/bin/env bash
printf '<html>502 Bad Gateway</html>'
STUB
chmod +x "$CP_CURL_BIN"
before="$(cat "$cache")"
out="$(cp_usage_read "$CFG" work)"
assert_eq '91' "$(cp_usage_pct "$out" five_hour)" \
  'a malformed response falls back to the stale cache'
assert_eq "$before" "$(cat "$cache")" 'a malformed response leaves the cache file unchanged'

# --- failure: JSON with the wrong shape is a fetch failure too -----------
cat > "$CP_CURL_BIN" <<'STUB'
#!/usr/bin/env bash
printf '{"five_hour":{"utilization":5},"seven_day":"nope","limits":{}}'
STUB
chmod +x "$CP_CURL_BIN"
out="$(cp_usage_read "$CFG" work)"
assert_eq '91' "$(cp_usage_pct "$out" five_hour)" \
  'a wrongly shaped response falls back to the stale cache'
assert_eq "$before" "$(cat "$cache")" 'a wrongly shaped response leaves the cache file unchanged'
cat > "$CP_CURL_BIN" <<'STUB'
#!/usr/bin/env bash
printf '{"five_hour":"91%%"}'
STUB
chmod +x "$CP_CURL_BIN"
out="$(cp_usage_read "$CFG" work)"
assert_eq "$before" "$(cat "$cache")" 'a non-object five_hour leaves the cache file unchanged'
assert_eq '91' "$(cp_usage_pct "$out" five_hour)" 'a non-object five_hour still serves the stale 91%'

# --- success: seven_day and limits are optional, only their shape is checked
cat > "$CP_CURL_BIN" <<'STUB'
#!/usr/bin/env bash
printf '{"five_hour":{"utilization":12,"resets_at":"2026-09-14T20:00:00Z"},"seven_day":null}'
STUB
chmod +x "$CP_CURL_BIN"
out="$(cp_usage_read "$CFG" work)"
assert_eq '12' "$(cp_usage_pct "$out" five_hour)" \
  'a response without seven_day/limits is still accepted'
jq '.fetched_at = 1 | .five_hour.utilization = 91' "$cache" > "$cache.tmp" && mv "$cache.tmp" "$cache"
cat > "$CP_CURL_BIN" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$CP_CURL_BIN"

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
out="$(CPROF_NO_USAGE=1 cp_usage_read "$CFG" work)"
assert_eq '' "$out" 'opt-out with no cache yields nothing'
assert_eq 'false' "$([ -f "$CP_T_TMP/curl-called" ] && echo true || echo false)" \
  'opt-out never invokes curl'

# --- opt-out: an existing cache is still served, however old ------------
mkdir -p "$CP_T_TMP/state/usage"
cat > "$cache" <<'JSON'
{"fetched_at":1,"five_hour":{"utilization":64,"resets_at":"2026-09-14T18:30:00Z"},
 "seven_day":{"utilization":20,"resets_at":"2026-09-20T00:00:00Z"},"limits":[]}
JSON
out="$(CPROF_NO_USAGE=1 cp_usage_read "$CFG" work)"
assert_eq '64' "$(cp_usage_pct "$out" five_hour)" 'opt-out serves the cached value'
assert_eq 'false' "$([ -f "$CP_T_TMP/curl-called" ] && echo true || echo false)" \
  'opt-out with a stale cache still never invokes curl'
rm -f "$cache"

# --- cache paths: a profile name can never address a file outside usage/ ---
assert_eq 'work' "$(cp_state_key work)" 'a plain name is its own state key'
assert_eq 'a.b_c-d' "$(cp_state_key a.b_c-d)" 'dots, underscores and dashes pass through'
key="$(cp_state_key '../../escape')"
case "$key" in *..*|*/*) assert_eq 'no slash or dotdot' "$key" 'a traversal name is hashed' ;;
                 *) assert_eq ok ok 'a traversal name is hashed' ;; esac
case "$(cp_state_key 'team alpha')" in *' '*) assert_eq 'no space' "$(cp_state_key 'team alpha')" 'a name with a space is hashed' ;;
                                         *) assert_eq ok ok 'a name with a space is hashed' ;; esac
assert_eq "$(cp_state_key '../../escape')" "$(cp_state_key '../../escape')" 'the hashed key is stable'
# a plain name that looks like a hashed key is hashed too, so no two names
# can ever share a state file
hk="$(cp_state_key 'team alpha')"
case "$hk" in h-*) assert_eq ok ok 'hashed keys carry the h- prefix' ;; *) assert_eq 'h-...' "$hk" 'hashed keys carry the h- prefix' ;; esac
assert_eq 'false' "$([ "$(cp_state_key "$hk")" = "$hk" ] && echo true || echo false)" \
  'a name spelled like another name'"'"'s hashed key does not collide with it'
case "$(cp_state_key 'h-work')" in h-work) assert_eq 'hashed' 'h-work' 'a plain name starting with h- is hashed' ;;
                                    h-*) assert_eq ok ok 'a plain name starting with h- is hashed' ;;
                                    *) assert_eq 'h-<hash>' "$(cp_state_key 'h-work')" 'a plain name starting with h- is hashed' ;; esac
assert_eq "$CP_T_TMP/state/usage/$(cp_state_key '../../escape').json" \
  "$(cp_usage_cache_file '../../escape')" 'the cache file for a hostile name stays under usage/'
case "$(cp_usage_cache_file '../../escape')" in
  "$CP_T_TMP/state/usage/"*) assert_eq ok ok 'hostile cache path is inside the state dir' ;;
  *) assert_eq "$CP_T_TMP/state/usage/..." "$(cp_usage_cache_file '../../escape')" 'hostile cache path is inside the state dir' ;;
esac

# --- no token: native/never-logged-in profile fails fast, no crash -------
cp_t_write_config <<JSON
{"default":"native","profiles":[{"name":"native","native":true}],"rules":[],"repos":{}}
JSON
CFG="$(cp_config_read)"
assert_fail cp_usage_fetch "$CFG" native

# --- cp_time_epoch: the endpoint's RFC 3339 timestamps, in every spelling --
assert_eq '1902700800' "$(cp_time_epoch '2030-04-18T00:00:00Z')" 'Z suffix parses as UTC'
assert_eq '1902700800' "$(cp_time_epoch '2030-04-18T00:00:00.528743+00:00')" 'fractional seconds and +00:00 parse'
assert_eq '1902700800' "$(cp_time_epoch '2030-04-18T02:00:00+02:00')" 'a positive offset is applied'
assert_eq '1902700800' "$(cp_time_epoch '2030-04-17T19:00:00-05:00')" 'a negative offset is applied'
assert_eq '1902700800' "$(cp_time_epoch '2030-04-18T00:00:00')" 'no zone is read as UTC'
assert_fail cp_time_epoch 'not-a-time'
assert_fail cp_time_epoch ''
assert_fail cp_time_epoch '2030-04-18'
assert_fail cp_time_epoch '2030-04-18T00:00:00+99:99'
assert_fail cp_time_epoch '2030-04-18T00:00:00-25:00'
assert_fail cp_time_epoch '2030-04-18T00:00:00+05:60'
assert_eq '1902700800' "$(cp_time_epoch '2030-04-18T23:59:00+23:59')" 'the largest valid offset is accepted'

# --- cp_usage_window_open: only a parseable, future resets_at counts -------
assert_eq '2030-01-01T00:00:00Z' "$(cp_usage_window_open '{"five_hour":{"resets_at":"2030-01-01T00:00:00Z"}}' five_hour)" \
  'an open window returns its resets_at'
assert_fail cp_usage_window_open '{"five_hour":{"resets_at":"2020-01-01T00:00:00Z"}}' five_hour
assert_fail cp_usage_window_open '{"five_hour":{"utilization":92}}' five_hour

# --- cp_usage_bar: rounding and bounds ------------------------------------
assert_eq '▓▓▓▓░░░░░░' "$(cp_usage_bar 42)" 'bar rounds down under half'
assert_eq '▓▓▓▓▓░░░░░' "$(cp_usage_bar 45)" 'bar rounds half up at the boundary'
assert_eq '░░░░░░░░░░' "$(cp_usage_bar 0)"  'bar at 0%'
assert_eq '▓▓▓▓▓▓▓▓▓▓' "$(cp_usage_bar 100)" 'bar at 100%'
assert_eq '▓▓▓▓▓▓▓▓▓▓' "$(cp_usage_bar 250)" 'bar clamps above 100%'
assert_fail cp_usage_bar ''
assert_fail cp_usage_bar 'nope'

# --- the bar's glyphs and width are parameters, with today's defaults -------
assert_eq '▓▓▓░░░░░░░' "$(cp_usage_bar 30)" 'one argument still means cprof own ten-cell bar'
assert_eq '███░░░░░░░' "$(cp_usage_bar 30 '█' '░' 10)" 'the filled glyph is a parameter'
assert_eq '██·······' "$(cp_usage_bar 25 '█' '·' 9)" 'the empty glyph and the width are parameters'
assert_eq '█████' "$(cp_usage_bar 100 '█' '·' 5)" 'a full bar at any width is all filled'
assert_eq '·····' "$(cp_usage_bar 0 '█' '·' 5)" 'an empty bar at any width is all empty'
assert_eq '██' "$(cp_usage_bar 100 '█' '·' 2)" 'a two-cell bar still rounds to full'
# assert_fail forwards every argument to the command, so a description here
# would be a sixth argument to cp_usage_bar, not a label. Same line, comment.
assert_fail cp_usage_bar 'x' '█' '·' 5   # a non-numeric percentage still fails at a configured width

# --- cp_usage_pct: floors a fractional utilization instead of passing it
# through raw, which would fail cp_usage_bar/render's plain-integer check
# and silently degrade every UI surface to "-" ------------------------------
frac='{"five_hour":{"utilization":42.7}}'
assert_eq '42' "$(cp_usage_pct "$frac" five_hour)" 'pct floors a fractional utilization'
assert_eq '▓▓▓▓░░░░░░' "$(cp_usage_bar "$(cp_usage_pct "$frac" five_hour)")" \
  'floored fractional pct renders via cp_usage_bar'
assert_eq '▓▓▓▓░░░░░░ 42%' "$(cp_usage_render "$(cp_usage_pct "$frac" five_hour)")" \
  'floored fractional pct renders via cp_usage_render'

# --- cp_usage_severity_colour ----------------------------------------------
assert_eq 'green'  "$(cp_usage_severity_colour 42)" 'severity: green under 70'
assert_eq 'yellow' "$(cp_usage_severity_colour 70)" 'severity: yellow at 70'
assert_eq 'yellow' "$(cp_usage_severity_colour 89)" 'severity: yellow just under 90'
assert_eq 'red'    "$(cp_usage_severity_colour 90)" 'severity: red at 90'

# --- severity thresholds are parameters, with today's defaults -------------
assert_eq 'green'  "$(cp_usage_severity_colour 69)" 'below warn is green by default'
assert_eq 'yellow' "$(cp_usage_severity_colour 70)" 'warn is inclusive by default'
assert_eq 'red'    "$(cp_usage_severity_colour 90)" 'critical is inclusive by default'
assert_eq 'yellow' "$(cp_usage_severity_colour 50 50 80)" 'a configured warn is inclusive'
assert_eq 'green'  "$(cp_usage_severity_colour 49 50 80)" 'below a configured warn is green'
assert_eq 'red'    "$(cp_usage_severity_colour 80 50 80)" 'a configured critical is inclusive'
assert_fail cp_usage_severity_colour '' 50 80   # an empty percentage still fails against configured thresholds

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
 "limits":[{"kind":"weekly_scoped","percent":55.7,
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
case "$out" in *'Claude Opus 4.5'*'▓▓▓▓▓▓░░░░ 55%'*) assert_eq ok ok 'usage detail floors a fractional weekly_scoped utilization to its bar and percentage' ;;
                *) assert_eq 'Claude Opus 4.5 ... ▓▓▓▓▓▓░░░░ 55%' "$out" 'usage detail floors a fractional weekly_scoped utilization to its bar and percentage' ;; esac

# --- contract: the live endpoint's shape (paths captured from a real
# logged-in response on 2026-09-16, values synthetic). Top-level windows use
# `utilization`; limits[] entries use `percent` and come in kinds session,
# weekly_all, weekly_scoped; five_hour may carry no resets_at while the
# window is idle; extra_usage / spend / seven_day_breakdown ride along. ------
live='{"five_hour":{"utilization":41},
 "seven_day":{"utilization":23,"resets_at":"2030-01-05T00:00:00Z"},
 "limits":[{"group":"a","kind":"session","percent":41,"resets_at":"2030-01-01T18:00:00Z","severity":"ok"},
           {"group":"b","kind":"weekly_all","percent":23,"resets_at":"2030-01-05T00:00:00Z","severity":"ok","is_active":true},
           {"group":"c","kind":"weekly_scoped","percent":67.4,"resets_at":"2030-01-05T00:00:00Z","severity":"ok","is_active":true,
            "scope":{"model":{"display_name":"Claude Opus 5"}}}],
 "seven_day_breakdown":{"as_of":"2030-01-01T00:00:00Z","window_started_at":"2029-12-29T00:00:00Z",
   "rows":[{"display_name":"Claude Opus 5","key":"opus","percent":20}]},
 "extra_usage":{"credits_ever_enabled":false,"currency":"USD","decimal_places":2,"disabled_reason":null,"monthly_limit":0,"used_credits":0,"utilization":0},
 "nimbus_quill":{"utilization":0},
 "spend":{"disclaimer":"x","percent":0,"severity":"ok","used":{"amount_minor":0,"currency":"USD","exponent":2}}}'
assert_ok cp_usage_valid "$live"
assert_eq '41' "$(cp_usage_pct "$live" five_hour)" 'live shape: five_hour utilization reads'
assert_eq '23' "$(cp_usage_pct "$live" seven_day)" 'live shape: seven_day utilization reads'
assert_fail cp_usage_window_open "$live" five_hour
cat > "$CP_CURL_BIN" <<STUB
#!/usr/bin/env bash
printf '%s' '$live'
STUB
chmod +x "$CP_CURL_BIN"
rm -f "$CP_T_TMP/state/usage/work.json"
out="$(NO_COLOR=1 "$CLI" usage work 2>/dev/null)"
case "$out" in *'Claude Opus 5'*'▓▓▓▓▓▓▓░░░ 67%'*) assert_eq ok ok 'live shape: the weekly_scoped row reads percent' ;;
                *) assert_eq 'Claude Opus 5 ... ▓▓▓▓▓▓▓░░░ 67%' "$out" 'live shape: the weekly_scoped row reads percent' ;; esac
case "$out" in *'5h    ▓▓▓▓░░░░░░ 41%  resets unknown'*) assert_eq ok ok 'live shape: an idle five_hour shows resets unknown' ;;
                *) assert_eq '5h    ▓▓▓▓░░░░░░ 41%  resets unknown' "$out" 'live shape: an idle five_hour shows resets unknown' ;; esac

# --- CP_USAGE_URL must be https: a token never goes anywhere else -----------
rm -f "$CP_T_TMP/curl-called"
cat > "$CP_CURL_BIN" <<'STUB'
#!/usr/bin/env bash
echo 'should not be called' >> "$CP_T_TMP/curl-called"
exit 1
STUB
chmod +x "$CP_CURL_BIN"
rm -f "$CP_T_TMP/state/usage/work.json"
CFG="$(cp_config_read)"
rc=0; CP_USAGE_URL=http://attacker.example/usage cp_usage_fetch "$CFG" work >/dev/null 2>&1 || rc=$?
assert_eq '1' "$rc" 'a non-https CP_USAGE_URL fails the fetch'
assert_eq 'false' "$([ -f "$CP_T_TMP/curl-called" ] && echo true || echo false)" \
  'a non-https CP_USAGE_URL never reaches curl'
rc=0; CP_USAGE_URL=http://attacker.example/usage cp_usage_fetch_raw tok >/dev/null 2>&1 || rc=$?
assert_eq '1' "$rc" 'a non-https CP_USAGE_URL fails the raw fetch'
assert_eq 'false' "$([ -f "$CP_T_TMP/curl-called" ] && echo true || echo false)" \
  'a non-https CP_USAGE_URL never reaches curl on the raw path either'

# --- cprof usage <unknown> -------------------------------------------------
assert_fail "$CLI" usage nope

# --- cprof usage: names with spaces or glob characters stay one row each --
mkdir -p "$CP_T_TMP/ta" "$CP_T_TMP/star" "$CP_T_TMP/state/usage"
cp_t_write_config <<JSON
{"default":"team alpha","profiles":[{"name":"team alpha","dir":"$CP_T_TMP/ta"},{"name":"work*","dir":"$CP_T_TMP/star"}],"rules":[],"repos":{}}
JSON
now="$(date +%s)"
for n in 'team alpha' 'work*'; do
  printf '{"fetched_at":%s,"five_hour":{"utilization":33},"seven_day":{"utilization":11},"limits":[]}' "$now" \
    > "$CP_T_TMP/state/usage/$(cp_state_key "$n").json"
done
rm -f "$CP_T_TMP/curl-called"
cat > "$CP_CURL_BIN" <<'STUB'
#!/usr/bin/env bash
echo 'should not be called' >> "$CP_T_TMP/curl-called"
exit 1
STUB
chmod +x "$CP_CURL_BIN"
out="$(cd "$CP_T_TMP" && NO_COLOR=1 "$CLI" usage 2>/dev/null)"
assert_eq '3' "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" \
  'usage table has one row per profile when names hold spaces or globs'
case "$out" in *'team alpha'*'33%'*) assert_eq ok ok 'a name with a space is one row' ;;
                *) assert_eq 'team alpha ... 33%' "$out" 'a name with a space is one row' ;; esac
case "$out" in *'work*'*'33%'*) assert_eq ok ok 'a name with a glob character is one row' ;;
                *) assert_eq 'work* ... 33%' "$out" 'a name with a glob character is one row' ;; esac
assert_eq 'false' "$([ -f "$CP_T_TMP/curl-called" ] && echo true || echo false)" \
  'fresh caches under hashed keys are found, so curl is never invoked'

# --- usage --render: no cache yields nothing -----------------------------
cp_t_write_config <<JSON
{"default":"fresh","profiles":[{"name":"fresh","dir":"$CP_T_TMP/f"}],"rules":[],"repos":{}}
JSON
mkdir -p "$CP_T_TMP/f"
assert_eq '' "$("$CLI" usage --render fresh 2>/dev/null)" \
  '--render with no cache prints nothing'

# --- usage --render: cache present, no network needed --------------------
rm -f "$CP_CURL_BIN"
mkdir -p "$CP_T_TMP/state/usage"
cat > "$CP_T_TMP/state/usage/fresh.json" <<'JSON'
{"fetched_at":1,"five_hour":{"utilization":73,"resets_at":"2026-09-14T18:30:00Z"},
 "seven_day":{"utilization":10,"resets_at":"2026-09-20T00:00:00Z"},"limits":[]}
JSON
fields="$("$CLI" usage --render fresh 2>/dev/null)"
assert_eq '73' "$(printf '%s' "$fields" | cut -f1)" '--render field 1 is the five_hour pct'
assert_eq "$(cp_usage_bar 73)" "$(printf '%s' "$fields" | cut -f2)" '--render field 2 is the bar'
assert_eq '33' "$(printf '%s' "$fields" | cut -f3)" '--render field 3 is the SGR code (yellow=33)'

# --- statusline: renders the cached badge, never touches the network ------
SEG="$(cd "$(dirname "$0")/.." && pwd -P)/statusline/segment.sh"
rm -f "$CP_T_TMP/curl-called"
cat > "$CP_CURL_BIN" <<'STUB'
#!/usr/bin/env bash
echo 'should not be called' >> "$CP_T_TMP/curl-called"
exit 1
STUB
chmod +x "$CP_CURL_BIN"
out="$(CLAUDE_CONFIG_DIR="$CP_T_TMP/f" NO_COLOR=1 bash "$SEG" </dev/null 2>/dev/null)"
case "$out" in *'⚑ fresh'*'▓▓▓▓▓▓▓░░░ 73%'*) assert_eq ok ok 'segment appends the cached usage badge' ;;
                *) assert_eq '⚑ fresh ▓▓▓▓▓▓▓░░░ 73%' "$out" 'segment appends the cached usage badge' ;; esac
case "$out" in *"$(printf '\033')"*) assert_eq 'no escape bytes' "$out" 'NO_COLOR output carries no SGR sequences' ;;
                *) assert_eq ok ok 'NO_COLOR output carries no SGR sequences' ;; esac
assert_eq 'false' "$([ -f "$CP_T_TMP/curl-called" ] && echo true || echo false)" \
  'segment never invokes curl'
rm -f "$CP_T_TMP/state/usage/fresh.json"
out="$(CLAUDE_CONFIG_DIR="$CP_T_TMP/f" NO_COLOR=1 bash "$SEG" </dev/null 2>/dev/null)"
case "$out" in *'%'*) assert_eq '⚑ fresh' "$out" 'segment omits the badge with no cache' ;;
                *) assert_eq ok ok 'segment omits the badge with no cache' ;; esac

# --- "resets in" wording ---------------------------------------------------
now=1700000000
assert_eq '2h 19m' "$(cp_usage_reset_in $((now + 2*3600 + 19*60 + 30)) "$now")" 'reset_in renders hours and minutes'
assert_eq '37m' "$(cp_usage_reset_in $((now + 37*60 + 5)) "$now")" 'reset_in renders minutes alone under an hour'
assert_eq '<1m' "$(cp_usage_reset_in $((now + 20)) "$now")" 'reset_in renders <1m under a minute'
assert_fail cp_usage_reset_in "$now" "$now"            # a reset that is due
assert_fail cp_usage_reset_in $((now - 5)) "$now"      # a reset already past
assert_fail cp_usage_reset_in 'soon' "$now"            # a non-epoch reset

# --- usage --render: a statusline payload on stdin supplies live figures ----
# No cache for fresh at this point: everything below comes from the payload.
soon=$(( $(date +%s) + 2*3600 + 19*60 + 40 ))
payload='{"context_window":{"used_percentage":37.4,"context_window_size":200000},
          "rate_limits":{"five_hour":{"used_percentage":30.2,"resets_at":'"$soon"'}}}'
fields="$(printf '%s' "$payload" | "$CLI" usage --render fresh --stdin 2>/dev/null)"
assert_eq '30' "$(printf '%s' "$fields" | cut -f1)" 'payload: field 1 is the five_hour pct, floored'
assert_eq "$(cp_usage_bar 30)" "$(printf '%s' "$fields" | cut -f2)" 'payload: field 2 is its bar'
assert_eq '32' "$(printf '%s' "$fields" | cut -f3)" 'payload: field 3 is its SGR code (green=32)'
assert_eq '2h 19m' "$(printf '%s' "$fields" | cut -f4)" 'payload: field 4 is the time to reset'
assert_eq '37' "$(printf '%s' "$fields" | cut -f5)" 'payload: field 5 is the context pct, floored'
assert_eq "$(cp_usage_bar 37)" "$(printf '%s' "$fields" | cut -f6)" 'payload: field 6 is the context bar'
assert_eq '32' "$(printf '%s' "$fields" | cut -f7)" 'payload: field 7 is the context SGR code'
# resets_at as an RFC 3339 string works the same way
iso="$(TZ=UTC date -j -f '%s' "$soon" '+%Y-%m-%dT%H:%M:%SZ')"
fields="$(printf '{"rate_limits":{"five_hour":{"used_percentage":91,"resets_at":"%s"}}}' "$iso" | "$CLI" usage --render fresh --stdin 2>/dev/null)"
assert_eq '91	'"$(cp_usage_bar 91)"'	31	2h 19m' "$(printf '%s' "$fields" | cut -f1-4)" 'payload: an RFC 3339 resets_at is parsed'
assert_eq '' "$(printf '%s' "$fields" | cut -f5)" 'payload: no context_window means an empty context field'
# no native percentage yet: context is the current tokens over the window
fields="$(printf '%s' '{"context_window":{"context_window_size":200000,"used_percentage":0,
  "current_usage":{"input_tokens":50000,"cache_read_input_tokens":30000}}}' | "$CLI" usage --render fresh --stdin 2>/dev/null)"
assert_eq '40' "$(printf '%s' "$fields" | cut -f5)" 'payload: context falls back to tokens over window size'
assert_eq '' "$(printf '%s' "$fields" | cut -f1)" 'payload: no rate_limits and no cache means an empty usage field'
# a payload without rate_limits still lets the cache supply the usage bar
cat > "$CP_T_TMP/state/usage/fresh.json" <<'JSON'
{"fetched_at":1,"five_hour":{"utilization":73,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":10},"limits":[]}
JSON
fields="$(printf '%s' '{"context_window":{"used_percentage":12}}' | "$CLI" usage --render fresh --stdin 2>/dev/null)"
assert_eq '73' "$(printf '%s' "$fields" | cut -f1)" 'payload without rate_limits: usage comes from the cache'
assert_eq '' "$(printf '%s' "$fields" | cut -f4)" 'payload without rate_limits: no reset text from the cache'
assert_eq '12' "$(printf '%s' "$fields" | cut -f5)" 'payload without rate_limits: context still rendered'
# without --stdin the payload is not read at all, even when one is piped in
fields="$(printf '%s' "$payload" | "$CLI" usage --render fresh 2>/dev/null)"
assert_eq '73' "$(printf '%s' "$fields" | cut -f1)" '--render without --stdin: usage from the cache'
assert_eq '' "$(printf '%s' "$fields" | cut -f5)" '--render without --stdin: no context'
# garbage on stdin is ignored, not fatal
fields="$(printf 'not json' | "$CLI" usage --render fresh --stdin 2>/dev/null)"
assert_eq '73' "$(printf '%s' "$fields" | cut -f1)" 'garbage payload: usage from the cache'
assert_eq '' "$(printf '%s' "$fields" | cut -f5)" 'garbage payload: no context'
fields="$(printf '%s' '{"rate_limits":{"five_hour":{"used_percentage":"lots","resets_at":"never"}}}' | "$CLI" usage --render fresh --stdin 2>/dev/null)"
assert_eq '73' "$(printf '%s' "$fields" | cut -f1)" 'non-numeric payload pct: usage from the cache'

# --- the segment with --stdin draws both bars from the payload -------------
out="$(printf '%s' "$payload" | CLAUDE_CONFIG_DIR="$CP_T_TMP/f" NO_COLOR=1 bash "$SEG" --stdin 2>/dev/null)"
assert_eq "⚑ fresh │ Context $(cp_usage_bar 37) 37% │ Usage $(cp_usage_bar 30) 30% (resets in 2h 19m)" "$out" \
  'segment --stdin: labelled context and usage bars with the reset time'
out="$(printf '%s' "$payload" | CLAUDE_CONFIG_DIR="$CP_T_TMP/f" bash "$SEG" --stdin 2>/dev/null)"
case "$out" in *$'\033[2mContext\033[0m \033[32m'"$(cp_usage_bar 37)"' 37%'*'(resets in 2h 19m)'*)
       assert_eq ok ok 'segment --stdin: dim labels, severity-coloured bars' ;;
    *) assert_eq 'dim Context, green bar, resets' "$out" 'segment --stdin: dim labels, severity-coloured bars' ;; esac
# without --stdin the payload is not touched and the cache badge stands
leftover="$(printf '%s' "$payload" | { CLAUDE_CONFIG_DIR="$CP_T_TMP/f" NO_COLOR=1 bash "$SEG" >"$CP_T_TMP/seg.out" 2>/dev/null; cat; })"
assert_eq "$payload" "$leftover" 'segment without --stdin leaves the payload unconsumed'
assert_eq "⚑ fresh │ Usage $(cp_usage_bar 73) 73%" "$(cat "$CP_T_TMP/seg.out")" 'segment without --stdin: cached usage bar only'
# --stdin with nothing on it is the cached badge too
assert_eq "⚑ fresh │ Usage $(cp_usage_bar 73) 73%" "$(CLAUDE_CONFIG_DIR="$CP_T_TMP/f" NO_COLOR=1 bash "$SEG" --stdin </dev/null 2>/dev/null)" \
  'segment --stdin with empty input: cached usage bar only'
# an unknown flag prints nothing rather than a wrong line
assert_eq '' "$(CLAUDE_CONFIG_DIR="$CP_T_TMP/f" bash "$SEG" --bogus </dev/null 2>/dev/null)" 'segment ignores unknown flags silently'
rm -f "$CP_T_TMP/state/usage/fresh.json"
assert_eq 'false' "$([ -f "$CP_T_TMP/curl-called" ] && echo true || echo false)" \
  'segment with no cache still never invokes curl'

# --- cprof list: 5H/7D columns --------------------------------------------
cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","dir":"$CP_T_TMP/p"}],"rules":[],"repos":{}}
JSON
printf '{"claudeAiOauth":{"accessToken":"tok-work"}}' > "$CP_T_TMP/p/.credentials.json"
cat > "$CP_CLAUDE_BIN" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = auth ] && [ "${2:-}" = status ] && printf '{"loggedIn":true,"email":"me@x.com","subscriptionType":"max"}\n'
STUB
chmod +x "$CP_CLAUDE_BIN"
rm -f "$CP_T_TMP/state/usage/work.json"
cat > "$CP_CURL_BIN" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"five_hour":{"utilization":42,"resets_at":"2026-09-14T18:30:00Z"},
 "seven_day":{"utilization":18,"resets_at":"2026-09-20T00:00:00Z"},"limits":[]}
JSON
STUB
chmod +x "$CP_CURL_BIN"
out="$(NO_COLOR=1 "$CLI" list 2>/dev/null)"
case "$out" in *'5H'*'7D'*) assert_eq ok ok 'list header gains 5H/7D' ;;
                *) assert_eq '5H ... 7D' "$out" 'list header gains 5H/7D' ;; esac
case "$out" in *'42%'*'18%'*) assert_eq ok ok 'list row shows both windows' ;;
                *) assert_eq '42% ... 18%' "$out" 'list row shows both windows' ;; esac

# --- cprof list: no usage data shows a dash, not an error -----------------
rm -f "$CP_CURL_BIN" "$CP_T_TMP/state/usage/work.json"
rc=0; out="$(NO_COLOR=1 "$CLI" list 2>/dev/null)" || rc=$?
assert_eq '0' "$rc" 'list exits 0 with no usage data'
case "$out" in *'-'*) assert_eq ok ok 'list shows a dash for missing usage' ;;
                *) assert_eq 'a dash' "$out" 'list shows a dash for missing usage' ;; esac

cp_t_summary
