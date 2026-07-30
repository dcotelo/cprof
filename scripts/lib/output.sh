#!/usr/bin/env bash
# shellcheck shell=bash
# Shell-facing output: env exports, which, quoting.

# Shortens $HOME to ~ for display only. Never feed the result back to a command
# that resolves paths: rules and pins are stored and compared absolute.
#
# Both spellings of home are tried, because stored paths are physical while $HOME
# may be reached through a symlink — matching only the literal $HOME would print
# rule paths in full while profile directories shortened.
cp_path_display() {
  local p="$1" home_phys
  home_phys="$(cd "$HOME" 2>/dev/null && pwd -P)" || home_phys=''
  case "$p" in
    "$HOME")   printf '~\n'; return 0 ;;
    "$HOME"/*) printf '~%s\n' "${p#"$HOME"}"; return 0 ;;
  esac
  if [ -n "$home_phys" ]; then
    case "$p" in
      "$home_phys")   printf '~\n'; return 0 ;;
      "$home_phys"/*) printf '~%s\n' "${p#"$home_phys"}"; return 0 ;;
    esac
  fi
  printf '%s\n' "$p"
}

# Aligns tab-separated rows into columns two spaces apart, sizing each column to
# its widest cell so a long profile name cannot push a row out of alignment. A
# ragged row is fine: missing cells produce no padding, and no line keeps
# trailing whitespace. Cells may carry SGR colour: widths are measured on the
# text without its escapes, so colour never moves a column.
cp_table() {
  awk -F'\t' '
    {
      nf[NR] = NF
      for (i = 1; i <= NF; i++) {
        cell[NR, i] = $i
        # Colour is zero-width on screen but not in bytes. Measure the text
        # without its escapes, print the cell with them. \033 rather than \x1b:
        # the hex form is a gawk extension and the target is macOS awk.
        bare = $i
        gsub(/\033\[[0-9;]*m/, "", bare)
        if (length(bare) > w[i]) w[i] = length(bare)
      }
    }
    END {
      for (r = 1; r <= NR; r++) {
        line = ""
        for (i = 1; i <= nf[r]; i++) {
          line = line cell[r, i]
          if (i < nf[r]) {
            bare = cell[r, i]
            gsub(/\033\[[0-9;]*m/, "", bare)
            pad = w[i] - length(bare) + 2
            while (pad-- > 0) line = line " "
          }
        }
        sub(/[ \t]+$/, "", line)
        print line
      }
    }'
}

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

# Names the profile this process is actually running as, derived from the live
# CLAUDE_CONFIG_DIR rather than from resolution. Prints one of: a profile name,
# 'unknown' (config dir belongs to no profile), or 'stock' (no config dir and no
# native profile).
cp_cmd_status() {
  local cfg dir name
  cfg="$(cp_config_read)" || return 1
  if [ -z "${CLAUDE_CONFIG_DIR:-}" ]; then
    printf '%s\n' "$(cp_native_name "$cfg" 'stock')"
    return 0
  fi
  dir="$(cp_path_normalize "$CLAUDE_CONFIG_DIR")"
  name="$(printf '%s' "$cfg" | jq -r --arg d "$dir" \
    'first(.profiles[]? | select((.dir // "") != "") | select((.dir | sub("^~"; env.HOME)) == $d) | .name) // empty')"
  # A native profile is stored without a dir, because native means "runs when
  # CLAUDE_CONFIG_DIR is unset". Something else exporting the stock path is
  # still that profile, so match it explicitly rather than reporting unknown.
  if [ -z "$name" ] && [ "$dir" = "$(cp_path_normalize "$(cp_share_source)")" ]; then
    name="$(cp_native_name "$cfg" '')"
  fi
  printf '%s\n' "${name:-unknown}"
}

# The native profile's name, or $2 when no profile is marked native.
cp_native_name() {
  local name
  name="$(printf '%s' "$1" | jq -r 'first(.profiles[]? | select(.native == true) | .name) // empty')"
  printf '%s\n' "${name:-$2}"
}

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
  {
    printf 'PROFILE\tPLAN\tACCOUNT\tFLAGS\n'
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
      printf '%s\t%s\t%s\t%s\n' "$name" "$sub" "$email" "${markers# }"
    done
  } | cp_table
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
  # The reason carries an absolute path for rule and pin matches; shorten the
  # path only, so the leading keyword still reads as one word.
  case "$reason" in
    'rule '*) reason="rule $(cp_path_display "${reason#rule }")" ;;
    'pin '*)  reason="pin $(cp_path_display "${reason#pin }")" ;;
  esac
  if cp_profile_is_native "$cfg" "$name"; then
    printf '%s\tnative (keychain)\t%s\n' "$name" "$reason" | cp_table
  else
    dir="$(cp_profile_dir "$cfg" "$name")"
    printf '%s\t%s\t%s\n' "$name" "$(cp_path_display "$dir")" "$reason" | cp_table
  fi
}
