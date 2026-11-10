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
    # Placeholders: --preview, --apply and undo, and the panel itself, land in
    # the tasks that follow.
    --preview|--apply|undo|'')
      cp_warn 'config: not implemented yet'
      return 2
      ;;
    *)
      cp_warn "config: unknown option $sub"
      return 2
      ;;
  esac
}
