# Per-Profile Usage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show each profile's Claude usage (5h/7d rate-limit windows) in `cprof list`, `cprof doctor`, a new `cprof usage` command, and the statusline — colored, with the statusline never blocking on the network.

**Architecture:** New `scripts/lib/usage.sh` owns fetching (`GET api.anthropic.com/api/oauth/usage`), a 5-minute file cache under `$CP_STATE_DIR/usage/<name>.json`, and rendering (10-block bar + red/yellow/green severity color). `list`/`doctor`/`usage` call the fetch-or-cache path; the statusline calls a cache-only path via a new `cprof usage --render <name>` subcommand, mirroring the existing `cprof color --render` pattern exactly.

**Tech Stack:** bash 3.2, jq, curl (new runtime dependency — previously only jq was required).

**Spec:** `docs/superpowers/specs/2026-09-14-per-profile-usage-design.md`

## Global Constraints

- Target bash 3.2 (macOS system bash) — no arrays, no `[[ ]]`, no `${var,,}`, use `case`/`[ ]`/`printf`.
- `jq` and now `curl` are the only external dependencies; `curl` was previously undocumented as a runtime dep (only `install.sh` used it) — README's "jq as the only external dependency" line must be corrected.
- A live OAuth token must never appear in a process's argv (`ps` visibility) — the existing `cp_creds_read` discipline. `cp_usage_fetch` builds a curl `-K -` config string, which means the token touches one local shell variable (unavoidable to build that string); this is documented as an explicit, accepted deviation in the security-assessment update, not glossed over.
- The statusline segment must never make a network call and must never take longer than a cache read; a missing cache means no usage badge, not a wait.
- Every UI surface this feature touches (`list`, `doctor`, `usage`, statusline) must show color: identity color for profile names (already existing `cp_colorize`/`cp_color_for`), severity color (red ≥90%, yellow ≥70%, green otherwise) for the bar/percent, all gated by the existing `cp_color_enabled`/`NO_COLOR`/`CPROF_COLOR` conventions.
- `CPROF_NO_USAGE=1` disables all fetching everywhere (foreground commands behave as cache-only, same as the statusline).
- No test may make a real network call: the test harness stubs `curl` the same way it already stubs `claude` and `security`.
- The PR for this feature must include terminal screenshots of the colored `list`, `doctor`, `usage`, `usage <name>`, and statusline output (per the spec's Delivery section and a saved project preference) — this is the last task.

---

## File Structure

- **Create** `scripts/lib/usage.sh` — all fetch, cache, and render logic; the new `cp_cmd_usage` command.
- **Modify** `scripts/cprof` — source `usage.sh`; add the `usage` dispatch case; add a help line.
- **Modify** `scripts/lib/output.sh` — `cp_cmd_list` gains `5H`/`7D` columns.
- **Modify** `scripts/lib/auth.sh` — `cp_cmd_doctor` gains a usage-threshold warning line.
- **Modify** `statusline/segment.sh` — appends the cached usage bar after the name.
- **Modify** `tests/lib.sh` — `cp_t_setup` gains a `CP_CURL_BIN` stub path, same pattern as `CP_CLAUDE_BIN`/`CP_SECURITY_BIN`.
- **Create** `tests/test_usage.sh` — covers `usage.sh` end to end: fetch, cache, TTL, opt-out, the `usage` command (both forms), `--render`, and the new `list` columns.
- **Modify** `tests/test_auth_status.sh` — adds `cp_cmd_doctor`'s usage-warning assertions.
- **Modify** `tests/test_tables.sh` — one alignment case with the two new `list` columns present.
- **Modify** `README.md`, `docs/security-assessment.md`, `CHANGELOG.md` — document the feature, the new dependency, and the opt-out.

---

### Task 1: Cache + fetch core (`cp_usage_fetch`, `cp_usage_read`, `cp_usage_read_cached_only`, `cp_usage_pct`, `cp_usage_resets_at`)

**Files:**
- Create: `scripts/lib/usage.sh`
- Modify: `scripts/cprof` (source the new lib file)
- Modify: `tests/lib.sh:9-24` (`cp_t_setup`)
- Create: `tests/test_usage.sh`

**Interfaces:**
- Consumes: `cp_config_read` (`config.sh`), `cp_creds_read <cfg> <name>` (`auth.sh`), `CP_STATE_DIR` (`config.sh`).
- Produces: `cp_usage_cache_file <name>` → path; `cp_usage_fetch <cfg> <name>` → JSON on stdout, writes cache, returns 1 on any failure without touching the cache; `cp_usage_read <cfg> <name>` → JSON on stdout (fresh, refetched, or stale-fallback), empty + return 1 if nothing available; `cp_usage_read_cached_only <name>` → cached JSON or nothing, never fetches; `cp_usage_pct <json> <window>` → integer string or empty; `cp_usage_resets_at <json> <window>` → ISO string or empty. `window` is `five_hour` or `seven_day`.

- [ ] **Step 1: Add a `CP_CURL_BIN` stub slot to the test harness**

Edit `tests/lib.sh`, inside `cp_t_setup` (after the existing `CP_SECURITY_BIN` export):

```bash
  export CP_CURL_BIN="$CP_T_TMP/bin/curl"
```

This path does not exist by default, so any code that execs `"$CP_CURL_BIN"` without a test first creating it fails fast (exit 127, no output) instead of ever reaching the real network — this protects every *other* existing test file too, since `cp_cmd_list`/`cp_cmd_doctor` will call into usage code once later tasks wire them up.

- [ ] **Step 2: Write the failing test for a successful fetch**

Create `tests/test_usage.sh`:

```bash
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

cp_t_summary
```

- [ ] **Step 3: Run it to confirm it fails**

Run: `bash tests/test_usage.sh`
Expected: FAIL — `usage.sh` doesn't exist yet, sourcing it errors out (or `cp_usage_fetch: command not found`).

- [ ] **Step 4: Implement `scripts/lib/usage.sh` (fetch, cache, read)**

Create `scripts/lib/usage.sh`:

```bash
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
```

- [ ] **Step 5: Source `usage.sh` from the CLI entrypoint**

Edit `scripts/cprof`, after the `color.sh` source line (line 45):

```bash
# shellcheck source=lib/color.sh
. "$CP_LIB_DIR/color.sh"
# shellcheck source=lib/usage.sh
. "$CP_LIB_DIR/usage.sh"
```

- [ ] **Step 6: Run the test to confirm it passes**

Run: `bash tests/test_usage.sh`
Expected: PASS on all four assertions.

- [ ] **Step 7: Add TTL, stale-fallback, opt-out, and no-token tests**

Append to `tests/test_usage.sh` (before `cp_t_summary`):

```bash
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
```

- [ ] **Step 8: Run and verify all pass**

Run: `bash tests/test_usage.sh`
Expected: PASS on every assertion.

- [ ] **Step 9: Commit**

```bash
git add scripts/lib/usage.sh scripts/cprof tests/lib.sh tests/test_usage.sh
git commit -m "feat: fetch and cache per-profile usage from the OAuth usage endpoint"
```

---

### Task 2: Rendering (`cp_usage_bar`, `cp_usage_severity_colour`, `cp_usage_render`)

**Files:**
- Modify: `scripts/lib/usage.sh`
- Modify: `tests/test_usage.sh`

**Interfaces:**
- Consumes: `cp_color_code <colour>` (`color.sh`), `CP_COLOR_ON` (dynamic-scope convention from `color.sh`/`output.sh`).
- Produces: `cp_usage_bar <pct>` → 10-char block string on stdout, returns 1 (nothing printed) if `pct` isn't a plain non-negative integer; `cp_usage_severity_colour <pct>` → `red`/`yellow`/`green`, same failure mode; `cp_usage_render <pct>` → colored `"▓▓▓▓░░░░░░ 42%"` (or plain if `CP_COLOR_ON` isn't `1`), or `"-"` when `pct` is invalid/empty. Rounding: filled blocks = `(pct + 5) / 10` (integer division), clamped to 10 — i.e. round-half-up, so 45% shows 5 filled blocks and 44% shows 4.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_usage.sh`:

```bash
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
```

- [ ] **Step 2: Run to confirm failure**

Run: `bash tests/test_usage.sh`
Expected: FAIL — the three functions don't exist yet.

- [ ] **Step 3: Implement the rendering functions**

Append to `scripts/lib/usage.sh`:

```bash
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
```

- [ ] **Step 4: Run to confirm all pass**

Run: `bash tests/test_usage.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/usage.sh tests/test_usage.sh
git commit -m "feat: render usage as a colored 10-block bar"
```

---

### Task 3: `cprof usage [<name>]` command

**Files:**
- Modify: `scripts/lib/usage.sh`
- Modify: `scripts/cprof` (dispatch + help text)
- Modify: `tests/test_usage.sh`

**Interfaces:**
- Consumes: `cp_config_read`, `cp_profile_exists`, `cp_color_enabled` (`config.sh`/`color.sh`), `cp_colorize`, `cp_color_for` (`color.sh`), `cp_usage_read`, `cp_usage_pct`, `cp_usage_resets_at`, `cp_usage_render` (Tasks 1-2), `cp_table` (`output.sh`).
- Produces: `cp_cmd_usage "$@"` — dispatched from `scripts/cprof`'s `usage)` case. No argument lists every profile's 5h/7d bars; a profile name shows that profile's full breakdown including per-model `weekly_scoped` limits; `--render <name>` is handled separately in Task 4.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_usage.sh`:

