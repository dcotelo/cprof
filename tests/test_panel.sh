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

# --- apply -------------------------------------------------------------------
BAK="$CPROF_CONFIG.bak"
TAB="$(printf '\t')"
NL="$(printf '\nx')"; NL="${NL%x}"
# apply <id>=<value> -> rc in $rc, stderr in $err
apply() { err="$("$CLI" config --apply "$1" 2>&1 >/dev/null)"; rc=$?; }
# has <haystack> <needle> -> yes | no
has() { case "$1" in *"$2"*) printf 'yes' ;; *) printf 'no' ;; esac; }
# same <a> <b> -> same | differ
same() { if cmp -s "$1" "$2"; then printf 'same'; else printf 'differ'; fi; }
snap() { cp "$CPROF_CONFIG" "$CP_T_TMP/before"; }
fresh() { rm -f "$BAK"; fixture "${1:-null}"; snap; }
jqc() { jq -c "$1" "$CPROF_CONFIG"; }

fresh
apply statusline.bar.width=8
assert_eq '0:8:number:same' "$rc:$(jqc .statusline.bar.width):$(jq -r '.statusline.bar.width|type' "$CPROF_CONFIG"):$(same "$BAK" "$CP_T_TMP/before")" \
  'apply a valid integer writes it and backs up the old file'

fresh
cp "$CPROF_CONFIG" "$BAK"; cp "$BAK" "$CP_T_TMP/bak-before"
apply statusline.bar.width=41
assert_eq '1:yes:same:same' \
  "$rc:$(has "$err" 'statusline.bar.width: must be a whole number from 1 to 40; using 10'):$(same "$CPROF_CONFIG" "$CP_T_TMP/before"):$(same "$BAK" "$CP_T_TMP/bak-before")" \
  'apply out of range is rejected with the doctor wording'

fresh
apply statusline.bar.width=abc
assert_eq '1:yes:same:no' \
  "$rc:$(has "$err" 'statusline.bar.width: must be a whole number from 1 to 40; using 10'):$(same "$CPROF_CONFIG" "$CP_T_TMP/before"):$([ -e "$BAK" ] && echo yes || echo no)" \
  'a non-numeric integer is rejected, not coerced'

fresh
r=''
apply statusline.bar.width=1; r="$r$rc$(jqc .statusline.bar.width) "
apply statusline.bar.width=40; r="$r$rc$(jqc .statusline.bar.width) "
apply statusline.agents.keep_finished=0; r="$r$rc$(jqc .statusline.agents.keep_finished)"
assert_eq '01 040 00' "$r" 'boundary values are accepted'

fresh
apply 'statusline.bar.filled=##'
r="$rc:$(has "$err" 'statusline.bar.filled: must be exactly one character; using ▓')"
apply 'statusline.bar.filled=#'
assert_eq '1:yes 0:"#"' "$r $rc:$(jqc .statusline.bar.filled)" 'a glyph must be one character'

fresh
cp "$CPROF_CONFIG" "$BAK"; cp "$BAK" "$CP_T_TMP/bak-before"
r=''
for ch in "$TAB" "$NL" "$ESC"; do
  apply "statusline.bar.filled=$ch"
  r="$r$rc$(has "$err" 'statusline.bar.filled: must not contain an invisible character such as a tab; using ▓') "
  apply "statusline.colors.model=re${ch}d"
  r="$r$rc$(has "$err" 'statusline.colors.model: must not contain an invisible character such as a tab; using cyan') "
done
assert_eq '1yes 1yes 1yes 1yes 1yes 1yes :same:same' \
  "$r:$(same "$CPROF_CONFIG" "$CP_T_TMP/before"):$(same "$BAK" "$CP_T_TMP/bak-before")" \
  'a control character in the value is rejected'

fresh
apply statusline.colors.model=bogus
assert_eq '1:yes:same' "$rc:$(has "$err" 'statusline.colors.model: unknown colour "bogus"; rendering it plain'):$(same "$CPROF_CONFIG" "$CP_T_TMP/before")" \
  'an out-of-palette colour is rejected'
apply statusline.colors.model=red
assert_eq '0:"red"' "$rc:$(jqc .statusline.colors.model)" 'a palette colour is accepted'

