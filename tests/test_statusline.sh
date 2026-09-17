#!/usr/bin/env bash
set -u
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
for lib in config resolve profiles auth output color usage statusline fallback share; do
  # shellcheck source=/dev/null
  . "$(dirname "$0")/../scripts/lib/$lib.sh"
done
CLI="$(cd "$(dirname "$0")/.." && pwd -P)/scripts/cprof"
SEG="$(cd "$(dirname "$0")/.." && pwd -P)/statusline/segment.sh"
ESC="$(printf '\033')"

mkdir -p "$CP_T_TMP/p" "$CP_T_TMP/state/usage"
cp_t_write_config <<JSON
{"default":"work",
 "profiles":[{"name":"work","native":true,"color":"magenta"},
             {"name":"personal","dir":"$CP_T_TMP/p"}],
 "rules":[],"repos":{}}
JSON

# --- the payload's own fields ----------------------------------------------
meta() { printf '%s' "$1" | cp_sl_meta_fields; }
assert_eq "Opus 5	/tmp/x" "$(meta '{"model":{"display_name":"Opus 5"},"cwd":"/tmp/x"}')" \
  'meta reads the model name and the directory'
assert_eq "Opus 5	/ws" "$(meta '{"model":{"display_name":"Opus 5"},"cwd":"/tmp/x","workspace":{"current_dir":"/ws"}}')" \
  'the workspace directory wins over cwd'
assert_eq "	" "$(meta '{}')" 'an empty payload yields empty fields'
assert_eq '' "$(meta 'not json')" 'a malformed payload prints nothing, not an error'
assert_eq "	/tmp/x" "$(meta '{"model":{"display_name":42},"cwd":"/tmp/x"}')" 'a non-string model name is dropped'
long="$(printf 'x%.0s' $(seq 1 250))"
payload="$(printf '{"model":{"display_name":"%s"},"cwd":"%s"}' "$long" "$long")"
assert_eq "	" "$(meta "$payload")" \
  'absurdly long strings are dropped: the payload is untrusted and a statusline has one line'
boundary200="$(printf 'x%.0s' $(seq 1 200))"
payload200="$(printf '{"model":{"display_name":"%s"},"cwd":"/tmp"}' "$boundary200")"
assert_eq "$boundary200	/tmp" "$(meta "$payload200")" \
  'a 200-character model name survives'
boundary201="$(printf 'x%.0s' $(seq 1 201))"
payload201="$(printf '{"model":{"display_name":"%s"},"cwd":"/tmp"}' "$boundary201")"
assert_eq "	/tmp" "$(meta "$payload201")" \
  'a 201-character model name is dropped'

# --- what to show for a directory ------------------------------------------
assert_eq 'cprof' "$(cp_sl_dir_label /Users/x/dev/cprof)" 'the last path segment names the directory'
assert_eq '~' "$(cp_sl_dir_label "$HOME")" 'home itself shows as ~'
assert_eq '' "$(cp_sl_dir_label '')" 'no directory, nothing to show'

# --- branch and dirty marker ------------------------------------------------
R="$CP_T_TMP/repo"
git init -q "$R" 2>/dev/null
gitq() { git -C "$R" -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false "$@"; }
# An unborn branch has no HEAD to resolve, but it does have a name.
unborn="$(cp_sl_git_fields "$R" | cut -f1)"
assert_eq 'true' "$([ -n "$unborn" ] && echo true || echo false)" 'a fresh repository still reports its branch'
: > "$R/f"
gitq add f >/dev/null 2>&1
gitq commit -qm first >/dev/null 2>&1
gitq checkout -q -b feat/thing 2>/dev/null
assert_eq "feat/thing	" "$(cp_sl_git_fields "$R")" 'a clean tree reports the branch and no marker'
: > "$R/untracked"
assert_eq "feat/thing	*" "$(cp_sl_git_fields "$R")" 'an untracked file makes the tree dirty'
rm -f "$R/untracked"
printf 'changed\n' > "$R/f"
assert_eq "feat/thing	*" "$(cp_sl_git_fields "$R")" 'a modified file makes the tree dirty'
gitq checkout -q -- f 2>/dev/null
gitq checkout -q --detach HEAD 2>/dev/null
assert_eq "$(gitq rev-parse --short HEAD)	" "$(cp_sl_git_fields "$R")" 'a detached HEAD reports the short sha'
assert_eq '' "$(cp_sl_git_fields "$CP_T_TMP/p")" 'a directory outside a working tree reports nothing'
assert_eq '' "$(cp_sl_git_fields "$CP_T_TMP/nowhere")" 'a directory that does not exist reports nothing'
assert_eq '' "$(cp_sl_git_fields '')" 'no directory reports nothing'

