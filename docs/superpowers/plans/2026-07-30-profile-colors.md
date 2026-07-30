# Per-Profile Colours Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each profile a colour so the statusline badge and `cprof list` identify the active account at a glance.

**Architecture:** A new `scripts/lib/color.sh` owns the palette, per-profile resolution, and emission. Commands decide once — before any pipeline — whether colour is on, and export that decision as `CP_COLOR_ON`. `cp_table` learns to ignore escape sequences when measuring column width. The statusline segment forces colour on, because Claude Code captures it on a pipe.

**Tech Stack:** bash 3.2 (macOS system shell), `jq`, `cksum`, `stty`, awk (macOS system awk 20200816).

## Global Constraints

- Target bash 3.2. **No fractional `read -t`** (bash 4+), no `declare -A`, no `${var^^}`.
- `jq` is the only external dependency. `cksum`, `stty`, `awk`, `sed` are POSIX and already assumed.
- awk regex for ESC must be `\033`. `\x1b` is a gawk extension; the target is macOS system awk.
- Colour values are named ANSI only: `red green yellow blue magenta cyan` and their `bright-` variants.
- The auto palette is the six base colours only. Black and white are excluded — each vanishes against one terminal theme or the other.
- `NO_COLOR` set to **any value, including empty**, disables colour. This is the published NO_COLOR contract.
- Every command in this repo degrades rather than fails: an unrecognised colour yields no colour, never literal escape text.
- Tests use `tests/lib.sh` (`cp_t_setup`, `assert_eq`, `assert_ok`, `assert_fail`, `cp_t_summary`). `tests/run.sh` globs `test_*.sh`, so a new file is picked up automatically.
- Run `shellcheck -x -P scripts -P tests scripts/cprof scripts/lib/*.sh hooks/*.sh statusline/*.sh tests/*.sh` before every commit.

---

### Task 1: Colour vocabulary and emission

**Files:**
- Create: `scripts/lib/color.sh`
- Modify: `scripts/cprof:20` (add the source line after `output.sh`)
- Test: `tests/test_color.sh`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `CP_COLOR_PALETTE` — space-separated string, the six auto colours
  - `cp_color_code <name>` → SGR parameter on stdout (`31`), empty for unrecognised
  - `cp_color_enabled` → exit 0 when colour should be emitted, 1 otherwise
  - `cp_colorize <colour> <text>` → text wrapped in SGR when `CP_COLOR_ON=1` and the colour is known; otherwise the text unchanged

- [ ] **Step 1: Write the failing test**

Create `tests/test_color.sh`:

```bash
#!/usr/bin/env bash
set -u
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
# shellcheck source=/dev/null
. "$(dirname "$0")/../scripts/lib/config.sh"
# shellcheck source=/dev/null
. "$(dirname "$0")/../scripts/lib/color.sh"

# --- names map to SGR parameters --------------------------------------------
assert_eq '31' "$(cp_color_code red)"            'red is 31'
assert_eq '36' "$(cp_color_code cyan)"           'cyan is 36'
assert_eq '91' "$(cp_color_code bright-red)"     'bright-red is 91'
assert_eq ''   "$(cp_color_code chartreuse)"     'an unknown name has no code'
assert_eq ''   "$(cp_color_code '')"             'the empty name has no code'

# --- enabling ----------------------------------------------------------------
# NO_COLOR wins over everything, including an explicit always.
NO_COLOR= CPROF_COLOR=always cp_color_enabled
assert_eq '1' "$?" 'empty NO_COLOR still disables'
NO_COLOR=1 CPROF_COLOR=always cp_color_enabled
assert_eq '1' "$?" 'NO_COLOR beats CPROF_COLOR=always'
CPROF_COLOR=always cp_color_enabled
assert_eq '0' "$?" 'CPROF_COLOR=always enables'
CPROF_COLOR=never cp_color_enabled
assert_eq '1' "$?" 'CPROF_COLOR=never disables'
# The suite runs with stdout on a pipe, so auto resolves to off here.
CPROF_COLOR=auto cp_color_enabled
assert_eq '1' "$?" 'auto is off when stdout is not a terminal'

# --- wrapping ----------------------------------------------------------------
assert_eq 'work' "$(CP_COLOR_ON=0 cp_colorize red work)"  'no wrap when colour is off'
assert_eq 'work' "$(CP_COLOR_ON=1 cp_colorize '' work)"   'no wrap without a colour'
assert_eq 'work' "$(CP_COLOR_ON=1 cp_colorize bogus work)" 'no wrap for an unknown colour'
assert_eq "$(printf '\033[31mwork\033[0m')" \
          "$(CP_COLOR_ON=1 cp_colorize red work)"         'wraps when on'

cp_t_summary
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_color.sh`
Expected: FAIL — `color.sh: No such file or directory`, then every assertion fails.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/lib/color.sh`:

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# Colour for profile names: the palette, and when to emit it.

# The auto palette. Black and white are excluded deliberately: each disappears
# against one terminal theme or the other, and an indicator you cannot see is
# worse than no indicator.
# shellcheck disable=SC2034
CP_COLOR_PALETTE='red green yellow blue magenta cyan'

# cp_color_code <name> -> SGR parameter, or nothing when the name is unknown.
# Named ANSI only: these respect the terminal's own theme, work everywhere, and
# read plainly in the config file.
cp_color_code() {
  case "${1:-}" in
    red)            printf '31\n' ;;
    green)          printf '32\n' ;;
    yellow)         printf '33\n' ;;
    blue)           printf '34\n' ;;
    magenta)        printf '35\n' ;;
    cyan)           printf '36\n' ;;
    bright-red)     printf '91\n' ;;
    bright-green)   printf '92\n' ;;
    bright-yellow)  printf '93\n' ;;
    bright-blue)    printf '94\n' ;;
    bright-magenta) printf '95\n' ;;
    bright-cyan)    printf '96\n' ;;
    *)              return 0 ;;
  esac
}

# Whether colour should be emitted at all. NO_COLOR set to any value, empty
# included, disables it — that is the published contract, not an oversight.
cp_color_enabled() {
  [ -z "${NO_COLOR+set}" ] || return 1
  case "${CPROF_COLOR:-auto}" in
    never)  return 1 ;;
    always) return 0 ;;
  esac
  [ -t 1 ]
}

# cp_colorize <colour> <text>
#
# Reads CP_COLOR_ON rather than calling cp_color_enabled itself. Commands pipe
# their rows into cp_table, and inside a pipeline stdout is never a terminal, so
# the decision has to be made once by the caller and carried down.
cp_colorize() {
  local code
  code="$(cp_color_code "${1:-}")"
  if [ "${CP_COLOR_ON:-0}" != '1' ] || [ -z "$code" ]; then
    printf '%s\n' "${2:-}"
    return 0
  fi
  printf '\033[%sm%s\033[0m\n' "$code" "${2:-}"
}
```

