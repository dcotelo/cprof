# claudeprofile Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a Claude Code plugin that selects which Claude account a session uses, based on a default profile, per-repository pins, and directory rules.

**Architecture:** A bash CLI owns `~/.claudeprofile.json` and prints shell `export`/`unset` statements; a shell function shadowing `claude` evaluates them before launching, so `CLAUDE_CONFIG_DIR` points at a per-profile config directory holding its own `.credentials.json`. The plugin layer adds read-only slash commands and a `SessionStart` hook that warns when the live session no longer matches what the current directory resolves to.

**Tech Stack:** bash 3.2, `jq`, `git`, macOS `security`, Claude Code plugin manifest.

## Global Constraints

- Target **bash 3.2.57** (macOS system bash). No associative arrays, no `mapfile`, no `${var^^}`, no `&>>`. Scripts start `#!/usr/bin/env bash` and `set -u` (never `set -e` — resolution must degrade, not abort).
- `jq` is the only external data dependency. Every `jq` invocation must tolerate absent keys (`.rules[]?`).
- `claudeprofile env` **never exits non-zero** and always prints exactly one of `export CLAUDE_CONFIG_DIR=<quoted>` or `unset CLAUDE_CONFIG_DIR`. Never prints nothing.
- No profile may use `$HOME/.claude` as its directory. Setting `CLAUDE_CONFIG_DIR=$HOME/.claude` breaks authentication and relocates `.claude.json`. The existing setup is represented by `"native": true`, which exports nothing.
- At most one profile may be `native`.
- Keychain service name is exactly `Claude Code-credentials`; account is `${USER}`.
- Tests never touch the real config, the real keychain, or the real `claude` binary. All three are reached through overridable variables: `CLAUDEPROFILE_CONFIG`, `CLAUDEPROFILE_STATE_DIR`, `CP_CLAUDE_BIN`, `CP_SECURITY_BIN`.
- Every shell file must pass `shellcheck`.
- Version string lives in one place: `CP_VERSION` in `scripts/claudeprofile`. Start at `0.1.0`.

## File Structure

| Path | Responsibility |
| --- | --- |
| `scripts/claudeprofile` | Entrypoint: sources libs, dispatches subcommands, defines `CP_VERSION`, usage text |
| `scripts/lib/config.sh` | Config path resolution, read/validate/atomic-write, `~` expansion, profile lookup helpers, `cp_warn` |
| `scripts/lib/resolve.sh` | Path normalisation, prefix containment, repo root, the resolution ladder |
| `scripts/lib/profiles.sh` | Mutations: `add`, `default`, `pin`, `rule add/rm/list`, `remove` |
| `scripts/lib/auth.sh` | Per-profile `claude auth status`, keychain read/write, `login` with safety net, `doctor` |
| `scripts/lib/output.sh` | `env`, `which`, `list` formatting, shell quoting |
| `hooks/session-start.sh` | SessionStart mismatch warning |
| `hooks/hooks.json` | Hook registration |
| `commands/profile.md` | `/profile` slash command |
| `.claude-plugin/plugin.json` | Plugin manifest |
| `tests/lib.sh` | Assertions, sandbox setup/teardown, stub builders |
| `tests/run.sh` | Test runner over `tests/test_*.sh` |
| `tests/test_*.sh` | One file per library |
| `README.md` | Install, shell function, commands, mechanics |

Splitting `resolve.sh` from `config.sh` matters: resolution is the only logic dense enough to carry real bugs, and it must be testable with a config fixture and no filesystem side effects.

---

### Task 1: Test harness and config library

**Files:**
- Create: `tests/lib.sh`, `tests/run.sh`, `tests/test_config.sh`, `scripts/lib/config.sh`, `.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: `cp_warn <msg>`, `cp_have_jq`, `cp_config_default`, `cp_config_read` (stdout JSON, returns 1 on unusable config), `cp_config_write` (stdin JSON), `cp_expand <path>`, `cp_profile_exists <cfg> <name>`, `cp_profile_field <cfg> <name> <field>`, `cp_profile_is_native <cfg> <name>`, `cp_profile_dir <cfg> <name>`. Variables `CP_CONFIG_PATH`, `CP_STATE_DIR`, `CP_KEYCHAIN_SERVICE`. Test helpers `cp_t_setup`, `cp_t_teardown`, `assert_eq`, `assert_ok`, `assert_fail`, `cp_t_summary`, `cp_t_write_config`.

- [ ] **Step 1: Write the test harness**

Create `tests/lib.sh`:

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# Test harness. Sourced by tests/test_*.sh.

CP_T_PASS=0
CP_T_FAIL=0
CP_T_NAME="$(basename "${0}")"

cp_t_setup() {
  CP_T_TMP="$(mktemp -d "${TMPDIR:-/tmp}/cptest.XXXXXX")"
  CP_T_HOME="$CP_T_TMP/home"
  mkdir -p "$CP_T_HOME" "$CP_T_TMP/bin"
  export HOME="$CP_T_HOME"
  export CLAUDEPROFILE_CONFIG="$CP_T_TMP/config.json"
  export CLAUDEPROFILE_STATE_DIR="$CP_T_TMP/state"
  export CP_CLAUDE_BIN="$CP_T_TMP/bin/claude"
  export CP_SECURITY_BIN="$CP_T_TMP/bin/security"
  unset CLAUDE_PROFILE
  unset CLAUDE_CONFIG_DIR
}

cp_t_teardown() {
  case "$CP_T_TMP" in
    /*/cptest.*) rm -rf "$CP_T_TMP" ;;
    *) printf 'refusing to remove suspicious tmp: %s\n' "$CP_T_TMP" >&2 ;;
  esac
}

cp_t_write_config() {
  mkdir -p "$(dirname "$CLAUDEPROFILE_CONFIG")"
  cat > "$CLAUDEPROFILE_CONFIG"
}

assert_eq() {
  if [ "$1" = "$2" ]; then
    CP_T_PASS=$((CP_T_PASS + 1))
    printf '  ok   %s\n' "$3"
  else
    CP_T_FAIL=$((CP_T_FAIL + 1))
    printf '  FAIL %s\n    expected: [%s]\n    actual:   [%s]\n' "$3" "$1" "$2"
  fi
}

assert_ok() {
  if "$@" >/dev/null 2>&1; then
    CP_T_PASS=$((CP_T_PASS + 1))
    printf '  ok   %s\n' "$*"
  else
    CP_T_FAIL=$((CP_T_FAIL + 1))
    printf '  FAIL %s (expected success)\n' "$*"
  fi
}

assert_fail() {
  if "$@" >/dev/null 2>&1; then
    CP_T_FAIL=$((CP_T_FAIL + 1))
    printf '  FAIL %s (expected failure)\n' "$*"
  else
    CP_T_PASS=$((CP_T_PASS + 1))
    printf '  ok   %s (failed as expected)\n' "$*"
  fi
}

cp_t_summary() {
  printf '%s: %d passed, %d failed\n' "$CP_T_NAME" "$CP_T_PASS" "$CP_T_FAIL"
  [ "$CP_T_FAIL" -eq 0 ]
}
```

Create `tests/run.sh`:

```bash
#!/usr/bin/env bash
set -u
cd "$(dirname "$0")" || exit 1
status=0
for t in test_*.sh; do
  [ -f "$t" ] || continue
  printf '== %s\n' "$t"
  bash "$t" || status=1
done
if [ "$status" -eq 0 ]; then
  printf 'ALL TESTS PASSED\n'
else
  printf 'TESTS FAILED\n'
fi
exit "$status"
```

Create `.gitignore`:

```
*.tmp.*
.DS_Store
```

- [ ] **Step 2: Write the failing config tests**

Create `tests/test_config.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
. "$(dirname "$0")/../scripts/lib/config.sh"

# absent config yields the empty default
assert_eq '[]' "$(cp_config_read | jq -c '.profiles')" 'absent config: empty profiles'
assert_eq 'null' "$(cp_config_read | jq -c '.default')" 'absent config: null default'

# malformed config is rejected
printf 'not json' | cp_t_write_config
assert_fail cp_config_read 'malformed config returns non-zero'

# round trip
cp_t_write_config <<'JSON'
{"default":"personal","profiles":[{"name":"personal","dir":"~/.claude-profiles/personal"},{"name":"work","native":true}],"rules":[],"repos":{}}
JSON
cfg="$(cp_config_read)"
assert_eq 'personal' "$(printf '%s' "$cfg" | jq -r '.default')" 'round trip: default'

# profile helpers
assert_ok   cp_profile_exists "$cfg" personal 'known profile exists'
assert_fail cp_profile_exists "$cfg" nope     'unknown profile does not exist'
assert_ok   cp_profile_is_native "$cfg" work  'work is native'
assert_fail cp_profile_is_native "$cfg" personal 'personal is not native'
assert_eq "$HOME/.claude-profiles/personal" "$(cp_profile_dir "$cfg" personal)" 'dir is tilde-expanded'
assert_eq '' "$(cp_profile_dir "$cfg" work)" 'native profile has no dir'

# tilde expansion
assert_eq "$HOME/x"  "$(cp_expand '~/x')"  'expand ~/x'
assert_eq "$HOME"    "$(cp_expand '~')"    'expand ~'
assert_eq '/abs/x'   "$(cp_expand '/abs/x')" 'absolute path untouched'
assert_eq 'rel/x'    "$(cp_expand 'rel/x')"  'relative path untouched'

# atomic write refuses invalid JSON
assert_fail eval 'printf "nope" | cp_config_write' 'write rejects invalid JSON'
assert_eq 'personal' "$(cp_config_read | jq -r '.default')" 'config intact after rejected write'

cp_t_summary
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bash /Users/diego/dev/claudeprofile/tests/run.sh`
Expected: FAIL — `scripts/lib/config.sh` does not exist, source error.

