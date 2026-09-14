# Per-profile usage in `list`, `doctor`, and a new `usage` command

Status: approved (pending spec review)
Owner: Diego Cotelo
Related: clauth review synthesis (Obsidian vault note `clauth-ideas-for-cprof`, idea 1)

## Context

cprof (bash 3.2 + jq) routes Claude Code sessions to an account by directory,
via `CLAUDE_CONFIG_DIR`. It never touches a live login. A review of `clauth`
(a Rust multi-account manager with live usage monitoring) surfaced usage
visibility as the biggest gap: cprof has no way to show how close a profile is
to its rate limit.

This spec covers idea 1 from that review: per-profile usage in `cprof list`,
`cprof doctor`, and the statusline, plus a new `cprof usage` command for the
full breakdown. It is cprof's first feature that makes a network call.

Deliberately out of scope (per the synthesis and user preference for cprof's
directory-decides model over clauth's account-swap model): auto-switch
fallback chains, in-place credential swapping, a TUI/daemon, and the
`SessionStart`/`UserPromptSubmit` headroom nudge hook (synthesis idea 2) —
that hook can reuse this feature's cache later, but is a separate PR.

## Endpoint

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <claudeAiOauth.accessToken>
anthropic-beta: oauth-2025-04-20
```

Response carries `five_hour` and `seven_day` objects with `utilization`
(0-100) and `resets_at` (ISO 8601), plus a `limits[]` array whose entries have
`kind` of `session` (5h), `weekly_all` (7d), or `weekly_scoped` (per model,
with `scope.model.display_name`). This shape comes from reading clauth's
`src/usage/fetch.rs` at commit `435a859f`, not from an independently verified
live request — the implementation must tolerate missing fields.

## Architecture

New `scripts/lib/usage.sh`, sourced by `scripts/cprof` alongside the existing
lib files.

- **Fetch is on-demand, not backgrounded.** `cprof list`, `cprof doctor`, and
  `cprof usage` each may make one HTTP call per profile they display, with a
  short timeout. The user asked for the data, so a network call and a
  1-2 second wait are expected.
- **The statusline never fetches.** `statusline/segment.sh` runs every few
  seconds and must stay instant; it reads whatever is cached and shows
  nothing if there is no cache yet. This is a hard constraint, not a
  performance nice-to-have.
- **Cache is the only thing shared between the two.** `cp_usage_fetch` writes
  it; `cp_usage_read` (foreground commands) refreshes it when stale;
  `cp_usage_read_cached_only` (statusline) only ever reads it.

## Cache

Path: `$CP_STATE_DIR/usage/<profile-name>.json`, mode 600, directory mode 700
(same discipline as `cp_cmd_login`'s use of `CP_STATE_DIR`). Keyed by profile
name rather than config dir, since a native profile has no dir and names are
already unique in `~/.cprof.json`.

Contents (synthetic example, not real credentials or account data):

```json
{
  "fetched_at": 1735689600,
  "five_hour": {"utilization": 42, "resets_at": "2026-09-14T18:30:00Z"},
  "seven_day": {"utilization": 18, "resets_at": "2026-09-20T00:00:00Z"},
  "limits": [
    {"kind": "weekly_scoped", "utilization": 55, "resets_at": "2026-09-20T00:00:00Z",
     "scope": {"model": {"display_name": "Claude Opus 4.5"}}}
  ]
}
```

TTL: 5 minutes, checked against `fetched_at`. Chosen over 60s (too many calls
for no real gain — a 5h window doesn't move that fast) and 15min (more likely
to show a stale number right when the user is checking because they're
worried about hitting a cap).

## Functions (`scripts/lib/usage.sh`)

- `cp_usage_cache_file <name>` — the path above.
- `cp_usage_fetch <cfg> <name>` — reads the token via the existing
  `cp_creds_read <cfg> <name> | jq -r '.claudeAiOauth.accessToken // empty'`,
  returns 1 if empty (not logged in / native profile with no session).
  Otherwise calls curl with a `-K -` config block piped over stdin so the
  bearer token never appears in argv (`ps` stays clean):

  ```sh
  printf 'header = "Authorization: Bearer %s"\nheader = "anthropic-beta: oauth-2025-04-20"\n' "$token" \
    | "$CP_CURL_BIN" -sS --max-time 2 -K - "$CP_USAGE_URL"
  ```

  `CP_CURL_BIN` (default `curl`) and `CP_USAGE_URL` (default the endpoint
  above) are overridable the same way `CP_CLAUDE_BIN`/`CP_SECURITY_BIN` are in
  `auth.sh`, so tests can stub them. Note: the token still passes through a
  local shell variable to build the config block — cprof's existing
  `cp_creds_read` discipline of "pipe straight into jq, never let it land in a
  variable" can't be fully kept here because curl's stdin-config trick needs
  the value interpolated into a string first. This is still strictly better
  than argv (invisible to `ps`), and is called out explicitly in the
  SECURITY.md network-activity entry below rather than glossed over.

  On success (valid JSON with a 2xx-shaped body), writes the cache file
  (`umask 077`) and prints it. On any failure — timeout, non-JSON, curl error,
  empty token — returns 1 and touches nothing, so a temporary blip never
  clobbers a good cache with silence.

- `cp_usage_read <cfg> <name>` — the foreground path (`list`, `doctor`,
  `usage`). If `CPROF_NO_USAGE=1`, behaves like `cp_usage_read_cached_only`
  (below) and never fetches. Otherwise: if cache exists and `fetched_at` is
  within TTL, prints it; else calls `cp_usage_fetch`; if that fails, falls
  back to the stale cache if one exists; if there is no cache at all, prints
  nothing and the caller shows `-`.

- `cp_usage_read_cached_only <name>` — statusline path. Reads the cache file
  if present, regardless of age, and never calls fetch. No profile
  resolution needed since the statusline already knows its own name.

- `cp_usage_pct <json> <window>` — `jq -r '.[$window].utilization // empty'`
  wrapper, `window` is `five_hour` or `seven_day`.

- `cp_usage_render <pct>` — builds the 10-block bar (`▓` filled, `░` empty,
  filled count = `pct / 10` rounded) plus `NN%`, wrapped in an SGR color:
  green (<70), yellow (70-89), red (≥90). Honors the same
  `cp_color_enabled`/`NO_COLOR`/`CPROF_COLOR` rules `color.sh` already
  applies elsewhere — this is a new small helper in `usage.sh`, not a change
  to `color.sh`'s per-profile hashed-color logic, since it's a severity color
  rather than an identity color.

## Command changes

### `cp_cmd_list` (`output.sh`)

Two new columns, `5H` and `7D`, added to the existing tab-separated table
between `ACCOUNT` and `FLAGS`. For each profile, `cp_usage_read` then
`cp_usage_pct` then `cp_usage_render`; `-` (plain, no color) when there's no
data (opted out, never fetched, not logged in, or fetch failed with no
cache).

### `cp_cmd_doctor` (`auth.sh`)

After the existing logged-in/refresh-token checks for a profile, read usage
the same way and add a line when a window's utilization is ≥90:

```
work: 5h window at 92% (resets 2026-09-14T18:30:00Z)
```

and set `status=1`, consistent with how the refresh-token-expiring check
already does it. Silent (no line, no status change) when usage data isn't
available — this must never turn an otherwise-healthy profile into a
doctor failure just because the network was down.

### New `cp_cmd_usage [name]` (`usage.sh`)

- No argument: one row per profile, same bar+pct rendering as `list` but
  usage-only (`PROFILE  5H  7D`), for a quick "am I close to any cap" view.
  The `PROFILE` cell uses the same `cp_colorize "$(cp_color_for ...)"`
  identity color `list`/`which` already use — every UI surface this feature
  touches (`list`, `doctor`, `usage`, statusline) carries color: identity
  color for profile names, severity color for the bar/percent, consistently
  gated by the existing `cp_color_enabled`/`NO_COLOR`/`CPROF_COLOR` checks.
- With a profile name: full breakdown for that profile — 5h bar, 7d bar, and
  one line per `weekly_scoped` limit showing its model's `display_name`, all
  with `resets_at` printed alongside each. This is the only place the
  per-model breakdown is shown; `list` and `doctor` stay to the two
  aggregate windows to keep those tables narrow.
- Respects `CPROF_NO_USAGE` and the cache/TTL rules the same as `list`.

### `scripts/cprof` dispatcher

Add `usage) cp_cmd_usage "$@" ;;` and a `cprof usage [<name>]` line in
`cp_usage` (the help text function — unfortunate existing name collision with
the new `cp_usage_*` functions; the help function stays `cp_usage` since
renaming it is out of scope, and there's no real collision since one is a
function in `scripts/cprof` and the others live in `scripts/lib/usage.sh`
with no shared call site — but worth a comment in the code so a future
reader isn't confused).

### `statusline/segment.sh`

After resolving `name` (unchanged), the segment needs the pre-rendered 5h
bar+pct without sourcing lib files directly (it currently treats the CLI as a
service, e.g. `color --render`). Decision: add a `cprof usage --render <name>`
subcommand mirroring the existing `color --render` pattern, printing just the
bar+pct (tab-free) for the segment to splice in. Output changes only when a
cache exists:

```
⚑ work ▓▓▓░░░░░░░ 42%
```

No cache (never ran `list`/`doctor`/`usage`, or opted out): identical to
today's `⚑ work`, zero behavior change.

## Error handling summary

| Situation | Behavior |
|---|---|
| No network / timeout, no prior cache | `-` in `list`, silent in `doctor`, nothing in statusline |
| No network / timeout, stale cache exists | Foreground commands show the stale value (no explicit "stale" marker in v1 — noted as a future refinement, not blocking) |
| `CPROF_NO_USAGE=1` | No fetch attempted anywhere; an existing cache is still shown (even if stale), and a profile with no cache at all falls back to the normal no-data behavior (`-` in `list`, silent in `doctor`, nothing in statusline) |
| Native profile / not logged in | Same as no token: `cp_usage_fetch` returns 1 immediately |
| Malformed API response | Treated as fetch failure |

## Security & docs

- `SECURITY.md`: new row in its network-activity table — endpoint, trigger
  (`list`/`doctor`/`usage`, never statusline), payload (bearer token in
  header, nothing in the body), and the token-in-variable caveat from the
  `cp_usage_fetch` section above.
- `SECURITY.md` / README: document `CPROF_NO_USAGE=1`.
- `CHANGELOG.md`: entry for the release that ships this.
- `README.md`: `usage` added to the command list, `5H`/`7D` columns
  mentioned under `list`.

## Testing

New `tests/test_usage.sh`, following `tests/test_auth_status.sh`'s stub
pattern:

- Stub `CP_CURL_BIN` as a fake script reading its `-K -` stdin config and
  returning canned JSON (success, timeout via `sleep` past `--max-time`,
  malformed body, HTTP-error-shaped body) keyed off which fixture the test
  wants.
- Assert: cache file is written mode 600 on success; a fresh cache is served
  without invoking curl again (TTL respected — bump `fetched_at` in the
  fixture to test both sides); `CPROF_NO_USAGE=1` never invokes curl;
  `cp_cmd_doctor` emits the warning and sets exit 1 at ≥90% and stays silent
  under it; `cp_cmd_list` shows `-` when there's no token; the statusline's
  `--render` output is empty with no cache and matches the expected bar
  string with one.
- Existing `tests/test_status.sh` / `tests/test_cli.sh` should not need
  changes since the new columns/command are additive, but a quick pass to
  confirm `cp_table`'s column alignment still holds with the two new columns
  is worth a case in `tests/test_tables.sh`.

## Delivery

The PR for this feature includes terminal screenshots showing the colored
output — `list` with the new columns, `doctor`'s warning line, `usage` (both
forms), and the statusline badge — since color is a core part of what this
feature is for and a text-only diff doesn't show it.

## Open questions carried into implementation (non-blocking)

- Exact rounding rule for the 10-block bar at boundary values (e.g. does 95%
  show 9 or 10 filled blocks) — pick one during implementation, cover it with
  a test, no need to re-litigate the design for it.
- Whether `doctor`'s 90% threshold should be a `CPROF_*` env override like
  other thresholds in the codebase, or a flat constant — lean flat constant
  for v1, matching the existing refresh-token-expiry threshold's style
  (`1209600000` ms, not configurable).
