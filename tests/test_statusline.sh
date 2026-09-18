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

# --- the git segment's two colours, both configured and one gone wrong -----
sha="$(gitq rev-parse --short HEAD)"
mkcfg '{"lines":[["dir","git"]],"colors":{"git":"blue","branch":"yellow"}}'
out="$(printf '%s' "$PAY2" | "$CLI" statusline --stdin 2>/dev/null)"
case "$out" in
  *"${ESC}[34mgit:(${ESC}[0m${ESC}[33m${sha}${ESC}[0m${ESC}[34m)${ESC}[0m"*)
    assert_eq ok ok 'a configured git colour and branch colour each paint their own part' ;;
  *) assert_eq 'blue git brackets, yellow branch text' "$out" \
    'a configured git colour and branch colour each paint their own part' ;;
esac
mkcfg '{"lines":[["dir","git"]],"colors":{"git":"green","branch":"nonsense"}}'
out="$(printf '%s' "$PAY2" | "$CLI" statusline --stdin 2>/dev/null)"
assert_eq "$(printf '\033[33mrepo\033[0m git:(%s)' "$sha")" "$out" \
  'one unknown colour in the two-tone git segment renders the whole segment plain'

# --- the separator takes the label colour too -------------------------------
mkcfg '{"lines":[["model","dir"]],"colors":{"label":"blue"}}'
out="$(printf '%s' "$PAY2" | "$CLI" statusline --stdin 2>/dev/null)"
case "$out" in *"${ESC}[34m │ ${ESC}[0m"*) assert_eq ok ok 'a configured label colour paints the separator' ;;
                *) assert_eq 'blue separator' "$out" 'a configured label colour paints the separator' ;; esac
mkcfg '{"lines":[["model","dir"]],"colors":{"label":"nonsense"}}'
out="$(printf '%s' "$PAY2" | "$CLI" statusline --stdin 2>/dev/null)"
assert_eq "$(printf '\033[36m[M]\033[0m │ \033[33mrepo\033[0m')" "$out" \
  'an unknown label colour leaves the separator with no escape sequence'

# --- doctor says what the statusline will not say --------------------------
assert_eq '' "$(cp_sl_config_problems '{}')" 'no statusline block, nothing to report'
assert_eq '' "$(cp_sl_config_problems '{"statusline":{"bar":{"filled":"█"}}}')" 'a valid block, nothing to report'
assert_eq 'statusline.lines: not a list of segment lists; using the default layout' \
  "$(cp_sl_config_problems '{"statusline":{"lines":"nonsense"}}')" 'a malformed layout is reported'
assert_eq 'statusline.lines: unknown segment nonsense (known: badge model dir git context usage)' \
  "$(cp_sl_config_problems '{"statusline":{"lines":[["badge","nonsense"]]}}')" 'an unknown segment is named'
assert_eq 'statusline.bar.filled: must be exactly one character; using ▓' \
  "$(cp_sl_config_problems '{"statusline":{"bar":{"filled":"ab"}}}')" 'a bad glyph is reported with the fallback'
assert_eq 'statusline.bar.width: must be a whole number from 1 to 40; using 10' \
  "$(cp_sl_config_problems '{"statusline":{"bar":{"width":99}}}')" 'a bad width is reported with the fallback'
assert_eq 'statusline.thresholds: warn must be a whole number below critical, both from 1 to 100; using 70 and 90' \
  "$(cp_sl_config_problems '{"statusline":{"thresholds":{"warn":80,"critical":50}}}')" 'inverted thresholds are reported'
assert_eq 'statusline.colors.model: unknown colour nonsense; rendering it plain' \
  "$(cp_sl_config_problems '{"statusline":{"colors":{"model":"nonsense"}}}')" 'an unknown colour is reported'

