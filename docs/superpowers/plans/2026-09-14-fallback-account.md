# Fallback Account Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let one profile stand in for another, live, once the primary is out of usage headroom — an already-running `claude` process picks up the fallback account without restarting — with an automatic, confirmed restore once the primary's window resets.

**Architecture:** New `scripts/lib/fallback.sh` owns the config field (`cprof fallback <primary> <secondary>`), the swap mechanics (atomic credential overwrite with a sibling backup), and the active-swap marker file. Both swap-out and swap-back run opportunistically inside the existing `cp_cmd_env` (`scripts/lib/output.sh`) — no new hook. Swap-out is cache-only (free); swap-back does one confirming network fetch, but only when a marker already exists and its recorded `resets_at` has passed, so `cprof env`'s normal no-network path is unaffected in the common case.

**Tech Stack:** bash 3.2, jq, curl (already a dependency from the usage feature), macOS `security`(1), BSD `date -j -f` for the one timestamp comparison this feature needs (this codebase's test suite already runs macOS-only in CI, so BSD `date` is safe to rely on).

**Spec:** `docs/superpowers/specs/2026-09-14-fallback-account-design.md`

## Global Constraints

- Target bash 3.2 (macOS system bash) — no arrays, no `[[ ]]`, no `${var,,}`, use `case`/`[ ]`/`printf`.
- `cprof env` must keep its existing contract: always prints exactly one assignment line, never exits non-zero, human messages go to `cp_warn` (stderr) only. Swap-out/swap-back are best-effort side effects inside it — no code path they add may violate this.
- Swap-out reads only the existing usage cache (`cp_usage_read_cached_only`) — no network call. Swap-back makes exactly one confirming fetch (`cp_usage_fetch`), and only when a marker exists and its `resets_at` has already passed.
- A live OAuth token must not appear in argv (`ps` visibility) on any path cprof controls: the usage fetch feeds curl its headers over stdin (`-K -`), and reading a profile's credentials for the swap goes through `cp_creds_read` into one local shell variable that is `unset` immediately after use. The one accepted exception is the keychain write itself: `security add-generic-password` takes the secret only as `-w <value>` or from an interactive tty prompt, so `cp_keychain_write` (used by `cp_cmd_login`'s safety net before this feature, and by both swap directions here) exposes the blob in that subprocess's argv for its lifetime, same-user only. Recorded as an accepted risk in docs/security-assessment.md.
- Every atomic write (marker file, credential file overwrite, credential file restore) uses the existing tmp+chmod 600+mv discipline (`cp_config_write`/`cp_usage_fetch`'s pattern) — no code path leaves a partial file in place of a real one.
- If anything fails before the final mv/keychain-write in a swap-out or swap-back, the primary's live credentials must be provably untouched (verified by a forced-failure test in each direction).
- Default threshold 90 (matches `cprof doctor`'s existing warning), overridable via `CPROF_FALLBACK_THRESHOLD` (global env var).
- No test may make a real network call or a real keychain call — stub `CP_CURL_BIN` and `CP_SECURITY_BIN` the same way existing tests do.
- The PR includes terminal screenshots of `cprof doctor`'s active-swap line and `cprof list`'s annotated row, and updates README in the same PR (per the saved project preference — this is the last task).

---

## File Structure

- **Create** `scripts/lib/fallback.sh` — the `.profiles[].fallback` config field command, the marker file, and both swap directions.
- **Modify** `scripts/cprof` — source `fallback.sh`; add the `fallback` dispatch case; add help text.
- **Modify** `scripts/lib/auth.sh` — widen `cp_keychain_write` to take an optional service argument; `cp_cmd_doctor` gains an active-swap line.
- **Modify** `scripts/lib/output.sh` — `cp_cmd_env` calls `cp_fallback_swap_back`/`cp_fallback_swap_out`; `cp_cmd_list` annotates a swapped profile's row; `cp_cmd_which` gains a would-fire note.
- **Modify** `scripts/lib/profiles.sh` — `cp_cmd_remove` clears dangling `.fallback` references and the removed profile's marker file.
- **Create** `tests/test_fallback.sh` — covers the config command, both swap directions (including forced-failure cases), and the visibility changes.
- **Modify** `tests/test_auth_status.sh` — one active-swap doctor assertion, plus `cp_keychain_write` regression coverage.
- **Modify** `README.md`, `docs/security-assessment.md`, `CHANGELOG.md`.

---

### Task 1: `cprof fallback` command + config field + removal cleanup

**Files:**
- Create: `scripts/lib/fallback.sh`
- Modify: `scripts/cprof` (source the new lib file, dispatch, help text)
- Modify: `scripts/lib/profiles.sh:151-191` (`cp_cmd_remove`)
- Create: `tests/test_fallback.sh`

**Interfaces:**
- Consumes: `cp_config_read`, `cp_config_write`, `cp_profile_exists`, `cp_profile_field` (`config.sh`), `cp_warn`.
- Produces: `cp_cmd_fallback "$@"` — `cprof fallback <primary>` prints the current mapping or `none`; `cprof fallback <primary> <secondary>` sets `.profiles[].fallback`; `cprof fallback <primary> --clear` removes it. Validates both names exist and are different.

- [ ] **Step 1: Write the failing tests for the config command**

Create `tests/test_fallback.sh`:

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
# shellcheck source=/dev/null
. "$(dirname "$0")/../scripts/lib/fallback.sh"
CLI="$(cd "$(dirname "$0")/.." && pwd -P)/scripts/cprof"

mkdir -p "$CP_T_TMP/work" "$CP_T_TMP/personal"
cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","dir":"$CP_T_TMP/work"},{"name":"personal","dir":"$CP_T_TMP/personal"}],"rules":[],"repos":{}}
JSON

# --- set, get, clear -------------------------------------------------------
assert_eq 'none' "$("$CLI" fallback work 2>/dev/null)" 'no fallback configured yet'
"$CLI" fallback work personal >/dev/null 2>&1
assert_eq 'personal' "$("$CLI" fallback work 2>/dev/null)" 'fallback set and read back'
CFG="$(cp_config_read)"
assert_eq 'personal' "$(cp_profile_field "$CFG" work fallback)" 'config field holds the fallback name'
"$CLI" fallback work --clear >/dev/null 2>&1
assert_eq 'none' "$("$CLI" fallback work 2>/dev/null)" 'fallback cleared'

# --- validation --------------------------------------------------------
assert_fail "$CLI" fallback nope personal
assert_fail "$CLI" fallback work nope
assert_fail "$CLI" fallback work work

# --- removal cleans up a dangling reference ---------------------------
"$CLI" fallback work personal >/dev/null 2>&1
"$CLI" remove personal >/dev/null 2>&1
CFG="$(cp_config_read)"
assert_eq '' "$(cp_profile_field "$CFG" work fallback)" 'removing the fallback target clears the dangling reference'

cp_t_summary
```

- [ ] **Step 2: Run to confirm it fails**

Run: `bash tests/test_fallback.sh`
Expected: FAIL — `fallback.sh` doesn't exist yet, sourcing it errors.

- [ ] **Step 3: Implement `scripts/lib/fallback.sh` (config command only, for now)**

Create `scripts/lib/fallback.sh`:

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# Fallback account: config field, active-swap marker, both swap directions.

# cp_fallback_marker_file <name> -> path (may not exist)
cp_fallback_marker_file() {
  printf '%s/fallback-active/%s.json\n' "$CP_STATE_DIR" "${1:-}"
}

cp_cmd_fallback() {
  local name="${1:-}" target cfg
  [ -n "$name" ] || { cp_warn 'fallback: missing profile name'; return 2; }
  shift
  cfg="$(cp_config_read)" || return 1
  cp_profile_exists "$cfg" "$name" || { cp_warn "unknown profile $name"; return 1; }

  target="${1:-}"
  if [ -z "$target" ]; then
    target="$(cp_profile_field "$cfg" "$name" fallback)"
    printf '%s\n' "${target:-none}"
    return 0
  fi

  if [ "$target" = '--clear' ]; then
    printf '%s' "$cfg" | jq --arg n "$name" \
      '.profiles |= map(if .name == $n then del(.fallback) else . end)' | cp_config_write
    return $?
  fi

  cp_profile_exists "$cfg" "$target" || { cp_warn "unknown profile $target"; return 1; }
  if [ "$target" = "$name" ]; then
    cp_warn 'fallback: a profile cannot be its own fallback'
    return 2
  fi
  printf '%s' "$cfg" | jq --arg n "$name" --arg t "$target" \
    '.profiles |= map(if .name == $n then .fallback = $t else . end)' | cp_config_write
}
```

- [ ] **Step 4: Source it from the CLI entrypoint**

Edit `scripts/cprof`, after the `usage.sh` source line:

```bash
# shellcheck source=lib/usage.sh
. "$CP_LIB_DIR/usage.sh"
# shellcheck source=lib/fallback.sh
. "$CP_LIB_DIR/fallback.sh"
```

Add to the `case "$cmd" in` block, after the `usage)` case:

```bash
  fallback) cp_cmd_fallback "$@" ;;
```

Add to `cp_usage` (the help-text function), after the `cprof usage` line:

```
  cprof fallback <primary>          show the primary's configured fallback, or none
  cprof fallback <primary> <name>   swap to <name> once <primary> hits usage threshold
  cprof fallback <primary> --clear  remove the mapping
```

- [ ] **Step 5: Run to confirm the config-command tests pass**

Run: `bash tests/test_fallback.sh`
Expected: PASS on every assertion except the last (removal cleanup — not implemented yet).

- [ ] **Step 6: Add removal cleanup**

Edit `scripts/lib/profiles.sh`, `cp_cmd_remove` (lines 151-191). Change the `jq` pipeline to also clear a dangling `.fallback` reference, and add a marker cleanup line after the existing usage-cache cleanup:

```bash
  printf '%s' "$cfg" | jq --arg n "$name" \
    '.profiles = [.profiles[]? | select(.name != $n)]
     | .profiles = (.profiles | map(if .fallback == $n then del(.fallback) else . end))
     | .rules   = [.rules[]?   | select(.profile != $n)]
     | .repos   = (.repos | with_entries(select(.value != $n)))
     | if (.default == $n) then .default = (first(.profiles[]?.name) // null) else . end' | cp_config_write || return 1

  # Best-effort: a stale usage cache under this name must never be served to
  # whatever profile (possibly a different account) reuses the name later.
  # Inlined rather than sourcing usage.sh's cp_usage_cache_file, which isn't
  # this file's job. A missing file is not an error.
  rm -f "$CP_STATE_DIR/usage/$name.json"

  # Same reasoning for a fallback marker: a name reused later must not inherit
  # someone else's "currently swapped" state. Inlined for the same reason as
  # the usage-cache line above.
  rm -f "$CP_STATE_DIR/fallback-active/$name.json"
```

- [ ] **Step 7: Run to confirm all pass**

Run: `bash tests/test_fallback.sh`
Expected: PASS on every assertion.

- [ ] **Step 8: Run the full suite to catch regressions in `cp_cmd_remove`**

Run: `bash tests/run.sh`
Expected: all PASS, including the existing `tests/test_profiles.sh` removal assertions.

- [ ] **Step 9: Commit**

```bash
git add scripts/lib/fallback.sh scripts/cprof scripts/lib/profiles.sh tests/test_fallback.sh
git commit -m "feat: add cprof fallback command and config field"
```

---

### Task 2: Widen `cp_keychain_write` to take an optional service

**Files:**
- Modify: `scripts/lib/auth.sh:85-88`
- Modify: `tests/test_auth_status.sh` (regression coverage for the existing caller)

**Interfaces:**
- Consumes: nothing new.
- Produces: `cp_keychain_write <value> [<service>]` — `service` defaults to `$CP_KEYCHAIN_SERVICE` (the bare native item), matching today's only caller (`cp_cmd_login`) exactly, so that caller needs no change.

- [ ] **Step 1: Write the failing test**

The existing stub in `tests/test_auth_status.sh` (`CP_SECURITY_BIN`) only implements `find-generic-password`. Add `add-generic-password` support and a direct assertion. Append near the top of `tests/test_auth_status.sh`, right after the existing `CP_SECURITY_BIN` stub is written (after its `chmod +x "$CP_SECURITY_BIN"` line):

```bash
cat > "$CP_SECURITY_BIN" <<'STUB'
#!/usr/bin/env bash
cmd="$1"; shift
svc='' val=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -s) svc="$2"; shift 2 ;;
    -w) val="$2"; shift 2 ;;
    *)  shift ;;
  esac
done
case "$cmd" in
  find-generic-password)
    [ -n "$svc" ] && [ -f "$CP_T_KEYCHAIN_DIR/$svc" ] || exit 1
    cat "$CP_T_KEYCHAIN_DIR/$svc"
    ;;
  add-generic-password)
    [ -n "$svc" ] || exit 1
    printf '%s' "$val" > "$CP_T_KEYCHAIN_DIR/$svc"
    ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$CP_SECURITY_BIN"

# --- cp_keychain_write: bare service (existing caller, cp_cmd_login) -------
cp_keychain_write 'tok-native'
assert_eq 'tok-native' "$(cat "$CP_T_KEYCHAIN_DIR/Claude Code-credentials")" \
  'cp_keychain_write with no service writes the bare native item'

# --- cp_keychain_write: explicit service (new capability) -----------------
cp_keychain_write 'tok-work-bak' 'Claude Code-credentials-deadbeef-bak'
assert_eq 'tok-work-bak' "$(cat "$CP_T_KEYCHAIN_DIR/Claude Code-credentials-deadbeef-bak")" \
  'cp_keychain_write with an explicit service writes that service'
```

- [ ] **Step 2: Run to confirm it fails**

Run: `bash tests/test_auth_status.sh`
Expected: FAIL on the explicit-service assertion — `cp_keychain_write` ignores a second argument today (it only reads `"$1"`).

- [ ] **Step 3: Widen the function**

Edit `scripts/lib/auth.sh:85-88`:

```bash
cp_keychain_write() {
  "$CP_SECURITY_BIN" add-generic-password -U \
    -a "${USER:-$(id -un)}" -s "${2:-$CP_KEYCHAIN_SERVICE}" -w "$1" >/dev/null 2>&1
}
```

- [ ] **Step 4: Run to confirm all pass**

Run: `bash tests/test_auth_status.sh`
Expected: PASS, including the pre-existing `cp_cmd_login` assertions (unaffected — they never pass a second argument, so they keep hitting the bare service).

- [ ] **Step 5: Run the full suite**

Run: `bash tests/run.sh`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/auth.sh tests/test_auth_status.sh
git commit -m "feat: let cp_keychain_write target a specific service"
```

---

### Task 3: Swap-out

**Files:**
- Modify: `scripts/lib/fallback.sh`
- Modify: `tests/test_fallback.sh`

**Interfaces:**
- Consumes: `cp_profile_field`, `cp_profile_exists`, `cp_creds_file`, `cp_creds_read`, `cp_keychain_service`, `cp_keychain_read`, `cp_keychain_write` (`auth.sh`), `cp_usage_read_cached_only`, `cp_usage_pct`, `cp_usage_resets_at` (`usage.sh`), `cp_fallback_marker_file` (Task 1).
- Produces: `cp_fallback_swap_out <cfg> <name> <dir>` — always returns 0; on a genuine swap, writes the primary's credential storage (file or keychain, whichever already holds its credentials) with the fallback's blob, writes a backup first, and writes the marker file. No-ops silently (with a `cp_warn` when it can't proceed safely) in every other case: no fallback configured, fallback profile doesn't exist, a swap is already active, no usage cache yet, cache below threshold, fallback has no credentials, or the primary has no existing credentials to safely back up.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_fallback.sh` (before `cp_t_summary`):

```bash
# ==========================================================================
# Swap-out
# ==========================================================================
mkdir -p "$CP_T_TMP/w" "$CP_T_TMP/p"
KCD="$CP_T_TMP/keychain.d"
mkdir -p "$KCD"
export CP_T_KEYCHAIN_DIR="$KCD"
cat > "$CP_SECURITY_BIN" <<'STUB'
#!/usr/bin/env bash
cmd="$1"; shift
svc='' val=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -s) svc="$2"; shift 2 ;;
    -w) val="$2"; shift 2 ;;
    *)  shift ;;
  esac
done
case "$cmd" in
  find-generic-password)
    [ -n "$svc" ] && [ -f "$CP_T_KEYCHAIN_DIR/$svc" ] || exit 1
    cat "$CP_T_KEYCHAIN_DIR/$svc"
    ;;
  add-generic-password)
    [ -n "$svc" ] || exit 1
    printf '%s' "$val" > "$CP_T_KEYCHAIN_DIR/$svc"
    ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$CP_SECURITY_BIN"

cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","dir":"$CP_T_TMP/w","fallback":"personal"},{"name":"personal","dir":"$CP_T_TMP/p"}],"rules":[],"repos":{}}
JSON
CFG="$(cp_config_read)"
printf '{"claudeAiOauth":{"accessToken":"tok-personal"}}' > "$CP_T_TMP/p/.credentials.json"

# --- no usage cache yet: no-op --------------------------------------------
printf '{"claudeAiOauth":{"accessToken":"tok-work"}}' > "$CP_T_TMP/w/.credentials.json"
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'no swap with no usage cache'

# --- cache under threshold: no-op -----------------------------------------
mkdir -p "$CP_T_TMP/state/usage"
cat > "$CP_T_TMP/state/usage/work.json" <<'JSON'
{"fetched_at":1,"five_hour":{"utilization":42,"resets_at":"2026-09-14T18:30:00Z"},"seven_day":{"utilization":10,"resets_at":"2026-09-20T00:00:00Z"},"limits":[]}
JSON
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'no swap under threshold'

# --- cache at/above threshold: swaps, file-backed primary ------------------
cat > "$CP_T_TMP/state/usage/work.json" <<'JSON'
{"fetched_at":1,"five_hour":{"utilization":92,"resets_at":"2026-09-14T18:30:00Z"},"seven_day":{"utilization":10,"resets_at":"2026-09-20T00:00:00Z"},"limits":[]}
JSON
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
assert_eq '{"claudeAiOauth":{"accessToken":"tok-personal"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'swap-out overwrites the primary file with the fallback blob'
assert_eq '{"claudeAiOauth":{"accessToken":"tok-work"}}' "$(cat "$CP_T_TMP/w/.credentials.json.bak")" \
  'swap-out backs up the primary original first'
assert_eq 'true' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'swap-out writes the marker'
assert_eq 'personal' "$(jq -r .fallback "$(cp_fallback_marker_file work)")" 'marker records the fallback name'
assert_eq "$CP_T_TMP/w/.credentials.json.bak" "$(jq -r .backup "$(cp_fallback_marker_file work)")" \
  'marker records the backup path'
assert_eq 'file' "$(jq -r .backup_kind "$(cp_fallback_marker_file work)")" 'marker records the backup kind'
assert_eq '2026-09-14T18:30:00Z' "$(jq -r .resets_at "$(cp_fallback_marker_file work)")" \
  'marker records the primary window reset time'
perm="$(cd "$CP_T_TMP/w" && ls -l .credentials.json.bak | cut -c1-10)"
assert_eq '-rw-------' "$perm" 'backup file is mode 600'

# --- already active: no-op, no double-swap ---------------------------------
printf '{"claudeAiOauth":{"accessToken":"tok-personal-v2"}}' > "$CP_T_TMP/p/.credentials.json"
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
assert_eq '{"claudeAiOauth":{"accessToken":"tok-personal"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'an already-active swap does not swap again'
rm -f "$CP_T_TMP/w/.credentials.json.bak" "$(cp_fallback_marker_file work)"
printf '{"claudeAiOauth":{"accessToken":"tok-work"}}' > "$CP_T_TMP/w/.credentials.json"
printf '{"claudeAiOauth":{"accessToken":"tok-personal"}}' > "$CP_T_TMP/p/.credentials.json"

# --- keychain-backed primary -------------------------------------------
rm -f "$CP_T_TMP/w/.credentials.json"
service="$(cp_keychain_service "$CP_T_TMP/w")"
printf '%s' 'tok-work-kc' > "$KCD/$service"
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
assert_eq '{"claudeAiOauth":{"accessToken":"tok-personal"}}' "$(cat "$KCD/$service")" \
  'swap-out writes the fallback blob into the primary keychain item'
assert_eq 'tok-work-kc' "$(cat "$KCD/$service-bak")" 'swap-out backs up the primary keychain item first'
assert_eq 'keychain' "$(jq -r .backup_kind "$(cp_fallback_marker_file work)")" \
  'marker records keychain as the backup kind'
rm -f "$KCD/$service" "$KCD/$service-bak" "$(cp_fallback_marker_file work)"

# --- no fallback configured: no-op -----------------------------------------
cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","dir":"$CP_T_TMP/w"},{"name":"personal","dir":"$CP_T_TMP/p"}],"rules":[],"repos":{}}
JSON
CFG="$(cp_config_read)"
printf '{"claudeAiOauth":{"accessToken":"tok-work"}}' > "$CP_T_TMP/w/.credentials.json"
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'no swap with no fallback configured'

# --- primary has no existing credentials at all: refuses, no marker -------
cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","dir":"$CP_T_TMP/w","fallback":"personal"},{"name":"personal","dir":"$CP_T_TMP/p"}],"rules":[],"repos":{}}
JSON
CFG="$(cp_config_read)"
rm -f "$CP_T_TMP/w/.credentials.json"
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'no swap when the primary has nothing to back up'

# --- forced failure before the final write leaves the primary untouched ---
printf '{"claudeAiOauth":{"accessToken":"tok-work"}}' > "$CP_T_TMP/w/.credentials.json"
chmod 500 "$CP_T_TMP/w"
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
chmod 700 "$CP_T_TMP/w"
assert_eq '{"claudeAiOauth":{"accessToken":"tok-work"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'a write failure leaves the primary credentials untouched'
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'a write failure writes no marker'
```

- [ ] **Step 2: Run to confirm it fails**

Run: `bash tests/test_fallback.sh`
Expected: FAIL — `cp_fallback_swap_out` doesn't exist yet.

- [ ] **Step 3: Implement `cp_fallback_swap_out`**

Append to `scripts/lib/fallback.sh`:

```bash
# cp_fallback_swap_out <cfg> <name> <dir> -> always returns 0. Overwrites
# <name>'s own credential storage with its configured fallback's blob, once
# the cached 5h usage is at/above threshold. No-ops (with a cp_warn) whenever
# it cannot proceed safely.
cp_fallback_swap_out() {
  local cfg="$1" name="$2" dir="$3"
  local fallback cached pct marker file service before blob kind backup

  fallback="$(cp_profile_field "$cfg" "$name" fallback)"
  [ -n "$fallback" ] || return 0

  marker="$(cp_fallback_marker_file "$name")"
  [ -f "$marker" ] && return 0

  cached="$(cp_usage_read_cached_only "$name")"
  [ -n "$cached" ] || return 0
  pct="$(cp_usage_pct "$cached" five_hour)"
  case "$pct" in ''|*[!0-9]*) return 0 ;; esac
  [ "$pct" -ge "${CPROF_FALLBACK_THRESHOLD:-90}" ] || return 0

  cp_profile_exists "$cfg" "$fallback" || {
    cp_warn "fallback: $name's fallback profile $fallback no longer exists"
    return 0
  }

  file="$(cp_creds_file "$cfg" "$name")"
  service="$(cp_keychain_service "$dir")"
  if [ -n "$file" ] && [ -f "$file" ]; then
    kind=file
  elif [ -n "$(cp_keychain_read "$service")" ]; then
    kind=keychain
  else
    cp_warn "fallback: $name has no existing credentials to back up; skipping swap"
    return 0
  fi

  blob="$(cp_creds_read "$cfg" "$fallback")"
  if [ -z "$blob" ]; then
    cp_warn "fallback: $fallback has no credentials to swap in"
    return 0
  fi

  if [ "$kind" = file ]; then
    backup="$file.bak"
    cp "$file" "$backup" 2>/dev/null && chmod 600 "$backup" 2>/dev/null || {
      cp_warn "fallback: could not back up $file"
      unset blob
      return 0
    }
    if ! { printf '%s' "$blob" > "$file.tmp.$$" 2>/dev/null \
        && chmod 600 "$file.tmp.$$" 2>/dev/null \
        && mv "$file.tmp.$$" "$file" 2>/dev/null; }; then
      rm -f "$file.tmp.$$"
      rm -f "$backup"
      cp_warn "fallback: could not write $fallback's credentials for $name"
      unset blob
      return 0
    fi
  else
    backup="$service-bak"
    before="$(cp_keychain_read "$service")"
    if ! cp_keychain_write "$before" "$backup"; then
      cp_warn "fallback: could not back up the keychain item for $name"
      unset blob before
      return 0
    fi
    unset before
    if ! cp_keychain_write "$blob" "$service"; then
      cp_warn "fallback: could not write $fallback's credentials for $name"
      unset blob
      return 0
    fi
  fi
  unset blob

  mkdir -p "$(dirname "$marker")" 2>/dev/null
  chmod 700 "$(dirname "$marker")" 2>/dev/null
  if ! { jq -n --arg fb "$fallback" --arg backup "$backup" --arg kind "$kind" \
      --argjson swapped_at "$(date +%s)" \
      --arg resets_at "$(cp_usage_resets_at "$cached" five_hour)" \
      '{fallback: $fb, backup: $backup, backup_kind: $kind,
        swapped_at: $swapped_at, resets_at: $resets_at}' \
      > "$marker.tmp.$$" 2>/dev/null \
      && chmod 600 "$marker.tmp.$$" 2>/dev/null \
      && mv "$marker.tmp.$$" "$marker" 2>/dev/null; }; then
    rm -f "$marker.tmp.$$"
    cp_warn "fallback: swap to $fallback happened but the marker could not be written for $name"
    return 0
  fi
  cp_warn "profile $name: swapped to fallback $fallback (5h at ${pct}%)"
}
```

- [ ] **Step 4: Run to confirm all pass**

Run: `bash tests/test_fallback.sh`
Expected: PASS on every assertion.

Note on the forced-failure test: it makes `$CP_T_TMP/w` mode 500 (no write) so `cp` (the backup step) fails, and restores it to 700 immediately after the call regardless of outcome, so `cp_t_teardown`'s `rm -rf` isn't left fighting a read-only directory.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/fallback.sh tests/test_fallback.sh
git commit -m "feat: swap a primary's credentials to its fallback when usage is exhausted"
```

---

### Task 4: Swap-back

**Files:**
- Modify: `scripts/lib/fallback.sh`
- Modify: `tests/test_fallback.sh`

**Interfaces:**
- Consumes: `cp_fallback_marker_file` (Task 1), `cp_usage_fetch`, `cp_usage_pct` (`usage.sh`), `cp_keychain_read`, `cp_keychain_write` (`auth.sh`).
- Produces: `cp_fallback_swap_back <cfg> <name>` — always returns 0. Restores the primary's original credentials and deletes the marker once `resets_at` has passed AND a fresh fetch confirms the primary is back under threshold. No-ops otherwise, leaving the marker in place so the next `cprof env` call retries.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_fallback.sh`:

```bash
# ==========================================================================
# Swap-back
# ==========================================================================
cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","dir":"$CP_T_TMP/w","fallback":"personal"},{"name":"personal","dir":"$CP_T_TMP/p"}],"rules":[],"repos":{}}
JSON
CFG="$(cp_config_read)"

# --- no marker: no-op -------------------------------------------------------
rm -f "$(cp_fallback_marker_file work)"
cp_fallback_swap_back "$CFG" work
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'no-op with no marker (still absent)'

# --- marker present, resets_at not yet passed: no-op, marker stays --------
printf '{"claudeAiOauth":{"accessToken":"tok-work"}}' > "$CP_T_TMP/w/.credentials.json"
cp "$CP_T_TMP/w/.credentials.json" "$CP_T_TMP/w/.credentials.json.bak"
printf '{"claudeAiOauth":{"accessToken":"tok-personal"}}' > "$CP_T_TMP/w/.credentials.json"
mkdir -p "$(dirname "$(cp_fallback_marker_file work)")"
cat > "$(cp_fallback_marker_file work)" <<JSON
{"fallback":"personal","backup":"$CP_T_TMP/w/.credentials.json.bak","backup_kind":"file","swapped_at":1,"resets_at":"2099-01-01T00:00:00Z"}
JSON
rm -f "$CP_CURL_BIN"
cp_fallback_swap_back "$CFG" work
assert_eq '{"claudeAiOauth":{"accessToken":"tok-personal"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'no restore before resets_at has passed (no fetch attempted either — CP_CURL_BIN stays absent)'
assert_eq 'true' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'marker stays while resets_at has not passed'

# --- resets_at passed, fresh fetch still over threshold: no-op, retry later
cat > "$(cp_fallback_marker_file work)" <<JSON
{"fallback":"personal","backup":"$CP_T_TMP/w/.credentials.json.bak","backup_kind":"file","swapped_at":1,"resets_at":"2020-01-01T00:00:00Z"}
JSON
cat > "$CP_CURL_BIN" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"five_hour":{"utilization":91,"resets_at":"2026-09-15T00:00:00Z"},
 "seven_day":{"utilization":10,"resets_at":"2026-09-20T00:00:00Z"},"limits":[]}
JSON
STUB
chmod +x "$CP_CURL_BIN"
cp_fallback_swap_back "$CFG" work
assert_eq '{"claudeAiOauth":{"accessToken":"tok-personal"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'still over threshold after the confirming fetch: no restore'
assert_eq 'true' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'marker stays when the confirming fetch is still over threshold'

# --- resets_at passed, fetch fails: no-op, marker stays for a later retry -
cat > "$CP_CURL_BIN" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$CP_CURL_BIN"
cp_fallback_swap_back "$CFG" work
assert_eq 'true' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'a failed confirming fetch leaves the marker for a later retry'

# --- resets_at passed, fetch confirms under threshold: restores -----------
cat > "$CP_CURL_BIN" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"five_hour":{"utilization":12,"resets_at":"2026-09-15T00:00:00Z"},
 "seven_day":{"utilization":10,"resets_at":"2026-09-20T00:00:00Z"},"limits":[]}
JSON
STUB
chmod +x "$CP_CURL_BIN"
cp_fallback_swap_back "$CFG" work
assert_eq '{"claudeAiOauth":{"accessToken":"tok-work"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'restore writes back the original primary credentials'
assert_eq 'false' "$([ -f "$CP_T_TMP/w/.credentials.json.bak" ] && echo true || echo false)" \
  'restore deletes the backup file'
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'restore deletes the marker'

# --- keychain-backed restore ------------------------------------------------
service="$(cp_keychain_service "$CP_T_TMP/w")"
printf '%s' 'tok-work-kc' > "$KCD/$service-bak"
printf '%s' 'tok-personal-kc' > "$KCD/$service"
rm -f "$CP_T_TMP/w/.credentials.json"
cat > "$(cp_fallback_marker_file work)" <<JSON
{"fallback":"personal","backup":"$service-bak","backup_kind":"keychain","swapped_at":1,"resets_at":"2020-01-01T00:00:00Z"}
JSON
cp_fallback_swap_back "$CFG" work
assert_eq 'tok-work-kc' "$(cat "$KCD/$service")" 'keychain restore writes back the original value'
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'keychain restore deletes the marker'

# --- restore write failure: marker stays for a retry, nothing is deleted --
printf '{"claudeAiOauth":{"accessToken":"tok-work"}}' > "$CP_T_TMP/w/.credentials.json.bak"
printf '{"claudeAiOauth":{"accessToken":"tok-personal"}}' > "$CP_T_TMP/w/.credentials.json"
cat > "$(cp_fallback_marker_file work)" <<JSON
{"fallback":"personal","backup":"$CP_T_TMP/w/.credentials.json.bak","backup_kind":"file","swapped_at":1,"resets_at":"2020-01-01T00:00:00Z"}
JSON
chmod 500 "$CP_T_TMP/w"
cp_fallback_swap_back "$CFG" work
chmod 700 "$CP_T_TMP/w"
assert_eq 'true' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'a restore-write failure leaves the marker in place for a retry'
assert_eq 'true' "$([ -f "$CP_T_TMP/w/.credentials.json.bak" ] && echo true || echo false)" \
  'a restore-write failure leaves the backup in place for a retry'
chmod 700 "$CP_T_TMP/w"
rm -f "$CP_T_TMP/w/.credentials.json.bak" "$(cp_fallback_marker_file work)"
```

- [ ] **Step 2: Run to confirm it fails**

Run: `bash tests/test_fallback.sh`
Expected: FAIL — `cp_fallback_swap_back` doesn't exist yet.

- [ ] **Step 3: Implement `cp_fallback_swap_back`**

Append to `scripts/lib/fallback.sh`:

```bash
# cp_fallback_swap_back <cfg> <name> -> always returns 0. Restores <name>'s
# original credentials once its marker's resets_at has passed AND a fresh
# fetch confirms it is back under threshold. Leaves the marker in place (for
# a retry on the next call) whenever it cannot confirm or cannot restore.
cp_fallback_swap_back() {
  local cfg="$1" name="$2"
  local marker resets_at resets_epoch now_epoch fresh pct fallback backup kind file before

  marker="$(cp_fallback_marker_file "$name")"
  [ -f "$marker" ] || return 0

  resets_at="$(jq -r '.resets_at // empty' "$marker" 2>/dev/null)"
  [ -n "$resets_at" ] || return 0
  resets_epoch="$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$resets_at" +%s 2>/dev/null)"
  case "$resets_epoch" in ''|*[!0-9]*) return 0 ;; esac
  now_epoch="$(date +%s)"
  [ "$now_epoch" -ge "$resets_epoch" ] || return 0

  fresh="$(cp_usage_fetch "$cfg" "$name")" || return 0
  pct="$(cp_usage_pct "$fresh" five_hour)"
  case "$pct" in ''|*[!0-9]*) return 0 ;; esac
  [ "$pct" -lt "${CPROF_FALLBACK_THRESHOLD:-90}" ] || return 0

  fallback="$(jq -r '.fallback // empty' "$marker" 2>/dev/null)"
  backup="$(jq -r '.backup // empty' "$marker" 2>/dev/null)"
  kind="$(jq -r '.backup_kind // empty' "$marker" 2>/dev/null)"
  if [ -z "$backup" ] || [ -z "$kind" ]; then
    rm -f "$marker"
    return 0
  fi

  if [ "$kind" = file ]; then
    if [ ! -f "$backup" ]; then
      cp_warn "fallback: backup $backup missing for $name; leaving $fallback active"
      return 0
    fi
    file="${backup%.bak}"
    if ! { cp "$backup" "$file.tmp.$$" 2>/dev/null \
        && chmod 600 "$file.tmp.$$" 2>/dev/null \
        && mv "$file.tmp.$$" "$file" 2>/dev/null; }; then
      rm -f "$file.tmp.$$"
      cp_warn "fallback: restore failed for $name; leaving $fallback active"
      return 0
    fi
    rm -f "$backup"
  else
    before="$(cp_keychain_read "$backup")"
    if [ -z "$before" ]; then
      cp_warn "fallback: backup keychain item $backup missing for $name; leaving $fallback active"
      return 0
    fi
    if ! cp_keychain_write "$before" "${backup%-bak}"; then
      unset before
      cp_warn "fallback: restore failed for $name; leaving $fallback active"
      return 0
    fi
    unset before
    # security(1) has no delete path this codebase wraps; the -bak item is
    # left behind, harmless dead weight that the next swap-out overwrites.
  fi

  rm -f "$marker"
  cp_warn "profile $name: restored from fallback $fallback (5h back to ${pct}%)"
}
```

- [ ] **Step 4: Run to confirm all pass**

Run: `bash tests/test_fallback.sh`
Expected: PASS on every assertion.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/fallback.sh tests/test_fallback.sh
git commit -m "feat: restore a primary's own credentials once its usage window resets"
```

---

### Task 5: Wire both directions into `cprof env`

**Files:**
- Modify: `scripts/lib/output.sh:80-110` (`cp_cmd_env`)
- Modify: `tests/test_fallback.sh`

**Interfaces:**
- Consumes: `cp_fallback_swap_back`, `cp_fallback_swap_out` (Tasks 3-4).
- Produces: no new functions — `cp_cmd_env` calls both, in that order, right after it confirms the profile is non-native with a real directory, before it prints the export line. Neither call can change what gets printed or `cp_cmd_env`'s return code.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_fallback.sh`:

```bash
# ==========================================================================
# Wired into cprof env
# ==========================================================================
cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","dir":"$CP_T_TMP/w","fallback":"personal"},{"name":"personal","dir":"$CP_T_TMP/p"}],"rules":[],"repos":{}}
JSON
printf '{"claudeAiOauth":{"accessToken":"tok-work"}}' > "$CP_T_TMP/w/.credentials.json"
printf '{"claudeAiOauth":{"accessToken":"tok-personal"}}' > "$CP_T_TMP/p/.credentials.json"
cat > "$CP_T_TMP/state/usage/work.json" <<'JSON'
{"fetched_at":1,"five_hour":{"utilization":95,"resets_at":"2026-09-14T18:30:00Z"},"seven_day":{"utilization":10,"resets_at":"2026-09-20T00:00:00Z"},"limits":[]}
JSON
out="$("$CLI" env 2>/dev/null)"
assert_eq "export CLAUDE_CONFIG_DIR=$(cp_shquote "$CP_T_TMP/w")" "$out" \
  'cprof env still points at the primary directory after a swap'
assert_eq '{"claudeAiOauth":{"accessToken":"tok-personal"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'cprof env triggered the swap-out as a side effect'
rc=0
"$CLI" env >/dev/null 2>&1 || rc=$?
assert_eq '0' "$rc" 'cprof env still exits 0 with a swap active'
```

- [ ] **Step 2: Run to confirm it fails**

Run: `bash tests/test_fallback.sh`
Expected: FAIL — `cprof env` doesn't call the swap functions yet, so the credential file is unchanged.

- [ ] **Step 3: Wire it up**

Edit `scripts/lib/output.sh`, `cp_cmd_env` (lines 80-110). Add the two calls right after the directory is confirmed to exist, before the `printf 'export ...'` line:

```bash
  dir="$(cp_profile_dir "$cfg" "$name")"
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    cp_unset_line
    cp_warn "profile $name directory missing (${dir:-unset}); using stock configuration"
    return 0
  fi
  cp_fallback_swap_back "$cfg" "$name"
  cp_fallback_swap_out "$cfg" "$name" "$dir"
  printf 'export CLAUDE_CONFIG_DIR=%s\n' "$(cp_shquote "$dir")"
  cp_warn "profile $name - $reason"
  return 0
```

Swap-back runs first deliberately: if it restores and refreshes the usage cache in the same call, swap-out's cache-based check immediately after reads the just-refreshed (under-threshold) value instead of the stale over-threshold one, so the two never fight each other within one `cprof env` call.

- [ ] **Step 4: Run to confirm all pass**

Run: `bash tests/test_fallback.sh`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `bash tests/run.sh`
Expected: all PASS, including the existing `cprof env` assertions in other test files (unaffected — none of them configure a `.fallback` field, so both new calls no-op silently on their very first check).

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/output.sh tests/test_fallback.sh
git commit -m "feat: trigger fallback swap-out and swap-back from cprof env"
```

---

### Task 6: Visibility — `doctor`, `list`, `which`

**Files:**
- Modify: `scripts/lib/auth.sh:140-187` (`cp_cmd_doctor`)
- Modify: `scripts/lib/output.sh:149-224` (`cp_cmd_list`, `cp_cmd_which`)
- Modify: `tests/test_fallback.sh`
- Modify: `tests/test_auth_status.sh`

**Interfaces:**
- Consumes: `cp_fallback_marker_file` (Task 1).
- Produces: no new functions — `doctor` prints an extra line per profile with an active marker (does not change `status`); `list` renders a swapped profile's name cell as `<name>→<fallback>`; `which` appends a would-fire note when the resolved profile has a fallback configured and its cached 5h usage is at/above threshold but no swap is active yet.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_auth_status.sh` (before `cp_t_summary`):

```bash
# --- doctor: active-swap line ----------------------------------------------
mkdir -p "$CP_T_TMP/state/fallback-active"
cat > "$CP_T_TMP/state/fallback-active/personal.json" <<'JSON'
{"fallback":"work","backup":"/tmp/whatever.bak","backup_kind":"file","swapped_at":1,"resets_at":"2026-09-14T18:30:00Z"}
JSON
out="$(cd "$CP_T_TMP" && "$CLI" doctor 2>&1)"
case "$out" in *'personal: fallback active (using work'*'2026-09-14T18:30:00Z'*) assert_eq ok ok 'doctor shows the active-swap line' ;;
                *) assert_eq 'personal: fallback active (using work ... 2026-09-14T18:30:00Z)' "$out" 'doctor shows the active-swap line' ;; esac
rm -f "$CP_T_TMP/state/fallback-active/personal.json"
```

Append to `tests/test_fallback.sh` (before `cp_t_summary`):

```bash
# ==========================================================================
# Visibility: list, which
# ==========================================================================
cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","dir":"$CP_T_TMP/w","fallback":"personal"},{"name":"personal","dir":"$CP_T_TMP/p"}],"rules":[],"repos":{}}
JSON
printf '{"claudeAiOauth":{"accessToken":"tok-work"}}' > "$CP_T_TMP/w/.credentials.json"
printf '{"claudeAiOauth":{"accessToken":"tok-personal"}}' > "$CP_T_TMP/p/.credentials.json"
cat > "$CP_CLAUDE_BIN" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = auth ] && [ "${2:-}" = status ] && printf '{"loggedIn":true,"email":"me@x.com","subscriptionType":"max"}\n'
STUB
chmod +x "$CP_CLAUDE_BIN"
mkdir -p "$CP_T_TMP/state/fallback-active"
cat > "$CP_T_TMP/state/fallback-active/work.json" <<JSON
{"fallback":"personal","backup":"$CP_T_TMP/w/.credentials.json.bak","backup_kind":"file","swapped_at":1,"resets_at":"2026-09-14T18:30:00Z"}
JSON
out="$(NO_COLOR=1 "$CLI" list 2>/dev/null)"
case "$out" in *'work'*'personal'*) assert_eq ok ok 'list annotates the swapped row' ;;
                *) assert_eq 'work...personal' "$out" 'list annotates the swapped row' ;; esac
rm -f "$CP_T_TMP/state/fallback-active/work.json"

# --- which: would-fire note, only when no swap is active yet --------------
rm -f "$CP_T_TMP/state/usage/work.json"
cat > "$CP_T_TMP/state/usage/work.json" <<'JSON'
{"fetched_at":1,"five_hour":{"utilization":95,"resets_at":"2026-09-14T18:30:00Z"},"seven_day":{"utilization":10,"resets_at":"2026-09-20T00:00:00Z"},"limits":[]}
JSON
out="$(cd "$CP_T_TMP" && NO_COLOR=1 "$CLI" which 2>/dev/null)"
case "$out" in *'personal'*) assert_eq ok ok 'which notes the fallback would fire' ;;
                *) assert_eq '...personal...' "$out" 'which notes the fallback would fire' ;; esac
```

- [ ] **Step 2: Run to confirm failure**

Run: `bash tests/test_auth_status.sh && bash tests/test_fallback.sh`
Expected: FAIL — none of the three commands know about fallback state yet.

- [ ] **Step 3: Add the doctor line**

Edit `scripts/lib/auth.sh`, `cp_cmd_doctor`, inside the `for name in $names; do` loop, right after the existing usage-warning block (after its closing `fi` for the `[ -n "$usage_data" ]` check):

```bash
    if [ -f "$(cp_fallback_marker_file "$name")" ]; then
      printf '%s: fallback active (using %s, restores after it resets ~%s)\n' \
        "$name" \
        "$(jq -r '.fallback // "unknown"' "$(cp_fallback_marker_file "$name")" 2>/dev/null)" \
        "$(jq -r '.resets_at // "unknown"' "$(cp_fallback_marker_file "$name")" 2>/dev/null)"
    fi
```

This does not touch `status` — an active, working fallback is not a doctor failure.

- [ ] **Step 4: Add the list annotation**

Edit `scripts/lib/output.sh`, `cp_cmd_list`. Change the row-building block to check for an active marker and append `→<fallback>` to the name cell before colorizing:

```bash
      data="$(cp_usage_read "$cfg" "$name")"
      display_name="$name"
      if [ -f "$(cp_fallback_marker_file "$name")" ]; then
        display_name="$name→$(jq -r '.fallback // "?"' "$(cp_fallback_marker_file "$name")" 2>/dev/null)"
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(cp_colorize "$(cp_color_for "$cfg" "$name")" "$display_name")" \
        "$sub" "$email" \
        "$(cp_usage_render "$(cp_usage_pct "$data" five_hour)")" \
        "$(cp_usage_render "$(cp_usage_pct "$data" seven_day)")" \
        "${markers# }"
```

Add `display_name` to `cp_cmd_list`'s `local` declaration:

```bash
  local cfg names name active default_name st email sub markers dir data display_name CP_COLOR_ON=0
```

- [ ] **Step 5: Add the `which` would-fire note**

Edit `scripts/lib/output.sh`, `cp_cmd_which`. Add a check right before the final `if cp_profile_is_native ...` branch:

```bash
  note=''
  if [ ! -f "$(cp_fallback_marker_file "$name")" ]; then
    fallback="$(cp_profile_field "$cfg" "$name" fallback)"
    if [ -n "$fallback" ]; then
      pct="$(cp_usage_pct "$(cp_usage_read_cached_only "$name")" five_hour)"
      case "$pct" in
        ''|*[!0-9]*) : ;;
        *) [ "$pct" -ge "${CPROF_FALLBACK_THRESHOLD:-90}" ] && note=" (would fall back to $fallback)" ;;
      esac
    fi
  fi
```

Add `fallback pct note` to `cp_cmd_which`'s `local` declaration (currently `local cfg line name reason dir CP_COLOR_ON=0`):

```bash
  local cfg line name reason dir fallback pct note CP_COLOR_ON=0
```

Then append `$note` to `reason` right before the two `cp_table`-piped `printf` calls that follow:

```bash
  reason="$reason$note"
```

- [ ] **Step 6: Run to confirm all pass**

Run: `bash tests/test_auth_status.sh && bash tests/test_fallback.sh`
Expected: PASS on every assertion.

- [ ] **Step 7: Run the full suite**

Run: `bash tests/run.sh`
Expected: all PASS, including existing `test_tables.sh` alignment cases (the `→` character is a single display column wide like the ASCII it sits next to, so it does not need the same byte-vs-character normalization `cp_table` already applies to `▓`/`░`/`⚑` — confirm this by inspection of the alignment test's output during this run rather than assuming, since `cp_table`'s awk measures by `length()` and any character outside its explicit `gsub` list is otherwise assumed single-width).

- [ ] **Step 8: Commit**

```bash
git add scripts/lib/auth.sh scripts/lib/output.sh tests/test_fallback.sh tests/test_auth_status.sh
git commit -m "feat: surface active and would-fire fallback state in doctor, list, and which"
```

---

### Task 7: Docs — README, security assessment, CHANGELOG

**Files:**
- Modify: `README.md`
- Modify: `docs/security-assessment.md`
- Modify: `CHANGELOG.md`

**Interfaces:** none — documentation only.

- [ ] **Step 1: Add a README commands table row**

Edit `README.md`, the table at line 394. Add a row after the `cprof usage [<name>]` row (line 412):

```markdown
| `cprof fallback <primary> [<name>\|--clear]` | Show, set, or clear a live-swap fallback for when `<primary>` runs out of usage headroom |
```

- [ ] **Step 2: Document the swap behavior**

Edit `README.md`, right after the Statusline section's usage-badge paragraph (after line ~433, the paragraph ending "...colored red/yellow/green by how close it is to the cap"), add a new subsection:

```markdown
## Fallback accounts

`cprof fallback work personal` makes `personal` a live stand-in for `work`:
once `work`'s cached 5-hour usage hits 90% (override with
`CPROF_FALLBACK_THRESHOLD`), the next `cprof env` call overwrites `work`'s
own credential storage with `personal`'s, so an already-running `claude`
session under `work` starts authenticating as `personal` on its next token
use — no restart needed. `work`'s original credentials are backed up first
and restored automatically, with a fresh confirming check, once `work`'s
usage window resets.

This is the one place cprof changes a live session's credentials rather
than just choosing a directory. `cprof doctor` shows an active swap and
when it will restore; `cprof list` marks the row `work→personal`; `cprof
which` notes when a swap would fire before it actually does. Clear the
mapping with `cprof fallback work --clear`.
```

- [ ] **Step 3: Add a security-assessment row and accepted-risk note**

Edit `docs/security-assessment.md`. Add a row to the "Attack surface and mitigations" table (after the "Usage endpoint fetch" row):

```markdown
| Fallback swap (`cprof env`) | A live session's credentials change to a different account without the session restarting | Opt-in per profile (`cprof fallback`); the primary's original credentials are backed up (sibling file or `-bak` keychain item) before any overwrite, atomically, and restored automatically once usage resets and a fresh fetch confirms it. A write failure before the final mv/keychain-write leaves the primary's live credentials untouched |
```

Add a bullet to "Accepted risks":

```markdown
- **A fallback swap changes a live session's credentials underneath it.**
  This is a deliberate reversal of cprof's normal "directory decides, a
  session's credentials never change after launch" model, opt-in per
  profile via `cprof fallback`. If a session with a fallback swapped in
  never exits cleanly before the primary's window resets, the restore
  still runs on the next `cprof env` call from *any* session (including a
  fresh one), and the backup is never deleted until a restore actually
  succeeds — but there is no guarantee a restore runs promptly if `cprof
  env` is never invoked again for that profile.
```

- [ ] **Step 4: Add a CHANGELOG entry**

Edit `CHANGELOG.md`. Add to the `## [Unreleased]` section (currently empty, right after the header):

```markdown
## [Unreleased]

### Added
- `cprof fallback <primary> <name>` — live credential swap to a fallback
  profile once the primary's usage is exhausted, with an automatic,
  confirmed restore once it resets. Visible in `cprof doctor` (active swap),
  `cprof list` (annotated row), and `cprof which` (would-fire note). Override
  the 90% trigger with `CPROF_FALLBACK_THRESHOLD`.
```

- [ ] **Step 5: Commit**

```bash
git add README.md docs/security-assessment.md CHANGELOG.md
git commit -m "docs: document cprof fallback, the live credential swap, and its accepted risk"
```

---

### Task 8: Full verification and PR

**Files:** none (verification + delivery only).

**Interfaces:** none.

- [ ] **Step 1: Run the full test suite**

Run: `bash tests/run.sh`
Expected: every test file passes, including the new `tests/test_fallback.sh` and the modified `tests/test_auth_status.sh`.

- [ ] **Step 2: Run shellcheck**

Run:
```bash
shellcheck -x -P scripts -P tests scripts/cprof scripts/lib/*.sh hooks/*.sh \
  statusline/*.sh tests/*.sh install.sh
```
Expected: no warnings. Fix anything it flags in `fallback.sh` or the edited files before proceeding.

- [ ] **Step 3: Validate the plugin manifest**

Run: `claude plugin validate .`
Expected: passes.

- [ ] **Step 4: Capture terminal screenshots for the PR**

With at least one fixture profile configured, capture screenshots showing colored output for:
- `cprof doctor` with an active swap (the fallback-active line)
- `cprof list` with a swapped row (`work→personal`)
- `cprof which` showing the would-fire note before a swap has happened

This satisfies the spec's Delivery section and the saved project preference that any PR touching cprof's UI includes screenshots of the actual colored output.

- [ ] **Step 5: Open the PR**

Use the `superpowers:finishing-a-development-branch` skill to open the pull request, attaching the screenshots from Step 4 and linking `docs/superpowers/specs/2026-09-14-fallback-account-design.md` in the description (as text, not a repo link — that directory is gitignored and won't exist on the remote branch).