```bash
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
```

- [ ] **Step 2: Run to confirm failure**

Run: `bash tests/test_usage.sh`
Expected: FAIL — `cprof usage` isn't wired up yet (falls through to the CLI's default `cp_usage; exit 2` help/usage-error branch).

- [ ] **Step 3: Implement `cp_cmd_usage`, `cp_usage_list_all`, `cp_usage_detail`**

Append to `scripts/lib/usage.sh`:

```bash
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
```

Note: `cp_usage_render_fields` is defined in Task 4; `cp_cmd_usage` referencing it here is fine since bash resolves function calls at run time, not at source time, and Task 4 lands before this is ever exercised through the CLI's `--render` path. The test suite above never calls `--render`, so Task 3's tests pass without it existing yet — but to keep the file buildable top-to-bottom, add a placeholder now and let Task 4 replace it:

```bash
cp_usage_render_fields() { :; }
```

Add this placeholder right above `cp_cmd_usage` in this step; Task 4 Step 3 replaces it with the real implementation (not a second definition — the placeholder is deleted, not shadowed).

- [ ] **Step 4: Wire the dispatcher and help text**

Edit `scripts/cprof`. In `cp_usage` (the help-text function, lines 51-81), add a line after the `doctor` line:

```
  cprof usage [<name>]              usage bars (5h/7d), or full breakdown for one profile
```

