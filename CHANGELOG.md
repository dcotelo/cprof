# Changelog

Notable changes per release. Versions follow [semver](https://semver.org); the
release workflow reads its notes from the section matching the tag.

## [Unreleased]

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
