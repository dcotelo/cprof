# claudeprofile — design

Date: 2026-07-28

## Problem

Claude Code authenticates one account at a time. Switching between a personal
subscription and a work/team subscription means logging out and logging back in,
which discards the other account's session. There is no way to say "repos under
`~/dev/crowder` use the work account, everything else uses personal."

`gitprofile` solves the equivalent problem for git identities: a JSON store of
profiles, a default applied to global config, and a per-repo override. This
project applies the same shape to Claude Code accounts, plus directory rules.

## Verified mechanics

These were established empirically against Claude Code 2.1.220 on macOS before
designing. They are the foundation of the whole approach.

| Condition | `claude auth status` |
| --- | --- |
| `CLAUDE_CONFIG_DIR` unset | logged in — credentials from macOS keychain |
| `CLAUDE_CONFIG_DIR` = fresh directory | not logged in |
| fresh directory containing `oauthAccount` metadata but no credentials file | not logged in |
| fresh directory containing `.credentials.json` | logged in — `subscriptionType` read from the file |
| `CLAUDE_CONFIG_DIR` = `$HOME/.claude` (the default path, set explicitly) | not logged in |
| the above plus `CLAUDE_SECURESTORAGE_CONFIG_DIR=$HOME/.claude` | not logged in |

**Rule: the macOS keychain is consulted only when `CLAUDE_CONFIG_DIR` is unset.**
Once it is set, credentials come solely from `<CLAUDE_CONFIG_DIR>/.credentials.json`.

Two consequences drive the design:

1. Per-profile config directories give genuine account isolation. Each holds its
   own `.credentials.json`, and profile directories never read the keychain.
2. A profile must never point at `~/.claude`. Doing so breaks authentication (row
   5 above) and relocates `.claude.json` from `~/.claude.json` to
   `~/.claude/.claude.json`, orphaning existing history and project state. The
   existing setup is therefore represented as a *native* profile that exports
   nothing.

The keychain item itself is single-slot: writes go through
`security add-generic-password -U` against a fixed service name
(`Claude Code-credentials`). Profile directories never read it, so this does not
affect resolution — but it does mean a misbehaving login could overwrite the
native profile's credentials. See "Keychain safety net".

## Architecture

Two components sharing one config file.

**`scripts/claudeprofile`** — a bash + `jq` CLI. Sole owner of
`~/.claudeprofile.json`. Its only side effects are writing that file, creating
profile directories, and printing shell `export` statements.

**The plugin** — `commands/*.md` slash commands that wrap the CLI for in-session
use, plus a `SessionStart` hook that warns when the running session's profile
does not match what the current directory would resolve to. Read-only with
respect to credentials.

The two are joined by a shell function that shadows `claude`:

```bash
claude() { eval "$(claudeprofile env)"; command claude "$@"; }
```

`claudeprofile env` writes `export` lines to stdout and its resolution trace to
stderr.

Because `eval` runs in the interactive shell, any exported variable persists for
the rest of that shell's life. A later launch in a different directory would
otherwise inherit a stale `CLAUDE_CONFIG_DIR`. `env` therefore always emits a
complete assignment: either `export CLAUDE_CONFIG_DIR=…` or, for a native profile
and for the no-match case, `unset CLAUDE_CONFIG_DIR`. It never emits nothing when
the variable might already be set.

`env` never exits non-zero. A missing `jq`, a malformed config, or an
unknown profile results in `unset CLAUDE_CONFIG_DIR`, which means the shell falls
through to stock `claude` behaviour. The failure mode is "stock behaviour", never
"no Claude Code".

`command claude` remains available as an explicit escape hatch.

## Resolution

Evaluated highest-precedence first:

1. **`CLAUDE_PROFILE` environment variable** — `CLAUDE_PROFILE=work claude`.
   Explicit, one-shot override.
2. **Repository pin** — look up `git rev-parse --show-toplevel`, falling back to
   `$PWD`, in the `repos` map.
3. **Directory rule** — longest matching path prefix in `rules`, so a rule for
   `~/dev/work/client-a` wins over one for `~/dev/work`.
4. **Default profile**.
5. **Nothing matched** — `unset CLAUDE_CONFIG_DIR`; stock `~/.claude` behaviour.

Prefix matching operates on canonicalised absolute paths and respects path
boundaries: a rule for `~/dev/work` must not match `~/dev/workshop`. There is
deliberately no glob support. Longest-prefix covers the "everything under this
directory" requirement and has no ambiguous cases to debug.

## Configuration

`~/.claudeprofile.json`:

```json
{
  "default": "personal",
  "profiles": [
    { "name": "work", "native": true, "note": "Crowder team, keychain" },
    { "name": "personal", "dir": "~/.claude-profiles/personal", "note": "Max" }
  ],
  "rules": [
    { "path": "~/dev/crowder", "profile": "work" }
  ],
  "repos": {
    "/Users/diego/dev/temp": "personal"
  }
}
```

A profile is either:

- **native** (`"native": true`) — the launcher exports nothing, so Claude Code
  uses the keychain and `~/.claude.json` exactly as it does today. Exactly one
  profile may be native. This adopts the existing setup with no migration.
- **directory-backed** (`"dir": "…"`) — defaults to `~/.claude-profiles/<name>`
  but always written explicitly. Fully independent config tree: own credentials,
  settings, plugins, history, and projects.

Profiles are fully separate by design; nothing is symlinked between them. Settings
maintained twice is the accepted cost of complete isolation.

## Command-line interface

