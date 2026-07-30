# Per-profile colours

Give each profile a colour, so the statusline badge and `cprof list` say which
account is in use at a glance rather than on a read.

Status: approved, not implemented.
Target release: 0.6.0. New command and new config keys; nothing breaks.

## Problem

The badge is one dim line, identical for every profile:

```bash
printf '\033[2m⚑ %s\033[0m\n' "$name"   # statusline/segment.sh:21
```

Telling `⚑ work` from `⚑ personal` means reading the word. A switching tool
whose indicator has to be read is one you learn to skim past, which is the
failure mode the badge exists to prevent.

## Behaviour

Each profile resolves to a colour. The `⚑` is coloured; colouring the name text
as well is opt-in and global.

```
⚑ work        flag red,  name dim      default
⚑ work        flag red,  name red      colorText on
```

### Commands

```
cprof color <name>              open the picker
cprof color <name> <colour>     set directly
cprof color <name> auto         clear the override, back to hashed
cprof color --text on|off       global colorText toggle
cprof color --render <name>     SGR parameter and colorText, tab-separated
```

`--render` exists for the statusline segment: one subprocess per refresh rather
than three. It is documented because it is reachable from the shell, not because
anyone is expected to type it.

### Configuration

Two optional additions to `~/.cprof.json`:

```json
{
  "colorText": true,
  "profiles": [
    { "name": "work", "dir": "…", "color": "red" },
    { "name": "personal", "dir": "…" }
  ]
}
```

An absent `color` means auto. `colorText` defaults to false — flag only.

## Design

### Colour resolution

New `scripts/lib/color.sh`.

`cp_color_for <cfg> <name>` returns the colour for a profile. An explicit
`color` wins. Otherwise the name is hashed into the auto palette with `cksum`,
modulo the palette size: POSIX, deterministic across runs and machines, and no
new dependency.

The auto palette is the six base colours — red, green, yellow, blue, magenta,
cyan. Black and white are excluded because each disappears against one terminal
theme or the other. An explicit override may also name a `bright-` variant.

Values are named ANSI only. Named colours respect the user's terminal theme,
work in every terminal, and read plainly in the config file. A colour the code
does not recognise resolves to no colour rather than to an escape sequence
printed as literal text.

### When colour is emitted

`cp_color_enabled`, in precedence order:

1. `NO_COLOR` set to any value — disabled, per the specification
2. `CPROF_COLOR=never|always|auto`
3. `[ -t 1 ]`

`cp_colorize <colour> <text>` wraps the text, or returns it unchanged when
colour is disabled.

Two call sites need care, both established by reading the code rather than
assuming:

**Commands must test for a tty before the pipeline.** `cp_cmd_list` pipes into
`cp_table`, so `[ -t 1 ]` evaluated inside the pipeline is always false. Each
command calls `cp_color_enabled` once at the top and passes the answer down.

**The segment forces colour on.** It sets `CPROF_COLOR=always`, because Claude
Code captures the statusline on a pipe and auto-detection would therefore
disable colour permanently. The segment already emits `\033[2m` unconditionally,
so this matches existing behaviour.

The second rule also keeps `cprof status` safe. The segment shells out to it on
a pipe, so `status` stays plain and the segment cannot double-wrap escapes.

### Table alignment

`cp_table` sizes each column with awk's `length($i)`. Escape sequences inside a
cell count toward that width and break the alignment the table exists to
guarantee:

```
PROFILE        PLAN          header padded to the escape's width
\033[31mwork\033[0m  team
personal       max
```

`cp_table` therefore strips escapes when measuring and prints cells untouched:

```awk
t = $i; gsub(/\033\[[0-9;]*m/, "", t)
if (length(t) > w[i]) w[i] = length(t)
```

`\033` rather than `\x1b`: the hex form is a gawk extension, and the target is
the macOS system awk.

Applying colour where rows are built, rather than inside the table, means every
current and future caller gets it without further change.

Only the profile-name cell is coloured, in `cprof list`, `cprof which`, and
`cprof status`. Plans, accounts, paths and reasons stay plain: colour here means
"which profile", and spending it on anything else dilutes that. `status` is
included for consistency when run on a terminal; it stays plain when the segment
shells out to it, because that is a pipe.

### Picker

