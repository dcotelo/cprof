<img src="https://capsule-render.vercel.app/api?type=waving&color=0:1a1b27,50:414868,100:7aa2f7&height=200&section=header&text=%E2%9A%91%20cprof&fontSize=52&fontColor=c0caf5&animation=fadeIn&fontAlignY=35&desc=One%20personal%20Claude%20subscription%2C%20one%20for%20work%20%E2%80%94%20the%20right%20account%20per%20repository&descSize=16&descAlignY=55" width="100%" alt="cprof — one personal Claude subscription, one for work; the right account per repository, without thinking about it" />

<div align="center">

[![CI](https://img.shields.io/github/actions/workflow/status/dcotelo/cprof/ci.yml?style=for-the-badge&label=CI&labelColor=1a1b27&color=7aa2f7)](https://github.com/dcotelo/cprof/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/License-MIT-1a1b27?style=for-the-badge&color=414868)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS-1a1b27?style=for-the-badge&color=7aa2f7)](#install)
[![Bash](https://img.shields.io/badge/Bash-3.2%2B-1a1b27?style=for-the-badge&color=414868)](#development)
[![Requires](https://img.shields.io/badge/Requires-jq-1a1b27?style=for-the-badge&color=7aa2f7)](#install)
[![Tests](https://img.shields.io/badge/Tests-300%20assertions-1a1b27?style=for-the-badge&color=414868)](#development)

</div>

<p align="center">
  <strong>You have two Claude subscriptions. Claude Code has one login.</strong>
</p>

Log in for work, and your side project bills the company. Log in for yourself,
and the work repo runs on a personal account. Switching means logging out,
logging back in, and remembering which one you are on — every time you change
directory.

`cprof` makes the directory decide.

<p align="center">
  <img alt="cd into a work repo and claude runs as work; cd into a side project and it runs as personal" src="docs/demo.gif" width="720">
</p>

Each profile is its own Claude config directory with its own credentials, so the
accounts never touch. A default covers most of your work, a directory rule routes
a whole tree, and a per-repository pin overrides both.

```console
$ cprof list
PROFILE   PLAN  ACCOUNT            FLAGS
work      team  you@acme.com       native
personal  max   you@personal.dev   (default) (active)

$ cd ~/dev/acme/api && cprof which
work  native (keychain)  rule ~/dev/acme
```

## Install

```bash
brew install dcotelo/tap/cprof
```

Or without Homebrew — no sudo, installs to `~/.local`, needs `jq` on `PATH`.
Download the installer, read it, then run it:

```bash
curl -fsSLO https://raw.githubusercontent.com/dcotelo/cprof/main/install.sh && less install.sh
```

then, once it reads right:

```bash
bash install.sh
```

Then one line in your shell config, and you are done:

```bash
claude() { eval "$(cprof env)"; command claude "$@"; }
```

The Claude Code plugin is optional and adds the ambient parts — a warning when
you walk into a directory expecting a different account, `/profile`, and the
statusline badge:

```bash
claude plugin marketplace add dcotelo/cprof
claude plugin install cprof@dcotelo
```

**[Quickstart](#quickstart)** walks the whole setup — profiles, rules, default —
in about two minutes. Requires macOS; Homebrew pulls in `jq`, the only other
dependency. [Install details](#install-details) covers the plugin-only path
and updating.

### Why it is built this way

- **Nothing is moved, nothing is re-authenticated.** Your existing login stays
  exactly where it is, as a `native` profile. Adding `cprof` to a working setup
  changes nothing about that setup.
- **Your customisations follow you.** A Claude config directory holds plugins,
  skills, settings and `CLAUDE.md` as well as credentials — so a naive profile
  switch would silently switch away everything you have installed. `cprof` links
  them, and never links the files that identify you.
- **It cannot lose your account.** `login` snapshots the keychain first and
  restores it if a profile login writes to the shared item. `env` never exits
  non-zero, so a broken config degrades to stock Claude Code rather than a
  broken shell.
- **You can see it at a glance.** Every profile has a colour, hashed from its
  name so two profiles differ with no configuration at all — and
  [you can pick your own](#colours):

<p>
  <img alt="work in magenta" src="https://img.shields.io/badge/⚑%20work-bc3fbc?style=flat-square">
  <img alt="personal in green" src="https://img.shields.io/badge/⚑%20personal-0dbc79?style=flat-square">
  <img alt="client in cyan" src="https://img.shields.io/badge/⚑%20client-11a8cd?style=flat-square">
</p>

**Contents** · [Quickstart](#quickstart) · [How it works](#how-it-works) ·
[Install details](#install-details) · [Resolution order](#resolution-order) ·
[Commands](#commands) · [Statusline](#statusline) · [Safety](#safety) ·
[Development](#development) · [Releasing](#releasing)

## Quickstart

Five steps, about two minutes. Needs macOS.

```bash
# 1. install the CLI (jq comes with it), and the plugin for the ambient parts
brew install dcotelo/tap/cprof
claude plugin marketplace add dcotelo/cprof
claude plugin install cprof@dcotelo

# 2. route `claude` through it
cat >> ~/.zshrc <<'RC'
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

## Install details

What [Quickstart](#quickstart) steps 1 and 2 are doing, and why.

Requires macOS and bash 3.2+ (the system shell). Homebrew pulls in `jq`, the
only other dependency.

**Two pieces, and you can take either alone.** `brew` installs the CLI on
`PATH`; the plugin installs the parts that only exist inside a Claude Code
session — the `SessionStart` warning, `/profile`, and the statusline segment.
The CLI is what the shell function needs, so brew alone is a working setup; the
plugin alone is not.

**The curl installer** is the CLI piece without Homebrew, in the same layout
the formula uses: the latest release's `scripts`, `statusline`, `hooks` and
`commands` land in `~/.local/share/cprof`, with `~/.local/bin/cprof` a symlink
into it. It refuses to run without `jq` and warns when `~/.local/bin` is not
on `PATH`. Pin a version with `CPROF_VERSION=cprof--v0.8.0 bash install.sh`;
uninstall by deleting those two paths.

<details>
<summary><strong>Installing the plugin without Homebrew</strong></summary>

The plugin puts nothing on `PATH` — the CLI lives inside a versioned cache
directory — so reaching it takes a resolver function:

```bash
cprof() {
  local cli
  cli=$({ ls -1 "$HOME"/.claude/plugins/cache/*/cprof/*/scripts/cprof ; } 2>/dev/null | sort -V | tail -1)
  [ -x "$cli" ] || { print -u2 'cprof: plugin not installed'; return 127; }
  "$cli" "$@"
}
```

Resolving at call time means plugin updates need no edit; `sort -V` keeps
`0.10.0` ahead of `0.9.0`; and the braces around `ls` put zsh's own "no matches
found" on the suppressed stream when nothing is installed. Install `jq` yourself
(`brew install jq`).

With both installed, `PATH` wins and this function is unnecessary.

</details>

Skipping the wrapper is always available: `command claude` ignores profiles and
uses stock keychain behaviour. That is also the silent failure mode worth knowing
— if `cprof` cannot be reached, `eval` of a failed command is a no-op, so
`claude` starts stock with only one line on stderr to say so.

### Updating

Two pieces installed, two things to update:

```bash
brew upgrade dcotelo/tap/cprof   # the CLI on PATH
cprof update                     # the plugin
```

Then restart Claude Code — a running session keeps the version it started with.

A curl install updates its CLI by running the installer again — it
replaces `~/.local/share/cprof` with the latest release — with `cprof update`
still covering the plugin.

Brew-only installs (see [Install details](#install-details)) have nothing for
`cprof update` to act on and should stop at the first line. Plugin-only
installs — the CLI reached through the resolver function described under
[Installing the plugin without Homebrew](#install-details) instead of
Homebrew — should stop at the second.

`cprof update` is exactly the two commands below, run in order. Reach for them
directly only when `cprof` itself is unreachable, or when you want to see what
each step reported:

```bash
env -u CLAUDE_CONFIG_DIR claude plugin marketplace update dcotelo
env -u CLAUDE_CONFIG_DIR claude plugin update cprof@dcotelo
```

Both details in those commands are load-bearing, and neither is obvious:

**`env -u CLAUDE_CONFIG_DIR`.** Marketplace commands fail from a directory that
resolves to a non-native profile:

```
Failed to refresh marketplace 'dcotelo': corrupted installLocation
(~/.claude/plugins/marketplaces/dcotelo) — expected a path inside
~/.claude-profiles/<name>/plugins/marketplaces
```

This is `cprof`'s own doing. `share` links `plugins` into the profile directory,
and Claude Code checks that the recorded `installLocation` sits under the config
directory's plugins path — a check the stored `~/.claude/…` string fails even
though the symlink resolves to exactly that place. Unsetting the variable for one
command runs it as the native profile, where the path matches.

**`cprof@dcotelo`, not `cprof`.** `plugin update` does not resolve the bare name
and reports `Plugin "cprof" not found`, which reads like a broken install rather
than a naming rule. `plugin list` and `marketplace update` both accept the short
form, so the inconsistency is in Claude Code, not in this plugin.

Confirm with:

```bash
cprof version                                  # the version you expected
env -u CLAUDE_CONFIG_DIR claude plugin list    # cprof@dcotelo, enabled
```

`failed to load` rather than `enabled` means the plugin is installed but its
hooks did not register, so the `SessionStart` warning and `/profile` are missing
even though the CLI still works.

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
| `cprof color --text on\|off` | Whether the statusline badge's name is coloured too; on by default |
| `cprof default <name>` | Set the default profile |
| `cprof pin [<name>] \| pin --clear` | Pin or unpin this repository |
| `cprof rule add <path> <name>` | Route a directory tree to a profile |
| `cprof rules` / `rule list` | Rules in the order resolution consults them |
| `cprof rule rm <path>` | Drop a rule |
| `cprof login <name>` | Sign a profile in, with keychain protection |
| `cprof doctor` | Report unauthenticated profiles and expiring tokens |
| `cprof update` | Refresh the marketplace, then update this plugin |
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

The badge carries the profile's colour, and `--text` decides how far it
reaches:

<p>
  <img alt="default: flag and name both coloured" src="https://img.shields.io/badge/⚑%20work-bc3fbc?style=flat-square">
  &nbsp;&nbsp;<code>default — flag and name both coloured</code>
</p>
<p>
  <img alt="--text off: flag only" src="https://img.shields.io/badge/⚑-bc3fbc?style=flat-square&label=&labelColor=bc3fbc">
  <img alt="work" src="https://img.shields.io/badge/work-6e7681?style=flat-square">
  &nbsp;&nbsp;<code>cprof color --text off</code>
</p>

### Colours

Colours are hashed from the profile name,
so two profiles differ without any configuration and keep the same colour on
every machine, because nothing is stored. `cprof color work red` sets one
directly (`auto` returns to the hash), and `cprof color work` with no colour
opens a picker:

<table>
<tr>
<td valign="top">

```bash
cprof color work
```

```text
Colour for work
up/down move, enter select, q cancel

    ⚑ work   auto (magenta)
  > ⚑ work   red
    ⚑ work   green
    ⚑ work   yellow
```

</td>
<td valign="top">

The palette, drawn as the badge<br>will actually look:

<img alt="red" src="https://img.shields.io/badge/⚑%20red-cd3131?style=flat-square"><br>
<img alt="green" src="https://img.shields.io/badge/⚑%20green-0dbc79?style=flat-square"><br>
<img alt="yellow" src="https://img.shields.io/badge/⚑%20yellow-b5a300?style=flat-square"><br>
<img alt="blue" src="https://img.shields.io/badge/⚑%20blue-2472c8?style=flat-square"><br>
<img alt="magenta" src="https://img.shields.io/badge/⚑%20magenta-bc3fbc?style=flat-square"><br>
<img alt="cyan" src="https://img.shields.io/badge/⚑%20cyan-11a8cd?style=flat-square">

</td>
</tr>
</table>

Plus a `bright-` variant of each. The swatches above are approximations — the
real values are named ANSI colours, so they follow your terminal's theme
instead of fighting it, and what you see is whatever your theme maps them to,
not what this page shows. `NO_COLOR` is honoured, and
`CPROF_COLOR=never|always|auto` overrides the terminal detection the same way
it does for every other command.

`cprof color --text off` narrows the colour to the flag alone.
That toggle is statusline-only: `cprof list` and `cprof which` colour the
profile name unconditionally, regardless of `--text`.

Both settings live in `~/.cprof.json`, alongside profiles and rules, though you
will normally reach them through the commands above rather than edit the file:
a `color` field on a profile (`auto`, a base colour, or a `bright-` variant) and
a top-level `colorText` boolean, defaulting to `true` when absent.

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
  statusline/*.sh tests/*.sh install.sh
claude plugin validate .             # check the manifests
```

CI runs all three on every pull request: shellcheck and the manifest checks on
Ubuntu, the suite on macOS, where `/bin/bash` is the 3.2 the code targets.

Targets bash 3.2 (macOS system bash), with `jq` as the only external dependency.

Found a bug? [Open an issue](https://github.com/dcotelo/cprof/issues) —
templates are provided. Security problems go through
[private vulnerability reporting](https://github.com/dcotelo/cprof/security/advisories/new)
instead; see [SECURITY.md](SECURITY.md). Contributions: [CONTRIBUTING.md](CONTRIBUTING.md).

Tests sandbox `HOME`, the config path, the `claude` binary, and the `security`
binary. No test touches the real keychain or a real account.

## Releasing

Merging a release-worthy pull request is releasing. Open one as usual;
`release-bump.yml` reads the
[Conventional Commits](https://www.conventionalcommits.org) subjects on the
branch, works out whether they warrant a release, and if they do, commits the
version bump and a `CHANGELOG.md` section to the branch:

| Commit type on the branch | Effect |
|---|---|
| `feat!:`, or any type with `!` | major |
| `feat:` | minor |
| `fix:`, `perf:` | patch |
| `docs:`, `chore:`, `test:`, `ci:`, `refactor:` | no release |

The bump lands in the pull request, so it is reviewable and editable before it
ships — **rewrite the generated CHANGELOG entries into prose before merging**,
since generated notes read like a commit log. Anything already written by hand
under `## [Unreleased]` is promoted as-is instead of being generated over.

Merging then puts the manifest change on `main`, where `tag.yml` tags
`cprof--v<version>` and calls the release workflow: it re-verifies the tag
against the manifests, runs the suite on macOS, and publishes a GitHub release
with that CHANGELOG section as its notes and a `checksums.txt` beside the
tarball.

The version lives in four places that must agree — `CP_VERSION` in
`scripts/cprof`, `plugin.json`, the `marketplace.json` metadata, and its plugin
entry. The bump writes all four; `tests/test_manifest.sh` and
`tests/test_cli.sh` fail when they drift, or when `CHANGELOG.md` has no section
for the version.

`release-bump.yml` runs `.github/scripts/release-version.sh` as it exists on the
*base* revision, never the branch's copy, so that a pull request cannot choose
what a write-capable token executes. A change to that script therefore takes
effect once it merges, not in the pull request making it.

To release by hand instead — a fork's pull request cannot be bumped by CI, since
its token is read-only:

```bash
bash .github/scripts/release-version.sh apply <version>   # or edit the four by hand
bash tests/run.sh && claude plugin validate .
```

then merge, or tag directly with `claude plugin tag . --push`.

Installs track the marketplace, so consumers update with:

```bash
claude plugin marketplace update cprof
claude plugin update cprof     # restart Claude Code to apply
```

The plugin cache is keyed by version, so a release without a version bump gives
`plugin update` nothing to act on.

## License

MIT — see [LICENSE](LICENSE).

<div align="center">

**Maintained by [@dcotelo](https://github.com/dcotelo)** · [dcotelo.dev](https://dcotelo.dev)

</div>

<img src="https://capsule-render.vercel.app/api?type=waving&color=0:7aa2f7,50:414868,100:1a1b27&height=120&section=footer" width="100%" alt="" />
