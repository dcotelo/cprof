# Changelog

Notable changes per release. Versions follow [semver](https://semver.org); the
release workflow reads its notes from the section matching the tag.

## [0.3.0]

### Fixed

- A profile no longer starts without your customisations. `CLAUDE_CONFIG_DIR`
  relocates the entire configuration directory, not just its credentials, so a
  profile pointed elsewhere had no plugins, skills, agents, commands, hooks,
  settings, or `CLAUDE.md` — switching account silently switched away every
  customisation too.

### Added

- `claudeprofile share <name>` links the shared assets — `settings.json`,
  `keybindings.json`, `CLAUDE.md`, `plugins`, `skills`, `agents`, `commands`,
  `hooks` — from `~/.claude` into a profile. Symlinks, so installing a plugin or
  editing settings once applies everywhere, with nothing to re-sync. Content the
  profile already had is moved aside, never deleted.
- `claudeprofile unshare <name>` removes those links, and only those: a real file
  in the profile and a link pointing anywhere else are both left alone.
- `add` shares by default; `add --isolated` opts out.

Identity and history stay per-profile, which is what keeps the accounts apart:
`.credentials.json`, `.claude.json`, `projects`, `sessions`, `history.jsonl`,
`todos`, and the caches are never linked.

### Changed

- `claudeprofile version` reads 0.3.0. It reported 0.1.0 through the 0.2.0
  release: the constant was never bumped, and the test that should have caught it
  hardcoded the same stale literal. Both the test and a manifest check now compare
  against `plugin.json`.

## [0.2.0]

### Added

- `claudeprofile status` names the profile the running process is signed in as,
  derived from the live `CLAUDE_CONFIG_DIR` rather than from resolution — the two
  disagree after a pin or rule lands without a relaunch.
- `statusline/segment.sh`, a one-line statusline badge (`⚑ work`). Reads no stdin,
  so it composes ahead of another statusline, and never fails one: any problem
  prints nothing and exits 0.
- `claudeprofile rules`, an alias for `rule list`.
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
