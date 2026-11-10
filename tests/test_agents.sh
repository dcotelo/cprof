#!/usr/bin/env bash
set -u
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
for lib in config resolve profiles auth output color usage statusline fallback share agents; do
  # shellcheck source=/dev/null
  . "$(dirname "$0")/../scripts/lib/$lib.sh"
done
# shellcheck disable=SC2034  # render tests added later use it
ESC="$(printf '\033')"

# --- model short form ------------------------------------------------------
assert_eq 'haiku-4.5' "$(cp_agents_model_short claude-haiku-4-5-20251001)" 'dated id: date dropped, version dotted'
assert_eq 'opus-5.5'  "$(cp_agents_model_short claude-opus-5-5)"  'undated id'
assert_eq 'fable-5.1' "$(cp_agents_model_short claude-fable-5-1)" 'fable'
assert_eq 'sonnet-5'  "$(cp_agents_model_short claude-sonnet-5)"  'single version part'
assert_eq 'haiku'     "$(cp_agents_model_short haiku)"            'an alias renders as-is'
assert_eq 'claude-3-5-sonnet-20241022' "$(cp_agents_model_short claude-3-5-sonnet-20241022)" \
  'version before family does not fit the shape: as-is'
assert_eq '' "$(cp_agents_model_short '')" 'empty in, empty out'
# --- duration ---------------------------------------------------------------
assert_eq '0s'     "$(cp_agents_duration 0)"    'zero'
assert_eq '59s'    "$(cp_agents_duration 59)"   'under a minute'
assert_eq '1m 0s'  "$(cp_agents_duration 60)"   'exactly a minute'
assert_eq '1m 12s' "$(cp_agents_duration 72)"   'minutes and seconds'
assert_eq '1h 0m'  "$(cp_agents_duration 3600)" 'exactly an hour drops seconds'
assert_eq '1h 4m'  "$(cp_agents_duration 3840)" 'hours and minutes'
assert_eq '25h 0m' "$(cp_agents_duration 90000)" 'no day unit'
assert_fail cp_agents_duration abc
# --- clock seam -------------------------------------------------------------
assert_eq '1700000000' "$(CP_AGENTS_NOW=1700000000 cp_agents_now)" 'the seam wins'
assert_eq "$(date +%s)" "$(CP_AGENTS_NOW=junk cp_agents_now)" 'a non-numeric seam is ignored'
# --- reading one agent ------------------------------------------------------
AG="$CP_T_TMP/sess/subagents"; mkdir -p "$AG"
HB_TEXT='{"success":true,"message":"Report delivered to your caller."}'
r_asst()  { jq -cn --arg m "$1" '{type:"assistant",timestamp:"2026-11-10T09:00:00.000Z",message:{model:$m,content:[{type:"text",text:"x"}]}}'; }
r_hb()    { jq -cn --arg t "$HB_TEXT" '{type:"user",message:{content:[{type:"tool_result",tool_use_id:"t1",content:[{type:"text",text:$t}]}]}}'; }
r_quote() { jq -cn --arg t "grep found: $HB_TEXT in a file" '{type:"user",message:{content:[{type:"tool_result",tool_use_id:"t2",content:[{type:"text",text:$t}]}]}}'; }
r_intr()  { jq -cn '{type:"user",message:{content:[{type:"text",text:"[Request interrupted by user]"}]}}'; }
ag() {   # ag <id> <meta-json> <record-lines...>
  local id="$1" meta="$2"; shift 2
  printf '%s\n' "$meta" > "$AG/agent-$id.meta.json"
  printf '%s\n' "$@" > "$AG/agent-$id.jsonl"
}
insp() { cp_agents_inspect "$AG/agent-$1.jsonl" "$AG/agent-$1.meta.json" "${2:-1}"; }
M='{"agentType":"Explore","description":"Find callers"}'
ag run "$M" "$(r_asst claude-opus-5-5)"
assert_eq "running	Explore	claude-opus-5-5	Find callers	0" "$(insp run)" 'no handback: running'
ag fin "$M" "$(r_asst claude-opus-5-5)" "$(r_hb)"
assert_eq "finished	Explore	claude-opus-5-5	Find callers	0" "$(insp fin)" 'handback after the last assistant record: finished'
ag res "$M" "$(r_asst a-1)" "$(r_hb)" "$(r_asst claude-opus-5-5)"
assert_eq running "$(insp res | cut -f1)" 'assistant activity after a handback: running again'
ag quo "$M" "$(r_asst claude-opus-5-5)" "$(r_quote)"
assert_eq running "$(insp quo | cut -f1)" 'a tool_result that merely quotes the handback text is not a handback'
ag mfin '{"agentType":"Explore","description":"d","finished":true}' "$(r_asst claude-opus-5-5)"
assert_eq "finished	1" "$(insp mfin | cut -f1,5)" 'meta finished wins without a handback in the tail'
ag stop '{"agentType":"Explore","description":"d","stoppedByUser":true}' "$(r_asst claude-opus-5-5)"
assert_eq stopped "$(insp stop | cut -f1)" 'stoppedByUser'
ag intr "$M" "$(r_asst claude-opus-5-5)" "$(r_intr)"
assert_eq stopped "$(insp intr | cut -f1)" 'interrupt record as the last user record, no handback'
# model sources, in order
ag mpk '{"agentType":"E","description":"d","pickedEffortModel":"claude-fable-5-1","model":"haiku"}' '{"type":"attachment"}'
assert_eq claude-fable-5-1 "$(insp mpk | cut -f3)" 'no assistant record in the tail: pickedEffortModel'
ag mal '{"agentType":"E","description":"d","model":"haiku"}' '{"type":"attachment"}'
assert_eq haiku "$(insp mal | cut -f3)" 'then the meta alias'
ag mno '{"agentType":"E","description":"d"}' '{"type":"attachment"}'
assert_eq '' "$(insp mno | cut -f3)" 'no model anywhere: empty'
ag mlast "$M" "$(r_asst claude-haiku-4-5-20251001)" "$(r_asst claude-opus-5-5)"
assert_eq claude-opus-5-5 "$(insp mlast | cut -f3)" 'the last assistant record wins'
# partial first line when the tail is not the whole file
ag part "$M" '{"type":"assistant","message":{"model":"claude-trunc' "$(r_asst claude-opus-5-5)"
assert_eq claude-opus-5-5 "$(insp part 0 | cut -f3)" 'a partial first line is discarded, not fatal'
# hostile and long strings
ag hos "$(jq -cn '{agentType:("Ex"+([27]|implode)+"[31mplore"),description:("a"+([9,10]|implode)+"b")}')" "$(r_asst claude-opus-5-5)"
assert_eq "Ex[31mplore	ab" "$(insp hos | cut -f2,4)" 'characters below 32 are dropped (ESC, tab, newline)'
ag long "$(jq -cn --arg d "$(printf 'é%.0s' $(seq 1 70))" '{agentType:"E",description:$d}')" "$(r_asst x)"
assert_eq "$(printf 'é%.0s' $(seq 1 59))…" "$(insp long | cut -f4)" 'multibyte description cut to 59 characters plus an ellipsis'
ag ok60 "$(jq -cn --arg d "$(printf 'x%.0s' $(seq 1 60))" '{agentType:"E",description:$d}')" "$(r_asst x)"
assert_eq 60 "$(insp ok60 | cut -f4 | tr -d '\n' | wc -m | tr -d ' ')" 'exactly 60 characters is not cut'
# meta problems
printf '%s\n' "$(r_asst x)" > "$AG/agent-nometa.jsonl"
assert_eq '' "$(insp nometa)" 'no meta.json: nothing'
ag badm 'not json' "$(r_asst x)"
assert_eq '' "$(insp badm)" 'malformed meta.json: nothing'
# malformed records must not blank the agent
MM='{"agentType":"E","description":"d","model":"haiku"}'
ag mu "$MM" '{"type":"assistant","message":{"model":"m-1"}}' '{"type":"user","message":"hello"}'
assert_eq "running	m-1" "$(insp mu | cut -f1,3)" 'a user record whose message is a string is skipped, not fatal'
ag ma "$MM" '{"type":"assistant","message":"x"}'
assert_eq "running	haiku" "$(insp ma | cut -f1,3)" 'an assistant record whose message is a string: meta model'
ag mc "$MM" '{"type":"assistant","message":{"model":7,"content":5}}' '{"type":"user","message":{"content":{"a":1}}}' '{"type":"user","message":{"content":[7,null,{"type":"tool_result","content":[1,{"type":"text","text":5}]}]}}'
assert_eq "running	haiku" "$(insp mc | cut -f1,3)" 'non-array content, non-string model and text are tolerated'
# --- choosing and timing the visible agents ---------------------------------
# Each case gets a fresh directory. Birth time cannot be set forward with
# touch, so durations are computed from the birth read back with stat; moving
# an mtime into the past drags birth with it, which the hiding and ordering
# cases rely on.
NOW="$(date +%s)"
at()   { date -r "$1" '+%Y%m%d%H%M.%S'; }            # epoch -> touch -t stamp
age()  { touch -t "$(at $((NOW - $2)))" "$1"; }       # age <file> <seconds-ago>
fut()  { touch -t "$(at $((NOW + $2)))" "$1"; }       # fut <file> <seconds-ahead>
rows() { cp_agents_rows "$AG" "$NOW" "${1:-600}" "${2:-120}"; }
birth() { stat -f %B "$AG/agent-$1.jsonl"; }
ageboth() { age "$AG/agent-$1.jsonl" "$2"; age "$AG/agent-$1.meta.json" "$2"; }
RN=0
fresh() { RN=$((RN + 1)); AG="$CP_T_TMP/rows$RN/subagents"; mkdir -p "$AG"; }
nrows() { if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi; }
MF='{"agentType":"Explore","description":"Find callers","finished":true}'
MS='{"agentType":"Explore","description":"Find callers","stoppedByUser":true}'

assert_eq '' "$(cp_agents_rows "$CP_T_TMP/none" "$NOW" 600 120)" 'no subagents dir: nothing'

fresh; ag run "$M" "$(r_asst claude-opus-5-5)"; b="$(birth run)"
assert_eq "running	Explore	claude-opus-5-5	Find callers	$((NOW + 75 - b))" \
  "$(cp_agents_rows "$AG" $((NOW + 75)) 600 120)" 'running, recently written: shown with now minus birth'
fresh; ag run "$M" "$(r_asst claude-opus-5-5)"; ageboth run 601
assert_eq '' "$(rows)" 'running, silent past stale_after: abandoned, hidden'
fresh; ag run "$M" "$(r_asst claude-opus-5-5)"; ageboth run 600
assert_eq 1 "$(nrows "$(rows)")" 'running, silent exactly stale_after: still shown'

fresh; ag fin "$M" "$(r_asst claude-opus-5-5)" "$(r_hb)"; ageboth fin 119
assert_eq finished "$(rows | cut -f1)" 'finished within keep_finished: shown'
fresh; ag fin "$M" "$(r_asst claude-opus-5-5)" "$(r_hb)"; ageboth fin 121
assert_eq '' "$(rows)" 'finished past keep_finished: hidden'
fresh; ag fin "$M" "$(r_asst claude-opus-5-5)" "$(r_hb)"; ageboth fin 0
assert_eq '' "$(rows 600 0)" 'keep_finished 0 hides a just-finished agent'

fresh; ag mf "$MF" "$(r_asst claude-opus-5-5)"; b="$(birth mf)"
fut "$AG/agent-mf.jsonl" 40; fut "$AG/agent-mf.meta.json" 50
assert_eq "finished	$((NOW + 50 - b))" "$(cp_agents_rows "$AG" $((NOW + 60)) 600 120 | cut -f1,5)" \
  'meta finished: end is the meta mtime'
fresh; ag hf "$M" "$(r_asst claude-opus-5-5)" "$(r_hb)"; b="$(birth hf)"
fut "$AG/agent-hf.jsonl" 40; fut "$AG/agent-hf.meta.json" 50
assert_eq "finished	$((NOW + 40 - b))" "$(cp_agents_rows "$AG" $((NOW + 60)) 600 120 | cut -f1,5)" \
  'handback-only finished: end is the jsonl mtime'
fresh; ag st "$MS" "$(r_asst claude-opus-5-5)"; b="$(birth st)"
fut "$AG/agent-st.jsonl" 50; fut "$AG/agent-st.meta.json" 40
assert_eq "stopped	$((NOW + 50 - b))" "$(cp_agents_rows "$AG" $((NOW + 60)) 600 120 | cut -f1,5)" \
  'stopped: end is the later mtime'
fresh; ag st "$MS" "$(r_asst claude-opus-5-5)"; ageboth st 119
assert_eq stopped "$(rows | cut -f1)" 'stopped: within keep_finished, shown'
fresh; ag st "$MS" "$(r_asst claude-opus-5-5)"; ageboth st 121
assert_eq '' "$(rows)" 'stopped: past keep_finished, hidden'

# Ordering. Births are set by ageing into the past first, then the mtimes are
# brought forward again (that leaves birth where it is).
fresh
ag r1 '{"agentType":"E","description":"r1"}' "$(r_asst m)"; ageboth r1 100; ageboth r1 5
ag r2 '{"agentType":"E","description":"r2"}' "$(r_asst m)"; ageboth r2 50; ageboth r2 5
ag f1 '{"agentType":"E","description":"f1","finished":true}' "$(r_asst m)"; ageboth f1 200; ageboth f1 30
ag s1 '{"agentType":"E","description":"s1","stoppedByUser":true}' "$(r_asst m)"; ageboth s1 200; ageboth s1 10
assert_eq "running r2 running r1 stopped s1 finished f1" "$(rows | cut -f1,4 | tr '\t\n' '  ' | sed 's/ $//')" \
  'ordering: running newest first, then finished/stopped newest-ended first'

fresh; ag a "$M" "$(r_asst claude-opus-5-5)"
printf '%s\n' "$(r_asst x)" > "$AG/agent-nometa.jsonl"
assert_eq Explore "$(rows | cut -f2)" 'meta.json missing beside a jsonl: that agent skipped, others still shown'

fresh; ag fu "$M" "$(r_asst claude-opus-5-5)"; fut "$AG/agent-fu.jsonl" 300; fut "$AG/agent-fu.meta.json" 300
out="$(rows)"; d="$(printf '%s\n' "$out" | cut -f5)"
case "$d" in '' | *[!0-9]*) d=-1 ;; esac
assert_eq "running	ok" "$(printf '%s\t%s' "$(printf '%s\n' "$out" | cut -f1)" "$([ "$d" -ge 0 ] && echo ok)")" \
  'mtime in the future: age counts as 0, duration never negative'