# --- the bar's filled run is the value, the rest is background --------------
assert_eq "${ESC}[32m▓▓▓${ESC}[2m░░░░░░░${ESC}[0m" "$(cp_sl_bar "$(cp_usage_bar 30)" 32 '░')" 'the filled run carries the colour'
assert_eq "${ESC}[32m${ESC}[2m░░░░░░░░░░${ESC}[0m" "$(cp_sl_bar "$(cp_usage_bar 0)" 32 '░')" 'an empty bar is all background'
assert_eq "${ESC}[31m▓▓▓▓▓▓▓▓▓▓${ESC}[2m${ESC}[0m" "$(cp_sl_bar "$(cp_usage_bar 100)" 31 '░')" 'a full bar is all value'
assert_eq '▓▓░░░░░░░░' "$(cp_sl_bar "$(cp_usage_bar 20)" '' '░')" 'no colour to use, plain bar'
assert_eq "${ESC}[32m██${ESC}[2m···${ESC}[0m" "$(cp_sl_bar "$(cp_usage_bar 40 '█' '·' 5)" 32 '·')" \
  'the filled run is found by cutting at the configured empty glyph'

# --- the whole statusline, plain -------------------------------------------
soon=$(( $(date +%s) + 4*3600 + 20*60 + 30 ))
PAY="$(printf '{"cwd":"%s","model":{"display_name":"Opus 5 (1M context)"},"context_window":{"used_percentage":23},"rate_limits":{"five_hour":{"used_percentage":22,"resets_at":%s}}}' "$R" "$soon")"
out="$(printf '%s' "$PAY" | NO_COLOR=1 "$CLI" statusline --stdin 2>/dev/null)"
assert_eq "⚑ work │ [Opus 5 (1M context)] │ repo git:($(gitq rev-parse --short HEAD))
Context $(cp_usage_bar 23) 23% │ Usage $(cp_usage_bar 22) 22% (resets in 4h 20m)" "$out" \
  'the full statusline: account, model, directory and branch, then both bars'
assert_eq '2' "$(printf '%s' "$PAY" | NO_COLOR=1 "$CLI" statusline --stdin 2>/dev/null | wc -l | tr -d ' ')" \
  'two lines, so the layout is predictable'

# without a payload there is nothing to say but the account and its cache
assert_eq '⚑ work' "$(NO_COLOR=1 "$CLI" statusline 2>/dev/null)" 'no payload and no cache: the account alone'
cat > "$CP_T_TMP/state/usage/work.json" <<'JSON'
{"fetched_at":1,"five_hour":{"utilization":73,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":10},"limits":[]}
JSON
assert_eq "⚑ work
Usage $(cp_usage_bar 73) 73%" "$(NO_COLOR=1 "$CLI" statusline 2>/dev/null)" 'no payload: the account and the cached usage'
# a payload with no rate_limits still leaves the cache to fill the usage bar
out="$(printf '{"cwd":"%s","context_window":{"used_percentage":5}}' "$R" | NO_COLOR=1 "$CLI" statusline --stdin 2>/dev/null)"
assert_eq "⚑ work │ repo git:($(gitq rev-parse --short HEAD))
Context $(cp_usage_bar 5) 5% │ Usage $(cp_usage_bar 73) 73%" "$out" \
  'no model in the payload: that field is skipped, the rest still renders'
rm -f "$CP_T_TMP/state/usage/work.json"

# --- and coloured ----------------------------------------------------------
out="$(printf '%s' "$PAY" | "$CLI" statusline --stdin 2>/dev/null)"
case "$out" in
  *"${ESC}[35m⚑ work${ESC}[0m"*) assert_eq ok ok 'the badge carries the profile colour' ;;
  *) assert_eq 'magenta badge' "$out" 'the badge carries the profile colour' ;;
