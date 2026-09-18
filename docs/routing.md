# Routing

Which account a session gets, and why. A default covers most work, a directory
rule routes a whole tree, and a per-repository pin overrides both.

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

## Importing a directory you already use

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

## Customisations follow you

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
