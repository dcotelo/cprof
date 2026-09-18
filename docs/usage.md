# Usage and fallback

How much of its five-hour and seven-day windows a profile has spent, and what
happens when one runs out.

## Usage headroom

Two accounts means two rate limits, and the one you are about to hit is rarely
the one you are looking at. `cprof list` carries each profile's 5-hour and
7-day windows as a bar, `cprof usage` shows only that, and `cprof usage <name>`
adds the per-model weekly limits and when each window resets:

<p align="center">
  <img alt="cprof list with 5H and 7D usage bars per profile, cprof usage work showing the full breakdown with reset times, and cprof doctor warning that personal is at 91% of its 5-hour window" src="usage-demo.gif" width="860">
</p>

The bar turns yellow at 70% and red at 90%, the same threshold at which
`cprof doctor` starts reporting the profile. Numbers come from the account's
own usage endpoint, cached for five minutes under `~/.cprof/usage/`, so a
`list` right after a `usage` costs no second request; set `CPROF_NO_USAGE=1`
to turn fetching off everywhere and show whatever is cached (or `-`) instead.

## Fallback accounts

`cprof fallback work personal` makes `personal` a live stand-in for `work`:
once `work`'s cached 5-hour usage hits 90% (override with
`CPROF_FALLBACK_THRESHOLD`), the next `cprof env` call overwrites `work`'s
own credential storage with `personal`'s, so an already-running `claude`
session under `work` starts authenticating as `personal` on its next token
use — no restart needed. `work`'s original credentials are backed up first
and restored by the first `cprof env` call after `work`'s usage window
resets, once a fresh fetch confirms it is back under threshold — an idle
session is not restored until something launches `claude` again. A mutual
pair (`work → personal` and `personal → work`) is refused, like any chain: a
profile is a primary or a fallback target, never both.

If a swap or restore is interrupted mid-write (a crash, a killed process),
it recovers or fails safely rather than corrupting anything:

- **Interrupted swap-out**: the marker is staged as `<name>.json.pending`
  before any credential changes hands. On the next `cprof env`, cprof
  compares the backup with the live store: identical means the overwrite
  never ran, so the backup and the pending file are discarded; different
  means it did, so the pending file becomes the marker and the normal
  restore takes over. `cprof doctor` reports the interrupted swap until then.
- **Stuck restored with a leftover marker**: the credentials were correctly
  restored, but the marker survived. `cprof doctor`/`list` show a phantom
  active swap, and fallback swaps stop firing for that profile. Recover by
  deleting the marker file under `~/.cprof/fallback-active/` — `<name>.json`
  for an ordinary name; a name with characters outside `A-Z a-z 0-9 . _ @ + -`
  is filed under a hashed key instead, so list the directory to find it.

Anything cprof cannot decide from the evidence on disk is left in place and
reported — it would rather refuse and ask for help than guess wrong and
overwrite the wrong account's credentials. `cprof remove` takes the same
per-profile lock as the swaps, so it can never race one.

Both directions take a per-profile lock under `~/.cprof/fallback-lock/`
for the whole check-and-swap, so two `claude` launches racing each other
cannot both swap or undo each other's work; a launch that finds the lock
held says so and leaves it to the next one. A lock left by a crashed
process is reclaimed automatically. `CPROF_FALLBACK_THRESHOLD` must be a
whole percentage from 1 to 100 (a swap fires at or above it and restores
below it, so 0 could never restore); anything else is reported and 90 is
used. A
swap fires only while the cached 5-hour window is still open — its reset
time must parse and lie in the future — and only if the fallback's own
credentials carry an access token; `cprof which` applies the same test
before it says a swap would fire. Only a directory-backed profile can have
a fallback: `cprof env` exports nothing for a native one and never reaches
the swap. A profile is a primary or a fallback target, never both — chains
such as `work → personal → backup` are refused, and a swap declines a target
that is itself swapped at that moment. While a swap is active, `cprof remove` is refused with or without
`--purge`: the marker is the only record of where the profile's own
credentials are, and the restore needs it. Once the primary's credentials
are back, the confirming usage response is cached under its name before the
marker is dropped, so the swap-out check that follows in the same launch
sees fresh numbers rather than the fallback's.
`CPROF_NO_USAGE=1` also skips that confirming fetch, so with it set an active
swap stays in place until fetching is allowed again.

This is the one place cprof changes a live session's credentials rather
than just choosing a directory. `cprof doctor` shows an active swap and
when it will restore; `cprof list` marks the row `work→personal`; `cprof
which` notes when a swap would fire before it actually does. Clear the
mapping with `cprof fallback work --clear`.
