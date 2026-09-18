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

# cp_sl_bar <bar> <sgr-code> <empty-glyph> -> the bar with its filled run in
# the severity colour and its remainder dim, so the empty part reads as
# background rather than as a second value. Plain when there is no colour.
# The empty glyph is a parameter because it is configurable: cutting at a
# hardcoded one would colour the whole bar as filled.
cp_sl_bar() {
  local bar="${1:-}" code="${2:-}" empty_g="${3:-░}" filled rest
  if [ -z "$bar" ] || [ -z "$code" ]; then
    printf '%s\n' "$bar"
    return 0
  fi
  filled="${bar%%"$empty_g"*}"
  rest="${bar#"$filled"}"
  printf '\033[%sm%s\033[2m%s\033[0m\n' "$code" "$filled" "$rest"
}

# cp_sl_config <cfg> -> four lines of resolved configuration:
#   1  layout:     segments space-separated, lines joined by ';'
#   2  bar:        filled<TAB>empty<TAB>width
#   3  thresholds: warn<TAB>critical
#   4  colours:    model<TAB>dir<TAB>git<TAB>branch<TAB>label   (names)
#
# One jq pass, so a tick spends one call here and the renderers never read a
# raw value. Every rejected value is replaced by its default and nothing is
# said about it: this runs every few seconds with its stderr discarded, so a
# warning here would be invisible and endless. `cprof doctor` does the
# reporting instead, from cp_sl_config_problems.
#
# Colour names, not SGR parameters: cp_color_code owns that mapping and knows
# the palette `cprof color` documents. `dim` is the one name it does not
# carry, and the renderers translate it. A colour name over 20 characters is
# rejected too: that length is not part of the documented palette, it is a
# defensive bound against an untrusted config, and it fails the same way
# every other rejected value does -- silently, to its default.
#
# Every default below is a shell variable, defined exactly once, passed into
# the jq program with --argjson/--arg and reused to build the `||` fallback
# for a config jq cannot even parse. That fallback derives its layout line
# from the same JSON the jq program uses, rather than a second hand-typed
# copy, so the two paths cannot silently drift apart.
cp_sl_config() {
  local cfg="${1:-}"
  local d_layout='[["badge","model","dir","git"],["context","usage"]]'
  local d_fill='▓' d_empty='░' d_width=10 d_warn=70 d_crit=90
  local d_model=cyan d_dir=yellow d_git=magenta d_branch=cyan d_label=dim
  [ -n "$cfg" ] || cfg='{}'
  printf '%s' "$cfg" | jq -r \
    --argjson deflayout "$d_layout" \
    --arg fill "$d_fill" --arg empty "$d_empty" \
    --argjson width "$d_width" --argjson warn "$d_warn" --argjson crit "$d_crit" \
    --arg model "$d_model" --arg dir "$d_dir" --arg git "$d_git" \
    --arg branch "$d_branch" --arg label "$d_label" '
    def known: ["badge","model","dir","git","context","usage"];
    def pick($v; $d): if ($v|type) == "string" and ($v|length) > 0 and ($v|length) < 20
                      then $v else $d end;
    def glyph($v; $d): if ($v|type) == "string" and ($v|length) == 1 then $v else $d end;
    def whole($v; $lo; $hi; $d): if ($v|type) == "number" and $v == ($v|floor)
                                    and $v >= $lo and $v <= $hi
                                 then $v else $d end;
    (.statusline // {}) as $s
    | (if ($s.lines|type) == "array" then $s.lines else [] end) as $raw
    | ([ $raw[] | select(type == "array")
         | [ .[] | select(type == "string") | select(. as $seg | known | index($seg)) ]
         | select(length > 0) ]) as $clean
    | (if ($clean|length) > 0 then $clean else $deflayout end) as $layout
    | ($s.bar // {}) as $b
    | ($s.thresholds // {}) as $t
    | ($s.colors // {}) as $c
    | (whole($t.warn; 1; 100; 0)) as $w
    | (whole($t.critical; 1; 100; 0)) as $cr
    | (if $w > 0 and $cr > 0 and $w < $cr then [$w, $cr] else [$warn, $crit] end) as $th
    | ([ $layout[] | join(" ") ] | join(";")),
      ([glyph($b.filled; $fill), glyph($b.empty; $empty),
        (whole($b.width; 1; 40; $width) | tostring)] | join("\t")),
      ($th | map(tostring) | join("\t")),
      ([pick($c.model; $model), pick($c.dir; $dir), pick($c.git; $git),
        pick($c.branch; $branch), pick($c.label; $label)] | join("\t"))
  ' 2>/dev/null || printf '%s\n%s\t%s\t%s\n%s\t%s\n%s\t%s\t%s\t%s\t%s\n' \
      "$(printf '%s' "$d_layout" | jq -r '[.[] | join(" ")] | join(";")')" \
      "$d_fill" "$d_empty" "$d_width" "$d_warn" "$d_crit" \
      "$d_model" "$d_dir" "$d_git" "$d_branch" "$d_label"
}

# cp_sl_config_problems <cfg> -> one line per rejected statusline setting,
# nothing when the block is absent or wholly valid. The statusline itself is
# silent by design (see cp_sl_config), so this is where a reader finds out
# that a setting did not take.
#
# Every section is type-checked before it is indexed. cp_sl_config can get
# away with indexing straight through, because a crash partway through its
# jq program is caught whole by its blanket `|| printf <defaults>` -- the
# entire resolved config falls back together, so nothing there depends on
# the jq program finishing normally. This function has no such net: a crash
# partway through would silently drop every report queued after the crash
# point, in a function whose entire purpose is to not be silent. So a wrongly
# typed `statusline`, `bar`, `thresholds` or `colors` value gets its own
# guard and its own line, naming the default the resolver actually falls
# back to, and one bad section can never suppress another's report.
cp_sl_config_problems() {
  local cfg="${1:-}" key name default kind colors_ok
  printf '%s' "$cfg" | jq -r '
    def whole($v; $lo; $hi): ($v|type) == "number" and $v == ($v|floor)
                             and $v >= $lo and $v <= $hi;
    def known: ["badge","model","dir","git","context","usage"];
    (.statusline // {}) as $s
    | if ($s|type) != "object" then
        "statusline: not a JSON object; using the default configuration"
      else
        ( if ($s|has("lines")) and ($s.lines|type) != "array"
          then "statusline.lines: not a list of segment lists; using the default layout"
          elif ($s.lines|type) == "array"
          then
            ( [ $s.lines[] | select(type == "array")
                | [ .[] | select(type == "string")
                    | select(. as $seg | known | index($seg)) ]
                | select(length > 0) ]
            ) as $clean
            | if ($clean|length) == 0
              then "statusline.lines: not a list of segment lists; using the default layout"
              else empty end
          else empty end ),
        ( if ($s.lines|type) == "array"
          then ( [ $s.lines[] | select(type == "array") | .[] | select(type == "string") ]
                 | map(select(. as $seg | known | index($seg) | not)) | unique | .[]
                 | "statusline.lines: unknown segment \(.) (known: badge model dir git context usage)" )
          else empty end ),
        ( ($s.bar // {}) as $b
          | if ($b|type) != "object"
            then "statusline.bar: not a JSON object; using ▓, ░ and 10"
            else empty end ),
        ( ($s.bar // {}) as $b
          | if ($b|type) == "object" then
              ( if ($b|has("filled")) and (($b.filled|type) != "string" or ($b.filled|length) != 1)
                then "statusline.bar.filled: must be exactly one character; using ▓" else empty end ),
              ( if ($b|has("empty")) and (($b.empty|type) != "string" or ($b.empty|length) != 1)
                then "statusline.bar.empty: must be exactly one character; using ░" else empty end ),
              ( if ($b|has("width")) and (whole($b.width; 1; 40) | not)
                then "statusline.bar.width: must be a whole number from 1 to 40; using 10" else empty end )
            else empty end ),
        ( if ($s|has("thresholds")) then
            ( if ($s.thresholds|type) != "object"
              then "statusline.thresholds: not a JSON object; using 70 and 90"
              else ( if ((whole($s.thresholds.warn; 1; 100) and whole($s.thresholds.critical; 1; 100)
                          and $s.thresholds.warn < $s.thresholds.critical) | not)
                     then "statusline.thresholds: warn must be a whole number below critical, both from 1 to 100; using 70 and 90"
                     else empty end )
              end )
          else empty end )
      end
  ' 2>/dev/null
  # Colours last, and in bash: cp_sl_code decides what a usable name is. A
  # colour value pick() would never even consider (wrong type, or 20
  # characters or more) never reaches that judgement -- it is reported
  # against the specific default pick() substitutes for that key, not as an
  # "unknown colour", which is reserved for a name pick() accepted as-is
  # that simply is not in the palette.
  colors_ok="$(printf '%s' "$cfg" | jq -r '
    (.statusline // {}) as $s
    | if ($s|type) != "object" then "skip"
      else ( ($s.colors // {}) as $c
             | if ($c|type) != "object" then "bad" else "ok" end )
      end
  ' 2>/dev/null)"
  case "$colors_ok" in
    bad)
      printf 'statusline.colors: not a JSON object; using the defaults: model cyan, dir yellow, git magenta, branch cyan, label dim\n'
      ;;
    ok)
      for key in model dir git branch label; do
        case "$key" in
          model)  default=cyan ;;
          dir)    default=yellow ;;
          git)    default=magenta ;;
          branch) default=cyan ;;
          label)  default=dim ;;
        esac
        kind="$(printf '%s' "$cfg" | jq -r --arg k "$key" '
          ((.statusline.colors // {})[$k]) as $v
          | if $v == null or $v == false then "skip"
            elif ($v|type) != "string" then "badtype"
            elif ($v|length) == 0 then "skip"
            elif ($v|length) >= 20 then "toolong"
            else "ok" end
        ' 2>/dev/null)"
        case "$kind" in
          skip) continue ;;
          badtype|toolong)
            printf 'statusline.colors.%s: not a usable colour name; using %s\n' "$key" "$default"
            continue
            ;;
        esac
        name="$(printf '%s' "$cfg" | jq -r --arg k "$key" '(.statusline.colors // {})[$k] // empty' 2>/dev/null)"
        [ -n "$(cp_sl_code "$name")" ] && continue
        printf 'statusline.colors.%s: unknown colour %s; rendering it plain\n' "$key" "$name"
      done
      ;;
  esac
}

# cp_sl_code <name> -> an SGR parameter for a configured colour name, or
# nothing when the name is not one cprof knows, in which case the caller
# renders the segment plain rather than dropping it. `dim` is handled here
# because it is an attribute rather than a colour, so cp_color_code, which
# owns the palette `cprof color` documents, does not carry it.
cp_sl_code() {
  case "${1:-}" in
    dim) printf '2\n' ;;
    *)   cp_color_code "${1:-}" ;;
  esac
}