# --- a shape nobody thought of fails loudly, not silently -------------------
# Each of these used to crash the reporter's jq program partway through and
# print nothing at all -- exactly the silence this function exists to end.
# Built with printf into a plain variable (not a nested-quote command
# substitution inline in the array literal), per this project's bash 3.2
# word-splitting trap.
long="$(printf 'x%.0s' $(seq 1 31))"
longcfg="$(printf '{"statusline":{"colors":{"model":"%s"}}}' "$long")"
SLP_CFG=(
  '{"statusline":{"lines":["badge","model"]}}'
  '{"statusline":"nonsense"}'
  '{"statusline":{"colors":"nonsense"}}'
  "$longcfg"
)
SLP_WANT=(
  'statusline.lines'
  'statusline: not a JSON object'
  'statusline.colors: not a JSON object'
  'statusline.colors.model'
)
SLP_DESC=(
  'a flat lines array, not a list of segment lists, is reported'
  'a statusline value that is not a JSON object is reported'
  'a colors value that is not a JSON object is reported'
  'a colour name of 20 characters or more is reported'
)
i=0
while [ "$i" -lt "${#SLP_CFG[@]}" ]; do
  out="$(cp_sl_config_problems "${SLP_CFG[$i]}")"
  case "$out" in
    *"${SLP_WANT[$i]}"*) assert_eq ok ok "${SLP_DESC[$i]}" ;;
    *) assert_eq "${SLP_WANT[$i]}" "$out" "${SLP_DESC[$i]}" ;;
  esac
  i=$((i + 1))
done

# ... and one bad section can never suppress another section's report
out="$(cp_sl_config_problems '{"statusline":{"bar":"nonsense","thresholds":{"warn":80,"critical":50}}}')"
case "$out" in *'statusline.bar'*) assert_eq ok ok 'a bad bar type is reported' ;;
                *) assert_eq 'statusline.bar' "$out" 'a bad bar type is reported' ;; esac
case "$out" in *'statusline.thresholds'*) assert_eq ok ok 'a bad bar type does not suppress the thresholds report' ;;
                *) assert_eq 'statusline.thresholds' "$out" 'a bad bar type does not suppress the thresholds report' ;; esac
out="$(cp_sl_config_problems '{"statusline":{"thresholds":"high","bar":{"width":99}}}')"
case "$out" in *'statusline.thresholds'*) assert_eq ok ok 'a bad thresholds type is reported' ;;
                *) assert_eq 'statusline.thresholds' "$out" 'a bad thresholds type is reported' ;; esac
case "$out" in *'statusline.bar.width'*) assert_eq ok ok 'a bad thresholds type does not suppress the bar.width report' ;;
                *) assert_eq 'statusline.bar.width' "$out" 'a bad thresholds type does not suppress the bar.width report' ;; esac

# --- null and false are not the same "nothing configured here" -------------
# `null` (explicit, or via an absent key) is a plausible way to write
# "nothing configured" and stays silent, matching cp_sl_config's own `// $d`.
# `false` is never a plausible value for an object-valued section or a
# colour name, so it must be judged the same as any other wrong type rather
# than folded into "nothing configured" the way jq's `//` would fold it.
# Both directions are pinned here so the asymmetry rests on tests, not on a
# comment.
FALSE_CFG=(
  '{"statusline":false}'
  '{"statusline":{"bar":false}}'
  '{"statusline":{"colors":false}}'
  '{"statusline":{"colors":{"model":false}}}'
)
FALSE_WANT=(
  'statusline: not a JSON object'
  'statusline.bar: not a JSON object'
  'statusline.colors: not a JSON object'
  'statusline.colors.model: not a usable colour name; using cyan'
)
FALSE_DESC=(
  'a statusline value of false is reported, not treated as nothing configured'
  'a bar value of false is reported, not treated as nothing configured'
  'a colors value of false is reported, not treated as nothing configured'
  'a boolean colour value is reported, not treated as nothing configured'
)
i=0
while [ "$i" -lt "${#FALSE_CFG[@]}" ]; do
  out="$(cp_sl_config_problems "${FALSE_CFG[$i]}")"
  case "$out" in
    *"${FALSE_WANT[$i]}"*) assert_eq ok ok "${FALSE_DESC[$i]}" ;;
    *) assert_eq "${FALSE_WANT[$i]}" "$out" "${FALSE_DESC[$i]}" ;;
  esac
  i=$((i + 1))
