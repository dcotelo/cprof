# Statusline

<p align="center">
  <img alt="cprof statusline --full rendering the account, model, directory and branch with context and usage bars; the same session after narrowing the layout to a six-cell usage bar; and cprof doctor reporting a rejected statusline.bar.width setting" src="statusline-demo.gif" width="860">
</p>

```console
⚑ work │ [Opus 5 (1M context)] │ cprof git:(main*)
Context ▓▓▓▓░░░░░░ 37% │ Usage ▓▓▓░░░░░░░ 30% (resets in 2h 19m)
```

That is `cprof statusline`'s default render, given Claude Code's statusline
payload: the account, the model, the directory with its git branch, then a
context bar and a 5-hour usage bar with the time until it resets. Everything
here but the branch comes straight from the payload Claude Code already hands
a statusline, so it costs no request and refreshes every tick. Only the branch
costs anything extra — two `git` calls — and `git` is a soft dependency: no
`git` on `PATH`, or a directory outside a work tree, skips that field and
changes nothing else in the statusline (it does change which profile a
repository pin resolves — see [Dependencies](../CONTRIBUTING.md#dependencies)).

Without a payload there is only the account and, if something has fetched it
before, the *active* profile's cached usage — fetching it for a different
profile doesn't count — and there is no context bar:

```console
⚑ work
Usage ▓▓▓▓░░░░░░ 42%
```

A segment with nothing to say — here, `model`, `dir`, `git` and `context` —
prints nothing and leaves no stray separator; a line whose segments are all
empty is dropped rather than printed empty. With nothing cached either,
that drops the second line too, leaving only the account:

```console
⚑ work
```

The statusline never warns and never fails. Claude Code re-runs it every few
seconds with its error output discarded, so a warning printed there would be
invisible and endless — which is why a rejected setting falls back quietly
instead, and `cprof doctor` is where you find out about it.

## Configuration

A `statusline` block in `~/.cprof.json` chooses which segments appear, in
what order, and how they group into lines, along with the bar's glyphs and
width, the severity thresholds, and the colours of the model, directory, git,
branch and label text. This is what an absent block resolves to — the
defaults behind the render above:

```json
{
  "statusline": {
    "lines": [["badge", "model", "dir", "git"], ["context", "usage"]],
    "bar": {"filled": "▓", "empty": "░", "width": 10},
    "thresholds": {"warn": 70, "critical": 90},
    "colors": {"model": "cyan", "dir": "yellow", "git": "magenta", "branch": "cyan", "label": "dim"}
  }
}
```

`lines` is a list of lines, each a list of segment names; each inner list
becomes one printed line, its segments joined by ` │ ` (`git` hugs the `dir`
before it with a single space instead, so a directory and its branch read as
one thing). An inner list with no segment cprof recognises is dropped, and if
that empties the whole thing the default layout above is used instead — one
typo doesn't blank the statusline. Six segment names exist today: `badge`,
`model`, `dir`, `git`, `context`, `usage`. A seventh, `agents`, is planned for
a later release and is not a valid segment name yet — write it into `lines`
now and it is dropped like any other name cprof doesn't recognise.

Most other settings validate on their own and fall back to their own default
rather than failing the whole block — the thresholds and the colours are the
two exceptions, each for a different reason, both worth knowing before you
rely on them:

| Setting | Accepts | Falls back to |
| --- | --- | --- |
| `statusline.bar.filled` / `.empty` | exactly one character, and not an invisible one — a tab is one character and is rejected, with a message of its own | `▓` / `░` |
| `statusline.bar.width` | a whole number from 1 to 40 | `10` |
| `statusline.thresholds.warn` **and** `.critical` | both, together: whole numbers from 1 to 100 with `warn` below `critical` | `70` **and** `90` — setting only one, or an out-of-order pair, reverts both |
| `statusline.colors.*` — wrong shape | a string, 1-19 characters, with no invisible character in it — a trailing tab is rejected, with a message of its own | its own default (`cyan` for `model`/`branch`, `yellow` for `dir`, `magenta` for `git`, `dim` for `label`) |
| `statusline.colors.*` — right shape, unknown name | any name from [the palette](#colours), plus `dim` | *(not a fallback — see below)* |

Absent, or an explicit `null`, at any level, means "not configured" and is
silent — that's exactly what the defaults above are for. A value that *is*
configured but the resolver does not keep falls back to the named default,
and it isn't silent about it: `cprof doctor` names the key and the value
used instead, and exits non-zero, because the statusline itself cannot say
so:

```console
$ cprof doctor
statusline.bar.width: must be a whole number from 1 to 40; using 10
statusline.thresholds: warn must be a whole number below critical, both from 1 to 100; using 70 and 90
```

(one line per rejected setting — a config with only one problem prints only one line)

A key cprof doesn't recognise is reported too, at whichever level inside the
block it was written — `statusline`, `bar`, `thresholds` or `colors` — because
the resolver ignores it in silence and a misspelling is the likeliest reason
it is there:

```console
statusline.bar: unknown key "wdith" (known: filled empty width)
```

`colors.badge` is the one key accepted and ignored without a word: the badge
takes its colour from `cprof color`, so a profile's colour lives in one place.
A key outside the `statusline` block is not checked — that is a question about
the whole config schema, not about this block.

Two settings don't follow that simple rule, and are worth reading closely if
something you configured doesn't look right:

- **The thresholds resolve as a pair, not two independent fields.** Setting
  `warn` without `critical` (or the reverse), or a pair out of order, reverts
  *both* to `70` and `90` — the in-range one included — and `cprof doctor`
  reports it as `statusline.thresholds: warn must be a whole number below
  critical, both from 1 to 100; using 70 and 90`.
- **A colour name that's the right shape but not in the palette is not
  defaulted at all.** `chartreuse` (1-19 characters, a string) is *kept* as
  the resolved colour; there is no such colour to paint with, so that
  segment's text renders without colour instead of falling back to the
  default. `cprof doctor` tells the three colour failures apart with three
  different messages:

  ```console
  statusline.colors.model: not a usable colour name; using cyan
  statusline.colors.model: must not contain an invisible character such as a tab; using cyan
  statusline.colors.model: unknown colour "chartreuse"; rendering it plain
  ```

  The first is `123` or `""` for `colors.model` — the wrong-shape row above.
  The second is a value the length rule alone would have kept, such as
  `"red\t"`: "not a usable colour name" would leave someone who typed a
  trailing tab none the wiser, so it says what is actually wrong. The third
  is `"chartreuse"` — well-formed, just not a colour `cprof color` knows.

  A name a report quotes is quoted for a reason: it is escaped, so that a
  configuration file cannot write lines of `cprof doctor` output of its own.

Narrowing the layout to the account, the directory, and a six-cell usage bar
drawn with different glyphs:

```json
{
  "statusline": {
    "lines": [["badge", "dir"], ["usage"]],
    "bar": {"filled": "█", "empty": "·", "width": 6}
  }
}
```

```console
⚑ work │ cprof
Usage ██···· 30% (resets in 2h 19m)
```

| Segment | Shows | Source |
| --- | --- | --- |
| `badge` | `⚑ work` in the profile's colour | the account this session runs as |
| `model` | `[Opus 5 (1M context)]` | the payload |
| `dir` | the last path segment, `~` for home | the payload |
| `git` | `git:(main*)`, the star meaning uncommitted changes | two git calls |
| `context` | `Context ▓▓▓▓░░░░░░ 37%` | the payload |
| `usage` | `Usage ▓▓▓░░░░░░░ 30% (resets in 2h 19m)` | the payload, else the profile's cached usage |

## Colours

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

This is a different colour system from `statusline.colors` above: the badge's
colour identifies the *profile*, everywhere cprof shows one, while
`statusline.colors` only paints the model, directory, git, branch and label
text beside it.

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
it does for every other command — except in the statusline, which decides on
`NO_COLOR` alone: its stdout is always a pipe, so terminal detection would
turn colour off in the one place it is always wanted.

`cprof color --text off` narrows the colour to the flag alone.
That toggle is statusline-only: `cprof list` and `cprof which` colour the
profile name unconditionally, regardless of `--text`.

Both settings live in `~/.cprof.json`, alongside profiles and rules, though you
will normally reach them through the commands above rather than edit the file:
a `color` field on a profile (`auto`, a base colour, or a `bright-` variant) and
a top-level `colorText` boolean, defaulting to `true` when absent.

Every entry point names the account before anything else. Every profile is
named, native included — a switching tool whose indicator is invisible in the
common case teaches you to ignore it. The statusline is omitted entirely only
when there is no profile to name: no config, or a config with no native
profile and no `CLAUDE_CONFIG_DIR` set.

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
seg=$({ ls -1 "$HOME"/.claude/plugins/cache/*/cprof/*/statusline/segment.sh ; } 2>/dev/null | sort -V | tail -1)
[ -r "$seg" ] && bash "$seg" --full
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

Without `--full`, `statusline/segment.sh` behaves exactly as it always has —
one line, the badge plus, with `--stdin`, the context and usage bars — and
touches stdin only when told to. `--full` hands the whole render above to
`cprof statusline`, reading stdin itself whenever it isn't a terminal.

<details>
<summary><strong>Already running a statusline?</strong> Compose them.</summary>

Point `settings.json` at a wrapper that prints cprof's lines first and hands
the payload on. `--full` reads stdin whenever one is there, the same way
`--stdin` always has, so composing means capturing the payload once and
piping a copy to each consumer:

```bash
#!/usr/bin/env bash
payload="$(cat)"
seg=$({ ls -1 "$HOME"/.claude/plugins/cache/*/cprof/*/statusline/segment.sh ; } 2>/dev/null | sort -V | tail -1)
[ -r "$seg" ] && printf '%s' "$payload" | bash "$seg" --full
printf '%s' "$payload" | your-existing-statusline
```

</details>

Neither entry point fails a statusline: a missing `jq`, an unreadable config,
an absent `git`, or a missing CLI prints nothing, or as much of the line as
it can, and exits 0.