fresh
apply statusline.thresholds.warn=80
r="$rc:$(jqc .statusline.thresholds)"
apply statusline.thresholds.warn=95
assert_eq '0:{"critical":90,"warn":80} 1:yes:{"critical":90,"warn":80}' \
  "$r $rc:$(has "$err" 'statusline.thresholds: warn must be a whole number below critical'):$(jqc .statusline.thresholds)" \
  'thresholds: setting warn keeps the effective critical'

fresh '{"bar":{"width":99}}'
apply statusline.bar.empty=.
assert_eq '0:"."' "$rc:$(jqc .statusline.bar.empty)" 'a pre-existing rejected value does not block another setting'

fresh
apply statusline.lines.2=usage
assert_eq '0:[["badge","model","dir","git"],["usage"],["agents"]]' "$rc:$(jqc .statusline.lines)" \
  'lines: editing a line of the default layout copies the layout first'
fresh
apply statusline.lines.3=
assert_eq '0:2' "$rc:$(jqc '.statusline.lines|length')" 'lines: an empty value removes that line'
fresh
apply statusline.lines.4=weekly
assert_eq '0:["weekly"]' "$rc:$(jqc '.statusline.lines[3]')" 'lines: the add row appends'
fresh
apply 'statusline.lines.1=badge bogus'
assert_eq '1:yes:same' "$rc:$(has "$err" 'unknown segment "bogus"'):$(same "$CPROF_CONFIG" "$CP_T_TMP/before")" \
  'lines: an unknown segment is rejected'

# Doctor's shared-line note is advice, not a rejection: it must not block.
fresh
apply 'statusline.lines.1=badge agents'
assert_eq '0:["badge","agents"]' "$rc:$(jqc '.statusline.lines[0]')" \
  'lines: agents may share a line, the advisory does not block'
fresh '{"lines":[["model","agents"],["usage"]]}'
apply statusline.lines.2=weekly
assert_eq '0:[["model","agents"],["weekly"]]' "$rc:$(jqc .statusline.lines)" \
  'lines: a layout already sharing agents does not block editing another line'
fresh '{"lines":[["model","agents"],["usage"]]}'
apply 'statusline.lines.2=badge bogus'
assert_eq '1:yes:same' "$rc:$(has "$err" 'unknown segment "bogus"'):$(same "$CPROF_CONFIG" "$CP_T_TMP/before")" \
  'lines: beside the advisory, an unknown segment still blocks'

fresh
apply default=personal
r="$rc:$(jqc .default):$(same "$BAK" "$CP_T_TMP/before")"
rm -f "$BAK"; snap
apply default=nobody
assert_eq '0:"personal":same 1:yes:same:no' \
  "$r $rc:$(has "$err" 'unknown profile nobody'):$(same "$CPROF_CONFIG" "$CP_T_TMP/before"):$([ -e "$BAK" ] && echo yes || echo no)" \
  'default goes through cprof default'

fresh
apply statusline.nope=1; r="$rc"
apply statusline.bar.width; r="$r $rc"
assert_eq '2 2:same:no' "$r:$(same "$CPROF_CONFIG" "$CP_T_TMP/before"):$([ -e "$BAK" ] && echo yes || echo no)" \
  'unknown id and missing = are usage errors'

rm -f "$CPROF_CONFIG" "$BAK"
apply statusline.bar.width=8
assert_eq '0:8:no' "$rc:$(jq .statusline.bar.width "$CPROF_CONFIG" 2>/dev/null):$([ -e "$BAK" ] && echo yes || echo no)" \
  'fresh install: apply creates the config and no backup'

# In a directory of its own, so the chmod below cannot touch state/ or home/.
saved_config="$CPROF_CONFIG"
mkdir -p "$CP_T_TMP/ro"
export CPROF_CONFIG="$CP_T_TMP/ro/config.json"
fixture null
printf 'known backup\n' > "$CPROF_CONFIG.bak"
cp "$CPROF_CONFIG" "$CP_T_TMP/before"; cp "$CPROF_CONFIG.bak" "$CP_T_TMP/bak-before"
chmod 500 "$CP_T_TMP/ro"
apply statusline.bar.width=8
chmod 700 "$CP_T_TMP/ro"
assert_eq '1:same:same' "$rc:$(same "$CPROF_CONFIG" "$CP_T_TMP/before"):$(same "$CPROF_CONFIG.bak" "$CP_T_TMP/bak-before")" \
  'a backup that cannot be staged: nothing written, old backup kept'
