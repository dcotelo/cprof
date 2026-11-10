#!/usr/bin/env bash
# shellcheck shell=bash
# `cprof config`: an fzf panel over the configuration. fzf owns the loop; the
# panel is CLI callbacks it calls back into (--rows, --preview,
# --preview-pick, --apply), so each one is a plain function testable without
# a terminal.
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
      # appends. A layout left as it is, with no `lines` written, stays
      # unwritten: an empty "add a line" must not pin the default layout. A
      # written `lines` is replaced even when the effect is the same -- that
      # is a rejected layout being repaired.
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
        | (try .statusline.lines catch null) as $w
        | if $new == $L and $w == null then .
          else setpath(["statusline", "lines"]; $new) end' 2>/dev/null || return 1
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

# cp_panel_apply <id>=<value> -> 0 written, or unchanged; 1 rejected or
# refused (messages on stderr, nothing written); 2 unknown id or no `=`. A
# value that leaves the config as it is writes nothing and prints `unchanged`
# on stdout: a rewrite would replace the .bak with the same content and lose
# the change it held.
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
    # Unchanged only when it names a profile: a default naming none is left
    # for cprof default to refuse.
    if printf '%s' "$cfg" | jq -e --arg v "$value" '.default == $v' >/dev/null 2>&1 \
      && cp_profile_exists "$cfg" "$value"; then
      printf 'unchanged\n'
      return 0
    fi
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
  if [ "$(printf '%s' "$cand" | jq -S .)" = "$(printf '%s' "$cfg" | jq -S .)" ]; then
    printf 'unchanged\n'
    return 0
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
  # A config is an object: `[]` or `1` is valid JSON, but restoring it would
  # leave every other command failing on the config.
  if ! jq -e 'type == "object"' "$bak" >/dev/null 2>&1; then
    cp_warn "config: $bak is not a JSON config object; not restoring it"
    return 1
  fi
  mv "$bak" "$CP_CONFIG_PATH" || { cp_warn 'config: could not restore the backup'; return 1; }
}

# cp_panel_payload -> the synthetic Claude Code payload a preview renders
# against: a fixed model, the current directory, context at 42% and the
# 5-hour window at 63%. The reset is two hours and thirty seconds out, mid-
# minute, so a second render a few seconds later reads the same "resets in".
cp_panel_payload() {
  local now
  now="$(date +%s)"
  jq -cn --arg d "$PWD" --argjson r "$((now + 7230))" '
    {model: {display_name: "Opus 5"}, workspace: {current_dir: $d},
     context_window: {used_percentage: 42},
     rate_limits: {five_hour: {used_percentage: 63, resets_at: $r}}}'
}

# cp_panel_fake_agents <subagents-dir> -> three running subagents and one
# finished one, in the record shapes Claude Code writes, so an agents setting
# previews against something. Their files are aged a little (an mtime moved
# into the past drags the birth time with it), giving each a plausible
# duration and letting a short stale_after or keep_finished visibly hide one.
cp_panel_fake_agents() {
  local dir="${1:-}" now hb
  mkdir -p "$dir" || return 1
  now="$(cp_agents_now)"
  hb='{"success":true,"message":"Report delivered to your caller."}'
  # _fa <id> <type> <model> <description> <jsonl-age> <meta-age> [finished]
  _fa() {
    local f="$dir/agent-$1" fin="${7:-}"
    jq -cn --arg t "$2" --arg d "$4" --arg f "$fin" \
      '{agentType: $t, description: $d} + (if $f == "" then {} else {finished: true} end)' \
      > "$f.meta.json"
    jq -cn --arg m "$3" \
      '{type: "assistant", timestamp: "2026-11-10T09:00:00.000Z",
        message: {model: $m, content: [{type: "text", text: "x"}]}}' > "$f.jsonl"
    if [ -n "$fin" ]; then
      jq -cn --arg t "$hb" '{type: "user", message: {content: [{type: "tool_result",
        tool_use_id: "t1", content: [{type: "text", text: $t}]}]}}' >> "$f.jsonl"
    fi
    touch -t "$(date -r "$((now - $5))" '+%Y%m%d%H%M.%S')" "$f.jsonl"
    touch -t "$(date -r "$((now - $6))" '+%Y%m%d%H%M.%S')" "$f.meta.json"
  }
  _fa a1 Explore claude-opus-5-5 'Find the callers' 12 12
  _fa a2 general-purpose claude-sonnet-5 'Draft the migration' 45 45
  _fa a3 Plan claude-haiku-4-5 'Outline the tests' 75 75
  _fa a4 Explore claude-haiku-4-5 'Map the config readers' 110 20 1
  unset -f _fa
}