fresh
i=0
while [ "$i" -lt 120 ]; do
  printf '%s\n' "$M" > "$AG/agent-old$i.meta.json"
  printf '%s\n' '{"type":"assistant","message":{"model":"m"}}' > "$AG/agent-old$i.jsonl"
  i=$((i + 1))
done
touch -t "$(at $((NOW - 3600)))" "$AG"/agent-old*
ag live '{"agentType":"E","description":"live"}' "$(r_asst m)"
assert_eq live "$(rows | cut -f4)" '120 stale agents and one live one: exactly one row'
# The per-tick cost must not grow with session history: with the same 120
# stale agents, only the live one is ever handed to cp_agents_inspect.
cp_agents_inspect() { printf '%s\n' "$1" >> "$CP_T_TMP/inspected"; }
: > "$CP_T_TMP/inspected"
rows > /dev/null
# shellcheck source=/dev/null
. "$(dirname "$0")/../scripts/lib/agents.sh"   # the real cp_agents_inspect again
assert_eq "$AG/agent-live.jsonl" "$(cat "$CP_T_TMP/inspected")" 'stale agents are never inspected'

fresh
printf '%s\n' '{"agentType":"E","description":"big","model":"haiku"}' > "$AG/agent-big.meta.json"
{
  r_asst claude-head-9-9
  yes "{\"type\":\"attachment\",\"pad\":\"$(printf 'x%.0s' $(seq 1 1000))\"}" | head -n 2100
} > "$AG/agent-big.jsonl"
assert_eq haiku "$(rows | cut -f3)" 'a large jsonl is not read from the head'