- [ ] **Step 4: Implement the config library**

Create `scripts/lib/config.sh`:

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# Config file ownership: paths, read/validate/write, profile field lookups.

CP_CONFIG_PATH="${CLAUDEPROFILE_CONFIG:-$HOME/.claudeprofile.json}"
CP_STATE_DIR="${CLAUDEPROFILE_STATE_DIR:-$HOME/.claudeprofile}"
CP_KEYCHAIN_SERVICE="Claude Code-credentials"

cp_warn() {
  printf 'claudeprofile: %s\n' "$1" >&2
}

cp_have_jq() {
  command -v jq >/dev/null 2>&1
}

cp_config_default() {
  printf '%s\n' '{"default":null,"profiles":[],"rules":[],"repos":{}}'
}

# stdout: config JSON. Returns 1 when the config exists but is unusable.
cp_config_read() {
  if [ ! -f "$CP_CONFIG_PATH" ]; then
    cp_config_default
    return 0
  fi
  if ! cp_have_jq; then
    cp_warn "jq not found; ignoring $CP_CONFIG_PATH"
    return 1
  fi
  if ! jq -e . "$CP_CONFIG_PATH" >/dev/null 2>&1; then
    cp_warn "malformed config $CP_CONFIG_PATH; ignoring"
    return 1
  fi
  cat "$CP_CONFIG_PATH"
}

# stdin: config JSON. Writes atomically, refusing invalid JSON.
cp_config_write() {
  local tmp
  mkdir -p "$(dirname "$CP_CONFIG_PATH")" || return 1
  tmp="$CP_CONFIG_PATH.tmp.$$"
  if ! jq -S . > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    cp_warn 'refusing to write invalid JSON to config'
    return 1
  fi
  mv "$tmp" "$CP_CONFIG_PATH"
}

cp_expand() {
  case "$1" in
    '~')   printf '%s\n' "$HOME" ;;
    '~/'*) printf '%s\n' "$HOME/${1#\~/}" ;;
    *)     printf '%s\n' "$1" ;;
  esac
}

# cp_profile_exists <cfg> <name>
cp_profile_exists() {
  printf '%s' "$1" | jq -e --arg n "$2" '.profiles[]? | select(.name == $n)' >/dev/null 2>&1
}

# cp_profile_field <cfg> <name> <field>
cp_profile_field() {
  printf '%s' "$1" | jq -r --arg n "$2" --arg f "$3" \
    '(.profiles[]? | select(.name == $n) | .[$f]) // empty' 2>/dev/null
}

cp_profile_is_native() {
  [ "$(cp_profile_field "$1" "$2" native)" = 'true' ]
}