# cp_panel_render <cand-cfg> <id> -> what `cprof statusline --stdin` prints
# for <cand-cfg> and the synthetic payload. In a subshell: CP_CONFIG_PATH
# points at a temp copy of the candidate for this render only, and the temp
# files go on every way out -- fzf kills a preview it no longer needs.
cp_panel_render() {
  local cand="${1:-}" id="${2:-}"
  (
    tmp='' sess='' name='' pdir=''
    # shellcheck disable=SC2317,SC2329 # run by the traps below
    cleanup() {
      [ -z "$tmp" ] || rm -f "$tmp"
      case "$sess" in */cprof-preview.*) rm -rf "$sess" ;; esac
    }
    trap cleanup EXIT
    trap 'exit 1' HUP INT TERM
    tmp="$(mktemp "${TMPDIR:-/tmp}/cprof-preview.XXXXXX")" || exit 1
    printf '%s\n' "$cand" > "$tmp" || exit 1
    payload="$(cp_panel_payload)"
    case "$id" in
      statusline.agents.*)
        sess="$(mktemp -d "${TMPDIR:-/tmp}/cprof-preview.XXXXXX")" || exit 1
        cp_panel_fake_agents "$sess/sess/subagents" || exit 1
        payload="$(printf '%s' "$payload" | jq -c --arg t "$sess/sess.jsonl" '.transcript_path = $t')"
        ;;
    esac
    CP_CONFIG_PATH="$tmp"
    # The statusline names the session's profile from CLAUDE_CONFIG_DIR (see
    # cp_cmd_status) and renders nothing for stock. The panel usually runs in
    # a plain terminal, so when the session is not a cprof profile (stock, or
    # unknown) the render is pinned to the config's default profile, else
    # its first one. CLAUDE_PROFILE would not do it: cp_cmd_status never
    # reads it. Only this subshell sees the change.
    name="$(CPROF_COLOR=never cp_cmd_status 2>/dev/null)"
    case "$name" in
      ''|stock|unknown)
        name="$(printf '%s' "$cand" | jq -r '
          [.profiles[]? | objects | .name | strings | select(length > 0)] as $n
          | .default as $d
          | if ([$n[] | select(. == $d)] | length) > 0
            then $d else ($n[0] // "") end' 2>/dev/null)"
        if [ -n "$name" ]; then
          pdir="$(cp_profile_dir "$cand" "$name")"
          if [ -n "$pdir" ]; then
            export CLAUDE_CONFIG_DIR="$pdir"
          else
            unset CLAUDE_CONFIG_DIR
          fi
          name="$(CPROF_COLOR=never cp_cmd_status 2>/dev/null)"
        fi
        case "$name" in
          ''|stock|unknown)
            printf 'no profile configured: the statusline renders only for a cprof profile\n'
            exit 0
            ;;
        esac
        ;;
    esac
    printf '%s' "$payload" | cp_cmd_statusline --stdin
  )
}

# cp_panel_preview_default <cfg> <name> -> the default row's preview: the
# profile's name, its directory or `native`, and its cached 5-hour usage.
# Cache-only: a preview runs on every cursor move and never fetches.
cp_panel_preview_default() {
  local cfg="${1:-}" name="${2:-}" dir data pct
  if [ -z "$name" ]; then
    printf 'no default profile\n'
    return 0
  fi
  printf '%s\n' "$name"
  cp_profile_exists "$cfg" "$name" || return 0
  dir="$(cp_profile_dir "$cfg" "$name")"
  printf '%s\n' "${dir:-native}"
  data="$(cp_usage_read_cached_only "$name" 2>/dev/null)"
  pct="$(cp_usage_pct "$data" five_hour)"
  if [ -n "$pct" ]; then
    printf 'usage: %s%% (5-hour, cached)\n' "$pct"
  else
    printf 'usage: not cached\n'
  fi
}