done
assert_eq '' "$(cp_sl_config_problems '{"statusline":null}')" \
  'a statusline value of null stays silent, unlike false'
assert_eq '' "$(cp_sl_config_problems '{"statusline":{"bar":null}}')" \
  'a bar value of null stays silent, unlike false'
assert_eq '' "$(cp_sl_config_problems '{"statusline":{"thresholds":null}}')" \
  'a thresholds value of null stays silent, unlike false, the same as every other section'
assert_eq '' "$(cp_sl_config_problems '{"statusline":{"colors":null}}')" \
  'a colors value of null stays silent, unlike false'
assert_eq '' "$(cp_sl_config_problems '{"statusline":{"colors":{"model":null}}}')" \
  'a null colour value stays silent, unlike false'

# --- the rule, asked of the resolver rather than restated -------------------
# One rule governs every configurable thing in the block -- the block
# itself, each section, and each field inside each section: a value that was
# never written (absent, or an explicit null) and a value the resolver kept
# are both passed over in silence, and a value the resolver replaced is
# named, together with what replaced it.
#
# The two helpers below check exactly that, and neither restates the
# resolver rules: they ask cp_sl_config what it resolved each key to and
# compare that with what the config wrote. So the table underneath covers
# any shape it lists, including shapes nobody has thought about yet, rather
# than the handful of cases someone happened to notice.
#
# The reporter is allowed to answer at a coarser key than the one that fell
# back -- a `bar` that is not an object is one line about `bar`, not three
# about its fields -- so a fallback counts as named when its own key, or any
# key containing it, is named.
#
# Two things are deliberately outside this comparison, and are covered by
# explicit assertions instead:
#
#   * `statusline.lines`, because the resolver honours a layout partially,
#     keeping the usable inner arrays and dropping the rest, so "the
#     resolver fell back" is not a yes or no there.
#   * a section that is present and neither null nor false nor an object,
#     because that makes the resolver abandon its jq program partway
#     through, so its output is no longer the four positional lines every
#     caller reads and a field-by-field comparison against it would be
#     meaningless. The section itself is still compared, which is what the
#     reporter answers such a config with.

# cp_t_sl_fallbacks <cfg> -> one line per key the resolver did not keep
cp_t_sl_fallbacks() {
  local cfg="$1" broken resolved tab key rv state
  local rfill='' rempty='' rwidth='' rwarn='' rcrit=''
  local rmodel='' rdir='' rgit='' rbranch='' rlabel=''
  tab="$(printf '\t')"
  # The block and the sections: structural, so no resolved value is needed.
  printf '%s' "$cfg" | jq -r '
    .statusline as $s
    | if $s == null then empty
      elif ($s|type) != "object" then "statusline"
      else ( ["bar","thresholds","colors"][] as $sec
             | $s[$sec] as $v
             | if $v == null or ($v|type) == "object" then empty
               else "statusline." + $sec end )
      end' 2>/dev/null
  broken="$(printf '%s' "$cfg" | jq -r '
    .statusline as $s
    | if $s == null then false
      elif ($s|type) != "object" then true
      else ([$s.bar, $s.thresholds, $s.colors]
            | map(. != null and . != false and (type != "object")) | any)
      end' 2>/dev/null)"
  [ "$broken" = false ] || return 0
  resolved="$(cp_sl_config "$cfg")"
  {
    read -r _
    IFS="$tab" read -r rfill rempty rwidth
    IFS="$tab" read -r rwarn rcrit
    IFS="$tab" read -r rmodel rdir rgit rbranch rlabel
  } <<EOF
$resolved
EOF
  printf '%s' "$cfg" | jq -r \
    --arg fill "$rfill" --arg empty "$rempty" --argjson width "$rwidth" \
    --argjson warn "$rwarn" --argjson crit "$rcrit" '
    def fell($v; $r): $v != null and $v != $r;
    .statusline as $s
    | ( if ($s.bar|type) == "object" then
          ( if fell($s.bar.filled; $fill) then "statusline.bar.filled" else empty end ),
          ( if fell($s.bar.empty; $empty) then "statusline.bar.empty" else empty end ),
          ( if fell($s.bar.width; $width) then "statusline.bar.width" else empty end )
        else empty end ),
      ( if ($s.thresholds|type) == "object" then
          ( if fell($s.thresholds.warn; $warn) then "statusline.thresholds.warn" else empty end ),
          ( if fell($s.thresholds.critical; $crit) then "statusline.thresholds.critical" else empty end )
        else empty end )' 2>/dev/null
  # The colours have a second resolution stage that cp_sl_code owns: a name
  # pick() keeps but the palette does not know is rendered plain, which is a
  # fallback too, so the palette has the last word here as well.
  for key in model dir git branch label; do
    case "$key" in
      model)  rv="$rmodel" ;;
      dir)    rv="$rdir" ;;
      git)    rv="$rgit" ;;
      branch) rv="$rbranch" ;;
      label)  rv="$rlabel" ;;
    esac
    state="$(printf '%s' "$cfg" | jq -r --arg k "$key" --arg rv "$rv" '
      .statusline as $s
      | if ($s|type) != "object" then "absent"
        else ($s.colors) as $c
        | if ($c|type) != "object" then "absent"
          else ($c[$k]) as $v
          | if $v == null then "absent" elif $v == $rv then "kept" else "fell" end
          end
        end' 2>/dev/null)"
    case "$state" in
      fell) printf 'statusline.colors.%s\n' "$key" ;;
      kept) [ -n "$(cp_sl_code "$rv")" ] || printf 'statusline.colors.%s\n' "$key" ;;
    esac
  done
}