esac
case "$out" in
  *"${ESC}[36m[Opus 5 (1M context)]${ESC}[0m"*) assert_eq ok ok 'the model is set apart from the account' ;;
  *) assert_eq 'coloured model' "$out" 'the model is set apart from the account' ;;
esac
case "$out" in
  *"${ESC}[35mgit:(${ESC}[0m${ESC}[36m"*) assert_eq ok ok 'the branch is wrapped in git:()' ;;
  *) assert_eq 'git:(branch)' "$out" 'the branch is wrapped in git:()' ;;
esac
case "$out" in
  *"${ESC}[2mContext${ESC}[0m"*"${ESC}[2mUsage${ESC}[0m"*"${ESC}[2m(resets in 4h 20m)${ESC}[0m"*)
     assert_eq ok ok 'labels and the reset note are dim, the values are not' ;;
  *) assert_eq 'dim labels' "$out" 'labels and the reset note are dim, the values are not' ;;
esac
# --text off keeps the colour on the flag alone
printf '%s' "$(cat "$CPROF_CONFIG")" | jq '.colorText = false' > "$CP_T_TMP/c.json" && mv "$CP_T_TMP/c.json" "$CPROF_CONFIG"
out="$(printf '%s' "$PAY" | "$CLI" statusline --stdin 2>/dev/null)"
case "$out" in
  *"${ESC}[35m⚑${ESC}[0m ${ESC}[2mwork${ESC}[0m"*) assert_eq ok ok '--text off colours the flag only' ;;
  *) assert_eq 'flag-only colour' "$out" '--text off colours the flag only' ;;
esac
printf '%s' "$(cat "$CPROF_CONFIG")" | jq 'del(.colorText)' > "$CP_T_TMP/c.json" && mv "$CP_T_TMP/c.json" "$CPROF_CONFIG"

# --- silence and failure ----------------------------------------------------
cp_t_write_config <<JSON
{"default":"personal","profiles":[{"name":"personal","dir":"$CP_T_TMP/p"}],"rules":[],"repos":{}}
JSON
assert_eq '' "$("$CLI" statusline 2>/dev/null)" 'no profile to name for this session, nothing printed'
cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","native":true}],"rules":[],"repos":{}}
JSON
rc=0; "$CLI" statusline --bogus >/dev/null 2>&1 || rc=$?
assert_eq '2' "$rc" 'an unknown flag is refused'
( CPROF_CONFIG=/dev/null "$CLI" statusline >/dev/null 2>&1 )
assert_eq '0' "$?" 'an unusable config still exits 0'

# --- the segment's --full flag is the same output --------------------------
a="$(printf '%s' "$PAY" | NO_COLOR=1 "$CLI" statusline --stdin 2>/dev/null)"
b="$(printf '%s' "$PAY" | NO_COLOR=1 bash "$SEG" --full 2>/dev/null)"
assert_eq "$a" "$b" 'segment --full prints exactly what the command prints'
# ... and the one-line contract still holds without it
assert_eq '1' "$(printf '%s' "$PAY" | NO_COLOR=1 bash "$SEG" --stdin 2>/dev/null | wc -l | tr -d ' ')" \
  'segment --stdin still prints one line'