export CPROF_CONFIG="$saved_config"

# The write itself failing, after the backup was staged: cp_config_write is
# overridden in a subshell that sources the libraries, as the CLI does.
fresh
printf 'known backup\n' > "$BAK"; cp "$BAK" "$CP_T_TMP/bak-before"
(
  # shellcheck disable=SC2329 # called by cp_panel_apply
  cp_config_write() { cat >/dev/null; return 1; }
  # shellcheck disable=SC2034 # read by the panel and config libraries
  CP_CONFIG_PATH="$CPROF_CONFIG"
  cp_panel_apply statusline.bar.width=8 2>/dev/null
); rc=$?
left="$(cd "$CP_T_TMP" && ls -d config.json.bak.* 2>/dev/null)"
assert_eq '1:same:same:' "$rc:$(same "$CPROF_CONFIG" "$CP_T_TMP/before"):$(same "$BAK" "$CP_T_TMP/bak-before"):$left" \
  'a failed write keeps the old backup and the old file, and leaves no staged copy'

# A backup with no config beside it may be the only copy of the old config.
rm -f "$CPROF_CONFIG"
printf '{"profiles":[],"precious":1}' > "$BAK"; cp "$BAK" "$CP_T_TMP/bak-before"
apply statusline.bar.width=8
assert_eq '0:same' "$rc:$(same "$BAK" "$CP_T_TMP/bak-before")" \
  'apply with no config never drops an existing backup'

# --- an already-rejected setting ----------------------------------------------
fresh '{"bar":{"width":99}}'
apply statusline.bar.width=41
assert_eq '1:yes:same:no' \
  "$rc:$(has "$err" 'statusline.bar.width: must be a whole number'):$(same "$CPROF_CONFIG" "$CP_T_TMP/before"):$([ -e "$BAK" ] && echo yes || echo no)" \
  'a bad value on an already-rejected integer is still rejected'
fresh '{"thresholds":{"warn":95,"critical":90}}'
apply statusline.thresholds.critical=50
assert_eq '1:yes:same:no' \
  "$rc:$(has "$err" 'statusline.thresholds: warn must be'):$(same "$CPROF_CONFIG" "$CP_T_TMP/before"):$([ -e "$BAK" ] && echo yes || echo no)" \
  'a bad value on an already-rejected thresholds pair is still rejected'
fresh '{"bar":{"filled":"##"}}'
apply 'statusline.bar.filled=@@@'
assert_eq '1:yes:same:no' \
  "$rc:$(has "$err" 'statusline.bar.filled: must be exactly one character'):$(same "$CPROF_CONFIG" "$CP_T_TMP/before"):$([ -e "$BAK" ] && echo yes || echo no)" \
  'a bad value on an already-rejected glyph is still rejected'
fresh '{"thresholds":{"warn":95,"critical":90}}'
apply statusline.thresholds.critical=99
# The other key is the effective one: the rejected pair resolves to 70/90.
assert_eq '0:{"critical":99,"warn":70}' "$rc:$(jqc .statusline.thresholds)" \
  'a good value repairs an already-rejected thresholds pair'

# --- undo --------------------------------------------------------------------
fresh
apply statusline.bar.width=8
"$CLI" config undo >/dev/null 2>&1; r="$?:$(same "$CPROF_CONFIG" "$CP_T_TMP/before"):$([ -e "$BAK" ] && echo yes || echo no)"
err="$("$CLI" config undo 2>&1 >/dev/null)"; rc=$?
assert_eq '0:same:no 1:yes' "$r $rc:$(has "$err" 'nothing to undo')" 'undo restores the backup and removes it'

fresh
printf 'not json' > "$BAK"
"$CLI" config undo >/dev/null 2>&1; rc=$?
assert_eq '1:same' "$rc:$(same "$CPROF_CONFIG" "$CP_T_TMP/before")" 'undo refuses a malformed backup'

rm -f "$BAK"
printf '{not json' > "$CPROF_CONFIG"; snap
apply statusline.bar.width=8
assert_eq '1:same:no' "$rc:$(same "$CPROF_CONFIG" "$CP_T_TMP/before"):$([ -e "$BAK" ] && echo yes || echo no)" \
  'malformed config: apply refuses'

