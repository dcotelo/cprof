# claudeprofile

Keep a personal Claude subscription and a work one apart, per repository.

`claudeprofile` stores your Claude accounts as profiles, then picks one for each
session based on a default, a per-repository pin, or a directory rule — so repos
under `~/dev/crowder` use the work account and everything else uses personal.

## How it works

Claude Code reads the macOS keychain **only when `CLAUDE_CONFIG_DIR` is unset**.
Set it, and credentials come solely from `$CLAUDE_CONFIG_DIR/.credentials.json`.
`claudeprofile` uses this: each profile is its own config directory with its own
credentials, and a shell function points `CLAUDE_CONFIG_DIR` at the right one
before launching.

Your existing setup stays exactly as it is, as a `native` profile — the launcher
exports nothing for it, so the keychain and `~/.claude.json` are used unchanged.
No profile may point at `~/.claude`; doing so would break authentication and
relocate `.claude.json`.

Credentials are fixed at process start, so switching accounts always means
relaunching `claude`. A `SessionStart` hook warns you when you have wandered into
a directory that expects a different account.

## Install

```bash
claude plugin marketplace add dcotelo/claudeprofile
claude plugin install claudeprofile
```

Then add the launcher to `~/.zshrc`:

```bash
claude() { eval "$(claudeprofile env)"; command claude "$@"; }
```

Point `claudeprofile` at the installed script, or add its `scripts/` directory to
`PATH`. `command claude` bypasses the wrapper.

## Setup

```bash
claudeprofile add work --native            # adopt your current account
claudeprofile add personal                 # ~/.claude-profiles/personal
claudeprofile login personal               # sign in
claudeprofile default personal
claudeprofile rule add ~/dev/crowder work
```

```console
$ claudeprofile list
personal     max      me@dcotelo.dev            (default) (active)
work         team     dcotelo@getcrowder.com    native
```

## Resolution order

1. `CLAUDE_PROFILE=work claude` — explicit override
2. repository pin (`claudeprofile pin`), keyed on the git top level
3. directory rule, longest matching path prefix
4. default profile
5. nothing matched — stock `~/.claude` behaviour

Prefix matching respects path boundaries: a rule for `~/dev/work` never matches
`~/dev/workshop`. There is no glob support.

## Commands

| Command | Description |
| --- | --- |
| `claudeprofile list` | Profiles with identity and subscription; marks default, active, native |
| `claudeprofile which` | Profile resolved here, and the rule that produced it |
| `claudeprofile env` | `export`/`unset` statements for `eval` |
| `claudeprofile add <name> [--dir P] [--native] [--note S]` | Register a profile |
| `claudeprofile default <name>` | Set the default profile |
| `claudeprofile pin [<name>] \| pin --clear` | Pin or unpin this repository |
| `claudeprofile rule add <path> <name>` | Route a directory tree to a profile |
| `claudeprofile rule rm <path>` / `rule list` | Manage rules |
| `claudeprofile login <name>` | Sign a profile in, with keychain protection |
| `claudeprofile doctor` | Report unauthenticated profiles and expiring tokens |
| `claudeprofile remove <name> [--purge]` | Unregister; `--purge` deletes the directory |

In a session, `/profile` shows status, `/profile pin <name>` pins the repository.

## Safety

`claudeprofile login` snapshots the keychain to `~/.claudeprofile/keychain.bak`
(mode 600) before signing in, then verifies that the profile's
`.credentials.json` appeared and the keychain went untouched. If a login writes
to the shared keychain item instead, it is restored from the snapshot and the
command fails loudly. Your working account cannot be lost to a profile login.

`claudeprofile env` never exits non-zero and always prints one assignment. A
missing `jq`, a malformed config, or a missing profile directory degrades to
stock Claude Code behaviour rather than a broken shell.

## Development

```bash
bash tests/run.sh                    # run the suite
shellcheck -x -P scripts -P tests scripts/claudeprofile scripts/lib/*.sh hooks/*.sh tests/*.sh
claude plugin validate .             # check the manifest
```

Targets bash 3.2 (macOS system bash), with `jq` as the only external dependency.

Tests sandbox `HOME`, the config path, the `claude` binary, and the `security`
binary. No test touches the real keychain or a real account.

## License

MIT
