#!/usr/bin/env bash
# shellcheck shell=bash
# `cprof config`: an fzf panel over the configuration. fzf owns the loop; the
# panel is three CLI callbacks it calls back into (--rows, --preview,
# --apply), so each one is a plain function testable without a terminal.
#
# A row is one line of seven tab-joined fields:
#
#   id  label  value  kind  constraint  action  state
#
#   kind        integer | glyph | color | segments | profile | screen
#   action      set | drill
#   state       set       written, and the resolver kept it
#               default   not written (absent, or an explicit null)
#               rejected  written, and the resolver used something else
#
# `value` is always the effective value -- what the statusline or the resolver
# actually uses -- never a raw rejected one. For the statusline it is read off
# cp_sl_config, not worked out again here: the resolver is the one judge of
# what a setting resolves to, and a second reading would drift from it.
#
# No field carries a character below 32. The rows are split on tabs and
# newlines by fzf and by the panel, and a profile name or a constraint is
# shown on a terminal, so anything invisible is dropped on the way out.

# cp_panel_rows <screen> [<cfg>] -> that screen's rows. Screens: main,
# statusline, statusline.lines. An unknown screen prints nothing, rc 2. <cfg>
# defaults to cp_config_read, whose rc 1 (and warning) passes through.
cp_panel_rows() {
  local screen="${1:-}" cfg eff
  case "$screen" in
    main|statusline|statusline.lines) ;;
    *) return 2 ;;
  esac
  if [ "$#" -ge 2 ]; then
    cfg="$2"
  else
    cfg="$(cp_config_read)" || return 1
  fi
  eff="$(cp_sl_config "$cfg")"
  cp_panel_rows_all "$cfg" "$eff" | awk -F'\t' -v s="$screen" \
    'BEGIN { OFS = "\t" } $1 == s { $1 = ""; sub(/^\t/, ""); print }'
}

# cp_panel_known_ids [<cfg>] -> every id on every screen, one per line, in
# screen order (main, statusline, statusline.lines).
cp_panel_known_ids() {
  local cfg
  if [ "$#" -ge 1 ]; then
    cfg="$1"
  else
    cfg="$(cp_config_read)" || return 1
  fi
  cp_panel_rows_all "$cfg" "$(cp_sl_config "$cfg")" | cut -f2
}