# cp_panel_preview <id>[=<value>] -> the preview pane for a row: the real
# statusline as it would render with <value> written at <id> (the current
# config without a value), a blank line, `<label> — <kind>, <constraint>`,
# then the problems the candidate would introduce, in doctor's wording.
# Nothing is written. rc 2 for an unknown id or a value on a screen row; rc 1
# for a malformed config or a value that cannot be placed.
cp_panel_preview() {
  local arg="${1:-}" id value has_value=0 cfg row label kind con action cur cand rc problems
  case "$arg" in
    *=*) id="${arg%%=*}"; value="${arg#*=}"; has_value=1 ;;
    *)   id="$arg"; value='' ;;
  esac
  [ -n "$id" ] || { cp_warn 'config: --preview needs <id>[=<value>]'; return 2; }
  cfg="$(cp_config_read)" || return 1
  # Checked before the candidate: cp_panel_candidate would quietly append a
  # statusline.lines.<n> far past the end.
  if ! cp_panel_known_ids "$cfg" | grep -Fxq -- "$id"; then
    cp_warn "config: unknown setting $id"
    return 2
  fi
  row="$(cp_panel_rows_all "$cfg" "$(cp_sl_config "$cfg")" \
    | awk -F'\t' -v id="$id" '$2 == id { print; exit }')"
  label="$(printf '%s' "$row" | cut -f3)"
  cur="$(printf '%s' "$row" | cut -f4)"
  kind="$(printf '%s' "$row" | cut -f5)"
  con="$(printf '%s' "$row" | cut -f6)"
  action="$(printf '%s' "$row" | cut -f7)"

  if [ "$id" = default ]; then
    [ "$has_value" -eq 1 ] || value="$cur"
    cp_panel_preview_default "$cfg" "$value"
    printf '\n%s — %s, %s\n' "$label" "$kind" "$con"
    if [ -n "$value" ] && ! cp_profile_exists "$cfg" "$value"; then
      printf 'unknown profile %s\n' "$value"
    fi
    return 0
  fi

  cand="$cfg"
  if [ "$action" = drill ]; then
    if [ "$has_value" -eq 1 ]; then
      cp_warn "config: $id is a screen, not a setting"
      return 2
    fi
  elif [ "$has_value" -eq 1 ]; then
    cand="$(cp_panel_candidate "$cfg" "$id" "$value")"; rc=$?
    case "$rc" in
      0) ;;
      2) cp_warn "config: $id is a screen, not a setting"; return 2 ;;
      *) cp_warn "config: cannot set $id: a section on its path is not a JSON object"; return 1 ;;
    esac
  fi
  cp_panel_render "$cand" "$id"
  printf '\n%s — %s, %s\n' "$label" "$kind" "$con"
  problems="$(cp_panel_new_problems "$cfg" "$cand" "$id")"
  [ -z "$problems" ] || printf '%s\n' "$problems"
  return 0
}

# cp_panel_preview_pick <id> <query> <line> -> the value picker's preview: the
# value cp_panel_pick_value picks from <query> and the highlighted <line>
# (empty when nothing is highlighted), previewed as cp_panel_preview does. The
# same rule as the picker's Enter, so the pane always shows what Enter writes.
# rc 2 for an unknown id, else cp_panel_preview's rc.
cp_panel_preview_pick() {
  local id="${1:-}" query="${2:-}" line="${3:-}" cfg row picked
  cfg="$(cp_config_read)" || return 1
  row="$(cp_panel_rows_all "$cfg" "$(cp_sl_config "$cfg")" \
    | awk -F'\t' -v id="$id" '$2 == id { print; exit }')"
  if [ -z "$id" ] || [ -z "$row" ]; then
    cp_warn "config: unknown setting $id"
    return 2
  fi
  picked="$(cp_panel_pick_value "$(printf '%s' "$row" | cut -f5)" \
    "$(printf '%s' "$row" | cut -f6)" "$query
$line")"
  cp_panel_preview "$id=$picked"
}

