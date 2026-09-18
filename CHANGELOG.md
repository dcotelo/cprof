# Changelog

Notable changes per release. Versions follow [semver](https://semver.org); the
release workflow reads its notes from the section matching the tag.

## [Unreleased]

## [0.15.0]

### Added

- A `weekly` statusline segment: the 7-day usage window as a bar, with the time
  until it resets. It renders only once the window is at or above
  `statusline.weekly_threshold` — a whole number from 1 to 100, 50 by default —
  and renders nothing below it, so the line costs no space early in the week and
  appears before the weekly cap ends a working day. Give it a line of its own in
  `statusline.lines` and that line disappears with it. The figure comes from the
  cache `cprof list` fills and is never fetched, because a Claude Code payload
  carries the 5-hour window and the context but never the week, and because the
  statusline must not add latency — so a profile whose usage has never been
  fetched shows no weekly bar.

### Changed

- A reset a day or more away is reported as days and hours, `3d 13h`, rather
  than as hours and minutes, `85h 40m` — the same instant, told legibly. The
  5-hour window cannot reach a day, so what it shows is unchanged.

## [0.14.0]
### Added
- `cprof doctor` reports two install problems that used to be invisible. It
  compares the `cprof` on `PATH` against the newest installed plugin and names
  the fix for whichever is behind — the two halves update through different
  channels, and a CLI older than the plugin lacks subcommands the plugin's own
  docs describe, which is enough to render an empty statusline. It also reports
  when Claude Code's `statusLine` is set to a command that does not reference
  `cprof`, naming the settings file without quoting the command back. Skew
  fails `doctor`; the wiring report does not, since running another statusline
  is a choice.

### Changed
- The README is the showcase and the quickstart; the reference material moved
  into `docs/` — routing, install details, commands, the statusline, usage and
  fallback, and safety — with development, the dependency policy and releasing
  in `CONTRIBUTING.md`. Every section kept its heading, so an anchor such as
  `#statusline` still resolves inside the file it moved to.
## [0.13.0]
### Added
- `cprof statusline` draws the whole statusline in one `cprof` invocation,
  where the one-line segment spent three: the account,
  the model, the directory with its git branch, and bars for the context
  window and the 5-hour usage window with the time until it resets. Everything
  but the branch comes from the payload Claude Code already hands a statusline,
  so it costs no request and refreshes every tick. `statusline/segment.sh
  --full` is the wiring for it; without that flag the segment prints the single
  line it always has and leaves stdin alone.
- A `statusline` block in the config chooses which segments appear, in what
  order, and how they group into lines, along with the bar's glyphs and width,
  the severity thresholds, and the colours of the labels and the fixed text.
  Absent configuration renders every segment, and the bar keeps its existing
  glyph, so nothing changes for anyone who does not ask. A setting that is
  rejected falls back silently, because a statusline re-runs every few seconds
  with its stderr discarded; `cprof doctor` names the key and the value used
  instead, and exits non-zero. It also names a key cprof does not recognise,
  at whichever level inside the block it was written, since the resolver
  ignores one in silence and a misspelling is the likeliest reason for it.
  Every name it reports — a key, a segment, a colour — comes back quoted and
  escaped, so a configuration file cannot forge a line of that output.

### Changed
- `git` is consulted for the statusline's branch field as well as for
  repository-root resolution, which has used it all along. It stays soft: no
  `git` on `PATH`, or a directory in no working tree, skips that field and
  changes nothing else about the statusline — but root resolution then falls
  back to the working directory, so a pin made at a repository root stops
  matching from a subdirectory of it and a different profile resolves there.
  `jq` remains the only hard dependency.
## [0.12.0]
### Added
- The statusline segment draws a context bar and a 5-hour usage bar with the
  time to reset — `⚑ work │ Context ▓▓▓▓░░░░░░ 37% │ Usage ▓▓▓░░░░░░░ 30%
  (resets in 2h 19m)` — from Claude Code's statusline payload when run with
  `--stdin`. Without the flag stdin is left alone as before and the usage bar
  comes from the profile's cache, now labelled `Usage`. `cprof usage --render
  <name> --stdin` reads the payload and returns seven fields instead of three.
## [0.11.0]
### Added
- `cprof fallback <primary> <name>` — live credential swap to a fallback
  profile once the primary's cached 5-hour usage reaches the threshold (90%
  by default, `CPROF_FALLBACK_THRESHOLD`). Both directions run from
  `cprof env`, i.e. when `claude` is launched: the first call after the
  primary's window resets fetches its usage afresh and, once it is back
  under threshold, restores the original credentials. An idle session is
  not restored until something launches `claude` again. Visible in `cprof
  doctor` (active swap),
  `cprof list` (annotated row), and `cprof which` (would-fire note). Override
  the 90% trigger with `CPROF_FALLBACK_THRESHOLD`.


### Changed
- The fallback marker joins the usage cache among the per-profile state
  files under `~/.cprof/`, filed under the same filename-safe key derived
  from the profile name, so no profile name can address a path outside the
  state directory through it either.
- Fallback swaps and restores hold a per-profile lock
  (`~/.cprof/fallback-lock/`), so two concurrent `cprof env` calls cannot
  both swap or undo each other (a lock left by a dead process is reclaimed
  through an atomic rename, so two reclaimers cannot both win); the
  keychain backup is created without update semantics and its presence is
  checked conclusively (`security`'s not-found exit vs. any other failure),
  so a keychain that cannot be read never passes for "no backup"; a swap is refused when the cached usage has
  no parseable reset time, since the restore keys on it; an invalid
  `CPROF_FALLBACK_THRESHOLD` (anything but a whole number from 1 to 100 — 0
  would swap on any reading and never restore) is reported and 90 used
  instead of surfacing a shell error.
- `remove --purge` deletes the profile's swap backup keychain item
  (`<service>-bak`) along with the live one, so a profile re-added at the
  same directory inherits neither.
- A fallback swap-out requires the primary's own stored credentials to be a
  blob with a token in it, for either store, since swap-back could never
  restore anything else.
- `CPROF_NO_USAGE=1` now also stops the fallback restore's confirming fetch,
  so no token is sent for usage data on any path; an active swap is then
  left in place until fetching is allowed again.
- A swap fires only while the cached 5-hour window is still open (reset
  time in the future) and only when the fallback's credentials carry an
  access token; `cprof which` uses the same test for its would-fire note.
- `cprof fallback` refuses a native profile as the primary (the swap can
  never fire for one) and refuses chains — a profile is a primary or a
  fallback target, never both — and a swap-out declines a target that is
  itself swapped right now, since its live store would hold a third
  profile's credentials. `cprof remove` — with or without `--purge` — is
  refused while a swap is active, since the marker is the only record of
  where the profile's own credentials are.
- A restore caches the confirming usage response under the primary's name
  before dropping the marker, so the swap-out check in the same `cprof env`
  call cannot read the fallback's stale numbers and swap straight back. If
  that cache write fails, the marker and backup stay for the next call.
- A fallback restore writes the primary's credentials back to the store the
  backup was taken from (the marker's recorded path or service), not to
  wherever the profile's directory points at restore time — and `cprof env`
  runs it before checking that directory, so a profile re-pointed at a
  missing one is still restored.
- A malformed fallback marker (no backup path, or an unknown backup kind)
  is left in place and reported rather than acted on: acting on an empty
  backup would have addressed the shared native keychain item.
- A swap-out interrupted between the credential overwrite and the marker
  commit is recovered on the next `cprof env`: the marker is staged at a
  fixed `.pending` name, and the next call compares backup and live store to
  either promote it or discard it with its backup. `cprof remove` runs under
  the same per-profile lock as the swaps.
- Restore cleanup is retryable: once the credentials are back, the marker is
  flagged `restored` before the backup and marker are deleted, each step
  checked, so a failed delete is retried on the next call without another
  fetch or rewrite, and cleanup itself can no longer leave a backup without
  a marker or a marker without its backup. (The two stuck states the README
  describes remain reachable only if a marker commit and its rollback both
  fail.) `cprof doctor` reports the swap even for a profile
  that no longer authenticates, and `cprof fallback` rejects surplus
  arguments instead of ignoring them.

## [0.10.0]
### Added
- `cprof usage [<name>]`, usage columns in `cprof list`, a usage warning in
  `cprof doctor`, and a usage badge on the statusline, backed by
  `api.anthropic.com/api/oauth/usage`. Opt out with `CPROF_NO_USAGE=1`.

### Changed
- Profile names may no longer be `.`, `..`, contain `/`, or contain a control
  character (tab, newline), and every per-profile state file under `~/.cprof/`
  (the usage cache) is filed under a filename-safe key derived from the name,
  so no profile name can address a path outside the state directory. `remove`
  scrubs that state before it rewrites the config, so a failed scrub leaves
  the profile registered for a retry instead of orphaning the files.
- A usage response is cached only when it has the shape the renderers read
  (`five_hour` an object; `seven_day` and `limits`, when present, an object
  and an array). Anything else is a failed fetch, and the previous cache
  stands.
- `list`, `doctor`, and `usage` treat a profile name containing spaces or
  glob characters as one profile, not several.
- `remove --purge` deletes the profile's live keychain item, so a profile
  re-added at the same directory does not inherit the removed one's
  credentials. A directory or keychain item that refuses to go — or a
  keychain that cannot be read — now fails the command and leaves the
  profile registered; the cached state is scrubbed first and the keychain
  item before the directory, so a refusal at any step leaves everything
  after it untouched.
- `cprof usage <name>` reads a per-model limit's `percent`, the field the
  endpoint sends (the top-level windows use `utilization`), so the model
  rows render instead of showing `-`. A bearer token is only ever sent to an
  `https://` usage URL.
- `cprof doctor`'s 5-hour warning fires only while that window is still
  open: a stale cache served after a failed refetch may describe a window
  that has already reset.
- `resets_at` is parsed as RFC 3339 in every spelling — `...Z`, numeric
  offsets, fractional seconds, or a bare UTC wall clock — rather than only
  the `...Z` form the fixtures use.
- The statusline badge prints plain text under `NO_COLOR`, with no dim
  escape sequences.

## [0.9.0]

### Added

- An installer for setups without Homebrew. `install.sh` puts the CLI in
  `~/.local` with no `sudo`, mirroring the layout the formula uses, so the
  Homebrew-less path is a supported install rather than a manual copy. Download
  and read it before running it — [Install](README.md#install) shows the two
  commands.

- `cprof pin` now says what it did: `pinned ~/dev/acme to work`, `unpinned
  ~/dev/acme`, or `no pin for ~/dev/acme` when there was nothing to clear.
  Pinning was silent on success and spoke only on failure, which left the most
  common outcome — it worked — indistinguishable from a command that had not
  run. The messages go to stderr, so `cprof env` output stays clean for the
  shell to evaluate.

- Releases ship a `checksums.txt` alongside a source tarball built from the
  released tag, so a download can be verified with
  `shasum -a 256 -c checksums.txt`. The archive is built during the release
  rather than taken from GitHub's generated tarball, whose bytes are not
  guaranteed stable over time.

### Changed

- Project documentation now covers the things a contributor or a reporter needs:
  [SECURITY.md](SECURITY.md) with a vulnerability-reporting route and response
  timeframe, [CONTRIBUTING.md](CONTRIBUTING.md) with the test and shellcheck
  requirements, a [security assessment](docs/security-assessment.md) recording
  the threat model, and issue and pull request templates.

## [0.8.0]

### Added

- `cprof update` refreshes the marketplace listing and updates the plugin
  itself, wrapping the two `env -u CLAUDE_CONFIG_DIR claude plugin …` commands
  documented under [Updating](docs/install.md#updating) so they no longer need to be
  run by hand or remembered. It covers the plugin only — Updating now also
  documents `brew upgrade dcotelo/tap/cprof` for the CLI, since the two are
  installed, and updated, separately.

## [0.7.0]

### Changed

- The statusline badge colours the profile name as well as the flag by default.
  Colour that stopped at the glyph put the signal on the part of the badge most
  people read as decoration, rather than on the word they actually read.
  `cprof color --text off` narrows it back to the flag alone.

  An absent `colorText` key reads as on, so a config written before this release
  gets the new badge without being touched. An explicit `--text off` is
  preserved.

## [0.6.1]

### Fixed

- A symlinked `cprof` could not find its library directory, and failed in the
  worst available direction. `$0` is the path used to invoke, not the file
  invoked, so `lib/` was looked for beside the link. With it unfound, `cprof`
  prints `unset CLAUDE_CONFIG_DIR` on stdout and exits 0 — which the shell
  function evals, so the session quietly ran the native account instead of the
  profile the directory asked for. Symlinks are now followed to the real file.
  This is what `ln -s /path/to/cprof ~/bin/cprof` does, and what a Homebrew
  install does.

### Added

- Documented how to update, including the two requirements that are not
  obvious: marketplace commands need `env -u CLAUDE_CONFIG_DIR` from a
  non-native profile directory, and `plugin update` resolves only the qualified
  `cprof@dcotelo`.

## [0.6.0]

### Added

- Each profile has a colour, so the badge and `cprof list` say which account is
  in use at a glance rather than on a read. Colours are assigned by hashing the
  profile name — no configuration, and stable across machines, because nothing
  is stored. `cprof color <name>` opens a picker; `cprof color <name> <colour>`
  sets one directly and `auto` returns to the hashed one. `cprof color --text on`
  colours the badge's name text as well as the flag — `list` and `which`
  already colour the name unconditionally, and are unaffected by this toggle.
- Values are named ANSI colours, so they follow the terminal's own theme instead
  of overriding it. `NO_COLOR` is honoured, and `CPROF_COLOR=never|always|auto`
  overrides the terminal detection.

### Fixed

- `cp_table` sized columns by counting bytes, so a cell containing colour padded
  every other row to a width that was not on screen. Widths are now measured with
  the escape sequences stripped, and colour moves nothing.

## [0.5.0]

### Changed

- The marketplace is named `dcotelo` rather than `cprof`, so the plugin installs
  as `cprof@dcotelo`. Installs are addressed as `plugin@marketplace`, and a
  marketplace named after its only plugin made `cprof@cprof` say nothing about
  where the plugin came from; every other marketplace in common use is named for
  its owner.

  The install id is part of the plugin's identity, so an existing install has to
  be replaced rather than updated:

  ```bash
  claude plugin uninstall cprof@cprof
  claude plugin marketplace remove cprof
  claude plugin marketplace add dcotelo/cprof
  claude plugin install cprof@dcotelo
  ```

  Nothing in `~/.cprof.json` or any profile directory is touched — profiles,
  rules, pins and logins all survive, because they live outside the plugin cache.
  The shell functions need no edit either: they glob the marketplace directory.

## [0.4.2]

### Fixed

- The plugin failed to load entirely, taking the `SessionStart` hook and
  `/profile` with it: `plugin.json` named `./hooks/hooks.json` in its `hooks`
  field, which Claude Code loads on its own, and the duplicate registration is an
  error. The field only ever exists to point at *additional* hook files, so it is
  gone. `claude plugin validate` does not catch this, so the manifest test now
  does.

## [0.4.1]

### Fixed

- `cprof login` failed on a successful sign-in, reporting `login did not produce
  <dir>/.credentials.json`. Claude Code 2.1 stopped writing that file: with
  `CLAUDE_CONFIG_DIR` set it stores credentials in a keychain item named after a
  hash of the directory. Success is now judged by `claude auth status`, which is
  indifferent to where the credentials landed.
- `cprof doctor` never warned about an expiring refresh token, for any profile.
  It read the expiry from `.credentials.json`, so on Claude Code 2.1 it found
  nothing and silently reported `ok` until the token died. It now reads whichever
  store the version in use actually keeps, file or keychain, and distinguishes an
  unknown expiry from a healthy one.
- `cprof status` (and so the statusline badge) reported `unknown` for a native
  profile whenever `CLAUDE_CONFIG_DIR` was exported pointing at the stock
  `~/.claude`. A native profile is stored without a `dir`, because native means
  "runs when the variable is unset", so the directory matched nothing. The stock
  path now resolves to the native profile.

## [0.4.0]

### Changed

- Renamed from `claudeprofile` to `cprof`, everywhere: the CLI, the plugin, the
  marketplace entry, the release tag prefix (`cprof--v*`), and the repository.
  Twelve characters was a lot to type for a command you reach for whenever you
  change directory.
- Config lives at `~/.cprof.json` and state at `~/.cprof/`. An existing
  `~/.claudeprofile.json` is **moved** to the new path on first run, with a line
  saying so; moved rather than copied, because two files would drift and a write
  landing in the one no longer read is a silently lost change.
- `CPROF_CONFIG` and `CPROF_STATE_DIR` are the environment overrides.
  `CLAUDEPROFILE_CONFIG` and `CLAUDEPROFILE_STATE_DIR` are still honoured, and an
  explicit path under either name is taken literally — never migrated.

Reinstall under the new name, since the plugin name is part of its cache path:

```bash
claude plugin uninstall claudeprofile
claude plugin marketplace add dcotelo/cprof
claude plugin install cprof
```

Then update the shell functions to call `cprof`. Earlier entries in this file use
the current name for readability, though those releases shipped as
`claudeprofile`.

## [0.3.0]

### Fixed

- A profile no longer starts without your customisations. `CLAUDE_CONFIG_DIR`
  relocates the entire configuration directory, not just its credentials, so a
  profile pointed elsewhere had no plugins, skills, agents, commands, hooks,
  settings, or `CLAUDE.md` — switching account silently switched away every
  customisation too.

### Added

- `cprof share <name>` links the shared assets — `settings.json`,
  `keybindings.json`, `CLAUDE.md`, `plugins`, `skills`, `agents`, `commands`,
  `hooks` — from `~/.claude` into a profile. Symlinks, so installing a plugin or
  editing settings once applies everywhere, with nothing to re-sync. Content the
  profile already had is moved aside, never deleted.
- `cprof unshare <name>` removes those links, and only those: a real file
  in the profile and a link pointing anywhere else are both left alone.
- `add` shares by default; `add --isolated` opts out.

Identity and history stay per-profile, which is what keeps the accounts apart:
`.credentials.json`, `.claude.json`, `projects`, `sessions`, `history.jsonl`,
`todos`, and the caches are never linked.

### Changed

- `cprof version` reads 0.3.0. It reported 0.1.0 through the 0.2.0
  release: the constant was never bumped, and the test that should have caught it
  hardcoded the same stale literal. Both the test and a manifest check now compare
  against `plugin.json`.

## [0.2.0]

### Added

- `cprof status` names the profile the running process is signed in as,
  derived from the live `CLAUDE_CONFIG_DIR` rather than from resolution — the two
  disagree after a pin or rule lands without a relaunch.
- `statusline/segment.sh`, a one-line statusline badge (`⚑ work`). Reads no stdin,
  so it composes ahead of another statusline, and never fails one: any problem
  prints nothing and exits 0.
- `cprof rules`, an alias for `rule list`.
- `/profile` leads with `status` and calls out a `status` vs `which` mismatch.

### Changed

- `list`, `which`, and `rule list` render through a shared table that sizes each
  column to its widest cell; fixed-width columns used to break alignment on a
  long profile name. Paths under home print as `~`.
- `rule list` gained a header, longest-prefix-first ordering (the order
  resolution consults rules), an explicit `no rules`, and an
  `(unknown profile)` flag on rules whose profile has been removed.
- Install documents a resolver function for the CLI, which the plugin does not
  put on `PATH`, and both wiring steps are single commands.

### Removed

- The design spec and implementation plan under `docs/` no longer ship. An
  install clones the repository, so they were copied into every plugin cache;
  they remain in git history.

### Fixed

- Paths under a symlinked home now shorten to `~`. Stored paths are physical, so
  matching only the literal `$HOME` made `which` print a rule path in full that
  `rule list` had just shortened.

## [0.1.0]

### Added

- Profiles as config directories, with `add`, `remove`, `default`, `login`, and
  `doctor`.
- Resolution by `CLAUDE_PROFILE`, repository pin, directory rule, then default,
  with `which` reporting the winner and the reason.
- `env` for shell integration; never exits non-zero, always prints one
  assignment.
- `login` snapshots the keychain first and restores it if a profile login writes
  to the shared item.
- Plugin manifest, `/profile` command, and a `SessionStart` hook that warns when
  the directory expects a different account.