| Command | Behaviour |
| --- | --- |
| `claudeprofile list` | Profiles with live identity and subscription type; marks `(default)`, `(active)`, `native` |
| `claudeprofile which` | Profile resolved for the current directory, and which rule produced it |
| `claudeprofile env` | `export` statements for `eval` |
| `claudeprofile add <name> [--dir P] [--native] [--note S]` | Register a profile; creates the directory unless native |
| `claudeprofile default <name>` | Set the default profile |
| `claudeprofile pin [<name>]` | Pin the current repository in `repos`; `--clear` removes the pin |
| `claudeprofile rule add <path> <name>` | Add a directory rule |
| `claudeprofile rule rm <path>` | Remove a directory rule |
| `claudeprofile rule list` | List directory rules, longest-prefix order |
| `claudeprofile login <name>` | Authenticate a profile (see below) |
| `claudeprofile doctor` | Report unauthenticated profiles, expiring refresh tokens, config problems |
| `claudeprofile remove <name> [--purge]` | Unregister; `--purge` also deletes the directory |
| `claudeprofile version` | Print version |

`list` derives identity by running `claude auth status --json` under each
profile's directory. This reads local files only — no network calls, no API
usage:

```
personal  Max    me@dcotelo.dev            (default)
work      team   dcotelo@getcrowder.com    native  (active)
```

## Slash commands

`/profile` — status: resolved profile, the rule that produced it, all profiles.
Read-only.

`/profile pin <name>` — pin the current repository, then state that a relaunch is
required for it to take effect.

`/profile rule <path> <name>` — add a directory rule.

There is deliberately no `/profile use`. A running session's credentials were
resolved at process start and cannot be changed. A command implying otherwise
would be lying.

## Authentication flow

`claudeprofile login <name>` runs `claude auth login --claudeai` with
`CLAUDE_CONFIG_DIR` pointed at the profile's directory.

### Keychain safety net

One behaviour could not be verified without a second real account: whether
`auth login` inside a profile directory writes the token to that directory's
`.credentials.json`, or still writes to the shared keychain item. Reads never
consult the keychain when `CLAUDE_CONFIG_DIR` is set, which makes file-write
overwhelmingly likely — but the downside case would overwrite the only currently
working account, so `login` guards against it:

1. Snapshot the keychain blob to `~/.claudeprofile/keychain.bak`, mode `0600`.
2. Run `claude auth login --claudeai` under the profile directory.
3. Assert that `<dir>/.credentials.json` now exists **and** that the keychain blob
   is byte-identical to the snapshot.
4. If the keychain changed, restore it from the snapshot, report the clobber
   prominently, and exit non-zero.

The first real login therefore doubles as the final verification of this
behaviour, and cannot cost the user their existing account.

## Bootstrap

```bash
claudeprofile add work --native                  # adopt the existing setup
claudeprofile add personal                       # ~/.claude-profiles/personal
claudeprofile login personal                     # authenticate it
claudeprofile default personal
claudeprofile rule add ~/dev/crowder work
```

Then, once in `~/.zshrc`:

```bash
claude() { eval "$(claudeprofile env)"; command claude "$@"; }
```

## SessionStart hook

Compares the running session's `CLAUDE_CONFIG_DIR` against what resolution would
select for the current directory. On mismatch it injects a single line:

```
⚠ claudeprofile: active=personal, expected=work (rule ~/dev/crowder). Relaunch to switch.
```

This catches the case where the user changes directory across a rule boundary
during a long session. The hook performs no writes, makes no network calls, and
always exits 0.

## Error handling

Every failure degrades to stock `~/.claude` behaviour rather than a broken shell.

- `jq` missing, or `~/.claudeprofile.json` malformed — emit
  `unset CLAUDE_CONFIG_DIR` plus one warning line on stderr.
- `add --native` when a native profile already exists — rejected, naming the
  existing one. At most one profile may be native, since it represents the single
  keychain-backed identity.
- A rule naming an unknown profile — skip that rule, warn, continue resolution.
- A profile directory missing or unauthenticated — warn and fall through to the
  default, so the user is not dropped into an unexpected login prompt.
- `remove --purge` is the only destructive operation. It prompts for confirmation
  and refuses outright if the target directory is `~/.claude`.

## Testing

Tests live in `tests/` and run with `HOME` pointed at a temporary directory, so
the real configuration and the real keychain are never touched. Bats if
available, plain bash assertions otherwise.

Coverage concentrates on resolution, where the actual bugs live:

- the full precedence ladder, including `CLAUDE_PROFILE`
- longest-prefix rule selection
- path-boundary correctness (`~/dev/work` must not match `~/dev/workshop`)
- git top-level versus `$PWD` for repository pins
- fallback when a named profile is missing or unauthenticated
- malformed and absent config files
- `env` emitting `unset CLAUDE_CONFIG_DIR` for a native profile, for the no-match
  case, and for every error path — never nothing
- `env` never exiting non-zero
- `add --native` refusing a second native profile

Keychain interaction is tested through an injected indirection over the
`security` command, following the way `gitprofile` indirects `gitSet` and
`gitGet` for its own tests. No test invokes the real keychain.

## Distribution

A single repository containing both the CLI and the plugin:

```
claudeprofile/
  .claude-plugin/plugin.json
  commands/profile.md
  hooks/session-start.sh
  scripts/claudeprofile
  tests/
  README.md
```

Installed through the Claude Code plugin marketplace; updating the plugin updates
the CLI. No build step and no release pipeline. The user adds one function to
`~/.zshrc`, pointing at `scripts/claudeprofile` in the installed plugin directory.

## Out of scope

- Non-macOS credential stores. The design should not actively break on Linux
  (where credentials are already file-based), but Linux is not a target for the
  first version.
- Portable, checked-in per-repo configuration. Overrides live centrally, keyed by
  absolute path, so nothing is added to the user's repositories.
- Switching accounts within a live session. Not possible; the hook warns instead.
