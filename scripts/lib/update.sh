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