# Birth time unavailable (stat reports 0): the first record timestamp, then the
# jsonl mtime. stat is shadowed in a subshell to zero the birth field.
# shellcheck disable=SC2329  # the stat shadow is called by cp_agents_rows
nobirth() { (stat() { command stat "$@" | awk -F '\t' 'BEGIN { OFS = "\t" } { $2 = 0; print }'; }
  cp_agents_rows "$AG" "$1" 600 120); }
T0="$(cp_time_epoch 2026-11-10T09:00:00.000Z)"
fresh; ag nb "$M" "$(r_asst claude-opus-5-5)"
touch -t "$(at $((T0 + 50)))" "$AG/agent-nb.jsonl" "$AG/agent-nb.meta.json"
assert_eq 100 "$(nobirth $((T0 + 100)) | cut -f5)" 'birth unavailable: start is the first record timestamp'
fresh; ag nt "$M" '{"type":"assistant","message":{"model":"m"}}'
touch -t "$(at $((T0 + 50)))" "$AG/agent-nt.jsonl" "$AG/agent-nt.meta.json"
assert_eq 50 "$(nobirth $((T0 + 100)) | cut -f5)" 'birth and timestamp unavailable: start is the jsonl mtime'

fresh; ag em '{"agentType":"E","description":" d "}' '{"type":"attachment"}'
assert_eq "running	E		 d " "$(rows | cut -f1-4)" 'an empty model field keeps its place; spaces in a description survive'

