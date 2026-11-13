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

# cp_share_check <dir>: how far a shared profile has drifted from the source.
# One line per asset the source has, "<asset><TAB><state>", in CP_SHARED_ASSETS
# order, where state is
#   ok       a link to the source's copy
#   drifted  a regular file or directory where that link should be -- what a
#            settings save that writes a temp file and renames it over the link
#            leaves behind
#   missing  nothing there: the asset appeared in the source after the share
#   foreign  a link, but to somewhere else
# A profile with no link into the source at all is not shared, so it prints
# nothing: that covers --isolated, unshare, the source itself, and a directory
# that does not exist. Reads only link targets and file types; never fails.
cp_share_check() {
  local dir="${1:-}" src asset target state rows='' linked=0
  src="$(cp_share_source)"
  [ -d "$dir" ] && [ -d "$src" ] || return 0
  [ "$(cd "$dir" && pwd -P)" = "$(cd "$src" && pwd -P)" ] && return 0
  for asset in $CP_SHARED_ASSETS; do
    [ -e "$src/$asset" ] || continue
    target="$dir/$asset"
    if [ -L "$target" ]; then
      if [ "$(readlink "$target")" = "$src/$asset" ]; then
        state=ok; linked=1
      else
        state=foreign
      fi
    elif [ -e "$target" ]; then
      state=drifted
    else
      state=missing
    fi
    rows="$rows$asset	$state
"
  done
  [ "$linked" = 1 ] || return 0
  printf '%s' "$rows"
}

# cp_share_drift_summary <dir>: the assets of a shared profile that are not
# following the source, as one phrase each joined with ", " -- e.g.
# "settings.json (replaced by a file), CLAUDE.md (not linked)" -- or nothing
# when the profile is healthy or not shared. Asset names come from
# CP_SHARED_ASSETS, never from the filesystem, so the text is safe to print.
cp_share_drift_summary() {
  local dir="${1:-}" asset state out='' phrase
  while IFS='	' read -r asset state; do
    case "$state" in
      drifted)
        if [ -d "$dir/$asset" ]; then phrase='replaced by a directory'; else phrase='replaced by a file'; fi ;;
      missing) phrase='not linked' ;;
      foreign) phrase='links elsewhere' ;;
      *) continue ;;
    esac
    out="${out:+$out, }$asset ($phrase)"
  done <<EOF
$(cp_share_check "$dir")
EOF
  [ -z "$out" ] || printf '%s\n' "$out"
}

# cp_share_key_diff <old> <source-copy>: how a settings file moved aside
# differed from the source copy, by top-level key name only -- values can hold
# tokens, so they are never printed, and neither are nested names. Prints
# "differs from ~/.claude in: a, b; only in the old copy: c; only in ~/.claude:
# d" (each part only when it has names), "matches ~/.claude" when all three are
# empty, or nothing when either file is not a single JSON object. A key
# that is not plain printable ASCII is counted rather than echoed, so a crafted
# name cannot drive the terminal.
cp_share_key_diff() {
  local old="${1:-}" new="${2:-}"
  [ -r "$old" ] && [ -r "$new" ] || return 0
  # shellcheck disable=SC2016  # a jq program, not shell
  jq -r -n --slurpfile o "$old" --slurpfile n "$new" '
    def plain: explode | all(. > 32 and . < 127);
    def names: (map(select(plain)) | join(", ")) as $shown
      | (map(select(plain | not)) | length) as $hidden
      | if $hidden == 0 then $shown
        elif $shown == "" then "\($hidden) unprintable key(s)"
        else "\($shown) and \($hidden) unprintable key(s)" end;
    if ($o | length) != 1 or ($n | length) != 1
       or ($o[0] | type) != "object" or ($n[0] | type) != "object" then empty
    else
      $o[0] as $a | $n[0] as $b
      | [$a | keys[] as $k | select(($b | has($k)) and $b[$k] != $a[$k]) | $k] as $differ
      | [$a | keys[] as $k | select($b | has($k) | not) | $k] as $only
      | [$b | keys[] as $k | select($a | has($k) | not) | $k] as $missing
      | if ($differ | length) == 0 and ($only | length) == 0 and ($missing | length) == 0
        then "matches ~/.claude"
        else [ (if ($differ | length) > 0 then "differs from ~/.claude in: \($differ | names)" else empty end),
               (if ($only | length) > 0 then "only in the old copy: \($only | names)" else empty end),
               (if ($missing | length) > 0 then "only in ~/.claude: \($missing | names)" else empty end) ]
             | join("; ")
        end
    end' 2>/dev/null
}

cp_cmd_share() {
  local cfg name="${1:-}" dir src asset target moved rows='' notes='' diff
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
      # A settings file that drifted may hold changes made from inside the
      # profile; name the keys, so nothing is lost without being seen.
      case "$asset" in
        *.json)
          diff="$(cp_share_key_diff "$moved" "$src/$asset")"
          [ -z "$diff" ] || notes="$notes$(basename "$moved"): $diff
"
          ;;
      esac
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
  [ -z "$notes" ] || printf '%s' "$notes"
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
