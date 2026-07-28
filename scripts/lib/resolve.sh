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