Add to `scripts/cprof`, immediately after the `output.sh` source line:

```bash
# shellcheck source=lib/color.sh
. "$CP_LIB_DIR/color.sh"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test_color.sh` — expect `14 passed, 0 failed`
Run: `bash tests/run.sh` — expect `ALL TESTS PASSED`
Run: `shellcheck -x -P scripts -P tests scripts/cprof scripts/lib/*.sh hooks/*.sh statusline/*.sh tests/*.sh` — expect no output

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/color.sh scripts/cprof tests/test_color.sh
git commit -m "feat(color): palette, enabling rules, and SGR wrapping"
```

---

### Task 2: Resolve a profile's colour

**Files:**
- Modify: `scripts/lib/color.sh` (append)
- Test: `tests/test_color.sh` (append)

**Interfaces:**
- Consumes: `CP_COLOR_PALETTE`, `cp_color_code` from Task 1.
- Produces:
  - `cp_color_auto <name>` → a palette colour, chosen by hashing the name
  - `cp_color_for <cfg> <name>` → the colour to use: an explicit `color` field when it names something recognised, otherwise the hashed one, and nothing when an explicit value is unrecognised

- [ ] **Step 1: Write the failing test**

Append to `tests/test_color.sh`, before `cp_t_summary`:

```bash
# --- auto assignment ---------------------------------------------------------
first="$(cp_color_auto work)"
assert_eq "$first" "$(cp_color_auto work)"        'auto is stable across calls'
case " $CP_COLOR_PALETTE " in
  *" $first "*) assert_eq ok ok 'auto returns a palette colour' ;;
  *) assert_eq 'a palette colour' "$first" 'auto returns a palette colour' ;;
esac
# Different names should generally differ; this pair is checked explicitly so a
# hash change that collapses everything to one colour fails loudly.
assert_eq 'false' \
  "$([ "$(cp_color_auto work)" = "$(cp_color_auto personal)" ] && echo true || echo false)" \
  'work and personal hash to different colours'

# --- explicit overrides ------------------------------------------------------
cfg='{"profiles":[{"name":"work","color":"red"},{"name":"personal"},
      {"name":"broken","color":"chartreuse"},{"name":"reset","color":"auto"}]}'
assert_eq 'red' "$(cp_color_for "$cfg" work)"     'an explicit colour wins'
assert_eq "$(cp_color_auto personal)" "$(cp_color_for "$cfg" personal)" \
  'no colour field falls back to auto'
assert_eq "$(cp_color_auto reset)" "$(cp_color_for "$cfg" reset)" \
  'the literal auto falls back to auto'
assert_eq '' "$(cp_color_for "$cfg" broken)" \
  'an unrecognised explicit colour yields no colour'
assert_eq "$(cp_color_auto ghost)" "$(cp_color_for "$cfg" ghost)" \
  'an unknown profile still gets a colour'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_color.sh`
Expected: FAIL — `cp_color_auto: command not found`, assertions after it fail.

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/lib/color.sh`:

```bash
# cp_color_auto <name> -> a palette colour derived from the name.
#
# cksum is POSIX and gives the same number on every machine, so a profile keeps
# its colour across runs, shells, and checkouts without storing anything.
cp_color_auto() {
  local sum idx
  sum="$(printf '%s' "${1:-}" | cksum | cut -d' ' -f1)"
  # shellcheck disable=SC2086
  set -- $CP_COLOR_PALETTE
  idx=$(( sum % $# ))
  while [ "$idx" -gt 0 ]; do
    shift
    idx=$(( idx - 1 ))
  done
  printf '%s\n' "$1"
}

# cp_color_for <cfg> <name> -> the colour for a profile.
#
# An explicit field wins. The literal "auto" means the same as no field at all,
# so `cprof color <name> auto` reads naturally even though it stores nothing.
# An explicit value nobody recognises yields no colour rather than a guess.
cp_color_for() {
  local explicit
  explicit="$(printf '%s' "${1:-}" | jq -r --arg n "${2:-}" \
    'first(.profiles[]? | select(.name == $n) | .color // empty) // empty' 2>/dev/null)"
  if [ -n "$explicit" ] && [ "$explicit" != 'auto' ]; then
    [ -n "$(cp_color_code "$explicit")" ] && printf '%s\n' "$explicit"
    return 0
  fi
  cp_color_auto "${2:-}"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test_color.sh` — expect `22 passed, 0 failed`
