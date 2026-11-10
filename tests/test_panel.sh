#!/usr/bin/env bash
set -u
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
for lib in config resolve profiles auth output color usage statusline fallback share agents panel; do
  # shellcheck source=/dev/null
  . "$(dirname "$0")/../scripts/lib/$lib.sh"
done
CLI="$(cd "$(dirname "$0")/.." && pwd -P)/scripts/cprof"
ESC="$(printf '\033')"

# fixture <statusline-json> -> a config with profiles work (native) and
# personal, default work, and the given statusline block (null for none).
fixture() {
  jq -n --argjson s "${1:-null}" --arg d "$CP_T_TMP/personal" '
    {default: "work",
     profiles: [{name: "work", native: true}, {name: "personal", dir: $d}],
     rules: [], repos: {}}
    + (if $s == null then {} else {statusline: $s} end)' | cp_t_write_config
}
rows() { "$CLI" config --rows "$1" 2>/dev/null; }
# row <screen> <id> -> that row
row() { rows "$1" | awk -F'\t' -v id="$2" '$1 == id'; }
# field <screen> <id> <n> -> field n of that row
field() { row "$1" "$2" | cut -f"$3"; }

# --- main screen -------------------------------------------------------------
fixture null
assert_eq 'statusline
default' "$(rows main | cut -f1)" 'main screen: statusline drill row and default row'
assert_eq 'work	profile	work personal	set	set' \
  "$(row main default | cut -f3-7)" 'main screen: default row value, kind, constraint, action, state'
assert_eq 'screen	-	drill' "$(row main statusline | cut -f4-6)" 'main screen: statusline is a drill row'
assert_eq '3 lines' "$(field main statusline 3)" 'main screen: statusline value summarises the layout'

# --- statusline screen -------------------------------------------------------
assert_eq 'statusline.lines
statusline.bar.filled
statusline.bar.empty
statusline.bar.width
statusline.thresholds.warn
statusline.thresholds.critical
statusline.weekly_threshold
statusline.colors.model
statusline.colors.dir
statusline.colors.git
statusline.colors.branch
statusline.colors.label
statusline.agents.stale_after
statusline.agents.keep_finished
statusline.agents.max_rows' "$(rows statusline | cut -f1)" 'statusline screen lists every setting id in order'

assert_eq '10	integer	1..40	set	default' "$(row statusline statusline.bar.width | cut -f3-7)" \
  'an unconfigured setting shows its default'
assert_eq '1..100' "$(field statusline statusline.thresholds.warn 5)" 'thresholds constraint'
assert_eq '30..86400' "$(field statusline statusline.agents.stale_after 5)" 'stale_after constraint'
assert_eq '0..86400' "$(field statusline statusline.agents.keep_finished 5)" 'keep_finished constraint'
assert_eq '1..20' "$(field statusline statusline.agents.max_rows 5)" 'max_rows constraint'
assert_eq 'glyph	1 char' "$(row statusline statusline.bar.filled | cut -f4-5)" 'glyph kind and constraint'
assert_eq "color	$(cp_color_names | tr '\n' ' ')dim" \
  "$(row statusline statusline.colors.model | cut -f4-5)" 'colour constraint: the cprof color palette plus dim'
assert_eq 'cyan' "$(field statusline statusline.colors.model 3)" 'colour default'

fixture '{"bar":{"width":8}}'
assert_eq '8	set' "$(row statusline statusline.bar.width | cut -f3,7)" 'a configured setting shows state set'
fixture '{"bar":{"width":99}}'
assert_eq '10	rejected' "$(row statusline statusline.bar.width | cut -f3,7)" \
  'a rejected value shows the effective default and state rejected'
fixture '{"bar":{"width":"8"}}'
assert_eq '10	rejected' "$(row statusline statusline.bar.width | cut -f3,7)" \
  'a string width is rejected, compared in its own representation'
fixture '{"bar":{"width":null}}'
assert_eq '10	default' "$(row statusline statusline.bar.width | cut -f3,7)" 'an explicit null is default'
fixture '{"colors":{"model":"red"},"agents":{"max_rows":5}}'
assert_eq 'red	set' "$(row statusline statusline.colors.model | cut -f3,7)" 'a configured colour shows set'
assert_eq '5	set' "$(row statusline statusline.agents.max_rows | cut -f3,7)" 'a configured agents setting shows set'
assert_eq 'set' "$(field main statusline 7)" \
  'main screen: a drill row is set unless a setting under it is rejected'