# --- preview -----------------------------------------------------------------
# upto_blank / after_blank <text> -> the lines before / after the first empty one
upto_blank() { printf '%s\n' "$1" | awk '$0 == "" { exit } { print }'; }
after_blank() { printf '%s\n' "$1" | awk 'seen { print } $0 == "" { seen = 1 }'; }
# preview <arg> -> rc in $rc, stdout in $pv (no colour), stderr in $err
preview() {
  local e="$CP_T_TMP/preview.err"
  pv="$(NO_COLOR=1 "$CLI" config --preview "$1" 2>"$e")"; rc=$?
  err="$(cat "$e")"; rm -f "$e"
}
# barw <render> -> the width of the Usage bar in it, in characters
barw() { printf '%s\n' "$1" | sed -n 's/.*Usage \([^ ]*\) 63%.*/\1/p' | tr -d '\n' | wc -m | tr -d ' '; }
PTMP="$CP_T_TMP/ptmp"; mkdir -p "$PTMP"

fresh
cp_panel_candidate "$(cat "$CPROF_CONFIG")" statusline.bar.width 6 > "$CP_T_TMP/cand.json"
want="$(cp_panel_payload | CPROF_CONFIG="$CP_T_TMP/cand.json" NO_COLOR=1 "$CLI" statusline --stdin 2>/dev/null)"
preview statusline.bar.width=6
assert_eq "0:$want:6:yes" "$rc:$(upto_blank "$pv"):$(barw "$want"):$(has "$want" '[Opus 5]')" \
  'preview renders exactly what cprof statusline renders for the same override'
assert_eq 'bar width — integer, 1..40' "$(after_blank "$pv")" \
  'preview: the description line follows the blank line, and nothing else for a clean value'

fresh '{"bar":{"width":8}}'
want="$(cp_panel_payload | NO_COLOR=1 "$CLI" statusline --stdin 2>/dev/null)"
preview statusline.bar.width
assert_eq "0:$want:8" "$rc:$(upto_blank "$pv"):$(barw "$(upto_blank "$pv")")" \
  'preview without a value shows the current setting'

fresh
preview statusline.bar.width=99
assert_eq '0:10:yes' \
  "$rc:$(barw "$(upto_blank "$pv")"):$(has "$(after_blank "$pv")" 'statusline.bar.width: must be a whole number from 1 to 40; using 10')" \
  'preview of a rejected candidate shows the fallback render and the doctor message'

fresh
printf '{"profiles":[],"old":1}' > "$BAK"; cp "$BAK" "$CP_T_TMP/bak-before"
ls_before="$(ls -A "$CP_T_TMP")"
r=''
for a in statusline.bar.width=6 statusline.bar.width=99 statusline.agents.max_rows=1 default=personal statusline; do
  pv="$(TMPDIR="$PTMP" NO_COLOR=1 "$CLI" config --preview "$a" 2>/dev/null)"; r="$r$? "
done
ls_after="$(ls -A "$CP_T_TMP")"
assert_eq '0 0 0 0 0 :same:same:same:' \
  "$r:$(same "$CPROF_CONFIG" "$CP_T_TMP/before"):$(same "$BAK" "$CP_T_TMP/bak-before"):$([ "$ls_before" = "$ls_after" ] && echo same || echo differ):$(ls -A "$PTMP")" \
  'preview leaves the config and backup untouched, and no temp file behind'

fresh
pv="$(TMPDIR="$PTMP" NO_COLOR=1 "$CLI" config --preview statusline.agents.max_rows=1 2>/dev/null)"; rc=$?
agents_out="$(upto_blank "$pv")"
assert_eq '0:yes:1:' \
  "$rc:$(has "$agents_out" '+3 more'):$(printf '%s\n' "$agents_out" | grep -c '^[⟳✓✗] '):$(ls -A "$PTMP")" \
  'agents preview shows the max_rows effect, and its session dir is gone afterwards'
preview statusline.agents.max_rows=20
assert_eq '3 1' "$(printf '%s\n' "$pv" | grep -c '^⟳ ') $(printf '%s\n' "$pv" | grep -c '^✓ ')" \
  'agents preview: three running agents and one finished'