Run: `bash tests/run.sh` and the shellcheck line from Task 1.

If `work` and `personal` happen to hash to the same colour, do **not** loosen the assertion — reorder `CP_COLOR_PALETTE` until they differ and note it in the commit. Two profiles is the common case and they must be distinguishable.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/color.sh tests/test_color.sh
git commit -m "feat(color): hashed auto colours with per-profile override"
```

---

### Task 3: Make `cp_table` escape-aware

**Files:**
- Modify: `scripts/lib/output.sh:31-53` (the `cp_table` awk block)
- Test: `tests/test_tables.sh` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: `cp_table` unchanged in signature — reads tab-separated rows on stdin, writes aligned rows on stdout — but column widths now ignore SGR sequences.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_tables.sh`, before `cp_t_summary`:

```bash
# --- colour must not disturb alignment ---------------------------------------
# cp_table sizes columns with awk length(). Escapes are zero-width on screen but
# not in bytes, so measuring them pads every other row to a phantom width.
plain="$({ printf 'PROFILE\tPLAN\n'; printf 'work\tteam\n'; printf 'personal\tmax\n'; } | cp_table)"
coloured="$({ printf 'PROFILE\tPLAN\n'
              printf '\033[31mwork\033[0m\tteam\n'
              printf 'personal\tmax\n'; } | cp_table)"
# Strip the escapes back out; what remains must be byte-identical to the plain
# rendering, which is exactly the property "colour does not move anything".
stripped="$(printf '%s\n' "$coloured" | sed 's/'"$(printf '\033')"'\[[0-9;]*m//g')"
assert_eq "$plain" "$stripped" 'escapes do not change column widths'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_tables.sh`
Expected: FAIL. The actual value shows `PROFILE` padded to 15 characters instead of 9, and `PLAN` shifted right — the escape bytes counted as width.

- [ ] **Step 3: Write minimal implementation**

In `scripts/lib/output.sh`, replace the width-measuring line inside `cp_table`. The current body:

```awk
      for (i = 1; i <= NF; i++) {
        cell[NR, i] = $i
        if (length($i) > w[i]) w[i] = length($i)
      }
```

becomes:

```awk
      for (i = 1; i <= NF; i++) {
        cell[NR, i] = $i
        # Colour is zero-width on screen but not in bytes. Measure the text
        # without its escapes, print the cell with them. \033 rather than \x1b:
        # the hex form is a gawk extension and the target is macOS awk.
        bare = $i
        gsub(/\033\[[0-9;]*m/, "", bare)
        if (length(bare) > w[i]) w[i] = length(bare)
      }
```

And in the `END` block, the padding calculation must measure the same way:

```awk
          if (i < nf[r]) {
            bare = cell[r, i]
            gsub(/\033\[[0-9;]*m/, "", bare)
            pad = w[i] - length(bare) + 2
            while (pad-- > 0) line = line " "
          }
```

Update the function's comment to record the new responsibility:

```bash
# Aligns tab-separated rows into columns two spaces apart, sizing each column to
# its widest cell so a long profile name cannot push a row out of alignment. A
# ragged row is fine: missing cells produce no padding, and no line keeps
# trailing whitespace. Cells may carry SGR colour: widths are measured on the
# text without its escapes, so colour never moves a column.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test_tables.sh` — expect `19 passed, 0 failed`
Run: `bash tests/run.sh` and the shellcheck line.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/output.sh tests/test_tables.sh
git commit -m "fix(table): measure column width without SGR escapes"
```

---

### Task 4: Colour the profile name in `list`, `which`, `status`

**Files:**
- Modify: `scripts/lib/output.sh:102-119` (`cp_cmd_status`), `:128-161` (`cp_cmd_list`), `:163-186` (`cp_cmd_which`)
- Test: `tests/test_color.sh` (append)

**Interfaces:**
- Consumes: `cp_color_enabled`, `cp_color_for`, `cp_colorize` from Tasks 1–2; escape-aware `cp_table` from Task 3.
- Produces: no new functions. Each command sets `CP_COLOR_ON` locally before building rows.

Only the profile-name cell is coloured. Plans, accounts, paths and reasons stay plain: colour here means "which profile", and spending it elsewhere dilutes the signal.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_color.sh`, before `cp_t_summary`:

```bash
# --- colour reaches list and which, and only the name -------------------------
CLI="$(cd "$(dirname "$0")/.." && pwd -P)/scripts/cprof"
cat > "$CP_CLAUDE_BIN" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = auth ] && [ "${2:-}" = status ] &&
  { printf '{"loggedIn":true,"email":"a@b.c","subscriptionType":"max"}\n'; exit 0; }
exit 1
STUB
chmod +x "$CP_CLAUDE_BIN"
mkdir -p "$CP_T_TMP/w"
cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","dir":"$CP_T_TMP/w","color":"red"}],
 "rules":[],"repos":{}}
JSON

esc="$(printf '\033')"
out="$(CPROF_COLOR=always "$CLI" list 2>/dev/null)"
case "$out" in
  *"$esc[31mwork$esc[0m"*) assert_eq ok ok 'list colours the profile name' ;;
  *) assert_eq 'coloured work' "$out" 'list colours the profile name' ;;
esac
case "$out" in
  *"$esc[31mmax"*|*"$esc[31ma@b.c"*)
    assert_eq 'plain plan and account' "$out" 'only the name is coloured' ;;
  *) assert_eq ok ok 'only the name is coloured' ;;
esac

out="$(CPROF_COLOR=never "$CLI" list 2>/dev/null)"
case "$out" in
  *"$esc["*) assert_eq 'no escapes' "$out" 'CPROF_COLOR=never suppresses colour' ;;
  *) assert_eq ok ok 'CPROF_COLOR=never suppresses colour' ;;
esac

out="$(NO_COLOR=1 CPROF_COLOR=always "$CLI" list 2>/dev/null)"
case "$out" in
  *"$esc["*) assert_eq 'no escapes' "$out" 'NO_COLOR suppresses colour in list' ;;
  *) assert_eq ok ok 'NO_COLOR suppresses colour in list' ;;
esac

out="$(cd "$CP_T_TMP" && CPROF_COLOR=always "$CLI" which 2>/dev/null)"
case "$out" in
  *"$esc[31mwork$esc[0m"*) assert_eq ok ok 'which colours the profile name' ;;
  *) assert_eq 'coloured work' "$out" 'which colours the profile name' ;;
esac

# status is what the segment shells out to; on a pipe it must stay plain so the
# segment can wrap it itself without nesting escapes.
out="$(CLAUDE_CONFIG_DIR="$CP_T_TMP/w" "$CLI" status 2>/dev/null)"
assert_eq 'work' "$out" 'status is plain when piped'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_color.sh`
Expected: FAIL on `list colours the profile name` and `which colours the profile name` — output contains no escapes. The `never`, `NO_COLOR`, and `status` assertions already pass, and must keep passing.

- [ ] **Step 3: Write minimal implementation**

In `cp_cmd_list`, add `CP_COLOR_ON` to the `local` declaration and set it before the row-building block:

```bash
cp_cmd_list() {
  local cfg names name active default_name st email sub markers dir CP_COLOR_ON=0
  cfg="$(cp_config_read)" || return 1
  # Decide once, here: the rows below are piped into cp_table, and inside a
  # pipeline stdout is never a terminal.
  cp_color_enabled && CP_COLOR_ON=1
```

and change the row `printf` to colour the name:

```bash
      printf '%s\t%s\t%s\t%s\n' \
        "$(cp_colorize "$(cp_color_for "$cfg" "$name")" "$name")" \
        "$sub" "$email" "${markers# }"
```

In `cp_cmd_which`, the same pattern:

```bash
cp_cmd_which() {
  local cfg line name reason dir CP_COLOR_ON=0
  cfg="$(cp_config_read)" || return 1
  cp_color_enabled && CP_COLOR_ON=1
```

and both `printf` calls colour the first field:

```bash
  if cp_profile_is_native "$cfg" "$name"; then
    printf '%s\tnative (keychain)\t%s\n' \
      "$(cp_colorize "$(cp_color_for "$cfg" "$name")" "$name")" "$reason" | cp_table
  else
    dir="$(cp_profile_dir "$cfg" "$name")"
    printf '%s\t%s\t%s\n' \
      "$(cp_colorize "$(cp_color_for "$cfg" "$name")" "$name")" \
      "$(cp_path_display "$dir")" "$reason" | cp_table
  fi
```

In `cp_cmd_status`, colour the single printed name. Both exit paths need it:

```bash
cp_cmd_status() {
  local cfg dir name CP_COLOR_ON=0
  cfg="$(cp_config_read)" || return 1
  cp_color_enabled && CP_COLOR_ON=1
  if [ -z "${CLAUDE_CONFIG_DIR:-}" ]; then
    name="$(cp_native_name "$cfg" 'stock')"
    cp_colorize "$(cp_color_for "$cfg" "$name")" "$name"
    return 0
  fi
```

and at the end:

```bash
  name="${name:-unknown}"
  cp_colorize "$(cp_color_for "$cfg" "$name")" "$name"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test_color.sh` — expect `28 passed, 0 failed`
Run: `bash tests/run.sh` — `test_status.sh` and `test_tables.sh` must still pass unchanged, which proves the plain path is untouched.
Run the shellcheck line.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/output.sh tests/test_color.sh
git commit -m "feat(color): colour the profile name in list, which, and status"
```

---

### Task 5: The `color` command

**Files:**
- Modify: `scripts/lib/color.sh` (append `cp_cmd_color`), `scripts/cprof` (dispatch and usage)
- Test: `tests/test_color.sh` (append)

**Interfaces:**
- Consumes: `cp_color_code`, `cp_color_for` from Tasks 1–2; `cp_config_read`, `cp_config_write`, `cp_warn` from `config.sh`; `cp_profile_exists` from `profiles.sh`.
- Produces: `cp_cmd_color` handling:
  - `cp_cmd_color <name> <colour>` — set
  - `cp_cmd_color <name> auto` — remove the field
  - `cp_cmd_color --text on|off` — set the global `colorText`
  - `cp_cmd_color --render <name>` — print `<sgr>\t<on|off>` for the statusline segment
  - `cp_cmd_color <name>` — the picker, added in Task 7; until then it prints `color: picker not implemented` and returns 2

- [ ] **Step 1: Write the failing test**

Append to `tests/test_color.sh`, before `cp_t_summary`:

```bash
# --- the color command --------------------------------------------------------
assert_ok "$CLI" color work blue
assert_eq 'blue' "$(jq -r '.profiles[0].color' "$CPROF_CONFIG")" 'sets an explicit colour'

assert_ok "$CLI" color work auto
assert_eq 'null' "$(jq -r '.profiles[0].color // "null"' "$CPROF_CONFIG")" \
  'auto removes the field rather than storing a word'

assert_fail "$CLI" color work chartreuse
assert_eq 'null' "$(jq -r '.profiles[0].color // "null"' "$CPROF_CONFIG")" \
  'a rejected colour leaves the config untouched'
