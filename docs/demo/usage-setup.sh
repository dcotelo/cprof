# shellcheck shell=bash
# Sourced by usage.tape before recording. Runs the real CLI against a
# sandboxed HOME with two file-backed profiles, a stub `claude` (answers
# `auth status`) and a stub `curl` (answers the usage endpoint per token), so
# the GIF shows genuine rendering — bars, colours, table alignment — without
# touching a real account or the network. HOME is a fresh temp dir per run.
DEMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DEMO_ROOT/../.." && pwd)"
HOME="$(mktemp -d "${TMPDIR:-/tmp}/cprof-usage-demo.XXXXXX")"
export HOME
# Nothing from the recording shell may steer the demo: no profile override,
# no config or state outside this HOME, no usage opt-out or endpoint override.
unset CLAUDE_PROFILE CLAUDE_CONFIG_DIR
unset CPROF_CONFIG CLAUDEPROFILE_CONFIG CPROF_STATE_DIR CLAUDEPROFILE_STATE_DIR
unset CPROF_NO_USAGE CP_USAGE_URL
mkdir -p "$HOME/.claude-profiles/work" "$HOME/.claude-profiles/personal" "$HOME/dev/acme/api"
printf '{"claudeAiOauth":{"accessToken":"tok-work","refreshTokenExpiresAt":99999999999999}}' \
  > "$HOME/.claude-profiles/work/.credentials.json"
printf '{"claudeAiOauth":{"accessToken":"tok-personal","refreshTokenExpiresAt":99999999999999}}' \
  > "$HOME/.claude-profiles/personal/.credentials.json"
cat > "$HOME/.cprof.json" <<JSON
{"default":"personal",
 "profiles":[{"name":"work","dir":"$HOME/.claude-profiles/work","note":"team"},
             {"name":"personal","dir":"$HOME/.claude-profiles/personal","note":"max"}],
 "rules":[{"path":"$HOME/dev/acme","profile":"work"}],"repos":{}}
JSON
export CP_CLAUDE_BIN="$DEMO_ROOT/usage-bin/claude"
export CP_CURL_BIN="$DEMO_ROOT/usage-bin/curl"
export CPROF_COLOR=always
export PATH="$REPO_ROOT/scripts:$PATH"
PS1='$ '
cd "$HOME" || return