# cp_sl_wants <layout> <segment> -> 0 when the layout names that segment,
# anywhere in any line. A helper rather than a pattern match on the layout
# string, which would have to special-case a segment at the start or end of
# a line.
cp_sl_wants() {
  local seg
  for seg in $(printf '%s' "${1:-}" | tr ';' ' '); do
    [ "$seg" = "${2:-}" ] && return 0
  done
  return 1
}

# cp_sl_assemble <layout> <sep>: prints one output line per configured line,
# skipping a line whose segments all came back empty. Each segment's
# rendered text comes from the shell variable CP_SL_<segment>, set by
# cp_cmd_statusline before calling this. `git` attaches to `dir` with a
# single space so that a directory and its branch read as one thing; every
# other adjacency takes the separator. A segment named more than once in a
# line renders every time it appears -- the layout is taken literally, not
# deduplicated.
cp_sl_assemble() {
  local layout="${1:-}" sep="${2:-}" line seg text out prev
  # A trailing newline before tr, not just the ';' separators, or the last
  # configured line reaches `read` as a no-newline EOF read: `read` returns
  # non-zero for it, and `while read` treats that as the end of input, so
  # the final line of the layout is silently dropped.
  printf '%s\n' "$layout" | tr ';' '\n' | while IFS= read -r line; do
    out=''; prev=''
    for seg in $line; do
      eval "text=\${CP_SL_$seg:-}"
      [ -n "$text" ] || continue
      if [ -z "$out" ]; then
        out="$text"
      elif [ "$seg" = git ] && [ "$prev" = dir ]; then
        out="$out $text"
      else
        out="$out$sep$text"
      fi
      prev="$seg"
    done
    [ -n "$out" ] && printf '%s\n' "$out"
  done
}

