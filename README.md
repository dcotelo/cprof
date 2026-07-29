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
work  native (keychain)  rule ~/dev/<company>

$ cd ~/dev/side-project && claudeprofile which
personal  ~/.claude-profiles/personal  default
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

Installing the plugin puts nothing on `PATH` — the CLI lives inside a versioned
cache directory. Two shell functions close the gap: one to reach the CLI, one to
launch `claude` with the resolved profile. Paste this, then `exec zsh`:

```bash
cat >> ~/.zshrc <<'RC'
claudeprofile() {
  local cli
  cli=$({ ls -1 "$HOME"/.claude/plugins/cache/*/claudeprofile/*/scripts/claudeprofile ; } 2>/dev/null | sort -V | tail -1)
  [ -x "$cli" ] || { print -u2 'claudeprofile: plugin not installed'; return 127; }
  "$cli" "$@"
}
claude() { eval "$(claudeprofile env)"; command claude "$@"; }
RC
```

Resolving at call time means plugin updates need no edit here. `sort -V` keeps
`0.10.0` ahead of `0.9.0`, and the braces around `ls` put zsh's own
"no matches found" on the suppressed stream when nothing is installed.

```console
$ exec zsh && claudeprofile list
PROFILE  PLAN  ACCOUNT            FLAGS
work     team  you@<company>.com  native
```

`command claude` bypasses the wrapper. Without the wrapper, `claude` ignores
profiles entirely and stock keychain behaviour applies — including when
`claudeprofile` is missing from `PATH`, since `eval` of a failed command is a
no-op.

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
PROFILE   PLAN  ACCOUNT            FLAGS
personal  max   you@personal.dev   (default) (active)
work      team  you@<company>.com  native

$ claudeprofile rules
PATH             PROFILE
~/dev/<company>  work
~/dev/oss        personal
```

Columns size themselves to their contents, so a long profile name widens the
table instead of breaking the alignment. Paths under your home print as `~`.

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
`claudeprofile rules` lists rules longest-first — the order they are consulted —
and flags any that name a profile you have since removed, since resolution skips
those without a word.

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
| `claudeprofile rules` / `rule list` | Rules in the order resolution consults them |
| `claudeprofile rule rm <path>` | Drop a rule |
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
yourself, pointing at a small script of your own.

**Check what you already have first** — the next step replaces it:

```bash
jq -r '.statusLine.command // "none"' ~/.claude/settings.json
```

If that says `none`, write the script and point `settings.json` at it:

```bash
cat > ~/.claude/statusline.sh <<'SL'
#!/usr/bin/env bash
# Profile badge, then whatever else you already run.
seg=$({ ls -1 "$HOME"/.claude/plugins/cache/*/claudeprofile/*/statusline/segment.sh ; } 2>/dev/null | sort -V | tail -1)
[ -r "$seg" ] && bash "$seg" </dev/null
exit 0   # a test as the last command would exit non-zero and fail the statusline
SL
chmod +x ~/.claude/statusline.sh

f=~/.claude/settings.json; [ -f "$f" ] || printf '{}\n' > "$f"
cp "$f" "$f.bak" && jq '.statusLine = {type:"command",command:"bash \"$HOME/.claude/statusline.sh\"",refreshInterval:5}' "$f" > "$f.new" && mv "$f.new" "$f"
```

Your other settings survive — `jq` sets one key and the previous file is kept at
`settings.json.bak`. Resolving the segment at call time means plugin updates do
not break the statusline; the segment finds its own CLI relative to itself, so no
environment variable is required.

<details>
<summary><strong>Already running a statusline?</strong> Compose them.</summary>

Point `settings.json` at a wrapper that prints the badge first and hands the
payload on. The segment deliberately does not read stdin, so Claude Code's JSON
stays unconsumed for the next component — `</dev/null` keeps it that way even if
that ever changes:

```bash
#!/usr/bin/env bash
payload="$(cat)"
seg=$({ ls -1 "$HOME"/.claude/plugins/cache/*/claudeprofile/*/statusline/segment.sh ; } 2>/dev/null | sort -V | tail -1)
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