# cp_panel_rows_all <cfg> <cp_sl_config output> -> every row of every screen,
# each prefixed by its screen and a tab. One jq pass: a drill row's state
# depends on the rows under it, so they are built together.
cp_panel_rows_all() {
  local cfg="${1:-}" eff="${2:-}" colors
  colors="$(cp_color_names | tr '\n' ' ')dim"
  [ -n "$cfg" ] || cfg='{}'
  # shellcheck disable=SC2016 # a jq program: the $names are jq variables
  printf '%s' "$cfg" | jq -r --arg eff "$eff" --arg colors "$colors" \
    --arg segs "$CP_SL_SEGMENTS" '
    def clean: tostring | explode | map(select(. >= 32)) | implode;
    def row($screen; $id; $label; $value; $kind; $con; $action; $state):
      [$screen, $id, $label, $value, $kind, $con, $action, $state]
      | map(clean) | join("\t");
    # A key read only through an object, so a wrongly typed section reads as
    # "nothing written here" instead of crashing the whole pass.
    def at($o; $k): if ($o|type) == "object" then $o[$k] else null end;
    # Compared in the written value'"'"'s own representation: a width written
    # as "8" is a string, which the resolver rejects, so it is not 8.
    def state($w; $e): if $w == null then "default"
                       elif $w == $e then "set" else "rejected" end;
    # A section the resolver could not read as an object, although something
    # was written there.
    def badtype($v): $v != null and ($v|type) != "object";
    def lines($n): "\($n) line" + (if $n == 1 then "" else "s" end);

    ($eff | split("\n")) as $L
    | ($L[0] | split(";") | map(split(" "))) as $layout
    | ($L[1] | split("\t")) as $bar
    | ($L[2] | split("\t") | map(tonumber)) as $th
    | ($L[3] | split("\t")) as $col
    | ($L[4] | split("\t") | map(tonumber)) as $ag
    | .statusline as $s0
    | (if ($s0|type) == "object" then $s0 else {} end) as $s
    | at($s; "lines") as $wl
    | ($layout|length) as $n
    | [ range(0; $n) as $i
        | (if $wl == null then "default"
           elif ($wl|type) == "array" and $wl[$i] == $layout[$i] then "set"
           else "rejected" end) as $st
        | {id: "statusline.lines.\($i + 1)", label: "line \($i + 1)",
           value: ($layout[$i] | join(" ")), kind: "segments", con: $segs,
           action: "set", state: $st} ]
      + [ {id: "statusline.lines.\($n + 1)", label: "add a line", value: "",
           kind: "segments", con: $segs, action: "set", state: "default"} ]
      as $linerows
    | def int($id; $label; $sec; $k; $e; $lo; $hi):
        {id: $id, label: $label, value: $e, kind: "integer", con: "\($lo)..\($hi)",
         action: "set", state: state(at($sec; $k); $e)};
      def glyph($id; $label; $k; $e):
        {id: $id, label: $label, value: $e, kind: "glyph", con: "1 char",
         action: "set", state: state(at(at($s; "bar"); $k); $e)};
      def colour($id; $label; $k; $e):
        {id: $id, label: $label, value: $e, kind: "color", con: $colors,
         action: "set", state: state(at(at($s; "colors"); $k); $e)};
      ([ glyph("statusline.bar.filled"; "bar filled glyph"; "filled"; $bar[0]),
         glyph("statusline.bar.empty"; "bar empty glyph"; "empty"; $bar[1]),
         int("statusline.bar.width"; "bar width"; at($s; "bar"); "width";
             ($bar[2] | tonumber); 1; 40),
         int("statusline.thresholds.warn"; "warn threshold"; at($s; "thresholds");
             "warn"; $th[0]; 1; 100),
         int("statusline.thresholds.critical"; "critical threshold";
             at($s; "thresholds"); "critical"; $th[1]; 1; 100),
         int("statusline.weekly_threshold"; "weekly bar from (%)"; $s;
             "weekly_threshold"; $th[2]; 1; 100),
         colour("statusline.colors.model"; "model colour"; "model"; $col[0]),
         colour("statusline.colors.dir"; "dir colour"; "dir"; $col[1]),
         colour("statusline.colors.git"; "git colour"; "git"; $col[2]),
         colour("statusline.colors.branch"; "branch colour"; "branch"; $col[3]),
         colour("statusline.colors.label"; "label colour"; "label"; $col[4]),
         int("statusline.agents.stale_after"; "agents: hide after (s)";
             at($s; "agents"); "stale_after"; $ag[0]; 30; 86400),
         int("statusline.agents.keep_finished"; "agents: keep finished (s)";
             at($s; "agents"); "keep_finished"; $ag[1]; 0; 86400),
         int("statusline.agents.max_rows"; "agents: max rows";
             at($s; "agents"); "max_rows"; $ag[2]; 1; 20) ]) as $settings
    | ([ $linerows[] | select(.state == "rejected") ] | length > 0) as $lines_bad
    | {id: "statusline.lines", label: "lines", value: lines($n), kind: "screen",
       con: "-", action: "drill",
       state: (if $lines_bad then "rejected"
               elif $wl == null then "default" else "set" end)} as $linesdrill
    | ([$linesdrill] + $settings) as $slrows
    | (([ $slrows[] | select(.state == "rejected") ] | length > 0)
       or badtype($s0)
       or ([at($s; "bar"), at($s; "thresholds"), at($s; "colors"), at($s; "agents")]
           | map(badtype(.)) | any)) as $sl_bad
    | (if (.profiles|type) == "array"
       then [ .profiles[] | at(.; "name") | strings ] else [] end) as $names
    | .default as $d
    | (if ($d|type) == "string" and ([ $names[] | select(. == $d) ] | length > 0)
       then $d else "" end) as $deff
    | row("main"; "statusline"; "statusline"; lines($n); "screen"; "-"; "drill";
          (if $sl_bad then "rejected" elif $s0 == null then "default" else "set" end)),
      row("main"; "default"; "default profile"; $deff; "profile"; ($names | join(" "));
          "set"; (if $d == null then "default"
                 elif $deff != "" and $d == $deff then "set" else "rejected" end)),
      ($slrows[] | row("statusline"; .id; .label; .value; .kind; .con; .action; .state)),
      ($linerows[] | row("statusline.lines"; .id; .label; .value; .kind; .con; .action;
                         .state))
  '
}