assert_fail "$CLI" color ghost red
assert_fail "$CLI" color

assert_ok "$CLI" color --text on
assert_eq 'true' "$(jq -r '.colorText' "$CPROF_CONFIG")" '--text on sets the global'
assert_ok "$CLI" color --text off
assert_eq 'false' "$(jq -r '.colorText' "$CPROF_CONFIG")" '--text off clears it'
assert_fail "$CLI" color --text maybe

# --render is what the statusline segment calls: one subprocess, two fields.
"$CLI" color work red >/dev/null
assert_eq "$(printf '31\toff')" "$("$CLI" color --render work)" \
  '--render prints the SGR parameter and the text flag'
"$CLI" color --text on >/dev/null
assert_eq "$(printf '31\ton')" "$("$CLI" color --render work)" \
  '--render reflects colorText'
"$CLI" color --text off >/dev/null
assert_eq "$(printf '\toff')" "$("$CLI" color --render ghost)" \
  '--render is empty-but-well-formed for an unknown profile with no colour'
```

Note: the last assertion holds because `ghost` is not in the config, so `cp_color_for` falls through to `cp_color_auto`, which always returns a palette colour. Replace the expectation with the hashed result if that is what the implementation yields — run `cp_color_auto ghost` and use its code. Do not weaken the assertion to a wildcard.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_color.sh`
Expected: FAIL — `cprof: unknown command color` and usage printed, exit 2.

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/lib/color.sh`:

```bash
# cp_cmd_color — set a profile's colour, toggle text colouring, or answer the
# statusline segment.
cp_cmd_color() {
  local cfg name colour

  case "${1:-}" in
    '')
      cp_warn 'color: missing profile name'
      return 2
      ;;
    --text)
      cfg="$(cp_config_read)" || return 1
      case "${2:-}" in
        on)  printf '%s' "$cfg" | jq '.colorText = true'  | cp_config_write ;;
        off) printf '%s' "$cfg" | jq '.colorText = false' | cp_config_write ;;
        *)   cp_warn 'color --text: expected on or off'; return 2 ;;
      esac
      return $?
      ;;
    --render)
      # One call, two tab-separated fields, so the statusline spawns one process
      # rather than three. Never fails: an unreadable config prints a blank
      # colour and the segment falls back to its dim style.
      cfg="$(cp_config_read 2>/dev/null)" || cfg=''
      name="${2:-}"
      printf '%s\t%s\n' \
        "$(cp_color_code "$(cp_color_for "$cfg" "$name")")" \
        "$(printf '%s' "$cfg" | jq -r 'if .colorText then "on" else "off" end' 2>/dev/null || printf 'off')"
      return 0
      ;;
  esac

  name="$1"
  colour="${2:-}"
  cfg="$(cp_config_read)" || return 1
  cp_profile_exists "$cfg" "$name" || { cp_warn "unknown profile $name"; return 1; }

  if [ -z "$colour" ]; then
    cp_color_pick "$cfg" "$name"
    return $?
  fi

  if [ "$colour" = 'auto' ]; then
    printf '%s' "$cfg" | jq --arg n "$name" \
      '.profiles |= map(if .name == $n then del(.color) else . end)' | cp_config_write
    return $?
  fi

  if [ -z "$(cp_color_code "$colour")" ]; then
    cp_warn "color: unknown colour $colour (try: $CP_COLOR_PALETTE, or a bright- variant)"
    return 2
  fi
  printf '%s' "$cfg" | jq --arg n "$name" --arg c "$colour" \
    '.profiles |= map(if .name == $n then .color = $c else . end)' | cp_config_write
}

# Replaced in full by the picker. Kept separate so Task 5 is committable on its
# own and the command surface can be tested before the terminal handling exists.
cp_color_pick() {
  cp_warn 'color: picker not implemented'
  return 2
}
```

In `scripts/cprof`, add to the dispatch `case`, after the `unshare` line:

```bash
  color)   cp_cmd_color "$@" ;;
```

and to `cp_usage`, after the `share`/`unshare` lines:

```
  cprof color <name> [<colour>]    pick or set a profile's colour
  cprof color <name> auto          back to the hashed colour
  cprof color --text on|off        colour the name as well as the flag
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test_color.sh` — expect `41 passed, 0 failed`
Run: `bash tests/run.sh` — `test_manifest.sh` still passes.
Run the shellcheck line.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/color.sh scripts/cprof tests/test_color.sh
git commit -m "feat(color): cprof color command for setting and querying"
```

---

### Task 6: Picker navigation arithmetic

**Files:**
- Modify: `scripts/lib/color.sh` (append)
- Test: `tests/test_color.sh` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: `cp_color_menu_step <index> <key> <count>` → the new 0-based index. `key` is one of `up`, `down`; anything else leaves the index unchanged. Wraps at both ends.