# cp_panel_choices <kind> <constraint> -> what a set row's value picker
# offers, one per line: the palette, the profiles or the segments, which the
# row's constraint already lists space-separated. Nothing for the free-typed
# kinds (integer, glyph), whose picker is the query line alone.
cp_panel_choices() {
  case "${1:-}" in
    color|profile|segments) printf '%s\n' "${2:-}" | tr ' ' '\n' | awk 'NF' ;;
  esac
}

# cp_panel_header <screen> <result> -> fzf's header: the screen and its keys,
# then the last write's result line when there is one.
cp_panel_header() {
  local screen="${1:-}" result="${2:-}"
  if [ "$screen" = main ]; then
    printf 'cprof config (Enter opens or edits, Esc quits)'
  else
    printf 'cprof config: %s (Enter edits, Esc goes back)' "$screen"
  fi
  [ -z "$result" ] || printf '\n%s' "$result"
  printf '\n'
}

# cp_panel_result <id> <value> <rc> <output> -> one line on how an --apply
# went: unchanged (its output says so), saved, or not applied with its rc and
# the first line it warned (the `cprof: ` prefix dropped -- the header is
# already cprof's).
cp_panel_result() {
  local id="${1:-}" value="${2:-}" rc="${3:-1}" err="${4:-}" first
  if [ "$rc" -eq 0 ] && printf '%s\n' "$err" | grep -Fxq unchanged; then
    printf '%s = %s unchanged; nothing written\n' "$id" "$value"
    return 0
  fi
  if [ "$rc" -eq 0 ]; then
    printf '%s = %s saved (cprof config undo reverts it)\n' "$id" "$value"
    return 0
  fi
  first="$(printf '%s\n' "$err" | awk 'NF { print; exit }')"
  first="${first#cprof: }"
  printf '%s = %s not applied (rc %s)%s\n' "$id" "$value" "$rc" "${first:+: $first}"
}

# cp_panel_fzf <args...> -> fzf with the flags every panel call shares. The
# one place the panel's fzf options live; each stays within fzf 0.30. fzf
# runs --preview through $SHELL, and the self path in it is quoted with
# bash's %q, so the callbacks run under bash whatever the login shell is.
cp_panel_fzf() {
  SHELL=/bin/bash "${CP_FZF_BIN:-fzf}" --ansi --layout=reverse \
    --preview-window=down:60%:wrap "$@"
}

# cp_panel_pick_value <kind> <constraint> <picker-output> -> the value a
# picker's Enter writes, from fzf --print-query output (the query, then the
# highlighted choice if any). The picker's preview runs this same rule
# (cp_panel_preview_pick), so it shows the value written here:
#   segments      always the query -- a line is several segments, an empty
#                 query removes it, and the choices are only a reference
#   color/profile the query when it names a choice exactly (`claude` must not
#                 become a higher-ranked `claude-max`), else the highlighted
#                 choice, else the query
#   others        the query (they are fed no choices)
cp_panel_pick_value() {
  local kind="${1:-}" con="${2:-}" out="${3:-}" query sel
  query="$(printf '%s\n' "$out" | sed -n 1p)"
  sel="$(printf '%s\n' "$out" | sed -n 2p)"
  case "$kind" in
    color|profile)
      if [ -z "$sel" ] || cp_panel_choices "$kind" "$con" | grep -Fxq -- "$query"; then
        printf '%s\n' "$query"
      else
        printf '%s\n' "$sel"
      fi
      ;;
    *) printf '%s\n' "$query" ;;
  esac
}

