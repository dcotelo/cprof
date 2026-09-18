# shellcheck shell=bash
# Sourced by statusline.tape before recording. Runs the real segment and CLI
# against a sandboxed HOME with one file-backed profile, a real git repo for
# the branch field, a stub `claude` (answers `auth status`), and a stub
# `date` that only fixes what `date +%s` answers (see statusline-bin/date),
# so the render — bars, colours, the reset countdown — is genuine without
# depending on the wall clock, the real HOME, or the real machine. HOME is a
# fresh temp dir per run.
DEMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DEMO_ROOT/../.." && pwd)"
HOME="$(mktemp -d "${TMPDIR:-/tmp}/cprof-statusline-demo.XXXXXX")"
export HOME
# Nothing from the recording shell may steer the demo: no profile override,
# no config or state outside this HOME, no usage opt-out surprise, no
# real usage fetch (the doctor beat cares about the rejected setting, not
# the network).
unset CLAUDE_PROFILE CLAUDE_CONFIG_DIR
unset CPROF_CONFIG CLAUDEPROFILE_CONFIG CPROF_STATE_DIR CLAUDEPROFILE_STATE_DIR
unset CP_USAGE_URL CPROF_FALLBACK_THRESHOLD
export CPROF_NO_USAGE=1
mkdir -p "$HOME/dev/acme/cprof"

# A real repository so the git segment has a real branch and a real dirty
# marker instead of a canned string.
git init -q -b main "$HOME/dev/acme/cprof"
git -C "$HOME/dev/acme/cprof" \
  -c user.email=demo@example.com -c user.name=demo -c commit.gpgsign=false \
  commit -q --allow-empty -m init
printf 'wip\n' > "$HOME/dev/acme/cprof/notes.txt"

# "work" is native (no `dir`, no credentials file): it is whatever profile
# is active when CLAUDE_CONFIG_DIR is unset, which is exactly this shell, so
# the badge and `cprof doctor`'s login check both resolve it without a
# CLAUDE_CONFIG_DIR override.
cat > "$HOME/.cprof.json" <<JSON
{"default":"work",
 "profiles":[{"name":"work","native":true,"color":"magenta"}],
 "rules":[],"repos":{}}
JSON

# The narrowed layout from the README's Statusline section, pre-written so
# the recording swaps configs with one short command instead of retyping a
# JSON block keystroke by keystroke.
cat > "$HOME/narrow-layout.cprof.json" <<JSON
{"default":"work",
 "profiles":[{"name":"work","native":true,"color":"magenta"}],
 "rules":[],"repos":{},
 "statusline":{"lines":[["badge","dir"],["usage"]],"bar":{"filled":"█","empty":"·","width":6}}}
JSON

# A config with one rejected statusline setting, for cprof doctor to report.
cat > "$HOME/bad-width.cprof.json" <<JSON
{"default":"work",
 "profiles":[{"name":"work","native":true,"color":"magenta"}],
 "rules":[],"repos":{},
 "statusline":{"bar":{"width":999}}}
JSON

# The Claude Code statusline payload: one session in that repo, at 37%
# context and 30% of its 5-hour window, resetting 2h19m after the fixture
# "now" the stubbed `date` answers — so "resets in 2h 19m" never depends on
# when this is recorded.
cat > "$HOME/session.json" <<JSON
{"cwd":"$HOME/dev/acme/cprof",
 "model":{"display_name":"Opus 5 (1M context)"},
 "context_window":{"used_percentage":37},
 "rate_limits":{"five_hour":{"used_percentage":30,"resets_at":1893464340}}}
JSON

export CP_CLAUDE_BIN="$DEMO_ROOT/statusline-bin/claude"
export CPROF_COLOR=always
export PATH="$DEMO_ROOT/statusline-bin:$REPO_ROOT/scripts:$PATH"
PS1='$ '
cd "$REPO_ROOT" || return