In the `case "$cmd" in` block (lines 86-105), add after the `doctor` case:

```bash
  usage)   cp_cmd_usage "$@" ;;
```

- [ ] **Step 5: Run to confirm all pass**

Run: `bash tests/test_usage.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/usage.sh scripts/cprof tests/test_usage.sh
git commit -m "feat: add cprof usage command"
```

---

### Task 4: `cprof usage --render <name>` + statusline integration

**Files:**
- Modify: `scripts/lib/usage.sh` (replace the Task 3 placeholder)
- Modify: `statusline/segment.sh`
- Modify: `tests/test_usage.sh`

**Interfaces:**
- Consumes: `cp_usage_read_cached_only <name>`, `cp_usage_pct`, `cp_usage_bar`, `cp_usage_severity_colour` (Tasks 1-2), `cp_color_code` (`color.sh`).
- Produces: `cp_usage_render_fields <name>` → tab-separated `"<pct>\t<bar>\t<sgr-code>"` on stdout when a cache exists and is valid, nothing otherwise. Never fetches. `cprof usage --render <name>` is the CLI-level entry point the statusline calls, mirroring `cprof color --render <name>`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_usage.sh`:

```bash
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
```

- [ ] **Step 2: Run to confirm failure**

Run: `bash tests/test_usage.sh`
Expected: FAIL — the placeholder `cp_usage_render_fields` returns nothing for every case.

- [ ] **Step 3: Replace the placeholder with the real implementation**

In `scripts/lib/usage.sh`, delete the `cp_usage_render_fields() { :; }` placeholder from Task 3 and put this in its place (same location, just above `cp_cmd_usage`):

```bash
# cp_usage_render_fields <name> -> "<pct>\t<bar>\t<sgr-code>", cache-only,
# nothing when there is no cache or it's unreadable. Never fetches — this is
# the statusline's rendering entry point via `cprof usage --render`.
cp_usage_render_fields() {
  local name="${1:-}" cached pct bar colour code
  cached="$(cp_usage_read_cached_only "$name")"
  [ -n "$cached" ] || return 0
  pct="$(cp_usage_pct "$cached" five_hour)"
  bar="$(cp_usage_bar "$pct")" || return 0
  colour="$(cp_usage_severity_colour "$pct")"
  code="$(cp_color_code "$colour")"
  printf '%s\t%s\t%s\n' "$pct" "$bar" "$code"
}
```

- [ ] **Step 4: Run to confirm all pass**

Run: `bash tests/test_usage.sh`
Expected: PASS.

- [ ] **Step 5: Wire the statusline segment**

Edit `statusline/segment.sh`. After the existing `render`/`code`/`text` block (lines 33-35) and before the final `if [ -z "$code" ]...` block, add:

```bash
# Usage badge: cache-only (never fetches — see cp_usage_read_cached_only),
# so this never adds latency. Empty fields mean no cache yet; the statusline
# looks exactly like it did before this feature in that case.
usage_render="$("$cli" usage --render "$name" 2>/dev/null)"
u_pct="$(printf '%s' "$usage_render" | cut -f1)"
u_bar="$(printf '%s' "$usage_render" | cut -f2)"
u_code="$(printf '%s' "$usage_render" | cut -f3)"
```

Then change the two final `printf` lines so each appends the usage suffix when present, honoring the same `NO_COLOR`/no-`code` fallback the badge itself already uses:

```bash
# No colour resolved, or the reader asked for none: the original dim badge,
# plus a plain usage suffix if a cache exists.
if [ -z "$code" ] || [ -n "${NO_COLOR+set}" ]; then
  if [ -n "$u_pct" ]; then
    printf '\033[2m⚑ %s\033[0m %s %s%%\n' "$name" "$u_bar" "$u_pct"
  else
    printf '\033[2m⚑ %s\033[0m\n' "$name"
  fi
  exit 0