Extracted as a pure function specifically so the wrap-around behaviour is testable without a terminal — the key loop in Task 7 is the one part the suite cannot reach.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_color.sh`, before `cp_t_summary`:

```bash
# --- picker navigation, without a terminal ------------------------------------
assert_eq '1' "$(cp_color_menu_step 0 down 5)"  'down moves forward'
assert_eq '0' "$(cp_color_menu_step 1 up   5)"  'up moves back'
assert_eq '0' "$(cp_color_menu_step 4 down 5)"  'down wraps to the top'
assert_eq '4' "$(cp_color_menu_step 0 up   5)"  'up wraps to the bottom'
assert_eq '2' "$(cp_color_menu_step 2 x    5)"  'an unknown key does not move'
assert_eq '0' "$(cp_color_menu_step 0 down 1)"  'a single entry stays put'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_color.sh`
Expected: FAIL — `cp_color_menu_step: command not found`, six failures.

- [ ] **Step 3: Write minimal implementation**

Append to `scripts/lib/color.sh`:

```bash
# cp_color_menu_step <index> <key> <count> -> the new 0-based index.
#
# Pure arithmetic, deliberately separate from the key loop: the loop needs a real
# terminal and cannot be covered by the suite, so everything that can be tested
# without one lives here.
cp_color_menu_step() {
  local i="${1:-0}" key="${2:-}" n="${3:-1}"
  [ "$n" -gt 0 ] || n=1
  case "$key" in
    up)   i=$(( (i - 1 + n) % n )) ;;
    down) i=$(( (i + 1) % n )) ;;
  esac
  printf '%s\n' "$i"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test_color.sh` — expect `47 passed, 0 failed`
Run: `bash tests/run.sh` and the shellcheck line.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/color.sh tests/test_color.sh
git commit -m "feat(color): picker navigation arithmetic"
```

---

### Task 7: The interactive picker

**Files:**
- Modify: `scripts/lib/color.sh` (replace the `cp_color_pick` stub from Task 5)
- Test: `tests/test_color.sh` (append)

**Interfaces:**
- Consumes: `cp_color_menu_step`, `cp_color_code`, `cp_color_for`, `CP_COLOR_PALETTE`, `cp_config_write`.
- Produces: `cp_color_pick <cfg> <name>` — draws the menu, writes the chosen colour, returns 0. Returns 2 without a terminal. Returns 0 without writing when cancelled.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_color.sh`, before `cp_t_summary`:

```bash
# --- the picker refuses to run blind ------------------------------------------
# The suite has no terminal, which is exactly the condition being asserted: the
# picker must say why rather than hang waiting for a keypress that cannot come.
out="$("$CLI" color work 2>&1 </dev/null)"
rc=$?
assert_eq '2' "$rc" 'the picker exits 2 without a terminal'
case "$out" in
  *'no terminal'*) assert_eq ok ok 'it says a terminal is missing' ;;
  *) assert_eq 'no terminal ...' "$out" 'it says a terminal is missing' ;;
esac
case "$out" in
  *'cprof color work red'*) assert_eq ok ok 'it names the non-interactive form' ;;
  *) assert_eq 'suggests cprof color work red' "$out" 'it names the non-interactive form' ;;
esac
assert_eq 'red' "$(jq -r '.profiles[0].color' "$CPROF_CONFIG")" \
  'a refused picker leaves the config untouched'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_color.sh`
Expected: FAIL — the stub prints `color: picker not implemented`, so the two message assertions fail. The exit code assertion passes already; it must keep passing.

- [ ] **Step 3: Write minimal implementation**

Replace the `cp_color_pick` stub in `scripts/lib/color.sh`:

```bash
# cp_color_pick <cfg> <name> — choose a colour interactively.
#
# Requires a terminal on both stdin and stdout. There is no silent fallback: a
# picker that quietly does nothing is worse than one that says why.
cp_color_pick() {
  local cfg="$1" name="$2" saved entries count idx=0 key chosen

  if [ ! -t 0 ] || [ ! -t 1 ]; then
    cp_warn "color: no terminal for the picker; pass a colour, e.g. cprof color $name red"
    return 2
  fi

  entries="auto $CP_COLOR_PALETTE"
  for c in $CP_COLOR_PALETTE; do entries="$entries bright-$c"; done
  # shellcheck disable=SC2086
  set -- $entries
  count=$#

  saved="$(stty -g)" || { cp_warn 'color: cannot read terminal state'; return 1; }
  # One trap for every way out: normal return, Ctrl-C, and being killed. Leaving
  # a terminal in raw mode with the cursor hidden is a worse bug than anything
  # this command could get wrong.
  trap 'stty "$saved" 2>/dev/null; printf "\033[?25h"; trap - EXIT INT TERM' EXIT INT TERM
  stty -echo -icanon min 1 time 0
  printf '\033[?25l'

  while :; do
    cp_color_menu_draw "$name" "$idx" $entries
    key="$(cp_color_read_key)"
    case "$key" in
      up|down) idx="$(cp_color_menu_step "$idx" "$key" "$count")" ;;
      select)  break ;;
      cancel)  cp_color_menu_erase "$count"; stty "$saved"; printf '\033[?25h'
               trap - EXIT INT TERM; return 0 ;;
    esac
    cp_color_menu_erase "$count"
  done

  cp_color_menu_erase "$count"
  stty "$saved"
  printf '\033[?25h'
  trap - EXIT INT TERM

  # shellcheck disable=SC2086
  set -- $entries
  while [ "$idx" -gt 0 ]; do shift; idx=$(( idx - 1 )); done
  chosen="$1"

  if [ "$chosen" = 'auto' ]; then
    printf '%s' "$cfg" | jq --arg n "$name" \
      '.profiles |= map(if .name == $n then del(.color) else . end)' | cp_config_write || return 1
    printf '%s -> auto\n' "$name"
    return 0
  fi
  printf '%s' "$cfg" | jq --arg n "$name" --arg c "$chosen" \
    '.profiles |= map(if .name == $n then .color = $c else . end)' | cp_config_write || return 1
  printf '%s -> %s\n' "$name" "$chosen"
}