fresh; printf '%s\n' "$M" > "$AG/agent-onlymeta.meta.json"
out="$(rows 2>"$CP_T_TMP/err")"; rc=$?
assert_eq "0||" "$rc|$out|$(cat "$CP_T_TMP/err")" 'only meta files, no jsonl: nothing, rc 0, no stderr'
fresh
out="$(rows 2>"$CP_T_TMP/err")"; rc=$?
assert_eq "0||" "$rc|$out|$(cat "$CP_T_TMP/err")" 'empty dir: nothing, rc 0, no stderr'

# --- cp_agents_render ---
R1="$(printf 'running\tgeneral-purpose\tclaude-opus-5-5\tImplement Task 2: cache layer\t72')"
R2="$(printf 'finished\tclaude-code-guide\tclaude-haiku-4-5-20251001\tCheck subagent lifecycle hooks\t3')"
R3="$(printf 'stopped\tExplore\t\tFind callers\t14')"
R4="$(printf 'running\t\tx\t \t5')"
assert_eq '⟳ general-purpose [opus-5.5]: Implement Task 2: cache layer (1m 12s)' \
  "$(cp_agents_render "$R1" 3 0 '' '')" 'plain running row'
assert_eq '✓ claude-code-guide [haiku-4.5]: Check subagent lifecycle hooks (3s)' \
  "$(cp_agents_render "$R2" 3 0 '' '')" 'plain finished row, the agreed format'