# cp_cmd_statusline [--stdin]: the whole statusline, laid out the way the
# resolved configuration says.
#
# Each segment renders into its own shell variable -- CP_SL_badge,
# CP_SL_model, CP_SL_dir, CP_SL_git, CP_SL_context, CP_SL_usage -- holding
# only that segment's own text, with no separator. cp_sl_assemble then walks
# the configured layout and joins what is there. A segment the layout does
# not name is never rendered at all, so an unconfigured git segment runs no
# git commands, and a segment with nothing to say leaves no stray separator.
#
# Colour is decided here the way the segment decides it, on NO_COLOR alone,
# rather than through cp_color_enabled: a statusline's stdout is a pipe, so
# the `[ -t 1 ]` test in that helper would turn colour off in the one place
# it is always wanted.
cp_cmd_statusline() {
  local read_stdin=0 payload='' cfg name colour code text sep=''
  local meta model dir dir_label git_fields branch dirty
  local u_pct u_bar u_code u_reset c_pct c_bar c_code
  local colour_on=1 config layout bar_cfg b_fill b_empty b_width
  local thresh_cfg th_warn th_crit
  local colors_cfg col_model col_dir col_git col_branch col_label
  local label_open='' label_close=''
  # These are read by cp_sl_assemble through `eval` on a name built from the
  # layout's own segment names, which is why nothing in this function appears
  # to use them.
  local CP_SL_badge='' CP_SL_model='' CP_SL_dir='' CP_SL_git=''
  local CP_SL_context='' CP_SL_usage=''

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

  config="$(cp_sl_config "$cfg")"
  layout="$(printf '%s' "$config" | sed -n '1p')"
  bar_cfg="$(printf '%s' "$config" | sed -n '2p')"
  b_fill="$(printf '%s' "$bar_cfg" | cut -f1)"
  b_empty="$(printf '%s' "$bar_cfg" | cut -f2)"
  b_width="$(printf '%s' "$bar_cfg" | cut -f3)"
  thresh_cfg="$(printf '%s' "$config" | sed -n '3p')"
  th_warn="$(printf '%s' "$thresh_cfg" | cut -f1)"
  th_crit="$(printf '%s' "$thresh_cfg" | cut -f2)"
  colors_cfg="$(printf '%s' "$config" | sed -n '4p')"
  col_model="$(cp_sl_code "$(printf '%s' "$colors_cfg" | cut -f1)" 2>/dev/null)"
  col_dir="$(cp_sl_code "$(printf '%s' "$colors_cfg" | cut -f2)" 2>/dev/null)"
  col_git="$(cp_sl_code "$(printf '%s' "$colors_cfg" | cut -f3)" 2>/dev/null)"
  col_branch="$(cp_sl_code "$(printf '%s' "$colors_cfg" | cut -f4)" 2>/dev/null)"
  col_label="$(cp_sl_code "$(printf '%s' "$colors_cfg" | cut -f5)" 2>/dev/null)"

  if [ "$colour_on" -eq 1 ] && [ -n "$col_label" ]; then
    label_open="$(printf '\033[%sm' "$col_label")"
    label_close="$(printf '\033[0m')"
  fi

  if [ "$colour_on" -eq 0 ]; then
    sep=' │ '
  elif [ -n "$col_label" ]; then
    sep="$(printf '\033[%sm │ \033[0m' "$col_label")"
  else
    sep=' │ '
  fi

  if cp_sl_wants "$layout" badge; then
    colour="$(cp_color_for "$cfg" "$name" 2>/dev/null)"
    code="$(cp_color_code "$colour" 2>/dev/null)"
    text="$(printf '%s' "$cfg" | jq -r 'if .colorText == false then "off" else "on" end' 2>/dev/null)"
    [ -n "$text" ] || text='off'
    if [ "$colour_on" -eq 0 ]; then
      CP_SL_badge="⚑ $name"
    elif [ -z "$code" ]; then
      CP_SL_badge="$(printf '\033[2m⚑ %s\033[0m' "$name")"
    elif [ "$text" = 'on' ]; then
      CP_SL_badge="$(printf '\033[%sm⚑ %s\033[0m' "$code" "$name")"
    else
      # shellcheck disable=SC2034 # read by cp_sl_assemble via eval
      CP_SL_badge="$(printf '\033[%sm⚑\033[0m \033[2m%s\033[0m' "$code" "$name")"
    fi
  fi

  if [ -n "$payload" ]; then
    meta="$(printf '%s' "$payload" | cp_sl_meta_fields)"
    model="$(printf '%s' "$meta" | cut -f1)"
    dir="$(printf '%s' "$meta" | cut -f2)"
  fi

  if cp_sl_wants "$layout" model && [ -n "${model:-}" ]; then
    if [ "$colour_on" -eq 1 ] && [ -n "$col_model" ]; then
      CP_SL_model="$(printf '\033[%sm[%s]\033[0m' "$col_model" "$model")"
    else
      # shellcheck disable=SC2034 # read by cp_sl_assemble via eval
      CP_SL_model="[$model]"
    fi
  fi

  if cp_sl_wants "$layout" dir; then
    dir_label="$(cp_sl_dir_label "${dir:-}")"
    if [ -n "$dir_label" ]; then
      if [ "$colour_on" -eq 1 ] && [ -n "$col_dir" ]; then
        CP_SL_dir="$(printf '\033[%sm%s\033[0m' "$col_dir" "$dir_label")"
      else
        # shellcheck disable=SC2034 # read by cp_sl_assemble via eval
        CP_SL_dir="$dir_label"
      fi
    fi
  fi

  if cp_sl_wants "$layout" git; then
    git_fields="$(cp_sl_git_fields "${dir:-}")"
    if [ -n "$git_fields" ]; then
      branch="$(printf '%s' "$git_fields" | cut -f1)"
      dirty="$(printf '%s' "$git_fields" | cut -f2)"
      if [ "$colour_on" -eq 1 ] && [ -n "$col_git" ] && [ -n "$col_branch" ]; then
        CP_SL_git="$(printf '\033[%smgit:(\033[0m\033[%sm%s%s\033[0m\033[%sm)\033[0m' \
          "$col_git" "$col_branch" "$branch" "$dirty" "$col_git")"
      else
        # shellcheck disable=SC2034 # read by cp_sl_assemble via eval
        CP_SL_git="git:($branch$dirty)"
      fi
    fi
  fi

  # The bars come from the same renderer the one-line segment uses, so the
  # two entry points can never disagree about a percentage or a colour. Only
  # spent when the layout actually asks for one of the two.
  if cp_sl_wants "$layout" context || cp_sl_wants "$layout" usage; then
    if [ -n "$payload" ]; then
      u_pct="$(printf '%s' "$payload" | cp_usage_render_fields "$name" --stdin)"
    else
      u_pct="$(cp_usage_render_fields "$name" </dev/null)"
    fi
    c_pct="$(printf '%s' "$u_pct" | cut -f5)"
    u_reset="$(printf '%s' "$u_pct" | cut -f4)"
    u_pct="$(printf '%s' "$u_pct" | cut -f1)"
    # The bars are redrawn here from the percentages with the configured
    # glyphs and width, rather than taking the pre-drawn ten-cell bar out of
    # cp_usage_render_fields, so the statusline can never disagree with the
    # tables about what a percentage looks like.
    u_bar="$(cp_usage_bar "$u_pct" "$b_fill" "$b_empty" "$b_width")"
    c_bar="$(cp_usage_bar "$c_pct" "$b_fill" "$b_empty" "$b_width")"
    # The colours are likewise derived here, from each bar's own percentage
    # and the configured thresholds, rather than taking cp_usage_render_fields'
    # SGR codes -- those are computed against the hardcoded 70/90 for the
    # helper's own callers, so reading them here would make a configured
    # threshold change nothing on screen.
    u_code="$(cp_color_code "$(cp_usage_severity_colour "$u_pct" "$th_warn" "$th_crit" 2>/dev/null)" 2>/dev/null)"
    c_code="$(cp_color_code "$(cp_usage_severity_colour "$c_pct" "$th_warn" "$th_crit" 2>/dev/null)" 2>/dev/null)"

    if cp_sl_wants "$layout" context && [ -n "$c_pct" ]; then
      if [ "$colour_on" -eq 1 ]; then
        CP_SL_context="$(printf '%sContext%s %s \033[%sm%s%%\033[0m' \
          "$label_open" "$label_close" "$(cp_sl_bar "$c_bar" "$c_code" "$b_empty")" "$c_code" "$c_pct")"
      else
        # shellcheck disable=SC2034 # read by cp_sl_assemble via eval
        CP_SL_context="Context $c_bar $c_pct%"
      fi
    fi
    if cp_sl_wants "$layout" usage && [ -n "$u_pct" ]; then
      if [ "$colour_on" -eq 1 ]; then
        CP_SL_usage="$(printf '%sUsage%s %s \033[%sm%s%%\033[0m' \
          "$label_open" "$label_close" "$(cp_sl_bar "$u_bar" "$u_code" "$b_empty")" "$u_code" "$u_pct")"
        [ -n "$u_reset" ] && CP_SL_usage="$CP_SL_usage$(printf ' %s(resets in %s)%s' "$label_open" "$u_reset" "$label_close")"
      else
        CP_SL_usage="Usage $u_bar $u_pct%"
        [ -n "$u_reset" ] && CP_SL_usage="$CP_SL_usage (resets in $u_reset)"
      fi
    fi
  fi

  cp_sl_assemble "$layout" "$sep"
  return 0
}
