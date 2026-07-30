<h1 align="center">⚑ cprof</h1>

<p align="center">
  <em>One personal Claude subscription, one for work.<br>
  The right account per repository, without thinking about it.</em>
</p>

<p align="center">
  <a href="https://github.com/dcotelo/cprof/actions/workflows/ci.yml"><img alt="ci" src="https://github.com/dcotelo/cprof/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="license MIT" src="https://img.shields.io/badge/license-MIT-blue">
  <img alt="platform macOS" src="https://img.shields.io/badge/platform-macOS-lightgrey">
  <img alt="bash 3.2+" src="https://img.shields.io/badge/bash-3.2%2B-green">
  <img alt="requires jq" src="https://img.shields.io/badge/requires-jq-orange">
  <img alt="288 assertions" src="https://img.shields.io/badge/tests-288%20assertions-brightgreen">
</p>

```console
$ cd ~/dev/<company>/api && cprof which
work  native (keychain)  rule ~/dev/<company>

$ cd ~/dev/side-project && cprof which
personal  ~/.claude-profiles/personal  default
```

`cprof` stores your Claude accounts as profiles, then picks one for each
session based on a default, a per-repository pin, or a directory rule — so repos
under `~/dev/<company>` use the work account and everything else uses personal.

**Contents** · [Quickstart](#quickstart) · [How it works](#how-it-works) ·
[Install](#install) · [Resolution order](#resolution-order) ·
[Commands](#commands) · [Statusline](#statusline) · [Safety](#safety) ·
[Development](#development) · [Releasing](#releasing)

## Quickstart

Five steps, about two minutes. Needs macOS and `jq` (`brew install jq`).

```bash
# 1. install the plugin
claude plugin marketplace add dcotelo/cprof
claude plugin install cprof@dcotelo

# 2. reach the CLI, and route `claude` through it
cat >> ~/.zshrc <<'RC'
cprof() {
  local cli
  cli=$({ ls -1 "$HOME"/.claude/plugins/cache/*/cprof/*/scripts/cprof ; } 2>/dev/null | sort -V | tail -1)
  [ -x "$cli" ] || { print -u2 'cprof: plugin not installed'; return 127; }
  "$cli" "$@"
}
claude() { eval "$(cprof env)"; command claude "$@"; }
RC
exec zsh

# 3. keep the account you already use, then add a second one
cprof add work --native        # adopts your current keychain login
cprof add personal             # ~/.claude-profiles/personal, sharing
                                       # your plugins, skills and settings
cprof login personal           # interactive, opens a browser

# 4. choose which one is the fallback, and route one tree to the other
cprof default personal
cprof rule add ~/dev/<company> work

# 5. confirm
cprof list
cprof which
```

```console
$ cprof list
PROFILE   PLAN  ACCOUNT            FLAGS
work      team  you@<company>.com  native
personal  max   you@personal.dev   (default) (active)

$ cd ~/dev/<company>/api && cprof which
work  native (keychain)  rule ~/dev/<company>
```

That is the whole setup. From here `claude` picks the account for you; the only
rule to remember is that **a change takes effect on the next `claude` launch**,
never in a running session, because credentials are read at process start.

Nothing was moved or re-signed-in along the way: `--native` adopts your existing
login where it already lives, and step 3's `login` writes only inside the new
profile's own directory.

### Importing a directory you already use

Step 3 assumes a profile that does not exist yet. If you have been switching
accounts by hand — an alias along the lines of

```bash
alias claude-client='CLAUDE_CONFIG_DIR=~/.claude-client claude'
```

— then that directory is already a profile in all but name, and `add` adopts it
where it stands:

```bash
cprof add client --dir ~/.claude-client --isolated --note 'client account'
```

`--isolated` is the flag that matters here. Without it `add` links the shared
assets, which moves the directory's own `settings.json`, `CLAUDE.md`, `plugins`
and the rest aside as `*.moved-<timestamp>` and puts links to `~/.claude` in
their place. Nothing is deleted and [`unshare`](#customisations-follow-you)
reverses it, but a directory you have already furnished usually wants to keep
what it has. Decide otherwise later with `cprof share client`.

The existing login carries over, with one caveat worth checking. Claude Code keys
credentials to the value of `CLAUDE_CONFIG_DIR`, and `add` stores the physical
path, so a symlink standing between the two leaves the stored path different from
the string your alias exported — and the login is then looked up under a name
nothing wrote:

```bash
[ "$(cd ~/.claude-client && pwd -P)" = "$HOME/.claude-client" ] && echo match || echo differs
```

`differs` costs one `cprof login client`. Either way `cprof list` reports the
account each profile actually resolves to, so it will tell you which happened.

Finish by giving the directory a rule, after which the alias has nothing left to
do:

```bash
cprof rule add ~/dev/<client> client
```

## How it works

Claude Code keys its credentials to `CLAUDE_CONFIG_DIR`. `cprof` uses this: each
profile is its own config directory with its own credentials, and a shell
function points `CLAUDE_CONFIG_DIR` at the right one before launching.

Where those credentials physically live depends on the Claude Code version, and
`cprof` deliberately does not care. Versions before 2.1 wrote
`$CLAUDE_CONFIG_DIR/.credentials.json`. Since 2.1 they go to the macOS keychain
under a service name derived from the directory —
`Claude Code-credentials-<sha256(CLAUDE_CONFIG_DIR)[0:8]>`, against the plain
`Claude Code-credentials` used when the variable is unset. Either way each
profile gets its own store, and `cprof` asks `claude auth status` whether a
profile is signed in rather than looking for a file.

Your existing setup stays exactly as it is, as a `native` profile — the launcher
exports nothing for it, so the keychain and `~/.claude.json` are used unchanged.
No profile may point at `~/.claude`; doing so would break authentication and
relocate `.claude.json`.

Credentials are fixed at process start, so switching accounts always means
relaunching `claude`. A `SessionStart` hook warns you when you have wandered into
a directory that expects a different account.

### Customisations follow you

`CLAUDE_CONFIG_DIR` relocates the whole configuration directory, not only the
credentials in it — plugins, skills, agents, commands, hooks, `settings.json` and
`CLAUDE.md` all live there. Left alone, a profile would therefore start with none
of them, and switching account would silently mean switching away every
customisation.

So `add` links them, and `cprof share <name>` does it for a profile that
predates this behaviour:

```console
$ cprof share personal
ASSET          RESULT
settings.json  linked (previous kept as settings.json.moved-20260729-103012)
CLAUDE.md      linked
plugins        linked
skills         linked
hooks          linked
```

They are symlinks, so installing a plugin or editing settings once applies to
every profile with nothing to re-sync. Anything the profile already had is moved
aside rather than deleted, and `unshare` removes only the links this created.

| Shared | Per-profile |
| --- | --- |
| `settings.json`, `keybindings.json` | credentials (keychain item, or `.credentials.json` before Claude Code 2.1) |
| `CLAUDE.md` | `.claude.json` |
| `plugins`, `skills`, `agents`, `commands`, `hooks` | `projects`, `sessions`, `history.jsonl`, `todos`, caches |

The right-hand column is what keeps two accounts apart, so nothing there is ever
linked. Use `add --isolated` for a profile that should share nothing.

## Install

What [Quickstart](#quickstart) steps 1 and 2 are doing, and why.

Requires macOS, bash 3.2+ (the system shell), and `jq`.

Installing the plugin puts nothing on `PATH` — the CLI lives inside a versioned
cache directory — so the first function reaches it and the second routes `claude`
through it. Resolving the path at call time means plugin updates need no edit;
`sort -V` keeps `0.10.0` ahead of `0.9.0`; and the braces around `ls` put zsh's
own "no matches found" on the suppressed stream when nothing is installed.

Skipping the wrapper is always available: `command claude` ignores profiles and
uses stock keychain behaviour. That is also the silent failure mode worth knowing
— if `cprof` cannot be reached, `eval` of a failed command is a no-op, so
`claude` starts stock with only one line on stderr to say so.

## Resolution order

First match wins.

| # | Source | Set with |
| --- | --- | --- |
| 1 | environment override, one session | `CLAUDE_PROFILE=work claude` |
| 2 | repository pin, keyed on the git top level | `cprof pin work` |
| 3 | directory rule, longest matching prefix | `cprof rule add ~/dev/<company> work` |
| 4 | default profile | `cprof default personal` |
| 5 | nothing matched — stock `~/.claude` behaviour | — |

`cprof which` reports both the winner and the rule that produced it.
`cprof rules` lists rules longest-first — the order they are consulted —
and flags any that name a profile you have since removed, since resolution skips
those without a word.

Prefix matching respects path boundaries: a rule for `~/dev/work` never matches
`~/dev/workshop`. There is no glob support.

## Commands

| Command | Description |
| --- | --- |
| `cprof list` | Profiles with identity and subscription; marks default, active, native |
| `cprof which` | Profile resolved here, and the rule that produced it |
| `cprof status` | Profile this process is actually running as |
| `cprof env` | `export`/`unset` statements for `eval` |
| `cprof add <name> [--dir P] [--native] [--note S] [--isolated]` | Register a profile |
| `cprof share <name>` / `unshare <name>` | Link `~/.claude` customisations into a profile, or drop the links |
| `cprof color <name>` | Pick a profile's colour interactively |
| `cprof color <name> <colour>` | Set it directly; `auto` returns to the hashed colour |
| `cprof color --text on\|off` | Colour the statusline badge's name as well as its flag |
| `cprof default <name>` | Set the default profile |
| `cprof pin [<name>] \| pin --clear` | Pin or unpin this repository |
| `cprof rule add <path> <name>` | Route a directory tree to a profile |
| `cprof rules` / `rule list` | Rules in the order resolution consults them |
| `cprof rule rm <path>` | Drop a rule |
| `cprof login <name>` | Sign a profile in, with keychain protection |
| `cprof doctor` | Report unauthenticated profiles and expiring tokens |
| `cprof remove <name> [--purge]` | Unregister; `--purge` deletes the directory |

In a session, `/profile` shows status, `/profile pin <name>` pins the repository.

`which` answers "what should this directory use", `status` answers "what am I
signed in as right now". They disagree after you pin or add a rule without
relaunching — which is exactly when knowing the difference matters.

Listings size their columns to the contents, so a long profile name widens the
table instead of breaking the alignment, and paths under your home print as `~`.

## Statusline

```console
⚑ work
```

The flag carries the profile's colour. Colours are hashed from the profile name,
so two profiles differ without any configuration and keep the same colour on
every machine, because nothing is stored. `cprof color <name>` opens a picker to
choose one, `cprof color <name> <colour>` sets it directly, and
`cprof color --text on` colours the badge's name text too, not just the flag.
That toggle is statusline-only: `cprof list` and `cprof which` colour the
profile name unconditionally, regardless of `--text`. Values are named ANSI
colours, so they follow your terminal's theme instead of fighting it —
`NO_COLOR` is honoured, and `CPROF_COLOR=never|always|auto` overrides the
terminal detection the same way it does for every other command.

Both settings live in `~/.cprof.json`, alongside profiles and rules, though you
will normally reach them through the commands above rather than edit the file:
a `color` field on a profile (`auto`, a base colour, or a `bright-` variant) and
a top-level `colorText` boolean, defaulting to `false`.

`statusline/segment.sh` prints that one line, naming the account the session
is running as. Every profile is named, native included — a
switching tool whose indicator is invisible in the common case teaches you to
ignore it. The line is omitted only when there is no profile to name: no config,
or a config with no native profile and no `CLAUDE_CONFIG_DIR` set.

A session on a config directory that belongs to no profile reads `⚑ unknown` —
worth seeing, since it means something else set `CLAUDE_CONFIG_DIR`. The stock
`~/.claude` is not one of those cases: a native profile is registered without a
directory, but an exported `CLAUDE_CONFIG_DIR` pointing there is still the
native profile, and is named as such.

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
seg=$({ ls -1 "$HOME"/.claude/plugins/cache/*/cprof/*/statusline/segment.sh ; } 2>/dev/null | sort -V | tail -1)
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
seg=$({ ls -1 "$HOME"/.claude/plugins/cache/*/cprof/*/statusline/segment.sh ; } 2>/dev/null | sort -V | tail -1)
[ -r "$seg" ] && bash "$seg" </dev/null
printf '%s' "$payload" | your-existing-statusline
```

</details>

The segment never fails a statusline: a missing `jq`, an unreadable config, or a
missing CLI prints nothing and exits 0.

## Safety

`cprof login` snapshots the shared keychain item to `~/.cprof/keychain.bak`
(mode 600) before signing in, then verifies that `claude auth status` reports the
profile signed in and that the shared item went untouched. If a login overwrites
the shared item instead of the profile's own, it is restored from the snapshot
and the command fails loudly. Your working account cannot be lost to a profile
login.

`cprof doctor` reads credentials only to extract the refresh token's expiry, and
pipes them straight into `jq` so a live token never lands in a shell variable. If
the store cannot be read, the expiry is reported as unknown rather than guessed.

`cprof env` never exits non-zero and always prints one assignment. A
missing `jq`, a malformed config, or a missing profile directory degrades to
stock Claude Code behaviour rather than a broken shell.

## Development

```bash
bash tests/run.sh                    # run the suite
shellcheck -x -P scripts -P tests scripts/cprof scripts/lib/*.sh hooks/*.sh \
  statusline/*.sh tests/*.sh
claude plugin validate .             # check the manifests
```

CI runs all three on every pull request: shellcheck and the manifest checks on
Ubuntu, the suite on macOS, where `/bin/bash` is the 3.2 the code targets.

Targets bash 3.2 (macOS system bash), with `jq` as the only external dependency.

Tests sandbox `HOME`, the config path, the `claude` binary, and the `security`
binary. No test touches the real keychain or a real account.

## Releasing

Version lives in three places that must agree — `plugin.json`, the
`marketplace.json` metadata, and its plugin entry. `tests/test_manifest.sh`
fails when they drift, and again if `CHANGELOG.md` has no section for the
version, since the release notes are read from it.

```bash
# 1. bump all three, add the CHANGELOG section, commit
bash tests/run.sh && claude plugin validate .

# 2. tag: refuses a dirty tree, and checks the manifests agree
claude plugin tag . --dry-run
claude plugin tag . --push
```

Pushing a `cprof--v<version>` tag runs the release workflow, which
re-verifies that the tag matches the manifests, runs the suite on macOS, then
publishes a GitHub release with that CHANGELOG section as its notes.

Installs track the marketplace, so consumers update with:

```bash
claude plugin marketplace update cprof
claude plugin update cprof     # restart Claude Code to apply
```

The plugin cache is keyed by version, so a release without a version bump gives
`plugin update` nothing to act on.

## License

MIT — see [LICENSE](LICENSE).