# cp_t_sl_rule <cfg>: both directions of the rule, in one assertion whose
# failure names the keys and which way round it went wrong.
cp_t_sl_rule() {
  local cfg="$1" fbs reported keys k f found verdict=''
  fbs="$(cp_t_sl_fallbacks "$cfg")"
  reported="$(cp_sl_config_problems "$cfg")"
  keys="$(printf '%s\n' "$reported" | sed -n 's/^\([^:]*\):.*/\1/p' \
          | grep -v '^statusline\.lines$' | sort -u)"
  for k in $keys; do
    found=no
    for f in $fbs; do
      case "$f" in "$k"|"$k".*) found=yes ;; esac
    done
    [ "$found" = yes ] || verdict="$verdict over-reports:$k"
  done
  for f in $fbs; do
    found=no
    for k in $keys; do
      case "$f" in "$k"|"$k".*) found=yes ;; esac
    done
    [ "$found" = yes ] || verdict="$verdict under-reports:$f"
  done
  assert_eq '' "$verdict" "the rule holds for $cfg"
}

long31="$(printf 'x%.0s' $(seq 1 31))"
cfg31="$(printf '{"statusline":{"colors":{"label":"%s"}}}' "$long31")"
SL_RULE_CFG=(
  '{}'
  '{"statusline":null}'
  '{"statusline":false}'
  '{"statusline":""}'
  '{"statusline":5}'
  '{"statusline":[]}'
  '{"statusline":{}}'
  '{"statusline":{"bar":null,"thresholds":null,"colors":null}}'
  '{"statusline":{"bar":false,"thresholds":false,"colors":false}}'
  '{"statusline":{"bar":""}}'
  '{"statusline":{"thresholds":""}}'
  '{"statusline":{"colors":""}}'
  '{"statusline":{"bar":[1]}}'
  '{"statusline":{"thresholds":7}}'
  '{"statusline":{"colors":true}}'
  '{"statusline":{"bar":{},"thresholds":{},"colors":{}}}'
  '{"statusline":{"bar":{"filled":null,"empty":null,"width":null}}}'
  '{"statusline":{"bar":{"filled":false,"empty":false,"width":false}}}'
  '{"statusline":{"bar":{"filled":"","empty":"","width":""}}}'
  '{"statusline":{"bar":{"filled":"ab","empty":[],"width":99}}}'
  '{"statusline":{"bar":{"filled":"█","empty":"·","width":40}}}'
  '{"statusline":{"bar":{"width":"10"}}}'
  '{"statusline":{"bar":{"width":0}}}'
  '{"statusline":{"bar":{"filled":"▓","empty":"░","width":10}}}'
  '{"statusline":{"thresholds":{"warn":null,"critical":90}}}'
  '{"statusline":{"thresholds":{"warn":null,"critical":50}}}'
  '{"statusline":{"thresholds":{"warn":false,"critical":false}}}'
  '{"statusline":{"thresholds":{"warn":"","critical":""}}}'
  '{"statusline":{"thresholds":{"warn":80,"critical":50}}}'
  '{"statusline":{"thresholds":{"warn":50,"critical":60}}}'
  '{"statusline":{"thresholds":{"warn":0,"critical":101}}}'
  '{"statusline":{"thresholds":{"warn":70}}}'
  '{"statusline":{"thresholds":{"critical":50}}}'
  '{"statusline":{"colors":{"model":null,"dir":null,"git":null,"branch":null,"label":null}}}'
  '{"statusline":{"colors":{"model":false,"dir":"","git":5,"branch":[],"label":{}}}}'
  '{"statusline":{"colors":{"model":"","dir":"","git":"","branch":"","label":""}}}'
  '{"statusline":{"colors":{"model":"nonsense","dir":"nope","git":"x","branch":"y","label":"z"}}}'
  '{"statusline":{"colors":{"model":"cyan","dir":"yellow","git":"magenta","branch":"blue","label":"dim"}}}'
  "$cfg31"
  '{"statusline":{"lines":[["model"]],"bar":{"width":20},"thresholds":{"warn":50,"critical":60},"colors":{"git":"green"}}}'
  '{"statusline":{"bar":{"filled":""},"thresholds":{"warn":80,"critical":50},"colors":{"model":""}}}'
)
i=0
while [ "$i" -lt "${#SL_RULE_CFG[@]}" ]; do
  cp_t_sl_rule "${SL_RULE_CFG[$i]}"
  i=$((i + 1))