# jq: a string that is all digits as a number, anything else as itself. An
# integer setting goes through this, so "8" is written as 8 while "abc" or
# "-1" stays a string the resolver rejects in its own words, rather than this
# panel coercing it into something the reader did not type.
CP_PANEL_JQ_NUM='def num: if length > 0
                            and (explode | map(select(. < 48 or . > 57)) | length) == 0
                          then tonumber else . end;'

# cp_panel_candidate <cfg> <id> <value> -> the config <cfg> would become with
# <value> written at <id>, as JSON on stdout. Pure: it writes nothing and
# judges nothing -- whether the candidate is acceptable is the resolver's call
# (see cp_panel_new_problems). rc 2 for an id that is not a setting; rc 1 when
# the value cannot be placed (a section on its path is not an object).
cp_panel_candidate() {
  local cfg="${1:-}" id="${2:-}" value="${3:-}" eff n th warn crit
  [ -n "$cfg" ] || cfg='{}'
  case "$id" in
    default)
      printf '%s' "$cfg" | jq --arg v "$value" '.default = $v' 2>/dev/null || return 1
      ;;
    statusline.lines.*)
      n="${id#statusline.lines.}"
      case "$n" in ''|0|*[!0-9]*) return 2 ;; esac
      # Always the effective layout, never the written `lines` array: the row
      # ids count effective lines, and the written array can hold entries the
      # resolver drops, so patching it by index could edit the wrong line. The
      # whole edited layout is written back. Empty removes line n; n = count+1
      # appends.
      eff="$(cp_sl_config "$cfg" | sed -n 1p)"
      # shellcheck disable=SC2016 # a jq program: the $names are jq variables
      printf '%s' "$cfg" | jq --arg lay "$eff" --arg n "$n" --arg v "$value" '
        ($lay | split(";") | map(split(" "))) as $L
        | (($n | tonumber) - 1) as $i
        | ($v | split(" ") | map(select(length > 0))) as $segs
        | (if ($segs | length) == 0
           then [ range(0; $L | length) as $j | select($j != $i) | $L[$j] ]
           elif $i < ($L | length) then ($L | .[$i] = $segs)
           else $L + [$segs] end) as $new
        | setpath(["statusline", "lines"]; $new)' 2>/dev/null || return 1
      ;;
    statusline.thresholds.warn|statusline.thresholds.critical)
      # The pair is judged together, so both keys are written: the one not
      # being set keeps the value the resolver uses for it now.
      th="$(cp_sl_config "$cfg" | sed -n 3p)"
      warn="$(printf '%s' "$th" | cut -f1)"
      crit="$(printf '%s' "$th" | cut -f2)"
      if [ "$id" = statusline.thresholds.warn ]; then warn="$value"; else crit="$value"; fi
      # shellcheck disable=SC2016 # a jq program: the $names are jq variables
      printf '%s' "$cfg" | jq --arg w "$warn" --arg c "$crit" "$CP_PANEL_JQ_NUM"'
        setpath(["statusline", "thresholds", "warn"]; $w | num)
        | setpath(["statusline", "thresholds", "critical"]; $c | num)' 2>/dev/null || return 1
      ;;
    statusline.bar.filled|statusline.bar.empty|statusline.colors.model|\
    statusline.colors.dir|statusline.colors.git|statusline.colors.branch|\
    statusline.colors.label)
      # shellcheck disable=SC2016 # a jq program: the $names are jq variables
      printf '%s' "$cfg" | jq --arg id "$id" --arg v "$value" \
        'setpath($id | split("."); $v)' 2>/dev/null || return 1
      ;;
    statusline.bar.width|statusline.weekly_threshold|statusline.agents.stale_after|\
    statusline.agents.keep_finished|statusline.agents.max_rows)
      # shellcheck disable=SC2016 # a jq program: the $names are jq variables
      printf '%s' "$cfg" | jq --arg id "$id" --arg v "$value" "$CP_PANEL_JQ_NUM"'
        setpath($id | split("."); $v | num)' 2>/dev/null || return 1
      ;;
    *) return 2 ;;
  esac
}

