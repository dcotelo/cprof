#!/usr/bin/env bash
# shellcheck shell=bash
# The full statusline: everything cprof can say about a session, rendered by
# one process. `cprof statusline` is the entry point; statusline/segment.sh
# --full is a thin wrapper around it.
#
# Claude Code re-runs a statusline every few seconds, so this file spends
# processes carefully: one jq pass for the payload metadata, one for the usage
# figures, and two git calls only when a working tree is actually there.

# cp_sl_meta_fields: a Claude Code statusline payload on stdin -> either
# nothing at all, or exactly two tab-separated fields, the model display name
# and the current directory. Callers read both with `cut`, which yields an
# empty field either way, so a malformed payload needs no special case here.
cp_sl_meta_fields() {
  jq -r '
    def s(v): if (v|type) == "string" and (v|length) > 0 and (v|length) <= 200
              then v else "" end;
    [s(.model.display_name), s(.workspace.current_dir // .cwd)] | @tsv
  ' 2>/dev/null
}

# cp_sl_dir_label <dir> -> what to show for it: the last path segment, or ~
# for the home directory itself. A statusline has one line to spend, and the
# leading path is the part that is the same in every session.
cp_sl_dir_label() {
  local dir="${1:-}"
  [ -n "$dir" ] || return 0
  [ "$dir" = "$HOME" ] && { printf '~\n'; return 0; }
  printf '%s\n' "${dir##*/}"
}

# cp_sl_git_fields <dir> -> "<branch>\t<dirty>", nothing when <dir> is not in
# a working tree. `dirty` is `*` or empty.
cp_sl_git_fields() {
  local dir="${1:-}" branch='' dirty=''
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  command -v git >/dev/null 2>&1 || return 0
  # An unborn branch (a fresh `git init`) has no HEAD to resolve, so
  # rev-parse fails where symbolic-ref still answers. A detached HEAD is the
  # other way round: symbolic-ref fails and the short sha is what to show.
  branch="$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null)" \
    || branch="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)" \
    || return 0
  [ -n "$branch" ] || return 0
  # The first line of output is all it takes to know the tree is not clean,
  # and stopping there keeps the cost bounded on a large repository.
  [ -n "$(git -C "$dir" status --porcelain 2>/dev/null | head -1)" ] && dirty='*'
  printf '%s\t%s\n' "$branch" "$dirty"
}

# cp_sl_bar <bar> <sgr-code> -> the bar with its filled run in the severity
# colour and the remainder dim, so the empty part reads as background rather
# than as a second value. Plain when there is no colour to use.
cp_sl_bar() {
  local bar="${1:-}" code="${2:-}" filled rest
  if [ -z "$bar" ] || [ -z "$code" ]; then
    printf '%s\n' "$bar"
    return 0
  fi
  filled="${bar%%░*}"
  rest="${bar#"$filled"}"
  printf '\033[%sm%s\033[2m%s\033[0m\n' "$code" "$filled" "$rest"
}

# cp_cmd_statusline [--stdin]: the whole statusline, one line or two.
#
# Line one names the account, then the model and the directory with its git
# branch. Line two carries the context and usage bars. Everything but the
# account needs the payload, so without --stdin this is the badge plus
# whatever usage the profile has cached — exactly what the segment printed
# before this command existed.
#
# Colour is decided here the way the segment decides it, on NO_COLOR alone,
# rather than through cp_color_enabled: a statusline's stdout is a pipe, so
# the `[ -t 1 ]` test in that helper would turn colour off in the one place
# it is always wanted.
cp_cmd_statusline() {
  local read_stdin=0 payload='' cfg name colour code text sep=''
  local meta model dir dir_label git_fields branch dirty
  local u_pct u_bar u_code u_reset c_pct c_bar c_code
  local line1 line2='' colour_on=1

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --stdin) read_stdin=1; shift ;;
      *)       cp_warn "statusline: unknown flag $1"; return 2 ;;
    esac
  done
  [ -z "${NO_COLOR+set}" ] || colour_on=0
  [ "$read_stdin" -eq 1 ] && [ ! -t 0 ] && payload="$(cat 2>/dev/null)"

  cfg="$(cp_config_read 2>/dev/null)" || cfg=''
  name="$(CPROF_COLOR=never cp_cmd_status 2>/dev/null)" || return 0
  case "$name" in ''|stock) return 0 ;; esac

  colour="$(cp_color_for "$cfg" "$name" 2>/dev/null)"
  code="$(cp_color_code "$colour" 2>/dev/null)"
  text="$(printf '%s' "$cfg" | jq -r 'if .colorText == false then "off" else "on" end' 2>/dev/null)"
  [ -n "$text" ] || text='off'

  if [ "$colour_on" -eq 0 ]; then
    line1="⚑ $name"
    sep=' │ '
  else
    sep="$(printf '\033[2m │ \033[0m')"
    if [ -z "$code" ]; then
      line1="$(printf '\033[2m⚑ %s\033[0m' "$name")"
    elif [ "$text" = 'on' ]; then
      line1="$(printf '\033[%sm⚑ %s\033[0m' "$code" "$name")"
    else
      line1="$(printf '\033[%sm⚑\033[0m \033[2m%s\033[0m' "$code" "$name")"
    fi
  fi

  if [ -n "$payload" ]; then
    meta="$(printf '%s' "$payload" | cp_sl_meta_fields)"
    model="$(printf '%s' "$meta" | cut -f1)"
    dir="$(printf '%s' "$meta" | cut -f2)"
  fi

  if [ -n "${model:-}" ]; then
    if [ "$colour_on" -eq 1 ]; then
      line1="$line1$sep$(printf '\033[36m[%s]\033[0m' "$model")"
    else
      line1="${line1}${sep}[$model]"
    fi
  fi

  dir_label="$(cp_sl_dir_label "${dir:-}")"
  if [ -n "$dir_label" ]; then
    if [ "$colour_on" -eq 1 ]; then
      line1="$line1$sep$(printf '\033[33m%s\033[0m' "$dir_label")"
    else
      line1="$line1$sep$dir_label"
    fi
    git_fields="$(cp_sl_git_fields "$dir")"
    if [ -n "$git_fields" ]; then
      branch="$(printf '%s' "$git_fields" | cut -f1)"
      dirty="$(printf '%s' "$git_fields" | cut -f2)"
      if [ "$colour_on" -eq 1 ]; then
        line1="$line1 $(printf '\033[35mgit:(\033[0m\033[36m%s%s\033[0m\033[35m)\033[0m' "$branch" "$dirty")"
      else
        line1="$line1 git:($branch$dirty)"
      fi
    fi
  fi

  # The bars come from the same renderer the one-line segment uses, so the
  # two entry points can never disagree about a percentage or a colour.
  if [ -n "$payload" ]; then
    u_pct="$(printf '%s' "$payload" | cp_usage_render_fields "$name" --stdin)"
  else
    u_pct="$(cp_usage_render_fields "$name" </dev/null)"
  fi
  c_code="$(printf '%s' "$u_pct" | cut -f7)"
  c_bar="$(printf '%s' "$u_pct" | cut -f6)"
  c_pct="$(printf '%s' "$u_pct" | cut -f5)"
  u_reset="$(printf '%s' "$u_pct" | cut -f4)"
  u_code="$(printf '%s' "$u_pct" | cut -f3)"
  u_bar="$(printf '%s' "$u_pct" | cut -f2)"
  u_pct="$(printf '%s' "$u_pct" | cut -f1)"

  if [ -n "$c_pct" ]; then
    if [ "$colour_on" -eq 1 ]; then
      line2="$(printf '\033[2mContext\033[0m %s \033[%sm%s%%\033[0m' "$(cp_sl_bar "$c_bar" "$c_code")" "$c_code" "$c_pct")"
    else
      line2="Context $c_bar $c_pct%"
    fi
  fi
  if [ -n "$u_pct" ]; then
    [ -n "$line2" ] && line2="$line2$sep"
    if [ "$colour_on" -eq 1 ]; then
      line2="$line2$(printf '\033[2mUsage\033[0m %s \033[%sm%s%%\033[0m' "$(cp_sl_bar "$u_bar" "$u_code")" "$u_code" "$u_pct")"
      [ -n "$u_reset" ] && line2="$line2$(printf ' \033[2m(resets in %s)\033[0m' "$u_reset")"
    else
      line2="${line2}Usage $u_bar $u_pct%"
      [ -n "$u_reset" ] && line2="$line2 (resets in $u_reset)"
    fi
  fi

  printf '%s\n' "$line1"
  [ -n "$line2" ] && printf '%s\n' "$line2"
  return 0
}