leftover="$(printf '%s' "$PAY" | { NO_COLOR=1 bash "$SEG" >/dev/null 2>&1; cat; })"
assert_eq "$PAY" "$leftover" 'the flagless segment still leaves the payload for the next component'
( CPROF_CONFIG=/dev/null bash "$SEG" --full </dev/null >/dev/null 2>&1 )
assert_eq '0' "$?" 'segment --full never fails the statusline'

# --- resolved configuration -------------------------------------------------
cfgline() { cp_sl_config "$1" | sed -n "${2}p"; }
DEFLAYOUT='badge model dir git;context usage'
assert_eq "$DEFLAYOUT" "$(cfgline '{}' 1)" 'no statusline block: the default layout'
assert_eq "▓	░	10" "$(cfgline '{}' 2)" 'no statusline block: cprof own bar, ten cells'
assert_eq "70	90" "$(cfgline '{}' 3)" 'no statusline block: the documented thresholds'
assert_eq "cyan	yellow	magenta	cyan	dim" "$(cfgline '{}' 4)" 'no statusline block: the default palette'
assert_eq 'badge;context usage' "$(cfgline '{"statusline":{"lines":[["badge"],["context","usage"]]}}' 1)" \
  'a configured layout is honoured, line by line'
assert_eq 'badge model' "$(cfgline '{"statusline":{"lines":[["badge","nonsense","model"]]}}' 1)" \
  'an unknown segment name is dropped, the rest of the line survives'
assert_eq "$DEFLAYOUT" "$(cfgline '{"statusline":{"lines":"nonsense"}}' 1)" \
  'a layout that is not an array falls back whole'
assert_eq "$DEFLAYOUT" "$(cfgline '{"statusline":{"lines":[[],["also-nonsense"]]}}' 1)" \
  'a layout that validates to nothing falls back whole'
assert_eq "█	·	24" "$(cfgline '{"statusline":{"bar":{"filled":"█","empty":"·","width":24}}}' 2)" \
  'bar glyphs and width are configurable'
assert_eq "▓	░	10" "$(cfgline '{"statusline":{"bar":{"filled":"ab","empty":5,"width":99}}}' 2)" \
  'a multi-character glyph, a non-string glyph and an out-of-range width each fall back'
assert_eq "▓	░	1" "$(cfgline '{"statusline":{"bar":{"width":1}}}' 2)" 'a width of exactly one is accepted'
assert_eq "▓	░	40" "$(cfgline '{"statusline":{"bar":{"width":40}}}' 2)" 'a width of exactly forty is accepted'
assert_eq "50	80" "$(cfgline '{"statusline":{"thresholds":{"warn":50,"critical":80}}}' 3)" \
  'thresholds are configurable'
assert_eq "70	90" "$(cfgline '{"statusline":{"thresholds":{"warn":80,"critical":50}}}' 3)" \
  'a warn threshold at or above critical falls back to both defaults'
assert_eq "70	90" "$(cfgline '{"statusline":{"thresholds":{"warn":50,"critical":50}}}' 3)" \
  'a warn threshold equal to critical falls back too, proving the comparison is strict'
assert_eq "70	90" "$(cfgline '{"statusline":{"thresholds":{"warn":0,"critical":101}}}' 3)" \
  'thresholds outside one to a hundred fall back'
assert_eq "1	100" "$(cfgline '{"statusline":{"thresholds":{"warn":1,"critical":100}}}' 3)" \
  'thresholds at exactly one and exactly a hundred are accepted'
assert_eq "70	90" "$(cfgline '{"statusline":{"thresholds":{"warn":50.5,"critical":80}}}' 3)" \
  'a fractional threshold falls back'
assert_eq "red	blue	green	bright-cyan	dim" \
  "$(cfgline '{"statusline":{"colors":{"model":"red","dir":"blue","git":"green","branch":"bright-cyan"}}}' 4)" \
  'colours are configurable and an unset one keeps its default'
