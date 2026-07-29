#!/usr/bin/env bash
# shellcheck shell=bash
# Config mutations: add, default, pin, rule, remove.

cp_forbidden_dir() {
  local d="$1" home_claude
  home_claude="$(cp_path_normalize "$HOME/.claude")"
  [ "$(cp_path_normalize "$d")" = "$home_claude" ]
}

cp_cmd_add() {
  local name='' dir='' note='' native=0 isolated=0 cfg existing
  name="${1:-}"
  [ -n "$name" ] || { cp_warn 'add: missing profile name'; return 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dir)      dir="${2:-}"; shift 2 ;;
      --note)     note="${2:-}"; shift 2 ;;
      --native)   native=1; shift ;;
      --isolated) isolated=1; shift ;;
      *)          cp_warn "add: unknown flag $1"; return 2 ;;
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
     | if (.default == null) then .default = $n else . end' | cp_config_write || return 1

  # A profile directory is a whole configuration directory, so an unshared one
  # starts with no plugins, skills or settings. Link them by default: an account
  # switch should not also be a customisation switch.
  if [ "$isolated" -eq 0 ]; then
    cp_cmd_share "$name" >/dev/null || cp_warn "profile $name added, but sharing failed; run: claudeprofile share $name"
  fi
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

# Rules in the order resolution consults them: longest path prefix first. A rule
# naming a profile that no longer exists is flagged rather than dropped, since
# resolution skips it silently and the config still carries it.
cp_rule_list() {
  local cfg="$1" rows path name note
  rows="$(printf '%s' "$cfg" | jq -r '.rules[]? | [.path, .profile] | @tsv' \
    | awk -F'\t' '{ print length($1) "\t" $0 }' | sort -rn | cut -f2-)"
  if [ -z "$rows" ]; then
    printf 'no rules\n'
    return 0
  fi
  {
    printf 'PATH\tPROFILE\n'
    printf '%s\n' "$rows" | while IFS="$(printf '\t')" read -r path name; do
      note=''
      cp_profile_exists "$cfg" "$name" || note='(unknown profile)'
      printf '%s\t%s\t%s\n' "$(cp_path_display "$path")" "$name" "$note"
    done
  } | cp_table
}

cp_cmd_rule() {
  local sub="${1:-}" path name cfg
  [ -n "$sub" ] && shift
  cfg="$(cp_config_read)" || return 1
  case "$sub" in
    add)
      path="${1:-}"; name="${2:-}"
      if [ -z "$path" ] || [ -z "$name" ]; then
        cp_warn 'rule add: need <path> <profile>'
        return 2
      fi
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
      cp_rule_list "$cfg"
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
