#!/usr/bin/env bash
# shellcheck shell=bash
# Self-update: refresh the plugin's marketplace listing, then update the
# plugin itself.
#
# Always runs with CLAUDE_CONFIG_DIR unset, regardless of the active or
# default profile. This is not a profile choice: share.sh links every
# profile's plugins/ back to ~/.claude/plugins, so a plugin's recorded
# installLocation is always relative to the native ~/.claude, and
# 'claude plugin marketplace update' rejects that recorded path from any
# directory that resolves to a non-native profile ("corrupted
# installLocation"). Unsetting the variable runs the update as if no profile
# were active at all, which is the one place the path always matches.

cp_cmd_update() {
  local rc=0
  if ! env -u CLAUDE_CONFIG_DIR "$CP_CLAUDE_BIN" plugin marketplace update "$CP_MARKETPLACE"; then
    cp_warn "marketplace update failed for $CP_MARKETPLACE"
    rc=1
  fi
  if ! env -u CLAUDE_CONFIG_DIR "$CP_CLAUDE_BIN" plugin update "$CP_PLUGIN_SCOPED"; then
    cp_warn "plugin update failed for $CP_PLUGIN_SCOPED"
    rc=1
  fi
  [ "$rc" -eq 0 ] && printf 'restart Claude Code to apply the update\n'
  return "$rc"
}

# Version skew between the cprof on PATH and the newest installed plugin.
#
# The two halves update through different channels — the CLI through Homebrew
# or the curl installer, the plugin through `cprof update` — so they drift, and
# the drift is invisible: an interactive shell may reach the plugin's own copy
# through a resolver function while every subprocess Claude Code spawns gets
# whatever `PATH` holds. A statusline wired to `cprof statusline` then renders
# nothing at all when the CLI on PATH predates that subcommand.

# True when a version is a plain dotted number, the only shape worth comparing.
# A dev build or a pre-release tag is deliberately not comparable, so it never
# produces advice.
cp_ver_parseable() {
  case "${1:-}" in
    ''|*[!0-9.]*|*..*|.*|*.) return 1 ;;
    *) return 0 ;;
  esac
}

# cp_ver_lt <a> <b> — true when a is strictly older than b, compared segment
# by segment as numbers. String order would rank 0.9.0 above 0.13.0, which is
# exactly the skew this check exists to catch.
cp_ver_lt() {
  local a="${1:-}" b="${2:-}" i=1 ai bi
  cp_ver_parseable "$a" || return 1
  cp_ver_parseable "$b" || return 1
  while [ "$i" -le 4 ]; do
    ai="$(printf '%s' "$a" | cut -d. -f"$i")"
    bi="$(printf '%s' "$b" | cut -d. -f"$i")"
    # A missing segment reads as zero, so 0.13 and 0.13.0 are equal. 10# keeps
    # a zero-padded segment decimal rather than octal.
    ai=$((10#0${ai:-0}))
    bi=$((10#0${bi:-0}))
    [ "$ai" -lt "$bi" ] && return 0
    [ "$ai" -gt "$bi" ] && return 1
    i=$((i + 1))
  done
  return 1
}

# The newest cprof version installed as a plugin, or empty when none is.
# Reads each manifest rather than trusting the directory name, and ignores one
# it cannot parse: a corrupt manifest is not evidence of a version.
cp_plugin_version() {
  local f v newest=''
  for f in "$HOME"/.claude/plugins/cache/*/cprof/*/plugin.json; do
    [ -r "$f" ] || continue
    v="$(jq -r '.version // empty' "$f" 2>/dev/null)" || continue
    cp_ver_parseable "$v" || continue
    if [ -z "$newest" ] || cp_ver_lt "$newest" "$v"; then
      newest="$v"
    fi
  done
  printf '%s' "$newest"
}

# cp_skew_report <path-version> <plugin-version> <path-to-cli>
#
# Prints at most one advisory line. Both versions reach this from outside — one
# from a binary's stdout, one from a JSON file — so neither is echoed unless it
# parsed as a dotted number, which is what keeps a control byte in either from
# reaching the report.
cp_skew_report() {
  local pv="${1:-}" gv="${2:-}" where="${3:-}"
  where="$(printf '%s' "$where" | LC_ALL=C tr -d '\000-\037\177')"
  # No cprof on PATH is a supported install (the plugin carries its own), and
  # no plugin installed leaves nothing to compare against.
  [ -n "$where" ] || return 0
  cp_ver_parseable "$gv" || return 0
  if ! cp_ver_parseable "$pv"; then
    printf 'could not read the version of the cprof at %s - skipping the version check\n' \
      "$where"
    return 0
  fi
  if cp_ver_lt "$pv" "$gv"; then
    printf 'cprof on PATH is %s; the installed plugin is %s - run: brew upgrade dcotelo/tap/cprof\n' \
      "$pv" "$gv"
  elif cp_ver_lt "$gv" "$pv"; then
    printf 'the installed plugin is %s; cprof on PATH is %s - run: cprof update\n' \
      "$gv" "$pv"
  fi
}

# Resolves both versions and reports. `type -P` deliberately ignores functions
# and aliases: the question is what a subprocess would run, not what this
# shell resolves.
#
# CP_CPROF_BIN overrides the lookup, the same seam CP_CLAUDE_BIN and
# CP_CURL_BIN provide for their tools. Set and empty means "no cprof on PATH",
# which a test cannot otherwise arrange on a machine that has one installed.
cp_skew_problems() {
  local bin pv
  bin="${CP_CPROF_BIN-$(type -P cprof 2>/dev/null)}" || bin=''
  [ -n "$bin" ] || return 0
  pv="$("$bin" version 2>/dev/null | head -1 | awk '{print $2}')" || pv=''
  cp_skew_report "$pv" "$(cp_plugin_version)" "$bin"
}