`cprof color <name>` with no colour argument. Each row is drawn as the badge
will actually appear, so the choice is made on the result rather than on a
colour name:

```
Colour for work    up/down move, enter select, q cancel

    ⚑ work   auto (magenta)
  > ⚑ work   red
    ⚑ work   green
```

The header and marker are ASCII. Arrow and return glyphs render inconsistently
across terminals and fonts, and a legend that renders as boxes is worse than a
plain one.

Rows are `auto`, the six base colours, and their `bright-` variants.

Terminal handling:

- **A tty on both stdin and stdout is required.** Without one the command
  refuses — `color: no terminal for the picker; pass a colour, e.g. cprof color
  work red` — and exits 2. There is no silent fallback: a picker that quietly
  does nothing is worse than one that says why.
- The original terminal state is saved with `stty -g` and restored by traps on
  `INT`, `TERM`, `QUIT`, `HUP` and `EXIT`, so Ctrl-C, Ctrl-\, a kill, a lost
  connection and any error path all restore it. Cursor hide and show ride the
  same traps. Each signal arm exits with the conventional 128+signal status;
  the `EXIT` arm must not exit, or it would overwrite the status the function is
  already returning with.
- The saved state lives in a global, not a local. Function locals are popped
  before an `EXIT` trap runs, so under `set -u` a local would be unbound by the
  time the handler read it — the handler would abort before restoring the
  cursor.
- **bash 3.2 has no fractional `read -t`**; it arrived in bash 4, and the target
  is the macOS system shell. The escape-sequence continuation bytes are read
  with `dd bs=1 count=2` under `stty min 0 time 1`, which bounds the wait at a
  tenth of a second. Without a bound, a bare ESC keypress blocks until the next
  key and then swallows it.

  An earlier draft set `stty min 0 time 1` and read with `read -r -n 2`. That
  does not work: bash's `read -n` sets its own VMIN/VTIME for the duration of
  the read, so the terminal reports `min=1 time=0` while it runs and the bound
  is ignored. Measured on bash 3.2.57 in a pty — the exact symptom the technique
  was meant to prevent. `dd` honours the terminal settings, which is why it is
  worth the extra process in the key loop.
- `k` and `j` are accepted alongside the arrows, so the picker stays usable if a
  terminal sends something unexpected.

Navigation arithmetic lives in `cp_color_menu_step <index> <key> <count>`, a
pure function, so the wrap-around behaviour is testable without a terminal.

## Testing

Every part except the key loop is a pure function.

| Unit | Assertions |
| --- | --- |
| `cp_color_for` | explicit beats auto; auto is stable across runs; an unrecognised name yields no colour |
| `cp_color_enabled` | `NO_COLOR` beats everything; `CPROF_COLOR` values; tty fallback |
| `cp_colorize` | wraps when enabled, passes through when not |
| `cp_table` | **alignment holds when cells contain escapes** — a regression test for the breakage above |
| `cp_color_menu_step` | movement and wrap-around at both ends |
| config writes | `color work red` sets; `color work auto` removes the field; `--text on\|off` flips the global |
| picker | refuses without a tty, and the message names the non-interactive form |
| segment | colours under `CPROF_COLOR=always`, plain under `NO_COLOR` |

### Known gap

The raw-tty key loop gets no automated coverage: the suite is non-interactive
and `stty` needs a real terminal. It will be verified by hand, and the pull
request will say so rather than imply otherwise. Covering it would mean driving
a pty through `script`, which macOS ships; that is a larger piece of work and
belongs in a follow-up if it is wanted.

## Rejected alternatives

**Colour applied after alignment**, leaving `cp_table` byte-pure. The post-pass
has to re-identify which text was the profile name, which breaks as soon as a
name appears elsewhere in the row — a profile named `max` against a plan named
`max`.

**Colouring only a leading glyph column**, so name cells never contain escapes
and the awk change is unnecessary. Simplest of the three, but it cannot colour
the name, which was the request.

**256-colour and hex values.** More range, but 256 ignores the terminal's theme
and hex prints as literal escape text where truecolor is unsupported. Named
colours cost nothing and degrade well.

## Note on this file's location

Release 0.2.0 removed `docs/` from the repository: an install clones the whole
repository, so anything here is copied into every user's plugin cache. This spec
re-introduces that, at the cost of one markdown file. Worth revisiting if the
directory grows.