# Draws one row per entry, each showing the badge as it will actually look, so
# the choice is made on the result rather than on the name of a colour.
cp_color_menu_draw() {
  local name="$1" idx="$2" i=0 marker code label
  shift 2
  printf 'Colour for %s    up/down move, enter select, q cancel\n' "$name"
  for label in "$@"; do
    if [ "$i" = "$idx" ]; then marker='>'; else marker=' '; fi
    if [ "$label" = 'auto' ]; then
      code="$(cp_color_code "$(cp_color_auto "$name")")"
      printf '  %s \033[%sm# %s\033[0m   auto\n' "$marker" "${code:-0}" "$name"
    else
      code="$(cp_color_code "$label")"
      printf '  %s \033[%sm# %s\033[0m   %s\n' "$marker" "${code:-0}" "$name" "$label"
    fi
    i=$(( i + 1 ))
  done
}

# Moves back over the menu so the next draw overwrites it: header plus one line
# per entry.
cp_color_menu_erase() {
  local n=$(( $1 + 1 ))
  while [ "$n" -gt 0 ]; do
    printf '\033[1A\033[2K'
    n=$(( n - 1 ))
  done
}

# Reads one keypress and names it.
#
# bash 3.2 has no fractional read -t — that arrived in bash 4, and the target is
# the macOS system shell. So the escape-sequence continuation is bounded at the
# terminal layer with `stty min 0 time 1` (a tenth of a second) instead. Without
# it, a bare ESC keypress blocks until the user presses something else.
cp_color_read_key() {
  local c rest
  IFS= read -r -n 1 c || { printf 'cancel\n'; return 0; }
  case "$c" in
    '') printf 'select\n'; return 0 ;;
    q|Q) printf 'cancel\n'; return 0 ;;
    k) printf 'up\n'; return 0 ;;
    j) printf 'down\n'; return 0 ;;
  esac
  if [ "$c" = "$(printf '\033')" ]; then
    stty min 0 time 1
    IFS= read -r -n 2 rest
    stty min 1 time 0
    case "$rest" in
      '[A') printf 'up\n'; return 0 ;;
      '[B') printf 'down\n'; return 0 ;;
      '')   printf 'cancel\n'; return 0 ;;
    esac
  fi
  printf 'none\n'
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test_color.sh` — expect `51 passed, 0 failed`
Run: `bash tests/run.sh` and the shellcheck line.

Then verify the interactive path **by hand**, because the suite cannot:

```bash
./scripts/cprof color work
```

Confirm each of these, and record the results in the pull request:
1. Arrow keys move the marker; it wraps at both ends
2. `k` and `j` also move
3. Enter writes the colour and prints `work -> <colour>`
4. `q` exits without changing the config
5. **Ctrl-C mid-menu restores the terminal** — afterwards `echo test` still echoes and the cursor is visible
6. `./scripts/cprof color work < /dev/null` refuses with the guidance message

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/color.sh tests/test_color.sh
git commit -m "feat(color): interactive colour picker"
```

---

### Task 8: Colour the statusline badge

**Files:**
- Modify: `statusline/segment.sh:12-22`
- Test: `tests/test_color.sh` (append)

**Interfaces:**
- Consumes: `cprof status` and `cprof color --render <name>` from Task 5.
- Produces: no new functions.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_color.sh`, before `cp_t_summary`:

```bash
# --- the statusline badge -----------------------------------------------------
SEG="$(cd "$(dirname "$0")/.." && pwd -P)/statusline/segment.sh"
"$CLI" color work red >/dev/null
"$CLI" color --text off >/dev/null

# The segment always runs on a pipe, so it must force colour on rather than
# auto-detect — otherwise the badge would be permanently plain.
out="$(CLAUDE_CONFIG_DIR="$CP_T_TMP/w" bash "$SEG" </dev/null)"
case "$out" in
  *"$esc[31m"*) assert_eq ok ok 'the badge is coloured despite running on a pipe' ;;
  *) assert_eq 'coloured badge' "$out" 'the badge is coloured despite running on a pipe' ;;
esac
case "$out" in
  *work*) assert_eq ok ok 'the badge still names the profile' ;;
  *) assert_eq 'names work' "$out" 'the badge still names the profile' ;;
esac

out="$(NO_COLOR=1 CLAUDE_CONFIG_DIR="$CP_T_TMP/w" bash "$SEG" </dev/null)"
case "$out" in
  *"$esc[31m"*) assert_eq 'no colour' "$out" 'NO_COLOR strips the badge colour' ;;
  *) assert_eq ok ok 'NO_COLOR strips the badge colour' ;;
esac
case "$out" in
  *work*) assert_eq ok ok 'NO_COLOR keeps the badge itself' ;;
  *) assert_eq 'still names work' "$out" 'NO_COLOR keeps the badge itself' ;;
esac
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_color.sh`
Expected: FAIL on `the badge is coloured despite running on a pipe` — the segment still prints the fixed dim line.

- [ ] **Step 3: Write minimal implementation**

Replace the tail of `statusline/segment.sh`, from `name=` onward:

```bash
name="$("$cli" status 2>/dev/null)" || exit 0
case "$name" in
  ''|stock) exit 0 ;;
esac

# One call, two fields: the SGR parameter for this profile and whether the name
# text is coloured too. Claude Code captures the statusline on a pipe, so the
# CLI's own auto-detection would disable colour permanently — hence CPROF_COLOR.
render="$(CPROF_COLOR=always "$cli" color --render "$name" 2>/dev/null)"
code="${render%%	*}"
text="${render##*	}"

# No colour resolved, or NO_COLOR set: the original dim badge, unchanged.
if [ -z "$code" ] || [ -n "${NO_COLOR+set}" ]; then
  printf '\033[2m⚑ %s\033[0m\n' "$name"
  exit 0
fi

if [ "$text" = 'on' ]; then
  printf '\033[%sm⚑ %s\033[0m\n' "$code" "$name"