fi

if [ "$text" = 'on' ]; then
  if [ -n "$u_pct" ]; then
    printf '\033[%sm⚑ %s\033[0m \033[%sm%s %s%%\033[0m\n' "$code" "$name" "$u_code" "$u_bar" "$u_pct"
  else
    printf '\033[%sm⚑ %s\033[0m\n' "$code" "$name"
  fi
else
  if [ -n "$u_pct" ]; then
    printf '\033[%sm⚑\033[0m \033[2m%s\033[0m \033[%sm%s %s%%\033[0m\n' "$code" "$name" "$u_code" "$u_bar" "$u_pct"
  else
    printf '\033[%sm⚑\033[0m \033[2m%s\033[0m\n' "$code" "$name"
  fi
fi
exit 0
```

- [ ] **Step 6: Manually verify the segment with no cache is unchanged**

Run: `CPROF_STATE_DIR=/tmp/cprof-manual-check ./statusline/segment.sh </dev/null`
(with a real config having at least one non-native, non-stock active profile)
Expected: identical output to before this task — `⚑ <name>` and nothing else, since `/tmp/cprof-manual-check` holds no usage cache.

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/usage.sh statusline/segment.sh tests/test_usage.sh
git commit -m "feat: add cprof usage --render and a statusline usage badge"
```

---

### Task 5: `cprof list` gains `5H`/`7D` columns

**Files:**
- Modify: `scripts/lib/output.sh:143-183` (`cp_cmd_list`)
- Modify: `tests/test_usage.sh`
- Modify: `tests/test_tables.sh`

**Interfaces:**
- Consumes: `cp_usage_read`, `cp_usage_pct`, `cp_usage_render` (Tasks 1-2).
- Produces: no new functions — `cp_cmd_list`'s table gains two columns between `ACCOUNT` and `FLAGS`.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_usage.sh`:

```bash
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
out="$(NO_COLOR=1 "$CLI" list 2>/dev/null)"
case "$out" in *'  -  '*|*$'\t-\t'*) : ;; esac
assert_eq '0' "$?" 'list tolerates missing usage data'
```

- [ ] **Step 2: Run to confirm failure**

Run: `bash tests/test_usage.sh`
Expected: FAIL — `list`'s header has no `5H`/`7D` yet.

- [ ] **Step 3: Add the columns**

Edit `scripts/lib/output.sh`, in `cp_cmd_list`. Change the header and row `printf` calls:

```bash
  {
    printf 'PROFILE\tPLAN\tACCOUNT\t5H\t7D\tFLAGS\n'
    for name in $names; do
      st="$(cp_auth_status "$cfg" "$name")"
      if [ "$(printf '%s' "$st" | jq -r '.loggedIn // false')" = 'true' ]; then
        email="$(printf '%s' "$st" | jq -r '.email // "unknown"')"
        sub="$(printf '%s' "$st" | jq -r '.subscriptionType // "unknown"')"
      else
        email='not logged in'
        sub='-'
      fi
      markers=''
      [ "$name" = "$default_name" ] && markers="$markers (default)"
      [ "$name" = "$active" ] && markers="$markers (active)"
      if cp_profile_is_native "$cfg" "$name"; then
        markers="$markers native"
      else
        dir="$(cp_profile_dir "$cfg" "$name")"
        [ -d "$dir" ] || markers="$markers [dir missing]"
      fi
      data="$(cp_usage_read "$cfg" "$name")"
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(cp_colorize "$(cp_color_for "$cfg" "$name")" "$name")" \
        "$sub" "$email" \
        "$(cp_usage_render "$(cp_usage_pct "$data" five_hour)")" \
        "$(cp_usage_render "$(cp_usage_pct "$data" seven_day)")" \
        "${markers# }"
    done
  } | cp_table
```

Add `data` to the function's `local` declaration at the top of `cp_cmd_list` (currently `local cfg names name active default_name st email sub markers dir CP_COLOR_ON=0`):

```bash
  local cfg names name active default_name st email sub markers dir data CP_COLOR_ON=0
```

- [ ] **Step 4: Run to confirm all pass**

Run: `bash tests/test_usage.sh`
Expected: PASS.

- [ ] **Step 5: Add an alignment case to `test_tables.sh`**

Append to `tests/test_tables.sh` (before the final summary):

```bash
# --- cp_table: alignment holds with the usage columns added ---------------
expected='PROFILE  PLAN  ACCOUNT       5H         7D   FLAGS
work     max   me@x.com      ▓▓▓▓░░░░░░ 42%  ░░░░░░░░░░ 0%  (active)'
assert_eq "$expected" "$(printf 'PROFILE\tPLAN\tACCOUNT\t5H\t7D\tFLAGS\nwork\tmax\tme@x.com\t▓▓▓▓░░░░░░ 42%%\t░░░░░░░░░░ 0%%\t(active)\n' | cp_table)" \
  'six-column rows with multi-byte bar characters still align'
```

- [ ] **Step 6: Run the full suite**

Run: `bash tests/run.sh`
Expected: all test files PASS, including `test_tables.sh` and `test_usage.sh`.

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/output.sh tests/test_usage.sh tests/test_tables.sh
git commit -m "feat: show 5h/7d usage columns in cprof list"
```

---

### Task 6: `cprof doctor` warns at ≥90% usage

**Files:**
- Modify: `scripts/lib/auth.sh:140-169` (`cp_cmd_doctor`)
- Modify: `tests/test_auth_status.sh`

**Interfaces:**
- Consumes: `cp_usage_read`, `cp_usage_pct`, `cp_usage_resets_at`, `cp_usage_render` (Tasks 1-2).
- Produces: no new functions — `cp_cmd_doctor` gains an additional warning line per profile when its 5h window is at or above 90%, and sets its existing `status=1` in that case. Silent when usage data isn't available (never turns a healthy profile into a failure just because the network was down).

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_auth_status.sh` (before `cp_t_summary`):

```bash
# --- doctor: usage warning at >=90%, silent otherwise ---------------------
export CP_CURL_BIN="$CP_T_TMP/bin/curl"
cat > "$CP_CURL_BIN" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"five_hour":{"utilization":92,"resets_at":"2026-09-14T18:30:00Z"},
 "seven_day":{"utilization":10,"resets_at":"2026-09-20T00:00:00Z"},"limits":[]}
JSON
STUB
chmod +x "$CP_CURL_BIN"
printf '{"claudeAiOauth":{"refreshTokenExpiresAt":99999999999999,"accessToken":"tok"}}' \
  > "$CP_T_TMP/p/.credentials.json"
out="$(cd "$CP_T_TMP" && "$CLI" doctor 2>&1)"
rc=$?
case "$out" in *'personal: 5h window at'*'92%'*) assert_eq ok ok 'doctor warns at 92% usage' ;;
                *) assert_eq 'personal: 5h window at 92%' "$out" 'doctor warns at 92% usage' ;; esac
assert_eq '1' "$rc" 'doctor fails when a profile is at 92% usage'

cat > "$CP_CURL_BIN" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"five_hour":{"utilization":42,"resets_at":"2026-09-14T18:30:00Z"},
 "seven_day":{"utilization":10,"resets_at":"2026-09-20T00:00:00Z"},"limits":[]}
JSON
STUB
chmod +x "$CP_CURL_BIN"
rm -f "$CP_T_TMP/state/usage/personal.json"
out="$(cd "$CP_T_TMP" && "$CLI" doctor 2>&1)"
case "$out" in *'5h window'*) assert_eq 'no usage warning' "$out" 'doctor stays silent under 90%' ;;
                *) assert_eq ok ok 'doctor stays silent under 90%' ;; esac

# --- doctor: no network, no cache -> usage check never fails the run -----
rm -f "$CP_CURL_BIN" "$CP_T_TMP/state/usage/personal.json"
out="$(cd "$CP_T_TMP" && "$CLI" doctor 2>&1)"
rc=$?
assert_eq '0' "$rc" 'doctor passes when usage data is simply unavailable'
```