# cp_panel_run -> the interactive panel: rc 0 on a normal exit (Esc on the
# main screen), and when fzf or a terminal is missing; rc 1 for a config it
# will not open. Deliberately thin -- rows, fzf, dispatch -- since a key press
# is the one thing no test can make: rows, previews and writes are the
# callbacks, and fzf runs them through the resolved, quoted CP_SELF_PATH.
cp_panel_run() {
  local self tab stack screen rows out rc id label value kind con action state result='' err sel
  if ! command -v "${CP_FZF_BIN:-fzf}" >/dev/null 2>&1 \
    || { [ "${CP_PANEL_ASSUME_TTY:-}" != 1 ] && ! { [ -t 0 ] && [ -t 1 ]; }; }; then
    printf '%s\n' 'cprof config needs fzf (brew install fzf) and a terminal. Every setting is also reachable with the cprof subcommands or by editing ~/.cprof.json; see docs/config.md.' >&2
    return 0
  fi
  cp_config_read >/dev/null || return 1
  self="$(printf '%q' "$CP_SELF_PATH")"
  tab="$(printf '\t')"
  # A stack of screens, space-separated (screen names carry no space).
  stack=main
  while [ -n "$stack" ]; do
    screen="${stack##* }"
    rows="$(cp_panel_rows "$screen")" || return 1
    out="$(printf '%s\n' "$rows" | cp_panel_fzf --no-sort --delimiter "$tab" --with-nth 2,3 \
      --header "$(cp_panel_header "$screen" "$result")" \
      --preview "$self config --preview {1}")"
    rc=$?
    result=''
    case "$rc" in
      0) ;;
      1) continue ;;
      130)
        case "$stack" in
          *' '*) stack="${stack% *}" ;;
          *) stack='' ;;
        esac
        continue
        ;;
      *) cp_warn "config: fzf failed (rc $rc)"; return 1 ;;
    esac
    # cut, not `IFS=<tab> read`: a tab is IFS whitespace, so read would fold
    # the empty value of an "add a line" row into the next field.
    id="$(printf '%s\n' "$out" | cut -f1)"
    label="$(printf '%s\n' "$out" | cut -f2)"
    value="$(printf '%s\n' "$out" | cut -f3)"
    kind="$(printf '%s\n' "$out" | cut -f4)"
    con="$(printf '%s\n' "$out" | cut -f5)"
    action="$(printf '%s\n' "$out" | cut -f6)"
    state="$(printf '%s\n' "$out" | cut -f7)"
    case "$action" in
      drill) stack="$stack $id"; continue ;;
      set) ;;
      *) continue ;;
    esac
    out="$(cp_panel_choices "$kind" "$con" | cp_panel_fzf --print-query \
      --query "$value" --prompt "$label> " \
      --header "$id (Enter applies, Esc cancels)" \
      --preview "$self config --preview-pick $id {q} {}")"
    rc=$?
    case "$rc" in
      0|1) ;;
      130) continue ;;
      *) cp_warn "config: fzf failed (rc $rc)"; return 1 ;;
    esac
    sel="$(cp_panel_pick_value "$kind" "$con" "$out")"
    # The value in effect, kept: nothing to write. Not for a rejected row,
    # whose value is the effective one and writing it is the repair.
    if [ "$sel" = "$value" ] && [ "$state" != rejected ]; then
      result="$(cp_panel_result "$id" "$sel" 0 unchanged)"
      continue
    fi
    # Both streams: `unchanged` comes on stdout, a rejection on stderr.
    err="$("$CP_SELF_PATH" config --apply "$id=$sel" 2>&1)"
    result="$(cp_panel_result "$id" "$sel" "$?" "$err")"
  done
  return 0
}

# cp_cmd_config [--rows <screen> | --preview <id>[=<value>] |
#                --preview-pick <id> <query> [<line>] | --apply <arg> | undo]
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
    --preview)
      [ "$#" -ge 2 ] || { cp_warn 'config: --preview needs <id>[=<value>]'; return 2; }
      cp_panel_preview "$2"
      ;;
    --preview-pick)
      [ "$#" -ge 3 ] || { cp_warn 'config: --preview-pick needs <id> <query> [<line>]'; return 2; }
      cp_panel_preview_pick "$2" "$3" "${4:-}"
      ;;
    undo) cp_panel_undo ;;
    '') cp_panel_run ;;
    *)
      cp_warn "config: unknown option $sub"
      return 2
      ;;
  esac
}