# cp_panel_new_problems <cur_cfg> <cand_cfg> <id> -> the problems writing <id>
# would introduce, one per line, nothing when it is clean. A problem is new
# problems the candidate has that are about <id>. Three kinds of line from
# cp_sl_config_problems <cand> count:
#
#   `<id>:` ...                     always. The resolver's messages do not
#                                   carry the raw value, so a bad value
#                                   written over an already-rejected one
#                                   reads exactly like the current line; a
#                                   not-in-current filter would let it in.
#   statusline.thresholds / .lines  always, for an id in those sections: the
#                                   write replaces the pair or the layout
#                                   whole, so whatever it reports is the
#                                   write's own doing.
#   any other `<sec>:` / `<sec>.`   only when the current config does not
#                                   report it already, so a sibling value
#                                   rejected before never blocks an
#                                   unrelated setting in the same section.
#
# One line never counts: CP_SL_AGENTS_SHARED_MSG, doctor's note that agents
# shares a line. The resolver keeps that layout, so it is advice, not a
# rejection. The resolver's own wording is passed through untouched -- it is
# the wording `cprof doctor` uses.
cp_panel_new_problems() {
  local cur="${1:-}" cand="${2:-}" id="${3:-}" sec cur_p line nl
  nl='
'
  case "$id" in
    # statusline.bar.width -> statusline.bar; statusline.weekly_threshold is
    # its own section.
    statusline.*) sec="${id#statusline.}"; sec="statusline.${sec%%.*}" ;;
    *) return 0 ;;
  esac
  cur_p="$(cp_sl_config_problems "$cur")"
  cp_sl_config_problems "$cand" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    # Doctor's advisory, not a rejection: the resolver keeps that layout.
    [ "$line" = "$CP_SL_AGENTS_SHARED_MSG" ] && continue
    case "$line" in
      "$id:"*) printf '%s\n' "$line"; continue ;;
      "$sec:"*|"$sec."*) ;;
      *) continue ;;
    esac
    case "$sec" in
      statusline.thresholds|statusline.lines) printf '%s\n' "$line"; continue ;;
    esac
    case "$nl$cur_p$nl" in *"$nl$line$nl"*) continue ;; esac
    printf '%s\n' "$line"
  done
}

# cp_panel_stage_backup -> path of a copy of the current config, made beside
# it with the same permissions, or nothing when there is no config yet. rc 1
# (with a warning) when the copy cannot be made: nothing is written without
# one.
cp_panel_stage_backup() {
  local tmp
  [ -f "$CP_CONFIG_PATH" ] || return 0
  tmp="$(mktemp "$CP_CONFIG_PATH.bak.XXXXXX" 2>/dev/null)" \
    || { cp_warn 'config: cannot create a backup beside the config; nothing written'; return 1; }
  # -p: the backup is never more readable than the config it copies.
  if ! cp -p "$CP_CONFIG_PATH" "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    cp_warn 'config: cannot back up the config; nothing written'
    return 1
  fi
  printf '%s\n' "$tmp"
}