assert_eq "cyan	yellow	magenta	cyan	dim" "$(cfgline '{"statusline":{"colors":{"model":123}}}' 4)" \
  'a non-string colour value falls back to its default'
assert_eq '4' "$(cp_sl_config '{}' | wc -l | tr -d ' ')" 'always exactly four lines'
assert_eq "$DEFLAYOUT" "$(cfgline 'not json' 1)" 'an unreadable config yields the defaults'
assert_eq '4' "$(cp_sl_config '' | wc -l | tr -d ' ')" 'an empty config argument still yields four lines'
assert_eq "$DEFLAYOUT" "$(cfgline '' 1)" 'an empty config argument yields the default layout'
assert_eq "$(cp_sl_config '{}')" "$(cp_sl_config 'not json')" \
  'the fallback and the jq defaults cannot drift apart'

# --- the configured layout drives the output -------------------------------
mkcfg() { cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","native":true,"color":"magenta"}],
 "rules":[],"repos":{},"statusline":$1}
JSON
}
SOON=$(( $(date +%s) + 2*3600 + 5*60 + 30 ))
PAY2="$(printf '{"cwd":"%s","model":{"display_name":"M"},"context_window":{"used_percentage":30},"rate_limits":{"five_hour":{"used_percentage":40,"resets_at":%s}}}' "$R" "$SOON")"
mkcfg '{"lines":[["badge"],["model"],["context"],["usage"]]}'
assert_eq "⚑ work
[M]
Context $(cp_usage_bar 30) 30%
Usage $(cp_usage_bar 40) 40% (resets in 2h 5m)" \
  "$(printf '%s' "$PAY2" | NO_COLOR=1 "$CLI" statusline --stdin 2>/dev/null)" \
  'one segment per line renders one line each'
mkcfg '{"lines":[["dir","git"]]}'
assert_eq "repo git:($(gitq rev-parse --short HEAD))" \
  "$(printf '%s' "$PAY2" | NO_COLOR=1 "$CLI" statusline --stdin 2>/dev/null)" \
  'git attaches to dir with a space, not a separator'
mkcfg '{"lines":[["git"]]}'
assert_eq "git:($(gitq rev-parse --short HEAD))" \
  "$(printf '%s' "$PAY2" | NO_COLOR=1 "$CLI" statusline --stdin 2>/dev/null)" \
  'git alone on a line stands by itself'
mkcfg '{"lines":[["model","git"]]}'
assert_eq "[M] │ git:($(gitq rev-parse --short HEAD))" \
  "$(printf '%s' "$PAY2" | NO_COLOR=1 "$CLI" statusline --stdin 2>/dev/null)" \
  'git after a segment that is not dir takes the ordinary separator'
mkcfg '{"lines":[["badge","model"],["dir"]]}'
assert_eq "⚑ work │ [M]
repo" "$(printf '%s' "$PAY2" | NO_COLOR=1 "$CLI" statusline --stdin 2>/dev/null)" \
  'segments on one line are joined with the separator'
mkcfg '{"lines":[["badge"],["model"]]}'
assert_eq '⚑ work' "$(NO_COLOR=1 "$CLI" statusline 2>/dev/null)" \
  'a line whose every segment is empty prints no line at all'
mkcfg '{"lines":[["context","usage"],["badge"]]}'
assert_eq "Context $(cp_usage_bar 30) 30% │ Usage $(cp_usage_bar 40) 40% (resets in 2h 5m)
⚑ work" "$(printf '%s' "$PAY2" | NO_COLOR=1 "$CLI" statusline --stdin 2>/dev/null)" \
  'the badge is not pinned to the first line'
mkcfg '{"lines":[["badge","badge"]]}'
assert_eq '⚑ work │ ⚑ work' "$(printf '%s' "$PAY2" | NO_COLOR=1 "$CLI" statusline --stdin 2>/dev/null)" \
  'a segment named twice renders twice: the layout is taken literally'