done

# --- lines, level by level: the one setting the rule above cannot judge ----
# Absent and null say nothing; every other rejected shape reports; a layout
# with something usable in it is honoured as far as it goes, and the junk
# alongside it is dropped in silence (accepted, and pinned here so a
# refactor cannot quietly start reporting it).
LINES_BAD='statusline.lines: not a list of segment lists; using the default layout'
assert_eq '' "$(cp_sl_config_problems '{"statusline":{"lines":null}}')" \
  'a lines value of null stays silent, the same as an absent one'
assert_eq "$LINES_BAD" "$(cp_sl_config_problems '{"statusline":{"lines":false}}')" \
  'a lines value of false is reported, not treated as nothing configured'
assert_eq "$LINES_BAD" "$(cp_sl_config_problems '{"statusline":{"lines":""}}')" \
  'an empty lines string is reported, not treated as nothing configured'
assert_eq "$LINES_BAD" "$(cp_sl_config_problems '{"statusline":{"lines":5}}')" \
  'a numeric lines value is reported'
assert_eq "$LINES_BAD" "$(cp_sl_config_problems '{"statusline":{"lines":{}}}')" \
  'an object lines value is reported'
assert_eq "$LINES_BAD" "$(cp_sl_config_problems '{"statusline":{"lines":[]}}')" \
  'an empty lines array is reported, not treated as nothing configured'
assert_eq "$LINES_BAD" "$(cp_sl_config_problems '{"statusline":{"lines":[[]]}}')" \
  'a lines array of empty lines is reported'
assert_eq "$LINES_BAD
statusline.lines: unknown segment nonsense (known: badge model dir git context usage)" \
  "$(cp_sl_config_problems '{"statusline":{"lines":[["nonsense"]]}}')" \
  'a layout whose only segment is unknown is reported both ways'
assert_eq '' "$(cp_sl_config_problems '{"statusline":{"lines":[["badge"],"junk"]}}')" \
  'a layout with one usable line keeps it and drops the junk in silence'
assert_eq '' "$(cp_sl_config_problems '{"statusline":{"lines":[["model"]]}}')" \
  'a usable layout stays silent'

cp_t_summary