fresh
rm -f "$CP_T_TMP/curl-called"
printf '#!/bin/sh\ntouch "%s"\nexit 1\n' "$CP_T_TMP/curl-called" > "$CP_CURL_BIN"; chmod +x "$CP_CURL_BIN"
preview default=personal
r="$rc:$(has "$pv" 'personal'):$(has "$pv" "$CP_T_TMP/personal"):$(has "$pv" 'usage: not cached')"
assert_eq "0:yes:yes:yes:no" "$r:$([ -e "$CP_T_TMP/curl-called" ] && echo yes || echo no)" \
  'default preview is cache-only'
mkdir -p "$(dirname "$(cp_usage_cache_file work)")"
printf '{"five_hour":{"utilization":37.6,"resets_at":"2026-11-10T12:00:00Z"}}' > "$(cp_usage_cache_file work)"
preview default=work
assert_eq "0:yes:yes:no:no" \
  "$rc:$(has "$pv" 'native'):$(has "$pv" '37%'):$(has "$pv" 'not cached'):$([ -e "$CP_T_TMP/curl-called" ] && echo yes || echo no)" \
  'default preview: a native profile, and its cached 5-hour percentage'
assert_eq 'default profile — profile, work personal' "$(after_blank "$pv")" 'default preview: the description line'
preview default=nobody
assert_eq '0:yes' "$rc:$(has "$(after_blank "$pv")" 'unknown profile nobody')" \
  'default preview: a profile that does not exist is reported'
rm -f "$CP_CURL_BIN" "$(cp_usage_cache_file work)"

fresh
preview statusline.nope=1; r="$rc"
preview statusline.lines.9=usage; r="$r $rc"
preview statusline=x; r="$r $rc"
assert_eq '2 2 2' "$r" 'preview: an unknown id, or a value on a screen, is a usage error'

# --- preview from a plain terminal --------------------------------------------
# No native profile and no CLAUDE_CONFIG_DIR: the ambient session is stock,
# yet the preview still renders for a cprof profile.
plain() {
  jq -n --arg a "$CP_T_TMP/pa" --arg b "$CP_T_TMP/pb" --argjson d "${1:-null}" '
    {profiles: [{name: "pa", dir: $a}, {name: "pb", dir: $b}], rules: [], repos: {}}
    + (if $d == null then {} else {default: $d} end)' | cp_t_write_config
}
plain '"pb"'
preview statusline.bar.width=6
assert_eq '0:yes:6' "$rc:$(has "$(upto_blank "$pv" | head -1)" '⚑ pb │ [Opus 5]'):$(barw "$(upto_blank "$pv")")" \
  'plain terminal: the preview renders for the default profile'
plain
preview statusline.bar.width=6
assert_eq '0:yes' "$rc:$(has "$(upto_blank "$pv" | head -1)" '⚑ pa │ [Opus 5]')" \
  'plain terminal, no default: the preview renders for the first profile'
plain '"pb"'
pv="$(CLAUDE_CONFIG_DIR="$CP_T_TMP/elsewhere" NO_COLOR=1 "$CLI" config --preview statusline.bar.width=6 2>/dev/null)"
assert_eq 'yes:no' "$(has "$(upto_blank "$pv" | head -1)" '⚑ pb │'):$(has "$pv" 'unknown')" \
  'an unknown session profile: the preview renders for the default profile'
pv="$(CLAUDE_CONFIG_DIR="$CP_T_TMP/pa" NO_COLOR=1 "$CLI" config --preview statusline.bar.width=6 2>/dev/null)"
assert_eq 'yes' "$(has "$(upto_blank "$pv" | head -1)" '⚑ pa │')" \
  'a session already running as a profile keeps that profile'
jq -n '{profiles: [], rules: [], repos: {}}' | cp_t_write_config
preview statusline.bar.width=6
assert_eq '0:no profile configured: the statusline renders only for a cprof profile
bar width — integer, 1..40' "$rc:$(upto_blank "$pv")
$(after_blank "$pv")" 'no profiles: the preview says so in place of the render'

printf '{not json' > "$CPROF_CONFIG"
preview statusline.bar.width=6
assert_eq '1:' "$rc:$pv" 'malformed config: preview refuses, rc 1'

cp_t_summary
