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

# Names the profile this process is actually running as, derived from the live
# CLAUDE_CONFIG_DIR rather than from resolution. Prints one of: a profile name,
# 'unknown' (config dir belongs to no profile), or 'stock' (no config dir and no
# native profile).
cp_cmd_status() {
  local cfg name
  cfg="$(cp_config_read)" || return 1
  if [ -z "${CLAUDE_CONFIG_DIR:-}" ]; then
    name="$(printf '%s' "$cfg" | jq -r 'first(.profiles[]? | select(.native == true) | .name) // empty')"
    printf '%s\n' "${name:-stock}"
    return 0
  fi
  name="$(printf '%s' "$cfg" | jq -r --arg d "$(cp_path_normalize "$CLAUDE_CONFIG_DIR")" \
    'first(.profiles[]? | select((.dir // "") != "") | select((.dir | sub("^~"; env.HOME)) == $d) | .name) // empty')"
  printf '%s\n' "${name:-unknown}"
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
