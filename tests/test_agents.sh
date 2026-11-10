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
cp_t_summary