Note: this relies on the `personal` profile (dir `$CP_T_TMP/p`) already set up earlier in `tests/test_auth_status.sh` and on `CPROF_STATE_DIR` already being `$CP_T_TMP/state` from `cp_t_setup` — no new fixtures needed beyond the `CP_CURL_BIN` stub and an `accessToken` field, which the earlier `refreshTokenExpiresAt`-only fixture didn't carry.

- [ ] **Step 2: Run to confirm failure**

Run: `bash tests/test_auth_status.sh`
Expected: FAIL — `doctor` has no usage-warning line yet.

- [ ] **Step 3: Implement the doctor check**

Edit `scripts/lib/auth.sh`, `cp_cmd_doctor`. Change the `local` line and the loop body:

```bash
cp_cmd_doctor() {
  local cfg names name st logged active ms left_days status=0 usage_data pct CP_COLOR_ON=0
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
  for name in $names; do
    st="$(cp_auth_status "$cfg" "$name")"
    logged="$(printf '%s' "$st" | jq -r '.loggedIn // false')"
    if [ "$logged" != 'true' ]; then
      printf '%s: not logged in - run: cprof login %s\n' "$name" "$name"
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
          if [ "$pct" -ge 90 ]; then
            printf '%s: 5h window at %s (resets %s)\n' \
              "$name" "$(cp_usage_render "$pct")" "$(cp_usage_resets_at "$usage_data" five_hour)"
            status=1
          fi
          ;;
      esac
    fi
  done
  printf 'active profile here: %s\n' "${active:-none}"
  return "$status"
}
```

- [ ] **Step 4: Run to confirm all pass**

Run: `bash tests/test_auth_status.sh`
Expected: PASS.

- [ ] **Step 5: Run the full suite to catch any regression**

