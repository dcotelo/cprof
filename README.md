<h1 align="center">⚑ claudeprofile</h1>

<p align="center">
  <em>One personal Claude subscription, one for work.<br>
  The right account per repository, without thinking about it.</em>
</p>

<p align="center">
  <img alt="license MIT" src="https://img.shields.io/badge/license-MIT-blue">
  <img alt="platform macOS" src="https://img.shields.io/badge/platform-macOS-lightgrey">
  <img alt="bash 3.2+" src="https://img.shields.io/badge/bash-3.2%2B-green">
  <img alt="requires jq" src="https://img.shields.io/badge/requires-jq-orange">
  <img alt="110 assertions" src="https://img.shields.io/badge/tests-110%20assertions-brightgreen">
</p>

```console
$ cd ~/dev/<company>/api && claudeprofile which
work        native (keychain)              rule ~/dev/<company>

$ cd ~/dev/side-project && claudeprofile which
personal    ~/.claude-profiles/personal    default
```

`claudeprofile` stores your Claude accounts as profiles, then picks one for each
session based on a default, a per-repository pin, or a directory rule — so repos
under `~/dev/<company>` use the work account and everything else uses personal.

**Contents** · [How it works](#how-it-works) · [Install](#install) ·
[Setup](#setup) · [Resolution order](#resolution-order) ·
[Commands](#commands) · [Statusline](#statusline) · [Safety](#safety) ·
[Development](#development)

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

Requires macOS, bash 3.2+ (the system shell), and `jq`.

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
claudeprofile rule add ~/dev/<company> work
```

```console
$ claudeprofile list
personal     max      you@personal.dev            (default) (active)
work         team     you@<company>.com           native
```

## Resolution order

First match wins.

| # | Source | Set with |
| --- | --- | --- |
| 1 | environment override, one session | `CLAUDE_PROFILE=work claude` |
| 2 | repository pin, keyed on the git top level | `claudeprofile pin work` |
| 3 | directory rule, longest matching prefix | `claudeprofile rule add ~/dev/<company> work` |
| 4 | default profile | `claudeprofile default personal` |
| 5 | nothing matched — stock `~/.claude` behaviour | — |

`claudeprofile which` reports both the winner and the rule that produced it.

Prefix matching respects path boundaries: a rule for `~/dev/work` never matches
`~/dev/workshop`. There is no glob support.

## Commands

| Command | Description |
| --- | --- |
| `claudeprofile list` | Profiles with identity and subscription; marks default, active, native |
| `claudeprofile which` | Profile resolved here, and the rule that produced it |
| `claudeprofile status` | Profile this process is actually running as |
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

`which` answers "what should this directory use", `status` answers "what am I
signed in as right now". They disagree after you pin or add a rule without
relaunching — which is exactly when knowing the difference matters.

## Statusline

```console
⚑ work
```

`statusline/segment.sh` prints that one dim line, naming the account the session
is running as. Every profile is named, native included — a
switching tool whose indicator is invisible in the common case teaches you to
ignore it. The line is omitted only when there is no profile to name: no config,
or a config with no native profile and no `CLAUDE_CONFIG_DIR` set.

A session on a config directory that belongs to no profile reads `⚑ unknown` —
worth seeing, since it means something else set `CLAUDE_CONFIG_DIR`.

Plugin manifests cannot declare a statusline, so wire it in `~/.claude/settings.json`
yourself, pointing at a small script of your own:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash \"$HOME/.claude/statusline.sh\"",
    "refreshInterval": 5
  }
}
```

```bash
#!/usr/bin/env bash
# ~/.claude/statusline.sh — profile badge, then whatever else you already run.
seg=$(ls -1 "$HOME"/.claude/plugins/cache/*/claudeprofile/*/statusline/segment.sh 2>/dev/null | tail -1)
[ -r "$seg" ] && bash "$seg" </dev/null
exit 0   # a test as the last command would exit non-zero and fail the statusline
```

The `ls | tail -1` resolves the newest installed version, so plugin updates do not
break the statusline. The segment finds its own CLI relative to itself; no
environment variable is required.

<details>
<summary><strong>Already running a statusline?</strong> Compose them.</summary>

Add the badge above whatever you already run. The segment deliberately does not
read stdin, so Claude Code's JSON payload stays unconsumed for the next
component — `</dev/null` keeps it that way even if that ever changes:

```bash
payload="$(cat)"
[ -r "$seg" ] && bash "$seg" </dev/null
printf '%s' "$payload" | your-existing-statusline
```

</details>

The segment never fails a statusline: a missing `jq`, an unreadable config, or a
missing CLI prints nothing and exits 0.

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
shellcheck -x -P scripts -P tests scripts/claudeprofile scripts/lib/*.sh hooks/*.sh \
  statusline/*.sh tests/*.sh
claude plugin validate .             # check the manifest
```

Targets bash 3.2 (macOS system bash), with `jq` as the only external dependency.

Tests sandbox `HOME`, the config path, the `claude` binary, and the `security`
binary. No test touches the real keychain or a real account.

## License

MIT
