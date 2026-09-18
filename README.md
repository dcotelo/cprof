<img src="https://capsule-render.vercel.app/api?type=waving&color=0:1a1b27,50:414868,100:7aa2f7&height=200&section=header&text=%E2%9A%91%20cprof&fontSize=52&fontColor=c0caf5&animation=fadeIn&fontAlignY=35&desc=One%20personal%20Claude%20subscription%2C%20one%20for%20work%20%E2%80%94%20the%20right%20account%20per%20repository&descSize=16&descAlignY=55" width="100%" alt="cprof — one personal Claude subscription, one for work; the right account per repository, without thinking about it" />

<div align="center">

[![CI](https://img.shields.io/github/actions/workflow/status/dcotelo/cprof/ci.yml?style=for-the-badge&label=CI&labelColor=1a1b27&color=7aa2f7)](https://github.com/dcotelo/cprof/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/License-MIT-1a1b27?style=for-the-badge&color=414868)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS-1a1b27?style=for-the-badge&color=7aa2f7)](#install)
[![Bash](https://img.shields.io/badge/Bash-3.2%2B-1a1b27?style=for-the-badge&color=414868)](CONTRIBUTING.md#development)
[![Requires](https://img.shields.io/badge/Requires-jq-1a1b27?style=for-the-badge&color=7aa2f7)](#install)
[![Tests](https://img.shields.io/badge/Tests-1130%20assertions-1a1b27?style=for-the-badge&color=414868)](CONTRIBUTING.md#development)

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
  <img alt="cd into a work repo and claude runs as work; cd into a side project and it runs as personal; cprof list shows both profiles with their 5-hour and 7-day usage bars" src="docs/demo.gif" width="860">
</p>

Each profile is its own Claude config directory with its own credentials, so the
accounts never touch. A default covers most of your work, a directory rule routes
a whole tree, and a per-repository pin overrides both.

```console
$ cprof list
PROFILE   PLAN  ACCOUNT            5H              7D              FLAGS
work      team  you@acme.com       ▓▓▓▓░░░░░░ 42%  ▓▓░░░░░░░░ 18%  native
personal  max   you@personal.dev   ▓▓▓▓▓▓▓▓▓░ 91%  ▓▓▓▓▓▓░░░░ 60%  (default) (active)

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
statusline — the account, the model, the directory and its branch, and bars
for the context window and the usage window:

```bash
claude plugin marketplace add dcotelo/cprof
claude plugin install cprof@dcotelo
```

**[Quickstart](#quickstart)** walks the whole setup — profiles, rules, default —
in about two minutes. Requires macOS; Homebrew pulls in `jq`, and usage data
needs `curl`, which macOS ships. [Install details](docs/install.md) covers
the plugin-only path and updating.

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
  [you can pick your own](docs/statusline.md#colours):

<p>
  <img alt="work in magenta" src="https://img.shields.io/badge/⚑%20work-bc3fbc?style=flat-square">
  <img alt="personal in green" src="https://img.shields.io/badge/⚑%20personal-0dbc79?style=flat-square">
  <img alt="client in cyan" src="https://img.shields.io/badge/⚑%20client-11a8cd?style=flat-square">
</p>

**Docs** · [Routing](docs/routing.md) · [Install details](docs/install.md) ·
[Commands](docs/commands.md) · [Statusline](docs/statusline.md) ·
[Usage and fallback](docs/usage.md) · [Safety](docs/security.md)

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

# 4. choose the default profile, and route one tree to the other
cprof default personal
cprof rule add ~/dev/<company> work

# 5. confirm
cprof list
cprof which
```

```console
$ cprof list
PROFILE   PLAN  ACCOUNT            5H              7D              FLAGS
work      team  you@<company>.com  ▓▓▓▓░░░░░░ 42%  ▓▓░░░░░░░░ 18%  native
personal  max   you@personal.dev   ▓▓▓▓▓▓▓▓▓░ 91%  ▓▓▓▓▓▓░░░░ 60%  (default) (active)

$ cd ~/dev/<company>/api && cprof which
work  native (keychain)  rule ~/dev/<company>
```

That is the whole setup. From here `claude` picks the account for you; the only
rule to remember is that **a change takes effect on the next `claude` launch**,
never in a running session, because credentials are read at process start.

Nothing was moved or re-signed-in along the way: `--native` adopts your existing
login where it already lives, and step 3's `login` writes only inside the new
profile's own directory.

## What you get

### Usage you can see before you hit it

Two accounts means two rate limits, and the one you are about to hit is rarely
the one you are looking at. `cprof list` carries each profile's 5-hour and 7-day
windows as a bar; `cprof usage <name>` adds the per-model weekly limits and when
each window resets.

<p align="center">
  <img alt="cprof list with 5H and 7D usage bars per profile, cprof usage work showing the full breakdown with reset times, and cprof doctor warning that personal is at 91% of its 5-hour window" src="docs/usage-demo.gif" width="860">
</p>

A profile that runs out can hand the session to a
[fallback account](docs/usage.md#fallback-accounts) instead of stopping.

### A statusline that answers "which account is this?"

One line inside the session: the account, the model, the directory and its
branch, then bars for the context window and the usage window.

<p align="center">
  <img alt="cprof statusline --full rendering the account, model, directory and branch with context and usage bars; the same session after narrowing the layout to a six-cell usage bar; and cprof doctor reporting a rejected statusline.bar.width setting" src="docs/statusline-demo.gif" width="860">
</p>

Which segments appear, how they are laid out, the bar glyphs and width, the
warning thresholds and every colour are configurable — and `cprof doctor` names
any setting it rejects rather than failing quietly. See
[Statusline](docs/statusline.md).

## Documentation

| Doc | What is in it |
| --- | --- |
| [Routing](docs/routing.md) | How a directory decides the account: defaults, rules, repository pins, resolution order, importing a directory you already use |
| [Install details](docs/install.md) | The plugin-only path, what the installer writes, updating, uninstalling |
| [Commands](docs/commands.md) | Every subcommand and what it does |
| [Statusline](docs/statusline.md) | Segments, layout, bars, thresholds, the colour palette, and what `cprof doctor` reports |
| [Usage and fallback](docs/usage.md) | Usage headroom, the 5-hour and 7-day windows, and fallback accounts |
| [Safety](docs/security.md) | Keychain snapshots, what `cprof` never touches, and the security assessment |
| [Contributing](CONTRIBUTING.md) | Development setup, conventions, dependency policy, releasing |

Found a bug? [Open an issue](https://github.com/dcotelo/cprof/issues) —
templates are provided. Security problems go through
[private vulnerability reporting](https://github.com/dcotelo/cprof/security/advisories/new)
instead; see [SECURITY.md](SECURITY.md). Contributions: [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).

<div align="center">

**Maintained by [@dcotelo](https://github.com/dcotelo)** · [dcotelo.dev](https://dcotelo.dev)

</div>

<img src="https://capsule-render.vercel.app/api?type=waving&color=0:7aa2f7,50:414868,100:1a1b27&height=120&section=footer" width="100%" alt="" />