# --- the statusline draws the same configured bar as the tables ------------
mkcfg '{"lines":[["context"]],"bar":{"filled":"█","empty":"·","width":5}}'
assert_eq 'Context ██··· 30%' \
  "$(printf '%s' "$PAY2" | NO_COLOR=1 "$CLI" statusline --stdin 2>/dev/null)" \
  'the statusline draws the configured bar'

# --- the statusline derives bar colour from the configured thresholds ------
mkcfg '{"lines":[["usage"]],"thresholds":{"warn":30,"critical":35}}'
out="$(printf '%s' "$PAY2" | "$CLI" statusline --stdin 2>/dev/null)"
case "$out" in *"${ESC}[31m"*) assert_eq ok ok 'usage at 40 is critical once critical is 35' ;;
                *) assert_eq 'red usage' "$out" 'usage at 40 is critical once critical is 35' ;; esac

mkcfg '{"lines":[["context"]],"thresholds":{"warn":30,"critical":35}}'
out="$(printf '%s' "$PAY2" | "$CLI" statusline --stdin 2>/dev/null)"
case "$out" in *"${ESC}[33m"*) assert_eq ok ok 'a configured warn threshold reaches the context bar' ;;
                *) assert_eq 'yellow context bar' "$out" 'a configured warn threshold reaches the context bar' ;; esac

# --- colours ---------------------------------------------------------------
assert_eq '2'  "$(cp_sl_code dim)"           'dim is the one name cp_color_code does not carry'
assert_eq '36' "$(cp_sl_code cyan)"          'a palette name goes through cp_color_code'
assert_eq '91' "$(cp_sl_code bright-red)"    'a bright variant resolves too'
assert_eq ''   "$(cp_sl_code nonsense)"      'an unknown name resolves to nothing, so the caller renders plain'
mkcfg '{"lines":[["model","dir"]],"colors":{"model":"red","dir":"bright-green"}}'
out="$(printf '%s' "$PAY2" | "$CLI" statusline --stdin 2>/dev/null)"
case "$out" in *"${ESC}[31m[M]${ESC}[0m"*"${ESC}[92mrepo${ESC}[0m"*) assert_eq ok ok 'configured colours reach the output' ;;
                *) assert_eq 'red model, bright-green dir' "$out" 'configured colours reach the output' ;; esac
mkcfg '{"lines":[["context"]],"colors":{"label":"blue"}}'
out="$(printf '%s' "$PAY2" | "$CLI" statusline --stdin 2>/dev/null)"
case "$out" in *"${ESC}[34mContext${ESC}[0m"*) assert_eq ok ok 'the label colour covers the Context word' ;;
                *) assert_eq 'blue label' "$out" 'the label colour covers the Context word' ;; esac
mkcfg '{"lines":[["model"]],"colors":{"model":"nonsense"}}'
assert_eq '[M]' "$(printf '%s' "$PAY2" | NO_COLOR=1 "$CLI" statusline --stdin 2>/dev/null)" \
  'an unknown colour still renders the segment'
# The same, with colour actually enabled: NO_COLOR alone proves nothing about
# cp_sl_code, since a plain render is the NO_COLOR path regardless.
assert_eq '[M]' "$(printf '%s' "$PAY2" | "$CLI" statusline --stdin 2>/dev/null)" \
  'an unknown colour still renders the segment plain when colour is otherwise on'
# The badge takes its colour from `cprof color`, so a profile's colour lives in
# one place; a colors.badge setting is not a way in.
mkcfg '{"lines":[["badge"]],"colors":{"badge":"green"}}'
out="$(printf '%s' "$PAY2" | "$CLI" statusline --stdin 2>/dev/null)"
case "$out" in *"${ESC}[35m⚑ work${ESC}[0m"*) assert_eq ok ok 'the badge keeps the profile colour, not a configured one' ;;
                *) assert_eq 'magenta badge' "$out" 'the badge keeps the profile colour, not a configured one' ;; esac

cp_t_summary