fixture '{"bar":{"width":99}}'
assert_eq 'rejected' "$(field main statusline 7)" 'main screen: a rejected setting under a drill row marks it rejected'

# --- default row -------------------------------------------------------------
jq -n '{default: null, profiles: [{name: "work", native: true}]}' | cp_t_write_config
assert_eq '	default' "$(row main default | cut -f3,7)" 'no default profile: empty value, state default'
jq -n '{default: "gone", profiles: [{name: "work", native: true}]}' | cp_t_write_config
assert_eq '	rejected' "$(row main default | cut -f3,7)" 'a default naming no profile: empty value, state rejected'

# --- lines screen ------------------------------------------------------------
fixture null
assert_eq 'statusline.lines.1	line 1	badge model dir git	segments	badge model dir git context usage weekly agents	set	default
statusline.lines.2	line 2	context usage	segments	badge model dir git context usage weekly agents	set	default
statusline.lines.3	line 3	agents	segments	badge model dir git context usage weekly agents	set	default
statusline.lines.4	add a line		segments	badge model dir git context usage weekly agents	set	default' \
  "$(rows statusline.lines)" 'lines screen: one row per line in effect plus an add row'
fixture '{"lines":[["model","usage"]]}'
assert_eq 'statusline.lines.1	model usage	set
statusline.lines.2		default' "$(rows statusline.lines | cut -f1,3,7)" 'lines screen: a configured layout'
assert_eq '1 line' "$(field main statusline 3)" 'main screen: one line, singular'
fixture '{"lines":[["nope"]]}'
assert_eq 'statusline.lines.1	badge model dir git	rejected' \
  "$(rows statusline.lines | head -1 | cut -f1,3,7)" 'lines screen: a rejected layout shows the default, rejected'

# --- row hygiene -------------------------------------------------------------
fixture "$(jq -n --arg e "$ESC" '{colors: {model: ("red" + $e + "[31m")}}')"
bad=''
for s in main statusline statusline.lines; do
  bad="$bad$(rows "$s" | awk -F'\t' 'NF != 7')"
done
case "$(rows main; rows statusline; rows statusline.lines)" in
  *"$ESC"*) bad="${bad}ESC" ;;
esac
assert_eq '' "$bad" 'every row has seven fields and no character below 32'
assert_eq '2 15 4' "$(rows main | wc -l | tr -d ' ') $(rows statusline | wc -l | tr -d ' ') $(rows statusline.lines | wc -l | tr -d ' ')" \
  'row hygiene ran over real rows'
assert_eq 'cyan	rejected' "$(row statusline statusline.colors.model | cut -f3,7)" 'an ESC in a colour is rejected'

fixture '"nope"'
assert_eq 'rejected' "$(field main statusline 7)" 'a statusline block that is not an object: drill row rejected'
assert_eq '10	default' "$(row statusline statusline.bar.width | cut -f3,7)" '... and its settings read as defaults'
fixture '{"bar":"x","colors":{"model":"red"}}'
assert_eq 'cyan	rejected' "$(row statusline statusline.colors.model | cut -f3,7)" \
  'a wrongly typed section takes the block down: a colour written beside it is rejected'
assert_eq 'rejected' "$(field main statusline 7)" '... and the drill row says so'

# --- known ids ---------------------------------------------------------------
fixture null
assert_eq "$( { rows main; rows statusline; rows statusline.lines; } | cut -f1)" \
  "$(cp_panel_known_ids "$(cat "$CPROF_CONFIG")")" 'known ids: every id on every screen'
assert_eq '21' "$(cp_panel_known_ids "$(cat "$CPROF_CONFIG")" | wc -l | tr -d ' ')" 'known ids: 2 + 15 + 4'

# --- errors ------------------------------------------------------------------
"$CLI" config --rows nope >/dev/null 2>&1; rc=$?
assert_eq '2' "$rc" 'unknown screen: rc 2'
assert_eq '' "$("$CLI" config --rows nope 2>/dev/null)" 'unknown screen: nothing on stdout'
printf '{not json' > "$CPROF_CONFIG"
out="$("$CLI" config --rows statusline 2>/dev/null)"; rc=$?
assert_eq '1:' "$rc:$out" 'malformed config: rc 1, nothing on stdout'
fixture null
"$CLI" config --bogus >/dev/null 2>&1; rc=$?
assert_eq '2' "$rc" 'unknown flag: rc 2'
"$CLI" config --rows >/dev/null 2>&1; rc=$?
assert_eq '2' "$rc" 'missing screen: rc 2'

cp_t_summary