assert_eq '✗ Explore: Find callers (14s)' "$(cp_agents_render "$R3" 3 0 '' '')" 'no model: no brackets'
assert_eq '⟳ agent [x] (5s)' "$(cp_agents_render "$R4" 3 0 '' '')" 'empty type: agent; blank description: no colon'
assert_eq '' "$(cp_agents_render '' 3 0 '' '')" 'no rows: nothing'
five="$(printf '%s\n' "$R1" "$R1" "$R2" "$R3" "$R3")"
assert_eq 4 "$(cp_agents_render "$five" 3 0 '' '' | grep -c .)" 'three rows plus one more-line'
assert_eq '+2 more' "$(cp_agents_render "$five" 3 0 '' '' | tail -n 1)" 'the hidden count'
three="$(printf '%s\n' "$R1" "$R2" "$R3")"
assert_eq 3 "$(cp_agents_render "$three" 3 0 '' '' | grep -c .)" 'exactly max_rows: no more-line'
assert_eq "${ESC}[33m⟳${ESC}[0m general-purpose ${ESC}[36m[opus-5.5]${ESC}[0m: Implement Task 2: cache layer ${ESC}[2m(1m 12s)${ESC}[0m" \
  "$(cp_agents_render "$R1" 3 1 36 2)" 'colour: yellow glyph, model colour, dim duration'
case "$(cp_agents_render "$R2" 3 1 36 2)" in "${ESC}[32m✓${ESC}[0m "*) r=ok ;; *) r=bad ;; esac
assert_eq ok "$r" 'finished glyph green'
case "$(cp_agents_render "$R3" 3 1 36 2)" in "${ESC}[31m✗${ESC}[0m "*) r=ok ;; *) r=bad ;; esac
assert_eq ok "$r" 'stopped glyph red'
assert_eq "${ESC}[2m+2 more${ESC}[0m" "$(cp_agents_render "$five" 3 1 36 2 | tail -n 1)" 'more-line in the label colour'
case "$(cp_agents_render "$R1" 3 0 36 2)" in *"$ESC"*) r=bad ;; *) r=ok ;; esac
assert_eq ok "$r" 'colour off: no escape bytes even with SGR arguments'
assert_eq 4 "$(cp_agents_render "$five" abc 0 '' '' | grep -c .)" 'invalid max_rows falls back to 3'
assert_eq 4 "$(cp_agents_render "$five" 0 0 '' '' | grep -c .)" 'max_rows 0 falls back to 3'
assert_eq 0 "$(cp_agents_render "$R1" 3 0 '' '' | tail -c 1 | wc -l | tr -d ' ')" 'no trailing newline'

cp_t_summary
