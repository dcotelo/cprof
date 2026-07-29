#!/usr/bin/env bash
# shellcheck shell=bash
# Sharing customisations across profiles.
#
# CLAUDE_CONFIG_DIR relocates the whole configuration directory, not just the
# credentials in it. Plugins, skills, agents, commands, hooks, settings and
# memory all live there, so a profile pointed at its own directory starts with
# none of them — the account switches and every customisation disappears with it.
#
# The fix is a symlink per shared asset, pointing back at the stock ~/.claude.
# Symlinks rather than copies: installing a plugin or editing settings once then
# applies to every profile, with nothing to re-sync.

# Assets shared between profiles: configuration and customisation, nothing that
# says who you are or what you did. Anything absent from this list stays
# per-profile, which is what keeps two accounts apart: the credentials (a
# per-config-dir keychain item since Claude Code 2.1, .credentials.json before
# it), .claude.json, projects, sessions, history.jsonl, todos, and the caches.
CP_SHARED_ASSETS='settings.json keybindings.json CLAUDE.md plugins skills agents commands hooks'

# The directory the shared assets come from. Stock Claude Code always reads this
# path when CLAUDE_CONFIG_DIR is unset, which is exactly what a native profile
# runs as, so it is the one copy every other profile borrows from.
cp_share_source() {
  printf '%s\n' "$HOME/.claude"
}

# Resolves the profile a share command applies to, rejecting the cases where
# sharing is meaningless: no name, no such profile, or the native profile, which
# already runs directly out of the source directory.
cp_share_target_dir() {
  local cfg="$1" name="$2" dir
  if [ -z "$name" ]; then
    cp_warn 'share: missing profile name'
    return 2
  fi
  if ! cp_profile_exists "$cfg" "$name"; then
    cp_warn "unknown profile $name"
    return 1
  fi
  if cp_profile_is_native "$cfg" "$name"; then
    cp_warn "profile $name is native; it already uses $(cp_share_source) directly"
    return 1
  fi
  dir="$(cp_profile_dir "$cfg" "$name")"
  if [ -z "$dir" ]; then
    cp_warn "profile $name has no directory"
    return 1
  fi
  printf '%s\n' "$dir"
}

cp_cmd_share() {
  local cfg name="${1:-}" dir src asset target moved rows=''
  cfg="$(cp_config_read)" || return 1
  src="$(cp_share_source)"
  dir="$(cp_share_target_dir "$cfg" "$name")" || return $?

  if [ ! -d "$src" ]; then
    cp_warn "no configuration directory at $src to share from"
    return 1
  fi
  mkdir -p "$dir" || return 1

  for asset in $CP_SHARED_ASSETS; do
    target="$dir/$asset"
    # Only assets that exist upstream: linking a name that is not there yet would
    # leave a dangling link, and Claude Code would create the real thing later.
    if [ ! -e "$src/$asset" ]; then
      continue
    fi
    if [ -L "$target" ] && [ "$(readlink "$target")" = "$src/$asset" ]; then
      rows="$rows$asset	kept
"
      continue
    fi
    if [ -L "$target" ]; then
      rm -f "$target"
      ln -s "$src/$asset" "$target" || return 1
      rows="$rows$asset	relinked
"
      continue
    fi
    if [ -e "$target" ]; then
      # Never destroy what the profile already accumulated; move it aside under a
      # name that says where it came from, and report the move.
      moved="$target.moved-$(date +%Y%m%d-%H%M%S)"
      mv "$target" "$moved" || return 1
      ln -s "$src/$asset" "$target" || return 1
      rows="$rows$asset	linked (previous kept as $(basename "$moved"))
"
      continue
    fi
    ln -s "$src/$asset" "$target" || return 1
    rows="$rows$asset	linked
"
  done

  if [ -z "$rows" ]; then
    printf 'nothing to share from %s\n' "$src"
    return 0
  fi
  {
    printf 'ASSET\tRESULT\n'
    printf '%s' "$rows"
  } | cp_table
}

cp_cmd_unshare() {
  local cfg name="${1:-}" dir src asset target rows=''
  cfg="$(cp_config_read)" || return 1
  src="$(cp_share_source)"
  dir="$(cp_share_target_dir "$cfg" "$name")" || return $?

  for asset in $CP_SHARED_ASSETS; do
    target="$dir/$asset"
    # Only links this tool made: a real file or directory in the profile is its
    # own, and a link somewhere else belongs to whoever made it.
    if [ -L "$target" ] && [ "$(readlink "$target")" = "$src/$asset" ]; then
      rm -f "$target"
      rows="$rows$asset	unlinked
"
    fi
  done

  if [ -z "$rows" ]; then
    printf 'no shared assets in %s\n' "$dir"
    return 0
  fi
  {
    printf 'ASSET\tRESULT\n'
    printf '%s' "$rows"
  } | cp_table
  printf 'the profile now starts without these; %s still has them\n' "$src"
}