Run: `bash tests/run.sh`
Expected: all PASS. (The pre-existing "doctor passes when an expiry is simply unknown" assertion at `tests/test_auth_status.sh:114-118` should still hold: no `CP_CURL_BIN` stub is active for that fixture at that point unless a later step set one and didn't clean it up — verify by inspection during this run rather than assuming.)

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/auth.sh tests/test_auth_status.sh
git commit -m "feat: warn in cprof doctor when a profile's 5h window hits 90%"
```

---

### Task 7: Docs — README, security assessment, CHANGELOG

**Files:**
- Modify: `README.md`
- Modify: `docs/security-assessment.md`
- Modify: `CHANGELOG.md`

**Interfaces:** none — documentation only.

- [ ] **Step 1: Update the README commands table**

Edit `README.md`, the table starting at line 394. Add a row after the `doctor` row:

```markdown
| `cprof usage [<name>]` | Usage bars (5h/7d) for every profile, or the full breakdown for one |
```

Update the `list` row's description to mention the new columns:

```markdown
| `cprof list` | Profiles with identity, subscription, usage (5h/7d), and markers; marks default, active, native |
```

- [ ] **Step 2: Update the Statusline section**

Edit `README.md` around line 424-428. Change the example and add one sentence:

````markdown
## Statusline

```console
⚑ work
```

Once `cprof list`, `doctor`, or `usage` has fetched usage data at least once,
the badge also carries a usage bar for the active profile's 5-hour window,
colored red/yellow/green by how close it is to the cap:

```console
⚑ work ▓▓▓▓░░░░░░ 42%
```

The badge carries the profile's colour, and `--text` decides how far it
reaches:
````

(the rest of that section is unchanged).

- [ ] **Step 3: Correct the "only external dependency" claim and document the opt-out**

Edit `README.md` line 593:

```markdown
Targets bash 3.2 (macOS system bash), with `jq` and (for usage data) `curl`
as the only external dependencies.
```

Edit `README.md`'s Safety section (around line 573-579), adding a new paragraph:

```markdown
`cprof list`, `cprof doctor`, and `cprof usage` fetch usage data from
`api.anthropic.com/api/oauth/usage` using the profile's own OAuth token,
cached for 5 minutes under `~/.cprof/usage/`. The statusline never makes this
call — it only reads the cache, so it never blocks. Set `CPROF_NO_USAGE=1` to
turn fetching off everywhere; existing cached data (or a plain `-`) is shown
instead.
```

- [ ] **Step 4: Add a security-assessment row and accepted-risk note**

Edit `docs/security-assessment.md`. Add a row to the "Attack surface and mitigations" table (after the "Keychain reads" row):

```markdown
| Usage endpoint fetch (`list`/`doctor`/`usage`) | Token exposure over the network, or via `ps` | TLS to `api.anthropic.com`; the bearer token is sent only in a request header, never in a URL or body; passed to curl via a `-K -` stdin config block, not argv, so it never appears in `ps`. `CPROF_NO_USAGE=1` disables the call entirely. The statusline never triggers this fetch, only reads a local cache |
```

Add a bullet to "Accepted risks":

```markdown
- **The usage-fetch token passes through one shell variable.** `cp_usage_fetch`
  (`scripts/lib/usage.sh`) has to interpolate the OAuth token into a string to
  build curl's `-K -` config block, so — unlike `cp_creds_read`'s callers,
  which pipe credentials straight into `jq` — the token briefly exists in a
  local variable. It never reaches argv (invisible to `ps`) and the variable
  is `unset` immediately after use.
```

- [ ] **Step 5: Add a CHANGELOG entry**

Edit `CHANGELOG.md` — add an "Unreleased" (or next version) entry following the file's existing style:

```markdown
### Added
- `cprof usage [<name>]`, usage columns in `cprof list`, a usage warning in
  `cprof doctor`, and a usage badge on the statusline, backed by
  `api.anthropic.com/api/oauth/usage`. Opt out with `CPROF_NO_USAGE=1`.
```

(Check the top of `CHANGELOG.md` first and match its exact existing heading style/placement before inserting.)

- [ ] **Step 6: Commit**

```bash
git add README.md docs/security-assessment.md CHANGELOG.md
git commit -m "docs: document per-profile usage, the new curl dependency, and CPROF_NO_USAGE"
```

---

### Task 8: Full verification and PR

**Files:** none (verification + delivery only).

**Interfaces:** none.

- [ ] **Step 1: Run the full test suite**

Run: `bash tests/run.sh`
Expected: every test file passes, including the new `tests/test_usage.sh` and the modified `tests/test_auth_status.sh` and `tests/test_tables.sh`.

- [ ] **Step 2: Run shellcheck**

Run:
```bash
shellcheck -x -P scripts -P tests scripts/cprof scripts/lib/*.sh hooks/*.sh \
  statusline/*.sh tests/*.sh install.sh
```
Expected: no warnings. Fix anything it flags in `usage.sh` or the edited files before proceeding.

- [ ] **Step 3: Validate the plugin manifest**

Run: `claude plugin validate .`
Expected: passes (this feature adds no new manifest entries, but confirms nothing else broke).

- [ ] **Step 4: Capture terminal screenshots for the PR**

With at least one real or fixture profile configured and logged in (or `CPROF_NO_USAGE` unset and network reachable), capture screenshots showing colored output for:
- `cprof list` (5H/7D columns visible)
- `cprof doctor` (a profile above 90%, to show the warning line in red)
- `cprof usage` (all-profiles bar view)
- `cprof usage <name>` (full breakdown with a `weekly_scoped` line, if available)
- the statusline segment output (`⚑ <name> <bar> <pct>%`)

This satisfies the spec's Delivery section and the saved project preference that any PR touching cprof's UI includes screenshots of the actual colored output.

- [ ] **Step 5: Open the PR**

Use the `superpowers:finishing-a-development-branch` skill to open the pull request, attaching the screenshots from Step 4 and linking `docs/superpowers/specs/2026-09-14-per-profile-usage-design.md` in the description.