else
  printf '\033[%sm⚑\033[0m \033[2m%s\033[0m\n' "$code" "$name"
fi
exit 0
```

Note the two literal tab characters in the `${render%%	*}` and `${render##*	}` expansions. They must be real tabs, not spaces.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/test_color.sh` — expect `55 passed, 0 failed`
Run: `bash tests/run.sh` — `test_status.sh` must still pass.
Run the shellcheck line.

Verify by eye that the badge still degrades to nothing on a broken config:

```bash
CPROF_CONFIG=/nonexistent bash statusline/segment.sh </dev/null; echo "exit=$?"
```

Expected: no output, `exit=0`.

- [ ] **Step 5: Commit**

```bash
git add statusline/segment.sh tests/test_color.sh
git commit -m "feat(color): colour the statusline badge"
```

---

### Task 9: Documentation and release

**Files:**
- Modify: `README.md` (Statusline section, Commands table), `CHANGELOG.md`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `scripts/cprof:4`
- Test: `tests/test_manifest.sh` (already asserts version agreement across all three places)

**Interfaces:**
- Consumes: everything above.
- Produces: release 0.6.0.

- [ ] **Step 1: Run the manifest test to see it fail**

Bump `.claude-plugin/plugin.json` `.version` to `0.6.0` only, then run:

Run: `bash tests/test_manifest.sh`
Expected: FAIL on `the CLI reports the manifest version`, `marketplace metadata version matches`, `marketplace plugin entry version matches`, and `CHANGELOG names this version first`. Those four failures are the checklist for this task.

- [ ] **Step 2: Bump the remaining three places**

```bash
jq '.metadata.version = "0.6.0" | .plugins[0].version = "0.6.0"' \
  .claude-plugin/marketplace.json > /tmp/m.$$ && mv /tmp/m.$$ .claude-plugin/marketplace.json
sed -i '' "s/CP_VERSION='0.5.0'/CP_VERSION='0.6.0'/" scripts/cprof
```

- [ ] **Step 3: Add the CHANGELOG section**

Insert after `## [Unreleased]`:

```markdown
## [0.6.0]

### Added

- Each profile has a colour, so the badge and `cprof list` say which account is
  in use at a glance rather than on a read. Colours are assigned by hashing the
  profile name, which needs no configuration and is stable across machines;
  `cprof color <name>` opens a picker, and `cprof color <name> <colour>` sets one
  directly. `cprof color --text on` colours the profile name as well as the flag.
- Values are named ANSI colours, so they follow the terminal's own theme rather
  than overriding it. `NO_COLOR` is honoured, and `CPROF_COLOR=never|always|auto`
  overrides the terminal detection.

### Fixed

- `cp_table` sized columns by counting bytes, so a cell containing colour padded
  every other row to a width that was not on screen. Widths are now measured
  with the escapes stripped.
```

- [ ] **Step 4: Document the commands**

In the README Commands table, after the `unshare` row:

```markdown
| `cprof color <name>` | Pick a profile's colour interactively |
| `cprof color <name> <colour>` | Set it directly; `auto` returns to the hashed colour |
| `cprof color --text on\|off` | Colour the profile name as well as the flag |
```

In the Statusline section, replace the opening console block and add a paragraph after it:

```markdown
```console
⚑ work
```

The flag carries the profile's colour. Colours are hashed from the profile name,
so two profiles differ without any configuration; `cprof color <name>` opens a
picker to choose one, and `cprof color --text on` colours the name too. Values
are named ANSI colours, so they follow your terminal's theme instead of fighting
it. `NO_COLOR` is honoured, and `CPROF_COLOR=never` turns colour off everywhere.
```

- [ ] **Step 5: Verify and commit**

Run: `bash tests/run.sh` — expect `ALL TESTS PASSED`
Run: `shellcheck -x -P scripts -P tests scripts/cprof scripts/lib/*.sh hooks/*.sh statusline/*.sh tests/*.sh`
Run: `claude plugin validate .`
Run: `bash tests/run.sh 2>&1 | sed -n 's/^test_.*: \([0-9]*\) passed.*/\1/p' | awk '{s+=$1} END {print s}'` and update the README assertions badge to that number.

```bash
git add -A
git commit -m "chore(release): 0.6.0, per-profile colours"
```

Merging to `main` triggers `tag.yml`, which tags `cprof--v0.6.0` and publishes.

---

## Self-Review

**Spec coverage.** Every section of the spec maps to a task: colour resolution and the palette → Tasks 1–2; when colour is emitted → Task 1, applied in Task 4; table alignment → Task 3; which cells are coloured → Task 4; command surface → Task 5; picker → Tasks 6–7; segment → Task 8; testing table → distributed across the tasks that add each unit; docs and version → Task 9.

**Type consistency.** `cp_color_for` returns a colour *name*; `cp_color_code` converts a name to an SGR parameter. `--render` emits the parameter, not the name, and `segment.sh` interpolates it directly — checked against Task 5's implementation and Task 8's consumer.

**Known deviation from the spec.** The spec described the segment reading colour and `colorText` itself. This plan adds `cprof color --render <name>` instead, so the statusline spawns one subprocess rather than three on every refresh. Same behaviour, fewer processes on a hot path.

**The one gap, stated plainly.** Task 7's key loop has no automated coverage — the suite is non-interactive and `stty` needs a real terminal. Task 7 Step 4 lists six manual checks, of which the Ctrl-C terminal restoration is the one that matters most: getting it wrong leaves the user's shell broken. Driving a pty through `script` would close this and belongs in a follow-up if wanted.