# Expanded directory, or empty for a native profile.
cp_profile_dir() {
  local d
  d="$(cp_profile_field "$1" "$2" dir)"
  [ -n "$d" ] || return 0
  cp_expand "$d"
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash /Users/diego/dev/claudeprofile/tests/run.sh`
Expected: PASS — `test_config.sh: N passed, 0 failed`, then `ALL TESTS PASSED`.

- [ ] **Step 6: Lint**

Run: `shellcheck /Users/diego/dev/claudeprofile/scripts/lib/config.sh /Users/diego/dev/claudeprofile/tests/*.sh`
Expected: no output.

- [ ] **Step 7: Commit**

```bash
cd /Users/diego/dev/claudeprofile
chmod +x tests/run.sh
git add .gitignore tests scripts/lib/config.sh
git commit -m "feat: config library and sandboxed test harness"
```

---

### Task 2: Path handling and the resolution ladder

**Files:**
- Create: `scripts/lib/resolve.sh`, `tests/test_resolve.sh`

**Interfaces:**
- Consumes: `cp_expand`, `cp_warn`, `cp_profile_exists` from `config.sh`.
- Produces: `cp_path_lexical <abs>`, `cp_path_normalize <path>`, `cp_path_under <parent> <child>`, `cp_repo_root`, `cp_resolve` (stdin config JSON; stdout `<name><TAB><reason>`; empty name plus reason `none` when nothing matched; always returns 0).

- [ ] **Step 1: Write the failing resolution tests**

Create `tests/test_resolve.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
. "$(dirname "$0")/../scripts/lib/config.sh"
. "$(dirname "$0")/../scripts/lib/resolve.sh"

# --- lexical normalisation -------------------------------------------------
assert_eq '/a/b'   "$(cp_path_lexical '/a/b/')"      'strips trailing slash'
assert_eq '/a/b'   "$(cp_path_lexical '/a//b')"      'collapses double slash'
assert_eq '/a/b'   "$(cp_path_lexical '/a/./b')"     'drops dot segment'
assert_eq '/a'     "$(cp_path_lexical '/a/b/..')"    'resolves parent segment'
assert_eq '/'      "$(cp_path_lexical '/')"          'root stays root'

# --- containment, including the boundary case ------------------------------
assert_ok   cp_path_under /dev/work /dev/work        'path contains itself'
assert_ok   cp_path_under /dev/work /dev/work/a/b    'path contains descendant'
assert_fail cp_path_under /dev/work /dev/workshop    'workshop is NOT under work'
assert_fail cp_path_under /dev/work /dev            'parent is not under child'
assert_ok   cp_path_under / /anything                'root contains everything'

# --- resolution ladder ----------------------------------------------------
mkdir -p "$CP_T_TMP/dev/crowder/api" "$CP_T_TMP/dev/crowder/api/deep" \
         "$CP_T_TMP/dev/personal" "$CP_T_TMP/dev/workshop" "$CP_T_TMP/elsewhere"

cfg="$(cat <<JSON
{"default":"personal",
 "profiles":[{"name":"personal","dir":"$CP_T_TMP/p"},
             {"name":"work","native":true},
             {"name":"client","dir":"$CP_T_TMP/c"}],
 "rules":[{"path":"$CP_T_TMP/dev/crowder","profile":"work"},
          {"path":"$CP_T_TMP/dev/crowder/api","profile":"client"}],
 "repos":{"$CP_T_TMP/elsewhere":"client"}}
JSON
)"

resolve_in() { ( cd "$1" && printf '%s' "$cfg" | cp_resolve ); }
name_in()    { resolve_in "$1" | cut -f1; }
reason_in()  { resolve_in "$1" | cut -f2; }

assert_eq 'personal' "$(name_in "$CP_T_TMP/dev/personal")"      'falls back to default'
assert_eq 'default'  "$(reason_in "$CP_T_TMP/dev/personal")"    'reason is default'
assert_eq 'work'     "$(name_in "$CP_T_TMP/dev/crowder")"       'directory rule matches'
assert_eq 'client'   "$(name_in "$CP_T_TMP/dev/crowder/api")"   'longest prefix wins'
assert_eq 'client'   "$(name_in "$CP_T_TMP/dev/crowder/api/deep")" 'longest prefix wins deeper'
assert_eq 'personal' "$(name_in "$CP_T_TMP/dev/workshop")"      'workshop does not match crowder-style prefix'
assert_eq 'client'   "$(name_in "$CP_T_TMP/elsewhere")"         'repo pin beats default'

# unknown names are skipped, never fatal
bad="$(printf '%s' "$cfg" | jq '.rules += [{"path":"'"$CP_T_TMP"'/dev/personal","profile":"ghost"}]')"
assert_eq 'personal' "$(cd "$CP_T_TMP/dev/personal" && printf '%s' "$bad" | cp_resolve | cut -f1)" \
  'rule naming unknown profile is skipped'

empty="$(cp_config_default)"
assert_eq ''     "$(cd "$CP_T_TMP" && printf '%s' "$empty" | cp_resolve | cut -f1)" 'empty config: no name'
assert_eq 'none' "$(cd "$CP_T_TMP" && printf '%s' "$empty" | cp_resolve | cut -f2)" 'empty config: reason none'

cp_t_summary
```

Every `cd` above happens inside a command substitution, so it affects only that
subshell — the assertion counters stay in the parent shell and `cp_t_summary` sees
them.

- [ ] **Step 2: Write the CLAUDE_PROFILE override test**

`CLAUDE_PROFILE` must be exported before `cp_resolve` runs, and the counters must
survive, so this case gets its own file rather than a subshell.

Create `tests/test_resolve_env.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
. "$(dirname "$0")/../scripts/lib/config.sh"
. "$(dirname "$0")/../scripts/lib/resolve.sh"

mkdir -p "$CP_T_TMP/elsewhere"
cfg="$(cat <<JSON
{"default":"personal",
 "profiles":[{"name":"personal","dir":"$CP_T_TMP/p"},{"name":"work","native":true}],
 "rules":[],
 "repos":{"$CP_T_TMP/elsewhere":"personal"}}
JSON
)"

export CLAUDE_PROFILE=work
out="$(cd "$CP_T_TMP/elsewhere" && printf '%s' "$cfg" | cp_resolve)"
assert_eq 'work'              "$(printf '%s' "$out" | cut -f1)" 'CLAUDE_PROFILE outranks a pin'
assert_eq 'env CLAUDE_PROFILE' "$(printf '%s' "$out" | cut -f2)" 'reason names the env var'

# an unknown CLAUDE_PROFILE is ignored, not fatal
export CLAUDE_PROFILE=ghost
out="$(cd "$CP_T_TMP/elsewhere" && printf '%s' "$cfg" | cp_resolve 2>/dev/null)"
assert_eq 'personal' "$(printf '%s' "$out" | cut -f1)" 'unknown CLAUDE_PROFILE falls through to the pin'
unset CLAUDE_PROFILE

cp_t_summary
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bash /Users/diego/dev/claudeprofile/tests/run.sh`
Expected: FAIL — `resolve.sh` missing.

- [ ] **Step 4: Implement path helpers and the ladder**

Create `scripts/lib/resolve.sh`:

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# Path handling and profile resolution. No side effects.

# Pure-lexical cleanup of an absolute path: collapses //, drops ., resolves ..
cp_path_lexical() {
  local in="$1" out='' seg
  local IFS='/'
  set -f
  for seg in $in; do
    case "$seg" in
      ''|'.') ;;
      '..')   out="${out%/*}" ;;
      *)      out="$out/$seg" ;;
    esac
  done
  set +f
  [ -n "$out" ] || out='/'
  printf '%s\n' "$out"
}

# Absolute, symlink-resolved when the directory exists; lexical otherwise.
cp_path_normalize() {
  local p
  p="$(cp_expand "$1")"
  case "$p" in
    /*) ;;
    *)  p="$PWD/$p" ;;
  esac
  if [ -d "$p" ]; then
    ( cd "$p" 2>/dev/null && pwd -P ) && return 0
  fi
  cp_path_lexical "$p"
}

# True when <child> is <parent> or lives beneath it. Boundary-aware.
cp_path_under() {
  local parent="$1" child="$2"
  [ "$parent" = '/' ] && return 0
  [ "$child" = "$parent" ] && return 0
  case "$child" in
    "$parent"/*) return 0 ;;
  esac
  return 1
}

cp_repo_root() {
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null)"
  if [ -n "$root" ]; then
    cp_path_normalize "$root"
  else
    pwd -P
  fi
}

# stdin: config JSON. stdout: "<name>\t<reason>". Always returns 0.
cp_resolve() {
  local cfg root name best_name='' best_path='' best_len=0 rp rn
  cfg="$(cat)"

  if [ -n "${CLAUDE_PROFILE:-}" ]; then
    if cp_profile_exists "$cfg" "$CLAUDE_PROFILE"; then
      printf '%s\tenv CLAUDE_PROFILE\n' "$CLAUDE_PROFILE"
      return 0
    fi
    cp_warn "CLAUDE_PROFILE=$CLAUDE_PROFILE is not a known profile; ignoring"
  fi

  root="$(cp_repo_root)"

  name="$(printf '%s' "$cfg" | jq -r --arg r "$root" '.repos[$r] // empty')"
  if [ -n "$name" ]; then
    if cp_profile_exists "$cfg" "$name"; then
      printf '%s\tpin %s\n' "$name" "$root"
      return 0
    fi
    cp_warn "pin for $root names unknown profile $name; ignoring"
  fi

  # Here-doc, not a pipe: a pipe would run the loop in a subshell and discard
  # best_name.
  while IFS="$(printf '\t')" read -r rp rn; do
    [ -n "$rp" ] || continue
    rp="$(cp_path_normalize "$rp")"
    cp_path_under "$rp" "$root" || continue
    [ "${#rp}" -gt "$best_len" ] || continue
    if cp_profile_exists "$cfg" "$rn"; then
      best_len="${#rp}"
      best_name="$rn"
      best_path="$rp"
    else
      cp_warn "rule $rp names unknown profile $rn; ignoring"
    fi
  done <<EOF
$(printf '%s' "$cfg" | jq -r '.rules[]? | [.path, .profile] | @tsv')
EOF

  if [ -n "$best_name" ]; then
    printf '%s\trule %s\n' "$best_name" "$best_path"
    return 0
  fi

  name="$(printf '%s' "$cfg" | jq -r '.default // empty')"
  if [ -n "$name" ] && cp_profile_exists "$cfg" "$name"; then
    printf '%s\tdefault\n' "$name"
    return 0
  fi
  if [ -n "$name" ]; then
    cp_warn "default profile $name is not defined; ignoring"
  fi

  printf '\tnone\n'
  return 0
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash /Users/diego/dev/claudeprofile/tests/run.sh`
Expected: PASS for `test_config.sh`, `test_resolve.sh`, `test_resolve_env.sh`.

- [ ] **Step 6: Lint and commit**

```bash
cd /Users/diego/dev/claudeprofile
shellcheck scripts/lib/*.sh tests/*.sh
git add scripts/lib/resolve.sh tests/test_resolve.sh tests/test_resolve_env.sh
git commit -m "feat: path handling and profile resolution ladder"
```

---

### Task 3: Entrypoint, `env`, `which`

**Files:**
- Create: `scripts/claudeprofile`, `scripts/lib/output.sh`, `tests/test_env.sh`
- Create stubs so the entrypoint sources cleanly: `scripts/lib/profiles.sh`, `scripts/lib/auth.sh` (each containing only the shebang comment header for now)

**Interfaces:**
- Consumes: everything from `config.sh` and `resolve.sh`.
- Produces: `cp_shquote <s>`, `cp_cmd_env`, `cp_cmd_which`. Entrypoint accepting `env|which|version|help`. `CP_VERSION=0.1.0`.

- [ ] **Step 1: Write the failing env tests**

Create `tests/test_env.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
CLI="$(cd "$(dirname "$0")/.." && pwd -P)/scripts/claudeprofile"

mkdir -p "$CP_T_TMP/p" "$CP_T_TMP/dev/crowder" "$CP_T_TMP/gone-parent"
cp_t_write_config <<JSON
{"default":"personal",
 "profiles":[{"name":"personal","dir":"$CP_T_TMP/p"},
             {"name":"work","native":true},
             {"name":"broken","dir":"$CP_T_TMP/gone-parent/missing"}],
 "rules":[{"path":"$CP_T_TMP/dev/crowder","profile":"work"}],
 "repos":{}}
JSON

# directory-backed profile exports
out="$(cd "$CP_T_TMP" && "$CLI" env 2>/dev/null)"
assert_eq "export CLAUDE_CONFIG_DIR='$CP_T_TMP/p'" "$out" 'default profile exports its dir'

# native profile unsets
out="$(cd "$CP_T_TMP/dev/crowder" && "$CLI" env 2>/dev/null)"
assert_eq 'unset CLAUDE_CONFIG_DIR' "$out" 'native profile unsets'

# missing directory degrades to unset
out="$(cd "$CP_T_TMP" && CLAUDE_PROFILE=broken "$CLI" env 2>/dev/null)"
assert_eq 'unset CLAUDE_CONFIG_DIR' "$out" 'missing profile dir unsets'

# malformed config degrades to unset, still exit 0
printf 'not json' > "$CLAUDEPROFILE_CONFIG"
out="$(cd "$CP_T_TMP" && "$CLI" env 2>/dev/null)"
assert_eq 'unset CLAUDE_CONFIG_DIR' "$out" 'malformed config unsets'
( cd "$CP_T_TMP" && "$CLI" env >/dev/null 2>&1 )
assert_eq '0' "$?" 'env exits 0 on malformed config'

# never silent
assert_eq '1' "$(cd "$CP_T_TMP" && "$CLI" env 2>/dev/null | grep -c 'CLAUDE_CONFIG_DIR')" \
  'env always prints exactly one CLAUDE_CONFIG_DIR line'

# quoting
mkdir -p "$CP_T_TMP/we'ird"
cp_t_write_config <<JSON
{"default":"q","profiles":[{"name":"q","dir":"$CP_T_TMP/we'ird"}],"rules":[],"repos":{}}
JSON
out="$(cd "$CP_T_TMP" && "$CLI" env 2>/dev/null)"
eval "$out"
assert_eq "$CP_T_TMP/we'ird" "$CLAUDE_CONFIG_DIR" 'single quote in dir survives eval'
unset CLAUDE_CONFIG_DIR

# which reports the reason
cp_t_write_config <<JSON
{"default":"personal","profiles":[{"name":"personal","dir":"$CP_T_TMP/p"},{"name":"work","native":true}],
 "rules":[{"path":"$CP_T_TMP/dev/crowder","profile":"work"}],"repos":{}}
JSON
out="$(cd "$CP_T_TMP/dev/crowder" && "$CLI" which 2>&1)"
case "$out" in
  *work*rule*) assert_eq 'ok' 'ok' 'which names profile and rule' ;;
  *)           assert_eq 'work + rule' "$out" 'which names profile and rule' ;;
esac

assert_eq "claudeprofile 0.1.0" "$("$CLI" version)" 'version output'

cp_t_summary
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash /Users/diego/dev/claudeprofile/tests/run.sh`
Expected: FAIL — `scripts/claudeprofile` not found.

- [ ] **Step 3: Implement output helpers**

Create `scripts/lib/output.sh`:

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# Shell-facing output: env exports, which, quoting.

# POSIX-safe single-quoting for eval.
cp_shquote() {
  local s="$1" q="'"
  printf "'%s'\n" "$(printf '%s' "$s" | sed "s/$q/'\\\\''/g")"
}

cp_unset_line() {
  printf 'unset CLAUDE_CONFIG_DIR\n'
}

# Always prints exactly one assignment line. Always returns 0.
cp_cmd_env() {
  local cfg line name reason dir
  if ! cfg="$(cp_config_read)"; then
    cp_unset_line
    return 0
  fi
  line="$(printf '%s' "$cfg" | cp_resolve)"
  name="$(printf '%s' "$line" | cut -f1)"
  reason="$(printf '%s' "$line" | cut -f2)"

  if [ -z "$name" ]; then
    cp_unset_line
    cp_warn 'no profile matched; using stock configuration'
    return 0
  fi
  if cp_profile_is_native "$cfg" "$name"; then
    cp_unset_line
    cp_warn "profile $name (native) - $reason"
    return 0
  fi
  dir="$(cp_profile_dir "$cfg" "$name")"
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    cp_unset_line
    cp_warn "profile $name directory missing (${dir:-unset}); using stock configuration"
    return 0
  fi
  printf 'export CLAUDE_CONFIG_DIR=%s\n' "$(cp_shquote "$dir")"
  cp_warn "profile $name - $reason"
  return 0
}

cp_cmd_which() {
  local cfg line name reason dir
  cfg="$(cp_config_read)" || return 1
  line="$(printf '%s' "$cfg" | cp_resolve 2>/dev/null)"
  name="$(printf '%s' "$line" | cut -f1)"
  reason="$(printf '%s' "$line" | cut -f2)"
  if [ -z "$name" ]; then
    printf 'no profile matched (%s)\n' "$reason"
    return 0
  fi
  if cp_profile_is_native "$cfg" "$name"; then
    printf '%s\tnative (keychain)\t%s\n' "$name" "$reason"
  else
    dir="$(cp_profile_dir "$cfg" "$name")"
    printf '%s\t%s\t%s\n' "$name" "$dir" "$reason"
  fi
}
```

- [ ] **Step 4: Implement the entrypoint**

Create `scripts/claudeprofile`:

```bash
#!/usr/bin/env bash
set -u

CP_VERSION='0.1.0'

CP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd -P)"
if [ -z "$CP_LIB_DIR" ]; then
  printf 'unset CLAUDE_CONFIG_DIR\n'
  printf 'claudeprofile: cannot locate lib directory\n' >&2
  exit 0
fi
# shellcheck source=lib/config.sh
. "$CP_LIB_DIR/config.sh"
# shellcheck source=lib/resolve.sh
. "$CP_LIB_DIR/resolve.sh"
# shellcheck source=lib/profiles.sh
. "$CP_LIB_DIR/profiles.sh"
# shellcheck source=lib/auth.sh
. "$CP_LIB_DIR/auth.sh"
# shellcheck source=lib/output.sh
. "$CP_LIB_DIR/output.sh"

cp_usage() {
  cat >&2 <<'USAGE'
claudeprofile - choose which Claude account a session uses

usage:
  claudeprofile list                       profiles, identities, markers
  claudeprofile which                      profile resolved for this directory
  claudeprofile env                        export statements for eval
  claudeprofile add <name> [--dir P] [--native] [--note S]
  claudeprofile default <name>
  claudeprofile pin [<name>] | pin --clear
  claudeprofile rule add <path> <name> | rule rm <path> | rule list
  claudeprofile login <name>
  claudeprofile doctor
  claudeprofile remove <name> [--purge]
  claudeprofile version

shell setup (~/.zshrc):
  claude() { eval "$(claudeprofile env)"; command claude "$@"; }
USAGE
}

cmd="${1:-}"
[ "$#" -gt 0 ] && shift

case "$cmd" in
  env)     cp_cmd_env; exit 0 ;;
  which)   cp_cmd_which ;;
  list)    cp_cmd_list "$@" ;;
  add)     cp_cmd_add "$@" ;;
  default) cp_cmd_default "$@" ;;
  pin)     cp_cmd_pin "$@" ;;
  rule)    cp_cmd_rule "$@" ;;
  login)   cp_cmd_login "$@" ;;
  doctor)  cp_cmd_doctor "$@" ;;
  remove)  cp_cmd_remove "$@" ;;
  version|--version|-v) printf 'claudeprofile %s\n' "$CP_VERSION" ;;
  help|--help|-h) cp_usage ;;
  *)       cp_usage; exit 2 ;;
esac
```

Create placeholder libs so sourcing succeeds — `scripts/lib/profiles.sh` and `scripts/lib/auth.sh`, each containing exactly:

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# Implemented in a later task.
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `chmod +x /Users/diego/dev/claudeprofile/scripts/claudeprofile && bash /Users/diego/dev/claudeprofile/tests/run.sh`
Expected: PASS, including `env exits 0 on malformed config`.

- [ ] **Step 6: Verify the shell function by hand**

Run:
```bash
cd /Users/diego/dev/claudeprofile
CLAUDEPROFILE_CONFIG=/dev/null ./scripts/claudeprofile env
```
Expected: prints `unset CLAUDE_CONFIG_DIR`, exit status 0. `/dev/null` is not valid JSON, so this also exercises the malformed path.

- [ ] **Step 7: Lint and commit**

```bash
cd /Users/diego/dev/claudeprofile
shellcheck scripts/claudeprofile scripts/lib/*.sh tests/*.sh
git add scripts tests/test_env.sh
git commit -m "feat: CLI entrypoint with env and which"
```

---

### Task 4: Mutations — add, default, pin, rule, remove

**Files:**
- Modify: `scripts/lib/profiles.sh` (replace the placeholder)
- Create: `tests/test_profiles.sh`

**Interfaces:**
- Consumes: `cp_config_read`, `cp_config_write`, `cp_profile_exists`, `cp_profile_dir`, `cp_path_normalize`, `cp_repo_root`, `cp_warn`.
- Produces: `cp_cmd_add`, `cp_cmd_default`, `cp_cmd_pin`, `cp_cmd_rule`, `cp_cmd_remove`.

- [ ] **Step 1: Write the failing mutation tests**

Create `tests/test_profiles.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
CLI="$(cd "$(dirname "$0")/.." && pwd -P)/scripts/claudeprofile"
cfg_get() { jq -r "$1" "$CLAUDEPROFILE_CONFIG"; }

# add creates the directory and becomes default when first
assert_ok "$CLI" add personal --dir "$CP_T_TMP/p" --note 'Max'
assert_eq 'personal' "$(cfg_get '.default')" 'first profile becomes default'
assert_eq 'true'     "$([ -d "$CP_T_TMP/p" ] && echo true)" 'add creates the directory'
assert_eq '700'      "$(stat -f '%Lp' "$CP_T_TMP/p")" 'profile dir is mode 700'

# duplicate names rejected
assert_fail "$CLI" add personal --dir "$CP_T_TMP/p2" 'duplicate name rejected'

# native profile
assert_ok "$CLI" add work --native --note 'Crowder team'
assert_eq 'true' "$(cfg_get '.profiles[] | select(.name=="work") | .native')" 'native flag stored'
assert_eq 'null' "$(cfg_get '.profiles[] | select(.name=="work") | .dir // "null"')" 'native has no dir'

# only one native
assert_fail "$CLI" add second --native 'second native profile rejected'

# ~/.claude is refused outright
assert_fail "$CLI" add danger --dir "$HOME/.claude" 'refuses ~/.claude as a profile dir'

# default
assert_ok  "$CLI" default work
assert_eq  'work' "$(cfg_get '.default')" 'default updated'
assert_fail "$CLI" default ghost 'default rejects unknown profile'

# rules
assert_ok "$CLI" rule add "$CP_T_TMP/dev/crowder" work
assert_eq "$CP_T_TMP/dev/crowder" "$(cfg_get '.rules[0].path')" 'rule path stored normalised'
assert_fail "$CLI" rule add "$CP_T_TMP/dev/x" ghost 'rule rejects unknown profile'
assert_ok "$CLI" rule add "$CP_T_TMP/dev/crowder" personal
assert_eq '1' "$(cfg_get '[.rules[] | select(.path=="'"$CP_T_TMP"'/dev/crowder")] | length')" \
  'repeat rule for same path replaces rather than duplicates'
assert_ok "$CLI" rule rm "$CP_T_TMP/dev/crowder"
assert_eq '0' "$(cfg_get '.rules | length')" 'rule rm removes it'

# pin uses the repo root when inside a git repo
mkdir -p "$CP_T_TMP/repo/sub"
( cd "$CP_T_TMP/repo" && git init -q )
( cd "$CP_T_TMP/repo/sub" && "$CLI" pin personal >/dev/null 2>&1 )
assert_eq 'personal' "$(cfg_get '.repos["'"$CP_T_TMP"'/repo"]')" 'pin keys on git top level, not cwd'
( cd "$CP_T_TMP/repo/sub" && "$CLI" pin --clear >/dev/null 2>&1 )
assert_eq 'null' "$(cfg_get '.repos["'"$CP_T_TMP"'/repo"] // "null"')" 'pin --clear removes the pin'

# pin with no argument uses the resolved profile
( cd "$CP_T_TMP/repo" && "$CLI" pin >/dev/null 2>&1 )
assert_eq 'work' "$(cfg_get '.repos["'"$CP_T_TMP"'/repo"]')" 'bare pin stores the resolved profile'

# remove
assert_ok "$CLI" remove personal
assert_fail "$CLI" remove personal 'removing a gone profile fails'
assert_eq 'true' "$([ -d "$CP_T_TMP/p" ] && echo true)" 'remove leaves the directory in place'

# purge needs confirmation and honours it
assert_ok "$CLI" add tmpp --dir "$CP_T_TMP/tp"
printf 'n\n' | "$CLI" remove tmpp --purge >/dev/null 2>&1
assert_eq 'true' "$([ -d "$CP_T_TMP/tp" ] && echo true)" 'declined purge keeps the directory'
printf 'y\n' | "$CLI" remove tmpp --purge >/dev/null 2>&1
assert_eq '' "$([ -d "$CP_T_TMP/tp" ] && echo true)" 'confirmed purge deletes the directory'

cp_t_summary
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash /Users/diego/dev/claudeprofile/tests/run.sh`
Expected: FAIL — `cp_cmd_add: command not found`.

- [ ] **Step 3: Implement the mutations**

Replace `scripts/lib/profiles.sh`:

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# Config mutations: add, default, pin, rule, remove.

cp_forbidden_dir() {
  local d="$1" home_claude
  home_claude="$(cp_path_normalize "$HOME/.claude")"
  [ "$(cp_path_normalize "$d")" = "$home_claude" ]
}

cp_cmd_add() {
  local name='' dir='' note='' native=0 cfg existing
  name="${1:-}"
  [ -n "$name" ] || { cp_warn 'add: missing profile name'; return 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dir)    dir="${2:-}"; shift 2 ;;
      --note)   note="${2:-}"; shift 2 ;;
      --native) native=1; shift ;;
      *)        cp_warn "add: unknown flag $1"; return 2 ;;
    esac
  done

  cfg="$(cp_config_read)" || return 1
  if cp_profile_exists "$cfg" "$name"; then
    cp_warn "profile $name already exists"
    return 1
  fi

  if [ "$native" -eq 1 ]; then
    [ -n "$dir" ] && { cp_warn 'add: --native and --dir are mutually exclusive'; return 2; }
    existing="$(printf '%s' "$cfg" | jq -r 'first(.profiles[]? | select(.native == true) | .name) // empty')"
    if [ -n "$existing" ]; then
      cp_warn "profile $existing is already native; only one native profile is allowed"
      return 1
    fi
    printf '%s' "$cfg" | jq --arg n "$name" --arg note "$note" \
      '.profiles += [{name: $n, native: true, note: $note}]
       | if (.default == null) then .default = $n else . end' | cp_config_write
    return $?
  fi

  [ -n "$dir" ] || dir="$HOME/.claude-profiles/$name"
  dir="$(cp_path_normalize "$dir")"
  if cp_forbidden_dir "$dir"; then
    cp_warn 'refusing to use ~/.claude as a profile directory; use --native instead'
    return 1
  fi
  mkdir -p "$dir" || return 1
  chmod 700 "$dir" || return 1

  printf '%s' "$cfg" | jq --arg n "$name" --arg d "$dir" --arg note "$note" \
    '.profiles += [{name: $n, dir: $d, note: $note}]
     | if (.default == null) then .default = $n else . end' | cp_config_write
}

cp_cmd_default() {
  local name="${1:-}" cfg
  [ -n "$name" ] || { cp_warn 'default: missing profile name'; return 2; }
  cfg="$(cp_config_read)" || return 1
  cp_profile_exists "$cfg" "$name" || { cp_warn "unknown profile $name"; return 1; }
  printf '%s' "$cfg" | jq --arg n "$name" '.default = $n' | cp_config_write
}

cp_cmd_pin() {
  local arg="${1:-}" cfg root name
  cfg="$(cp_config_read)" || return 1
  root="$(cp_repo_root)"
  if [ "$arg" = '--clear' ]; then
    printf '%s' "$cfg" | jq --arg r "$root" 'del(.repos[$r])' | cp_config_write
    return $?
  fi
  if [ -n "$arg" ]; then
    name="$arg"
  else
    name="$(printf '%s' "$cfg" | cp_resolve | cut -f1)"
    [ -n "$name" ] || { cp_warn 'pin: nothing resolved for this directory; name a profile'; return 1; }
  fi
  cp_profile_exists "$cfg" "$name" || { cp_warn "unknown profile $name"; return 1; }
  printf '%s' "$cfg" | jq --arg r "$root" --arg n "$name" '.repos[$r] = $n' | cp_config_write
}

cp_cmd_rule() {
  local sub="${1:-}" path name cfg
  [ -n "$sub" ] && shift
  cfg="$(cp_config_read)" || return 1
  case "$sub" in
    add)
      path="${1:-}"; name="${2:-}"
      [ -n "$path" ] && [ -n "$name" ] || { cp_warn 'rule add: need <path> <profile>'; return 2; }
      cp_profile_exists "$cfg" "$name" || { cp_warn "unknown profile $name"; return 1; }
      path="$(cp_path_normalize "$path")"
      printf '%s' "$cfg" | jq --arg p "$path" --arg n "$name" \
        '.rules = ([.rules[]? | select(.path != $p)] + [{path: $p, profile: $n}])' | cp_config_write
      ;;
    rm)
      path="${1:-}"
      [ -n "$path" ] || { cp_warn 'rule rm: need <path>'; return 2; }
      path="$(cp_path_normalize "$path")"
      printf '%s' "$cfg" | jq --arg p "$path" '.rules = [.rules[]? | select(.path != $p)]' | cp_config_write
      ;;
    list)
      printf '%s' "$cfg" | jq -r '.rules[]? | [.path, .profile] | @tsv' \
        | awk '{ print length($1) "\t" $0 }' | sort -rn | cut -f2-
      ;;
    *)
      cp_warn 'rule: expected add, rm, or list'
      return 2
      ;;
  esac
}

cp_cmd_remove() {
  local name='' purge=0 cfg dir reply
  name="${1:-}"
  [ -n "$name" ] || { cp_warn 'remove: missing profile name'; return 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --purge) purge=1; shift ;;
      *)       cp_warn "remove: unknown flag $1"; return 2 ;;
    esac
  done

  cfg="$(cp_config_read)" || return 1
  cp_profile_exists "$cfg" "$name" || { cp_warn "unknown profile $name"; return 1; }
  dir="$(cp_profile_dir "$cfg" "$name")"

  if [ "$purge" -eq 1 ] && [ -n "$dir" ]; then
    if cp_forbidden_dir "$dir"; then
      cp_warn 'refusing to purge ~/.claude'
      return 1
    fi
    printf 'Delete %s and every credential and session in it? [y/N] ' "$dir" >&2
    read -r reply
    case "$reply" in
      y|Y|yes|YES) rm -rf "$dir" ;;
      *) cp_warn 'purge declined; profile left registered'; return 1 ;;
    esac
  fi

  printf '%s' "$cfg" | jq --arg n "$name" \
    '.profiles = [.profiles[]? | select(.name != $n)]
     | .rules   = [.rules[]?   | select(.profile != $n)]
     | .repos   = (.repos | with_entries(select(.value != $n)))
     | if (.default == $n) then .default = (first(.profiles[]?.name) // null) else . end' | cp_config_write
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash /Users/diego/dev/claudeprofile/tests/run.sh`
Expected: PASS across all test files.

- [ ] **Step 5: Lint and commit**

```bash
cd /Users/diego/dev/claudeprofile
shellcheck scripts/claudeprofile scripts/lib/*.sh tests/*.sh
git add scripts/lib/profiles.sh tests/test_profiles.sh
git commit -m "feat: add, default, pin, rule, and remove commands"
```

---

### Task 5: Identity reporting — `list` and `doctor`

**Files:**
- Modify: `scripts/lib/auth.sh` (replace the placeholder), `scripts/lib/output.sh` (append `cp_cmd_list`)
- Create: `tests/test_auth_status.sh`

**Interfaces:**
- Consumes: config helpers, `cp_resolve`.
- Produces: `CP_CLAUDE_BIN`, `cp_auth_status <cfg> <name>` (stdout the `claude auth status --json` payload, `{}` on failure), `cp_creds_file <cfg> <name>`, `cp_cmd_list`, `cp_cmd_doctor`.

Native profiles must run `claude` with `CLAUDE_CONFIG_DIR` **removed** from the environment, not merely empty — an empty value is still a set value. Use `env -u CLAUDE_CONFIG_DIR`.

- [ ] **Step 1: Write the failing status tests**

Create `tests/test_auth_status.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
CLI="$(cd "$(dirname "$0")/.." && pwd -P)/scripts/claudeprofile"

# Stub claude: reports identity based on CLAUDE_CONFIG_DIR, and records whether
# the variable was set at all.
cat > "$CP_CLAUDE_BIN" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  if [ -z "${CLAUDE_CONFIG_DIR+set}" ]; then
    printf '{"loggedIn":true,"email":"native@example.com","subscriptionType":"team"}\n'
  elif [ -f "$CLAUDE_CONFIG_DIR/.credentials.json" ]; then
    printf '{"loggedIn":true,"email":"file@example.com","subscriptionType":"max"}\n'
  else
    printf '{"loggedIn":false,"authMethod":"none"}\n'
  fi
  exit 0
fi
exit 1
STUB
chmod +x "$CP_CLAUDE_BIN"

mkdir -p "$CP_T_TMP/p" "$CP_T_TMP/empty"
printf '{"claudeAiOauth":{"refreshTokenExpiresAt":99999999999999}}' > "$CP_T_TMP/p/.credentials.json"
cp_t_write_config <<JSON
{"default":"personal",
 "profiles":[{"name":"personal","dir":"$CP_T_TMP/p","note":"Max"},
             {"name":"work","native":true,"note":"team"},
             {"name":"cold","dir":"$CP_T_TMP/empty"}],
 "rules":[],"repos":{}}
JSON

out="$(cd "$CP_T_TMP" && "$CLI" list 2>/dev/null)"
case "$out" in *file@example.com*)   assert_eq ok ok 'list shows file-backed identity' ;;
                *) assert_eq 'file@example.com' "$out" 'list shows file-backed identity' ;; esac
case "$out" in *native@example.com*) assert_eq ok ok 'list shows native identity via unset env' ;;
                *) assert_eq 'native@example.com' "$out" 'list shows native identity via unset env' ;; esac
case "$out" in *'(default)'*)        assert_eq ok ok 'list marks default' ;;
                *) assert_eq '(default)' "$out" 'list marks default' ;; esac
case "$out" in *native*)             assert_eq ok ok 'list marks native' ;;
                *) assert_eq 'native' "$out" 'list marks native' ;; esac
case "$out" in *'not logged in'*)    assert_eq ok ok 'list flags unauthenticated profile' ;;
                *) assert_eq 'not logged in' "$out" 'list flags unauthenticated profile' ;; esac

# doctor exits non-zero while any profile is unauthenticated
( cd "$CP_T_TMP" && "$CLI" doctor >/dev/null 2>&1 )
assert_eq '1' "$?" 'doctor fails when a profile is not logged in'

# ... and zero once the cold profile is gone
"$CLI" remove cold >/dev/null 2>&1
( cd "$CP_T_TMP" && "$CLI" doctor >/dev/null 2>&1 )
assert_eq '0' "$?" 'doctor passes when every profile is logged in'

# expiring refresh token is reported
printf '{"claudeAiOauth":{"refreshTokenExpiresAt":1}}' > "$CP_T_TMP/p/.credentials.json"
out="$(cd "$CP_T_TMP" && "$CLI" doctor 2>&1)"
case "$out" in *expir*) assert_eq ok ok 'doctor reports an expiring refresh token' ;;
                *) assert_eq 'expiring' "$out" 'doctor reports an expiring refresh token' ;; esac

cp_t_summary
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash /Users/diego/dev/claudeprofile/tests/run.sh`
Expected: FAIL — `cp_cmd_list: command not found`.

- [ ] **Step 3: Implement status reading**

Replace `scripts/lib/auth.sh`:

```bash
#!/usr/bin/env bash
# shellcheck shell=bash
# Per-profile authentication: status, credential files, login, doctor.

CP_CLAUDE_BIN="${CP_CLAUDE_BIN:-claude}"
CP_SECURITY_BIN="${CP_SECURITY_BIN:-security}"

# cp_creds_file <cfg> <name> -> path, or empty for a native profile
cp_creds_file() {
  local dir
  dir="$(cp_profile_dir "$1" "$2")"
  [ -n "$dir" ] || return 0
  printf '%s/.credentials.json\n' "$dir"
}

# cp_auth_status <cfg> <name> -> JSON on stdout, {} on failure
cp_auth_status() {
  local cfg="$1" name="$2" dir out
  if cp_profile_is_native "$cfg" "$name"; then
    out="$(env -u CLAUDE_CONFIG_DIR "$CP_CLAUDE_BIN" auth status --json 2>/dev/null)"
  else
    dir="$(cp_profile_dir "$cfg" "$name")"
    if [ -z "$dir" ] || [ ! -d "$dir" ]; then
      printf '{}\n'
      return 0
    fi
    out="$(CLAUDE_CONFIG_DIR="$dir" "$CP_CLAUDE_BIN" auth status --json 2>/dev/null)"
  fi
  if [ -z "$out" ] || ! printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
    printf '{}\n'
    return 0
  fi
  printf '%s\n' "$out"
}

# Milliseconds until the refresh token expires, or empty when unknown.
cp_refresh_ms_left() {
  local file="$1" exp now
  [ -n "$file" ] && [ -f "$file" ] || return 0
  exp="$(jq -r '.claudeAiOauth.refreshTokenExpiresAt // empty' "$file" 2>/dev/null)"
  [ -n "$exp" ] || return 0
  now="$(( $(date +%s) * 1000 ))"
  printf '%s\n' "$(( exp - now ))"
}

cp_cmd_doctor() {
  local cfg names name st logged active ms left_days status=0
  cfg="$(cp_config_read)" || return 1
  active="$(printf '%s' "$cfg" | cp_resolve 2>/dev/null | cut -f1)"
  names="$(printf '%s' "$cfg" | jq -r '.profiles[]?.name')"
  if [ -z "$names" ]; then
    printf 'no profiles configured\n'
    return 1
  fi
  for name in $names; do
    st="$(cp_auth_status "$cfg" "$name")"
    logged="$(printf '%s' "$st" | jq -r '.loggedIn // false')"
    if [ "$logged" != 'true' ]; then
      printf '%s: not logged in - run: claudeprofile login %s\n' "$name" "$name"
      status=1
      continue
    fi
    ms="$(cp_refresh_ms_left "$(cp_creds_file "$cfg" "$name")")"
    if [ -n "$ms" ] && [ "$ms" -lt 1209600000 ]; then
      left_days="$(( ms / 86400000 ))"
      printf '%s: refresh token expires in %s day(s) - re-run: claudeprofile login %s\n' \
        "$name" "$left_days" "$name"
      status=1
    else
      printf '%s: ok\n' "$name"
    fi
  done
  printf 'active profile here: %s\n' "${active:-none}"
  return "$status"
}
```

- [ ] **Step 4: Implement `list`**

Append to `scripts/lib/output.sh`:

```bash
cp_cmd_list() {
  local cfg names name active default_name st email sub markers dir
  cfg="$(cp_config_read)" || return 1
  active="$(printf '%s' "$cfg" | cp_resolve 2>/dev/null | cut -f1)"
  default_name="$(printf '%s' "$cfg" | jq -r '.default // empty')"
  names="$(printf '%s' "$cfg" | jq -r '.profiles[]?.name')"
  if [ -z "$names" ]; then
    printf 'no profiles saved\n'
    return 0
  fi
  for name in $names; do
    st="$(cp_auth_status "$cfg" "$name")"
    if [ "$(printf '%s' "$st" | jq -r '.loggedIn // false')" = 'true' ]; then
      email="$(printf '%s' "$st" | jq -r '.email // "unknown"')"
      sub="$(printf '%s' "$st" | jq -r '.subscriptionType // "unknown"')"
    else
      email='not logged in'
      sub='-'
    fi
    markers=''
    [ "$name" = "$default_name" ] && markers="$markers (default)"
    [ "$name" = "$active" ] && markers="$markers (active)"
    if cp_profile_is_native "$cfg" "$name"; then
      markers="$markers native"
    else
      dir="$(cp_profile_dir "$cfg" "$name")"
      [ -d "$dir" ] || markers="$markers [dir missing]"
    fi
    printf '%-12s %-8s %-28s%s\n' "$name" "$sub" "$email" "$markers"
  done
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash /Users/diego/dev/claudeprofile/tests/run.sh`
Expected: PASS.

- [ ] **Step 6: Verify against the real binary, read-only**

Run:
```bash
cd /Users/diego/dev/claudeprofile
CLAUDEPROFILE_CONFIG=/tmp/cp-smoke.json ./scripts/claudeprofile add real --native
CLAUDEPROFILE_CONFIG=/tmp/cp-smoke.json ./scripts/claudeprofile list
rm -f /tmp/cp-smoke.json
```
Expected: one row showing the real account's email and `team`, marked `native (default) (active)`. No login prompt, no writes outside `/tmp`.

- [ ] **Step 7: Lint and commit**

```bash
cd /Users/diego/dev/claudeprofile
shellcheck scripts/claudeprofile scripts/lib/*.sh tests/*.sh
git add scripts/lib/auth.sh scripts/lib/output.sh tests/test_auth_status.sh
git commit -m "feat: list and doctor report per-profile identity"
```

---

### Task 6: `login` with the keychain safety net

**Files:**
- Modify: `scripts/lib/auth.sh` (append)
- Create: `tests/test_login.sh`

**Interfaces:**
- Consumes: `CP_CLAUDE_BIN`, `CP_SECURITY_BIN`, `CP_STATE_DIR`, `CP_KEYCHAIN_SERVICE`, `cp_profile_dir`, `cp_profile_is_native`.
- Produces: `cp_keychain_read`, `cp_keychain_write <blob>`, `cp_cmd_login <name>`.

Behaviour, in order: snapshot the keychain blob to `$CP_STATE_DIR/keychain.bak` at mode 0600; run `claude auth login --claudeai` with `CLAUDE_CONFIG_DIR` set to the profile directory; then require both that `<dir>/.credentials.json` exists and that the keychain blob is byte-identical to the snapshot. If the keychain changed, restore it from the snapshot, report loudly, and return non-zero.

- [ ] **Step 1: Write the failing login tests**

Create `tests/test_login.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
CLI="$(cd "$(dirname "$0")/.." && pwd -P)/scripts/claudeprofile"

# Stub keychain backed by a plain file.
KC="$CP_T_TMP/keychain.store"
printf 'ORIGINAL-BLOB' > "$KC"
cat > "$CP_SECURITY_BIN" <<'STUB'
#!/usr/bin/env bash
store="$CP_T_KEYCHAIN_STORE"
case "$1" in
  find-generic-password) cat "$store" 2>/dev/null; [ -s "$store" ] ;;
  add-generic-password)
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in -w) printf '%s' "$2" > "$store"; shift 2 ;; *) shift ;; esac
    done
    ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$CP_SECURITY_BIN"
export CP_T_KEYCHAIN_STORE="$KC"

mkdir -p "$CP_T_TMP/p"
cp_t_write_config <<JSON
{"default":"personal","profiles":[{"name":"personal","dir":"$CP_T_TMP/p"},{"name":"work","native":true}],
 "rules":[],"repos":{}}
JSON

# --- well-behaved login: writes the credentials file, leaves keychain alone ---
cat > "$CP_CLAUDE_BIN" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = login ]; then
  printf '{"claudeAiOauth":{"accessToken":"x"}}' > "$CLAUDE_CONFIG_DIR/.credentials.json"
  exit 0
fi
exit 1
STUB
chmod +x "$CP_CLAUDE_BIN"

assert_ok "$CLI" login personal 'login succeeds when creds file appears'
assert_eq 'true' "$([ -f "$CP_T_TMP/p/.credentials.json" ] && echo true)" 'credentials file created'
assert_eq 'ORIGINAL-BLOB' "$(cat "$KC")" 'keychain untouched by a well-behaved login'
assert_eq '600' "$(stat -f '%Lp' "$CLAUDEPROFILE_STATE_DIR/keychain.bak")" 'keychain backup is mode 600'

# --- misbehaving login: clobbers the keychain -> detected and restored --------
rm -f "$CP_T_TMP/p/.credentials.json"
cat > "$CP_CLAUDE_BIN" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = login ]; then
  printf 'CLOBBERED' > "$CP_T_KEYCHAIN_STORE"
  exit 0
fi
exit 1
STUB
chmod +x "$CP_CLAUDE_BIN"

out="$("$CLI" login personal 2>&1)"
assert_eq '1' "$?" 'login fails when the keychain was clobbered'
assert_eq 'ORIGINAL-BLOB' "$(cat "$KC")" 'keychain restored from backup'
case "$out" in *keychain*) assert_eq ok ok 'clobber is reported' ;;
                *) assert_eq 'keychain' "$out" 'clobber is reported' ;; esac

# --- native profile cannot be logged in through a profile dir ----------------
assert_fail "$CLI" login work 'login refuses a native profile'

# --- unknown profile ---------------------------------------------------------
assert_fail "$CLI" login ghost 'login rejects an unknown profile'

cp_t_summary
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash /Users/diego/dev/claudeprofile/tests/run.sh`
Expected: FAIL — `cp_cmd_login: command not found`.

- [ ] **Step 3: Implement keychain access and login**

Append to `scripts/lib/auth.sh`:

```bash
cp_keychain_read() {
  "$CP_SECURITY_BIN" find-generic-password -s "$CP_KEYCHAIN_SERVICE" -a "${USER:-$(id -un)}" -w 2>/dev/null
}

cp_keychain_write() {
  "$CP_SECURITY_BIN" add-generic-password -U \
    -a "${USER:-$(id -un)}" -s "$CP_KEYCHAIN_SERVICE" -w "$1" >/dev/null 2>&1
}

cp_cmd_login() {
  local name="${1:-}" cfg dir backup before after rc
  [ -n "$name" ] || { cp_warn 'login: missing profile name'; return 2; }
  cfg="$(cp_config_read)" || return 1
  cp_profile_exists "$cfg" "$name" || { cp_warn "unknown profile $name"; return 1; }
  if cp_profile_is_native "$cfg" "$name"; then
    cp_warn "profile $name is native; log in with a plain 'claude auth login' (no CLAUDE_CONFIG_DIR)"
    return 1
  fi
  dir="$(cp_profile_dir "$cfg" "$name")"
  [ -n "$dir" ] || { cp_warn "profile $name has no directory"; return 1; }
  mkdir -p "$dir" || return 1
  chmod 700 "$dir" || return 1

  mkdir -p "$CP_STATE_DIR" || return 1
  chmod 700 "$CP_STATE_DIR" || return 1
  backup="$CP_STATE_DIR/keychain.bak"
  before="$(cp_keychain_read)"
  if [ -n "$before" ]; then
    ( umask 077; printf '%s' "$before" > "$backup" ) || return 1
    chmod 600 "$backup" || return 1
  fi

  CLAUDE_CONFIG_DIR="$dir" "$CP_CLAUDE_BIN" auth login --claudeai
  rc=$?

  after="$(cp_keychain_read)"
  if [ -n "$before" ] && [ "$after" != "$before" ]; then
    cp_warn 'login wrote to the shared keychain item instead of the profile directory'
    if cp_keychain_write "$before"; then
      cp_warn "keychain restored from $backup"
    else
      cp_warn "COULD NOT RESTORE THE KEYCHAIN. Recover manually from $backup"
    fi
    cp_warn 'per-profile logins are unsafe on this Claude Code version; aborting'
    return 1
  fi

  if [ ! -f "$dir/.credentials.json" ]; then
    cp_warn "login did not produce $dir/.credentials.json (claude exited $rc)"
    return 1
  fi
  chmod 600 "$dir/.credentials.json" 2>/dev/null
  printf 'logged in: %s\n' "$name"
  return 0
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash /Users/diego/dev/claudeprofile/tests/run.sh`
Expected: PASS, including both the clean and clobber paths.

- [ ] **Step 5: Lint and commit**

```bash
cd /Users/diego/dev/claudeprofile
shellcheck scripts/claudeprofile scripts/lib/*.sh tests/*.sh
git add scripts/lib/auth.sh tests/test_login.sh
git commit -m "feat: profile login guarded against keychain clobber"
```

- [ ] **Step 6: Hand the real login to the user**

Do **not** run a real `claudeprofile login` autonomously — it opens a browser and needs the second account's password. Report to the user instead:

> Implementation is ready for the one step I can't take for you. Run:
> `~/dev/claudeprofile/scripts/claudeprofile add personal` then
> `~/dev/claudeprofile/scripts/claudeprofile login personal`, and sign in with the
> personal account. The safety net restores your keychain automatically if the
> login writes to the wrong place. Then `claudeprofile list` should show both
> accounts.

---

### Task 7: Plugin packaging — manifest, slash command, hook

**Files:**
- Create: `.claude-plugin/plugin.json`, `hooks/hooks.json`, `hooks/session-start.sh`, `commands/profile.md`, `tests/test_hook.sh`

**Interfaces:**
- Consumes: `scripts/claudeprofile` via `${CLAUDE_PLUGIN_ROOT}`.
- Produces: a plugin that passes `claude plugin validate`.

- [ ] **Step 1: Write the failing hook test**

Create `tests/test_hook.sh`:

```bash
#!/usr/bin/env bash
set -u
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
HOOK="$ROOT/hooks/session-start.sh"
export CLAUDE_PLUGIN_ROOT="$ROOT"

mkdir -p "$CP_T_TMP/p" "$CP_T_TMP/dev/crowder"
cp_t_write_config <<JSON
{"default":"personal","profiles":[{"name":"personal","dir":"$CP_T_TMP/p"},{"name":"work","native":true}],
 "rules":[{"path":"$CP_T_TMP/dev/crowder","profile":"work"}],"repos":{}}
JSON

# match: session already on the expected profile -> silent
out="$(cd "$CP_T_TMP" && CLAUDE_CONFIG_DIR="$CP_T_TMP/p" bash "$HOOK" 2>&1)"
assert_eq '' "$out" 'no output when the session matches'

# mismatch: expected native, session is on a profile dir -> warn
out="$(cd "$CP_T_TMP/dev/crowder" && CLAUDE_CONFIG_DIR="$CP_T_TMP/p" bash "$HOOK" 2>&1)"
case "$out" in *work*) assert_eq ok ok 'mismatch names the expected profile' ;;
                *) assert_eq 'work' "$out" 'mismatch names the expected profile' ;; esac
case "$out" in *Relaunch*) assert_eq ok ok 'mismatch says to relaunch' ;;
                *) assert_eq 'Relaunch' "$out" 'mismatch says to relaunch' ;; esac

# hook must never fail a session
( cd "$CP_T_TMP/dev/crowder" && CLAUDE_CONFIG_DIR="$CP_T_TMP/p" bash "$HOOK" >/dev/null 2>&1 )
assert_eq '0' "$?" 'hook exits 0 on mismatch'
printf 'not json' > "$CLAUDEPROFILE_CONFIG"
( cd "$CP_T_TMP" && bash "$HOOK" >/dev/null 2>&1 )
assert_eq '0' "$?" 'hook exits 0 on malformed config'

cp_t_summary
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash /Users/diego/dev/claudeprofile/tests/run.sh`
Expected: FAIL — `hooks/session-start.sh` does not exist.

- [ ] **Step 3: Implement the hook**

Create `hooks/session-start.sh`:

```bash
#!/usr/bin/env bash
# SessionStart: warn when the live session's account no longer matches what this
# directory resolves to. Never fails a session.
set -u

root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
cli="$root/scripts/claudeprofile"
[ -x "$cli" ] || exit 0

want="$("$cli" env 2>/dev/null)"
have="${CLAUDE_CONFIG_DIR:+export CLAUDE_CONFIG_DIR=$(printf "'%s'" "$CLAUDE_CONFIG_DIR")}"
[ -n "$have" ] || have='unset CLAUDE_CONFIG_DIR'

if [ "$want" = "$have" ]; then
  exit 0
fi

detail="$("$cli" which 2>/dev/null | head -1)"
printf 'claudeprofile: this session does not match this directory. Expected: %s. Relaunch claude here to switch.\n' \
  "${detail:-unknown}"
exit 0
```

- [ ] **Step 4: Run the hook test to verify it passes**

Run: `chmod +x /Users/diego/dev/claudeprofile/hooks/session-start.sh && bash /Users/diego/dev/claudeprofile/tests/run.sh`
Expected: PASS.

- [ ] **Step 5: Write the manifest, hook registration, and slash command**

Create `.claude-plugin/plugin.json`:

```json
{
  "name": "claudeprofile",
  "version": "0.1.0",
  "description": "Select which Claude account a session uses, by default profile, per-repo pin, or directory rule.",
  "author": { "name": "Diego Cotelo" },
  "hooks": "./hooks/hooks.json"
}
```

Create `hooks/hooks.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh"
          }
        ]
      }
    ]
  }
}
```

Create `commands/profile.md`:

```markdown
---
description: Show or change which Claude account this directory uses
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/claudeprofile:*)
---

Arguments: `$ARGUMENTS`

Run the matching command and report its output verbatim. Do not offer to switch
the current session's account — credentials are fixed at process start, so a
switch requires relaunching `claude`.

- No arguments: run `${CLAUDE_PLUGIN_ROOT}/scripts/claudeprofile which`, then
  `${CLAUDE_PLUGIN_ROOT}/scripts/claudeprofile list`.
- `pin <name>`: run `${CLAUDE_PLUGIN_ROOT}/scripts/claudeprofile pin <name>`, then
  state that a relaunch is required for it to take effect.
- `rule <path> <name>`: run
  `${CLAUDE_PLUGIN_ROOT}/scripts/claudeprofile rule add <path> <name>`.
- `doctor`: run `${CLAUDE_PLUGIN_ROOT}/scripts/claudeprofile doctor`.
- Anything else: run `${CLAUDE_PLUGIN_ROOT}/scripts/claudeprofile help`.
```

- [ ] **Step 6: Validate the manifest**

Run: `claude plugin validate /Users/diego/dev/claudeprofile`
Expected: reports the plugin as valid.

If it rejects `"hooks": "./hooks/hooks.json"`, inline the hook object directly into `plugin.json` under a `"hooks"` key using the same structure as `hooks/hooks.json`, delete `hooks/hooks.json`, and re-run validation until it passes.

- [ ] **Step 7: Inspect the component inventory**

Run: `claude plugin details /Users/diego/dev/claudeprofile 2>/dev/null || claude plugin validate /Users/diego/dev/claudeprofile`
Expected: one command (`profile`) and one `SessionStart` hook listed.

- [ ] **Step 8: Commit**

```bash
cd /Users/diego/dev/claudeprofile
git add .claude-plugin hooks commands tests/test_hook.sh
git commit -m "feat: plugin manifest, /profile command, and SessionStart hook"
```

---

### Task 8: README and end-to-end verification

**Files:**
- Create: `README.md`
- Modify: none

**Interfaces:**
- Consumes: everything.
- Produces: install and usage documentation.

- [ ] **Step 1: Write the README**

Create `README.md`:

```markdown
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
shellcheck scripts/claudeprofile scripts/lib/*.sh hooks/*.sh tests/*.sh
claude plugin validate .             # check the manifest
```

Tests sandbox `HOME`, the config path, the `claude` binary, and the `security`
binary. No test touches the real keychain or a real account.

## License

MIT
```

- [ ] **Step 2: Run the full suite and lint**

Run:
```bash
cd /Users/diego/dev/claudeprofile
bash tests/run.sh && shellcheck scripts/claudeprofile scripts/lib/*.sh hooks/*.sh tests/*.sh
```
Expected: `ALL TESTS PASSED`, then no shellcheck output.

- [ ] **Step 3: End-to-end check against the real binary, read-only**

Run:
```bash
cd /Users/diego/dev/claudeprofile
export CLAUDEPROFILE_CONFIG=/tmp/cp-e2e.json
./scripts/claudeprofile add work --native --note 'real account'
./scripts/claudeprofile which
./scripts/claudeprofile list
./scripts/claudeprofile env
rm -f /tmp/cp-e2e.json
unset CLAUDEPROFILE_CONFIG
```
Expected: `which` names `work` with reason `default`; `list` shows the real email
and `team`; `env` prints `unset CLAUDE_CONFIG_DIR` because `work` is native. No
directory is created under `~/.claude-profiles`, and the real keychain is never
written.

- [ ] **Step 4: Commit**

```bash
cd /Users/diego/dev/claudeprofile
git add README.md
git commit -m "docs: add README covering install, resolution, and safety"
```

- [ ] **Step 5: Report the remaining manual step**

Tell the user, verbatim in substance:

> Everything is implemented and the suite passes. One step needs you: run
> `claudeprofile add personal` then `claudeprofile login personal` and sign in
> with the personal account. That login is also the last unverified piece of the
> design — whether Claude Code writes the token to the profile directory or to the
> shared keychain. The safety net restores your keychain and aborts if it goes to
> the keychain, so your working account is not at risk either way. After it
> succeeds, `claudeprofile list` should show both accounts, and adding the shell
> function to `~/.zshrc` makes switching automatic.

---

## Self-Review Notes

Spec coverage check, section by section:

| Spec section | Task |
| --- | --- |
| Verified mechanics (file creds, native profile) | 3 (`env` unset semantics), 5 (`env -u` for native) |
| Architecture, two components, one config | 1, 3, 7 |
| Resolution ladder, longest prefix, boundaries | 2 |
| Configuration schema, native vs directory-backed | 1, 4 |
| CLI surface, all 13 commands | 3 (`env`, `which`, `version`, `help`), 4 (`add`, `default`, `pin`, `rule`, `remove`), 5 (`list`, `doctor`), 6 (`login`) |
| Slash commands, no `/profile use` | 7 |
| Authentication flow and keychain safety net | 6 |
| Bootstrap sequence | 8 (README), 6 Step 6 and 8 Step 5 (handoff) |
| SessionStart hook | 7 |
| Error handling, all six cases | 1 (jq/malformed), 2 (unknown names), 3 (missing dir), 4 (native uniqueness, purge guard, `~/.claude` refusal) |
| Testing, all nine listed cases | 1, 2, 3, 4, 5, 6 |
| Distribution layout | 7, 8 |

Naming consistency: `cp_profile_dir` returns an expanded path or empty for native
and is used with that contract in Tasks 3, 4, 5, and 6. `cp_resolve` emits
`<name><TAB><reason>` and is consumed with `cut -f1` / `cut -f2` everywhere.
`cp_auth_status` always emits valid JSON, so every caller can pipe it to `jq`
without guarding.