# cp_panel_commit_backup <staged> <rc> -> on rc 0 the staged copy becomes
# the .bak; otherwise it is dropped and the previous .bak stays. Passes <rc>
# through. A write that had no config to copy leaves an existing .bak alone:
# with the config gone it may be the only copy of it there is.
cp_panel_commit_backup() {
  local staged="${1:-}" rc="${2:-1}"
  if [ "$rc" -ne 0 ]; then
    [ -z "$staged" ] || rm -f "$staged"
    return "$rc"
  fi
  if [ -n "$staged" ]; then
    mv "$staged" "$CP_CONFIG_PATH.bak" \
      || { rm -f "$staged"; cp_warn 'config: written, but the backup could not be kept'; }
  fi
  return 0
}

# cp_panel_apply <id>=<value> -> 0 written; 1 rejected or refused (messages
# on stderr, nothing written); 2 unknown id or no `=`.
cp_panel_apply() {
  local arg="${1:-}" id value cfg cand problems staged rc line
  case "$arg" in
    *=*) ;;
    *) cp_warn 'config: --apply needs <id>=<value>'; return 2 ;;
  esac
  id="${arg%%=*}"
  value="${arg#*=}"
  cfg="$(cp_config_read)" || return 1
  if ! cp_panel_known_ids "$cfg" | grep -Fxq -- "$id"; then
    cp_warn "config: unknown setting $id"
    return 2
  fi
  if [ "$id" = default ]; then
    staged="$(cp_panel_stage_backup)" || return 1
    cp_cmd_default "$value"
    cp_panel_commit_backup "$staged" "$?"
    return
  fi
  cand="$(cp_panel_candidate "$cfg" "$id" "$value")"; rc=$?
  case "$rc" in
    0) ;;
    2) cp_warn "config: $id is a screen, not a setting"; return 2 ;;
    *) cp_warn "config: cannot set $id: a section on its path is not a JSON object"; return 1 ;;
  esac
  problems="$(cp_panel_new_problems "$cfg" "$cand" "$id")"
  if [ -n "$problems" ]; then
    printf '%s\n' "$problems" | while IFS= read -r line; do cp_warn "$line"; done
    return 1
  fi
  staged="$(cp_panel_stage_backup)" || return 1
  printf '%s\n' "$cand" | cp_config_write
  cp_panel_commit_backup "$staged" "$?"
}

# cp_panel_undo -> 0 restored the .bak over the config (and it is gone); 1
# nothing to undo, or a backup that is not a usable config, left untouched.
cp_panel_undo() {
  local bak="$CP_CONFIG_PATH.bak"
  if [ ! -e "$bak" ] && [ ! -L "$bak" ]; then
    cp_warn 'nothing to undo'
    return 1
  fi
  # A link would leave the config itself a link to wherever it points.
  if [ -L "$bak" ] || [ ! -f "$bak" ]; then
    cp_warn "config: $bak is not a regular file; not restoring it"
    return 1
  fi
  if ! jq -e . "$bak" >/dev/null 2>&1; then
    cp_warn "config: $bak is not valid JSON; not restoring it"
    return 1
  fi
  mv "$bak" "$CP_CONFIG_PATH" || { cp_warn 'config: could not restore the backup'; return 1; }
}

# cp_cmd_config [--rows <screen> | --preview <arg> | --apply <arg> | undo]
cp_cmd_config() {
  local sub="${1:-}" cfg
  case "$sub" in
    --rows)
      [ "$#" -ge 2 ] || { cp_warn 'config: --rows needs a screen'; return 2; }
      case "$2" in
        main|statusline|statusline.lines) ;;
        *) cp_warn "config: unknown screen $2"; return 2 ;;
      esac
      cfg="$(cp_config_read)" || return 1
      cp_panel_rows "$2" "$cfg"
      ;;
    --apply)
      [ "$#" -ge 2 ] || { cp_warn 'config: --apply needs <id>=<value>'; return 2; }
      cp_panel_apply "$2"
      ;;
    undo) cp_panel_undo ;;
    # Placeholders: --preview and the panel itself land in the tasks that
    # follow.
    --preview|'')
      cp_warn 'config: not implemented yet'
      return 2
      ;;
    *)
      cp_warn "config: unknown option $sub"
      return 2
      ;;
  esac
}
