#!/usr/bin/env bash
set -u
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
# shellcheck source=/dev/null
. "$(dirname "$0")/../scripts/lib/config.sh"
# shellcheck source=/dev/null
. "$(dirname "$0")/../scripts/lib/resolve.sh"
# shellcheck source=/dev/null
. "$(dirname "$0")/../scripts/lib/profiles.sh"
# shellcheck source=/dev/null
. "$(dirname "$0")/../scripts/lib/auth.sh"
# shellcheck source=/dev/null
. "$(dirname "$0")/../scripts/lib/output.sh"
# shellcheck source=/dev/null
. "$(dirname "$0")/../scripts/lib/color.sh"
# shellcheck source=/dev/null
. "$(dirname "$0")/../scripts/lib/usage.sh"
# shellcheck source=/dev/null
. "$(dirname "$0")/../scripts/lib/fallback.sh"
CLI="$(cd "$(dirname "$0")/.." && pwd -P)/scripts/cprof"

mkdir -p "$CP_T_TMP/work" "$CP_T_TMP/personal"
cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","dir":"$CP_T_TMP/work"},{"name":"personal","dir":"$CP_T_TMP/personal"}],"rules":[],"repos":{}}
JSON

# --- set, get, clear -------------------------------------------------------
assert_eq 'none' "$("$CLI" fallback work 2>/dev/null)" 'no fallback configured yet'
"$CLI" fallback work personal >/dev/null 2>&1
assert_eq 'personal' "$("$CLI" fallback work 2>/dev/null)" 'fallback set and read back'
CFG="$(cp_config_read)"
assert_eq 'personal' "$(cp_profile_field "$CFG" work fallback)" 'config field holds the fallback name'
"$CLI" fallback work --clear >/dev/null 2>&1
assert_eq 'none' "$("$CLI" fallback work 2>/dev/null)" 'fallback cleared'

# --- validation --------------------------------------------------------
assert_fail "$CLI" fallback nope personal
assert_fail "$CLI" fallback work nope
assert_fail "$CLI" fallback work work
# surplus arguments are a typo, not something to guess at
assert_fail "$CLI" fallback work personal typo
assert_eq 'none' "$("$CLI" fallback work 2>/dev/null)" 'a surplus argument sets nothing'
"$CLI" fallback work personal >/dev/null 2>&1
assert_fail "$CLI" fallback work --clear typo
assert_eq 'personal' "$("$CLI" fallback work 2>/dev/null)" 'a surplus argument clears nothing'
"$CLI" fallback work --clear >/dev/null 2>&1
# no chains: a profile is a primary or a fallback target, never both
cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","dir":"$CP_T_TMP/work"},{"name":"personal","dir":"$CP_T_TMP/personal"},{"name":"backup","dir":"$CP_T_TMP/backup"}],"rules":[],"repos":{}}
JSON
assert_ok   "$CLI" fallback work personal
assert_fail "$CLI" fallback personal backup
assert_eq 'none' "$("$CLI" fallback personal 2>/dev/null)" 'a fallback target cannot be given a fallback of its own'
assert_fail "$CLI" fallback backup work
assert_eq 'none' "$("$CLI" fallback backup 2>/dev/null)" 'a primary cannot be made another profile'"'"'s fallback'
"$CLI" fallback work --clear >/dev/null 2>&1
cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","dir":"$CP_T_TMP/work"},{"name":"personal","dir":"$CP_T_TMP/personal"}],"rules":[],"repos":{}}
JSON
# a native profile cannot be a primary: cprof env exports nothing for it and
# never reaches the swap, so the mapping could never fire
cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","dir":"$CP_T_TMP/work"},{"name":"personal","dir":"$CP_T_TMP/personal"},{"name":"nat","native":true}],"rules":[],"repos":{}}
JSON
assert_fail "$CLI" fallback nat personal
assert_eq 'none' "$("$CLI" fallback nat 2>/dev/null)" 'a native primary is not recorded'
assert_ok   "$CLI" fallback nat --clear
assert_ok   "$CLI" fallback work nat
assert_eq 'nat' "$("$CLI" fallback work 2>/dev/null)" 'a native profile may still be the fallback target'
"$CLI" fallback work --clear >/dev/null 2>&1
cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","dir":"$CP_T_TMP/work"},{"name":"personal","dir":"$CP_T_TMP/personal"}],"rules":[],"repos":{}}
JSON

# --- removal cleans up a dangling reference ---------------------------
"$CLI" fallback work personal >/dev/null 2>&1
"$CLI" remove personal >/dev/null 2>&1
CFG="$(cp_config_read)"
assert_eq '' "$(cp_profile_field "$CFG" work fallback)" 'removing the fallback target clears the dangling reference'

# ==========================================================================
# Swap-out
# ==========================================================================
mkdir -p "$CP_T_TMP/w" "$CP_T_TMP/p"
KCD="$CP_T_TMP/keychain.d"
mkdir -p "$KCD"
export CP_T_KEYCHAIN_DIR="$KCD"
cat > "$CP_SECURITY_BIN" <<'STUB'
#!/usr/bin/env bash
cmd="$1"; shift
svc='' val=''
case "$cmd" in
  find-generic-password)
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -s) svc="$2"; shift 2 ;;
        -w) shift ;;
        *)  shift ;;
      esac
    done
    [ -n "$svc" ] || exit 1
    [ -f "$CP_T_KEYCHAIN_DIR/$svc.readfail" ] && exit 1       # keychain trouble
    [ -f "$CP_T_KEYCHAIN_DIR/$svc" ] || exit 44                # errSecItemNotFound
    if [ -f "$CP_T_KEYCHAIN_DIR/$svc.maxreads" ]; then
      echo r >> "$CP_T_KEYCHAIN_DIR/$svc.reads"
      [ "$(wc -l < "$CP_T_KEYCHAIN_DIR/$svc.reads")" -le "$(cat "$CP_T_KEYCHAIN_DIR/$svc.maxreads")" ] || exit 1
    fi
    cat "$CP_T_KEYCHAIN_DIR/$svc"
    ;;
  add-generic-password)
    update=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -s) svc="$2"; shift 2 ;;
        -w) val="$2"; shift 2 ;;
        -U) update=1; shift ;;
        *)  shift ;;
      esac
    done
    [ -n "$svc" ] || exit 1
    case "$svc" in *FAIL*) exit 1 ;; esac
    [ -f "$CP_T_KEYCHAIN_DIR/$svc.deny" ] && exit 1
    [ "$update" -eq 0 ] && [ -f "$CP_T_KEYCHAIN_DIR/$svc" ] && exit 45   # errSecDuplicateItem
    printf '%s' "$val" > "$CP_T_KEYCHAIN_DIR/$svc"
    ;;
  delete-generic-password)
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -s) svc="$2"; shift 2 ;;
        *)  shift ;;
      esac
    done
    [ -f "$CP_T_KEYCHAIN_DIR/$svc.nodelete" ] && exit 1
    rm -f "$CP_T_KEYCHAIN_DIR/$svc"
    ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$CP_SECURITY_BIN"

cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","dir":"$CP_T_TMP/w","fallback":"personal"},{"name":"personal","dir":"$CP_T_TMP/p"}],"rules":[],"repos":{}}
JSON
CFG="$(cp_config_read)"
printf '{"claudeAiOauth":{"accessToken":"tok-personal"}}' > "$CP_T_TMP/p/.credentials.json"

# --- no usage cache yet: no-op --------------------------------------------
printf '{"claudeAiOauth":{"accessToken":"tok-work"}}' > "$CP_T_TMP/w/.credentials.json"
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'no swap with no usage cache'

# --- cache under threshold: no-op -----------------------------------------
mkdir -p "$CP_T_TMP/state/usage"
cat > "$CP_T_TMP/state/usage/work.json" <<'JSON'
{"fetched_at":1,"five_hour":{"utilization":42,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":10,"resets_at":"2026-09-20T00:00:00Z"},"limits":[]}
JSON
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'no swap under threshold'

# --- cache at/above threshold: swaps, file-backed primary ------------------
cat > "$CP_T_TMP/state/usage/work.json" <<'JSON'
{"fetched_at":1,"five_hour":{"utilization":92,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":10,"resets_at":"2026-09-20T00:00:00Z"},"limits":[]}
JSON
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
assert_eq '{"claudeAiOauth":{"accessToken":"tok-personal"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'swap-out overwrites the primary file with the fallback blob'
assert_eq '{"claudeAiOauth":{"accessToken":"tok-work"}}' "$(cat "$CP_T_TMP/w/.credentials.json.bak")" \
  'swap-out backs up the primary original first'
assert_eq 'true' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'swap-out writes the marker'
assert_eq 'personal' "$(jq -r .fallback "$(cp_fallback_marker_file work)")" 'marker records the fallback name'
assert_eq "$CP_T_TMP/w/.credentials.json.bak" "$(jq -r .backup "$(cp_fallback_marker_file work)")" \
  'marker records the backup path'
assert_eq 'file' "$(jq -r .backup_kind "$(cp_fallback_marker_file work)")" 'marker records the backup kind'
assert_eq '2030-01-01T00:00:00Z' "$(jq -r .resets_at "$(cp_fallback_marker_file work)")" \
  'marker records the primary window reset time'
perm="$(stat -f '%Sp' "$CP_T_TMP/w/.credentials.json.bak")"
assert_eq '-rw-------' "$perm" 'backup file is mode 600'

# --- already active: no-op, no double-swap ---------------------------------
printf '{"claudeAiOauth":{"accessToken":"tok-personal-v2"}}' > "$CP_T_TMP/p/.credentials.json"
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
assert_eq '{"claudeAiOauth":{"accessToken":"tok-personal"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'an already-active swap does not swap again'
rm -f "$CP_T_TMP/w/.credentials.json.bak" "$(cp_fallback_marker_file work)"
printf '{"claudeAiOauth":{"accessToken":"tok-work"}}' > "$CP_T_TMP/w/.credentials.json"
printf '{"claudeAiOauth":{"accessToken":"tok-personal"}}' > "$CP_T_TMP/p/.credentials.json"

# --- keychain-backed primary -------------------------------------------
rm -f "$CP_T_TMP/w/.credentials.json"
service="$(cp_keychain_service "$CP_T_TMP/w")"
printf '%s' '{"claudeAiOauth":{"accessToken":"tok-work-kc"}}' > "$KCD/$service"
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
assert_eq '{"claudeAiOauth":{"accessToken":"tok-personal"}}' "$(cat "$KCD/$service")" \
  'swap-out writes the fallback blob into the primary keychain item'
assert_eq '{"claudeAiOauth":{"accessToken":"tok-work-kc"}}' "$(cat "$KCD/$service-bak")" 'swap-out backs up the primary keychain item first'
assert_eq 'keychain' "$(jq -r .backup_kind "$(cp_fallback_marker_file work)")" \
  'marker records keychain as the backup kind'
rm -f "$KCD/$service" "$KCD/$service-bak" "$(cp_fallback_marker_file work)"

# --- keychain: the primary item is read once; the validated value is what
# gets backed up, so a read that fails afterwards cannot corrupt the backup -
printf '%s' '{"claudeAiOauth":{"accessToken":"tok-work-kc"}}' > "$KCD/$service"
printf '1' > "$KCD/$service.maxreads"; rm -f "$KCD/$service.reads"
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
assert_eq '{"claudeAiOauth":{"accessToken":"tok-work-kc"}}' "$(cat "$KCD/$service-bak")" \
  'the backup holds the validated blob even when only one keychain read is allowed'
assert_eq '{"claudeAiOauth":{"accessToken":"tok-personal"}}' "$(cat "$KCD/$service")" \
  'the swap still completes with a single keychain read'
rm -f "$KCD/$service" "$KCD/$service-bak" "$KCD/$service.maxreads" "$KCD/$service.reads" "$(cp_fallback_marker_file work)"

# --- keychain: when the -bak item's presence cannot be determined, no swap -
printf '%s' '{"claudeAiOauth":{"accessToken":"tok-work-kc"}}' > "$KCD/$service"
: > "$KCD/$service-bak.readfail"
STDERR_OUT="$(cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w" 2>&1 1>/dev/null)"
assert_eq '{"claudeAiOauth":{"accessToken":"tok-work-kc"}}' "$(cat "$KCD/$service")" \
  'an unreadable keychain refuses the swap: primary item untouched'
assert_eq 'false' "$([ -f "$KCD/$service-bak" ] && echo true || echo false)" \
  'an unreadable keychain refuses the swap: no backup written'
case "$STDERR_OUT" in *'could not tell whether a backup'*) assert_eq ok ok 'an unreadable keychain is reported as such, not as absent' ;;
                      *) assert_eq 'cprof: fallback: could not tell whether a backup ...' "$STDERR_OUT" 'an unreadable keychain is reported as such, not as absent' ;; esac
rm -f "$KCD/$service-bak.readfail" "$KCD/$service"

# --- the backup is created without update semantics: an existing recovery
# item can never be overwritten by the write itself ---------------------------
printf '%s' 'precious' > "$KCD/probe-bak"
assert_fail cp_keychain_create 'new' 'probe-bak'
assert_eq 'precious' "$(cat "$KCD/probe-bak")" 'cp_keychain_create leaves an existing item untouched'
assert_ok cp_keychain_write 'new' 'probe-bak'
assert_eq 'new' "$(cat "$KCD/probe-bak")" 'cp_keychain_write (with -U) does overwrite'
rm -f "$KCD/probe-bak"

# --- keychain: the primary write fails after the backup was taken ---------
# The -bak item must not be left behind, or every later swap-out would refuse
# on "a backup already exists" after one transient keychain error.
printf '%s' '{"claudeAiOauth":{"accessToken":"tok-work-kc"}}' > "$KCD/$service"
: > "$KCD/$service.deny"
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
assert_eq '{"claudeAiOauth":{"accessToken":"tok-work-kc"}}' "$(cat "$KCD/$service")" \
  'a failed primary keychain write leaves the primary item untouched'
assert_eq 'false' "$([ -f "$KCD/$service-bak" ] && echo true || echo false)" \
  'a failed primary keychain write removes the backup it had just taken'
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'a failed primary keychain write leaves no marker'
rm -f "$KCD/$service" "$KCD/$service.deny"

# --- a pre-existing backup path refuses the swap outright -------------------
printf '{"claudeAiOauth":{"accessToken":"tok-work"}}' > "$CP_T_TMP/w/.credentials.json"
printf 'stale-backup-from-a-previous-attempt' > "$CP_T_TMP/w/.credentials.json.bak"
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
assert_eq '{"claudeAiOauth":{"accessToken":"tok-work"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'an existing backup refuses the swap: primary credentials are untouched'
assert_eq 'stale-backup-from-a-previous-attempt' "$(cat "$CP_T_TMP/w/.credentials.json.bak")" \
  'an existing backup refuses the swap: the stale backup is left alone'
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'an existing backup refuses the swap: no marker is written'
rm -f "$CP_T_TMP/w/.credentials.json.bak"

# --- an interrupted swap-out leaves <marker>.pending; the next call either
# promotes it (credentials were changed) or discards it with the backup
# (they were not) — file-backed --------------------------------------------
pend="$(cp_fallback_marker_file work).pending"
mkdir -p "$(dirname "$pend")"
printf '{"claudeAiOauth":{"accessToken":"tok-work"}}' > "$CP_T_TMP/w/.credentials.json.bak"
printf '{"claudeAiOauth":{"accessToken":"tok-personal"}}' > "$CP_T_TMP/w/.credentials.json"
cat > "$pend" <<JSON
{"fallback":"personal","backup":"$CP_T_TMP/w/.credentials.json.bak","backup_kind":"file","swapped_at":1,"resets_at":"2030-01-01T00:00:00Z"}
JSON
out="$(cd "$CP_T_TMP" && NO_COLOR=1 "$CLI" doctor 2>&1)"
case "$out" in *'work: fallback swap interrupted'*) assert_eq ok ok 'doctor reports an interrupted swap' ;;
                *) assert_eq 'work: fallback swap interrupted ...' "$out" 'doctor reports an interrupted swap' ;; esac
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
assert_eq 'true' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'interrupted after the overwrite: the pending marker is promoted'
assert_eq 'false' "$([ -f "$pend" ] && echo true || echo false)" 'interrupted after the overwrite: no pending file remains'
assert_eq '{"claudeAiOauth":{"accessToken":"tok-personal"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'interrupted after the overwrite: the live credentials are left as they are'
assert_eq 'personal' "$(jq -r .fallback "$(cp_fallback_marker_file work)")" 'the promoted marker carries the staged content'
rm -f "$(cp_fallback_marker_file work)" "$CP_T_TMP/w/.credentials.json.bak"
printf '{"claudeAiOauth":{"accessToken":"tok-work"}}' > "$CP_T_TMP/w/.credentials.json"
printf '{"claudeAiOauth":{"accessToken":"tok-work"}}' > "$CP_T_TMP/w/.credentials.json.bak"
cat > "$pend" <<JSON
{"fallback":"personal","backup":"$CP_T_TMP/w/.credentials.json.bak","backup_kind":"file","swapped_at":1,"resets_at":"2030-01-01T00:00:00Z"}
JSON
cat > "$CP_T_TMP/state/usage/work.json" <<'JSON'
{"fetched_at":1,"five_hour":{"utilization":42,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":10},"limits":[]}
JSON
cp_fallback_swap_back "$CFG" work
assert_eq 'false' "$([ -f "$pend" ] && echo true || echo false)" 'interrupted before the overwrite: the pending file is discarded'
assert_eq 'false' "$([ -e "$CP_T_TMP/w/.credentials.json.bak" ] && echo true || echo false)" \
  'interrupted before the overwrite: the backup is discarded'
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'interrupted before the overwrite: no marker is created'
cat > "$CP_T_TMP/state/usage/work.json" <<'JSON'
{"fetched_at":1,"five_hour":{"utilization":92,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":10,"resets_at":"2030-01-05T00:00:00Z"},"limits":[]}
JSON

# --- ... and keychain-backed, both outcomes --------------------------------
rm -f "$CP_T_TMP/w/.credentials.json"
service="$(cp_keychain_service "$CP_T_TMP/w")"
printf '%s' '{"claudeAiOauth":{"accessToken":"tok-work-kc"}}' > "$KCD/$service-bak"
printf '%s' '{"claudeAiOauth":{"accessToken":"tok-personal-kc"}}' > "$KCD/$service"
cat > "$pend" <<JSON
{"fallback":"personal","backup":"$service-bak","backup_kind":"keychain","swapped_at":1,"resets_at":"2030-01-01T00:00:00Z"}
JSON
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
assert_eq 'true' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'keychain: interrupted after the overwrite promotes the pending marker'
assert_eq '{"claudeAiOauth":{"accessToken":"tok-personal-kc"}}' "$(cat "$KCD/$service")" \
  'keychain: interrupted after the overwrite leaves the live item alone'
rm -f "$(cp_fallback_marker_file work)" "$KCD/$service" "$KCD/$service-bak"
printf '%s' '{"claudeAiOauth":{"accessToken":"tok-work-kc"}}' > "$KCD/$service-bak"
printf '%s' '{"claudeAiOauth":{"accessToken":"tok-work-kc"}}' > "$KCD/$service"
cat > "$pend" <<JSON
{"fallback":"personal","backup":"$service-bak","backup_kind":"keychain","swapped_at":1,"resets_at":"2030-01-01T00:00:00Z"}
JSON
cp_fallback_swap_back "$CFG" work
assert_eq 'false' "$([ -f "$pend" ] && echo true || echo false)" 'keychain: interrupted before the overwrite discards the pending file'
assert_eq 'false' "$([ -f "$KCD/$service-bak" ] && echo true || echo false)" 'keychain: interrupted before the overwrite discards the -bak item'
assert_eq '{"claudeAiOauth":{"accessToken":"tok-work-kc"}}' "$(cat "$KCD/$service")" 'keychain: the live item is untouched'
rm -f "$KCD/$service"
printf '{"claudeAiOauth":{"accessToken":"tok-work"}}' > "$CP_T_TMP/w/.credentials.json"

# --- the marker must be writable BEFORE any credential changes hands -------
# A swap whose marker can't be written is the one state swap-back can't see,
# so an unwritable marker directory means no swap at all.
rm -f "$CP_T_TMP/state/fallback-active"/*.json 2>/dev/null
rmdir "$CP_T_TMP/state/fallback-active" 2>/dev/null
chmod 500 "$CP_T_TMP/state"
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
assert_eq '{"claudeAiOauth":{"accessToken":"tok-work"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'an unwritable marker dir refuses the swap: primary credentials are untouched'
assert_eq 'false' "$([ -e "$CP_T_TMP/w/.credentials.json.bak" ] && echo true || echo false)" \
  'an unwritable marker dir refuses the swap: no backup is left behind'
assert_eq 'false' "$([ -d "$CP_T_TMP/state/fallback-active" ] && echo true || echo false)" \
  'an unwritable marker dir refuses the swap: no marker dir is created'
chmod 700 "$CP_T_TMP/state"

# --- CPROF_FALLBACK_THRESHOLD is validated, never fed raw to a numeric test
assert_eq '90' "$(cp_fallback_threshold)" 'threshold defaults to 90'
assert_eq '75' "$(CPROF_FALLBACK_THRESHOLD=75 cp_fallback_threshold 2>/dev/null)" 'a valid threshold is used as given'
assert_eq '90' "$(CPROF_FALLBACK_THRESHOLD=abc cp_fallback_threshold 2>/dev/null)" 'a non-numeric threshold falls back to 90'
assert_eq '90' "$(CPROF_FALLBACK_THRESHOLD=150 cp_fallback_threshold 2>/dev/null)" 'a threshold above 100 falls back to 90'
assert_eq '90' "$(CPROF_FALLBACK_THRESHOLD=0 cp_fallback_threshold 2>/dev/null)" 'a threshold of 0 falls back to 90 (it could swap but never restore)'
assert_eq '1' "$(CPROF_FALLBACK_THRESHOLD=1 cp_fallback_threshold 2>/dev/null)" 'a threshold of 1 is the lowest accepted'
STDERR_OUT="$(CPROF_FALLBACK_THRESHOLD=abc cp_fallback_threshold 2>&1 1>/dev/null)"
case "$STDERR_OUT" in *'CPROF_FALLBACK_THRESHOLD'*) assert_eq ok ok 'an invalid threshold is reported via cp_warn' ;;
                      *) assert_eq 'cprof: ... CPROF_FALLBACK_THRESHOLD ...' "$STDERR_OUT" 'an invalid threshold is reported via cp_warn' ;; esac
STDERR_OUT="$(CPROF_FALLBACK_THRESHOLD=abc cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w" 2>&1 1>/dev/null)"
case "$STDERR_OUT" in *'integer expression'*) assert_eq 'no bash error' "$STDERR_OUT" 'an invalid threshold raises no shell error in swap-out' ;;
                      *) assert_eq ok ok 'an invalid threshold raises no shell error in swap-out' ;; esac
rm -f "$CP_T_TMP/w/.credentials.json.bak" "$(cp_fallback_marker_file work)"
printf '{"claudeAiOauth":{"accessToken":"tok-work"}}' > "$CP_T_TMP/w/.credentials.json"

# --- a cache with no parseable resets_at cannot swap: the marker it would
# write is exactly the one swap-back refuses to act on ------------------------
cat > "$CP_T_TMP/state/usage/work.json" <<'JSON'
{"fetched_at":1,"five_hour":{"utilization":92},"seven_day":{"utilization":10},"limits":[]}
JSON
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
assert_eq '{"claudeAiOauth":{"accessToken":"tok-work"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'no resets_at: primary credentials are untouched'
assert_eq 'false' "$([ -e "$CP_T_TMP/w/.credentials.json.bak" ] && echo true || echo false)" \
  'no resets_at: no backup is taken'
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'no resets_at: no marker is written'
cat > "$CP_T_TMP/state/usage/work.json" <<'JSON'
{"fetched_at":1,"five_hour":{"utilization":92,"resets_at":"not-a-time"},"seven_day":{"utilization":10},"limits":[]}
JSON
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'unparseable resets_at: no marker is written'
cat > "$CP_T_TMP/state/usage/work.json" <<'JSON'
{"fetched_at":1,"five_hour":{"utilization":92,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":10,"resets_at":"2026-09-20T00:00:00Z"},"limits":[]}
JSON

# --- the target must be its own account right now: a swapped-out target's
# live store holds a third profile's credentials --------------------------------
mkdir -p "$CP_T_TMP/state/fallback-active"
cat > "$(cp_fallback_marker_file personal)" <<JSON
{"fallback":"backup","backup":"$CP_T_TMP/p/.credentials.json.bak","backup_kind":"file","swapped_at":1,"resets_at":"2030-01-01T00:00:00Z"}
JSON
STDERR_OUT="$(cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w" 2>&1 1>/dev/null)"
assert_eq '{"claudeAiOauth":{"accessToken":"tok-work"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'a swapped-out target refuses the swap: primary credentials untouched'
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'a swapped-out target refuses the swap: no marker'
case "$STDERR_OUT" in *'is itself swapped'*) assert_eq ok ok 'a swapped-out target is reported' ;;
                      *) assert_eq 'cprof: fallback: personal is itself swapped ...' "$STDERR_OUT" 'a swapped-out target is reported' ;; esac
rm -f "$(cp_fallback_marker_file personal)"
# ... and a hand-edited chain (target with its own fallback) is refused too
cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","dir":"$CP_T_TMP/w","fallback":"personal"},{"name":"personal","dir":"$CP_T_TMP/p","fallback":"work"}],"rules":[],"repos":{}}
JSON
cp_fallback_swap_out "$(cp_config_read)" work "$CP_T_TMP/w"
assert_eq '{"claudeAiOauth":{"accessToken":"tok-work"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'a chained mapping edited into the config refuses the swap'
cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","dir":"$CP_T_TMP/w","fallback":"personal"},{"name":"personal","dir":"$CP_T_TMP/p"}],"rules":[],"repos":{}}
JSON
CFG="$(cp_config_read)"

# --- a cache whose 5h window has already reset cannot swap: the numbers in
# it describe a window that is over --------------------------------------------
cat > "$CP_T_TMP/state/usage/work.json" <<'JSON'
{"fetched_at":1,"five_hour":{"utilization":92,"resets_at":"2020-01-01T00:00:00Z"},"seven_day":{"utilization":10},"limits":[]}
JSON
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
assert_eq '{"claudeAiOauth":{"accessToken":"tok-work"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'past resets_at: primary credentials are untouched'
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'past resets_at: no marker is written'
cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","dir":"$CP_T_TMP/w","fallback":"personal"},{"name":"personal","dir":"$CP_T_TMP/p"}],"rules":[{"path":"$CP_T_TMP","profile":"work"}],"repos":{}}
JSON
out="$(cd "$CP_T_TMP" && NO_COLOR=1 "$CLI" which 2>/dev/null)"
case "$out" in *'would fall back'*) assert_eq 'no would-fall-back note' "$out" 'which shows no would-fire note for a past window' ;;
                *) assert_eq ok ok 'which shows no would-fire note for a past window' ;; esac
cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","dir":"$CP_T_TMP/w","fallback":"personal"},{"name":"personal","dir":"$CP_T_TMP/p"}],"rules":[],"repos":{}}
JSON
CFG="$(cp_config_read)"

# --- the real endpoint's resets_at carries fractional seconds and an offset
cat > "$CP_T_TMP/state/usage/work.json" <<'JSON'
{"fetched_at":1,"five_hour":{"utilization":92,"resets_at":"2030-01-01T02:00:00.528743+02:00"},"seven_day":{"utilization":10},"limits":[]}
JSON
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
assert_eq '{"claudeAiOauth":{"accessToken":"tok-personal"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'an RFC 3339 resets_at with fraction and offset still swaps'
assert_eq '2030-01-01T02:00:00.528743+02:00' "$(jq -r .resets_at "$(cp_fallback_marker_file work)")" \
  'the marker keeps the resets_at exactly as the endpoint sent it'
rm -f "$CP_T_TMP/w/.credentials.json.bak" "$(cp_fallback_marker_file work)"
printf '{"claudeAiOauth":{"accessToken":"tok-work"}}' > "$CP_T_TMP/w/.credentials.json"
cat > "$CP_T_TMP/state/usage/work.json" <<'JSON'
{"fetched_at":1,"five_hour":{"utilization":92,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":10,"resets_at":"2030-01-05T00:00:00Z"},"limits":[]}
JSON

# --- the fallback's own credentials must carry a token before they replace
# anything -------------------------------------------------------------------
printf '{"claudeAiOauth":{}}' > "$CP_T_TMP/p/.credentials.json"
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
assert_eq '{"claudeAiOauth":{"accessToken":"tok-work"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'a tokenless fallback blob: primary credentials are untouched'
assert_eq 'false' "$([ -e "$CP_T_TMP/w/.credentials.json.bak" ] && echo true || echo false)" \
  'a tokenless fallback blob: no backup is taken'
printf 'not json at all' > "$CP_T_TMP/p/.credentials.json"
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
assert_eq '{"claudeAiOauth":{"accessToken":"tok-work"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'a malformed fallback blob: primary credentials are untouched'
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'a malformed fallback blob: no marker is written'
printf '{"claudeAiOauth":{"accessToken":"tok-personal"}}' > "$CP_T_TMP/p/.credentials.json"

# --- per-profile lock: a live holder makes this call skip, a dead one is
# reclaimed --------------------------------------------------------------------
lock="$(cp_fallback_lock_dir work)"
mkdir -p "$lock"
printf '%s' "$$" > "$lock/pid"
STDERR_OUT="$(cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w" 2>&1 1>/dev/null)"
assert_eq '{"claudeAiOauth":{"accessToken":"tok-work"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'a held lock skips the swap: primary credentials are untouched'
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'a held lock skips the swap: no marker'
case "$STDERR_OUT" in *'another cprof'*) assert_eq ok ok 'a held lock is reported' ;;
                      *) assert_eq 'cprof: fallback: another cprof ...' "$STDERR_OUT" 'a held lock is reported' ;; esac
assert_eq "$$" "$(cat "$lock/pid")" 'a held lock is left in place'
printf '%s' '2147483000' > "$lock/pid"
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
assert_eq '{"claudeAiOauth":{"accessToken":"tok-personal"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'a lock left by a dead process is reclaimed and the swap proceeds'
assert_eq 'false' "$([ -d "$lock" ] && echo true || echo false)" 'the lock is released after the swap'
# two reclaimers racing over the same dead lock: rename is the arbiter, so
# exactly one wins and the other backs off; no stale directories are left
mkdir -p "$lock"; printf '%s' '2147483000' > "$lock/pid"
rm -f "$CP_T_TMP/won.1" "$CP_T_TMP/won.2"
( cp_fallback_lock work && : > "$CP_T_TMP/won.1" ) &
( cp_fallback_lock work && : > "$CP_T_TMP/won.2" ) &
wait
winners=0; [ -f "$CP_T_TMP/won.1" ] && winners=$((winners+1)); [ -f "$CP_T_TMP/won.2" ] && winners=$((winners+1))
assert_eq '1' "$winners" 'exactly one of two concurrent reclaimers acquires the lock'
assert_eq '' "$(ls -d "$lock".stale.* 2>/dev/null)" 'no stale lock directories are left behind'
cp_fallback_unlock work
rm -f "$CP_T_TMP/w/.credentials.json.bak" "$(cp_fallback_marker_file work)"
printf '{"claudeAiOauth":{"accessToken":"tok-work"}}' > "$CP_T_TMP/w/.credentials.json"

# --- a zero-byte primary credential file is not treated as real credentials -
: > "$CP_T_TMP/w/.credentials.json"
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
assert_eq '' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'an empty primary credential file is not swapped'
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'an empty primary credential file writes no marker'
# ... nor is a file whose token is the empty string, nor a keychain item
# holding something that is not a credential blob: swap-back could never
# restore either, so neither may be swapped out
printf '{"claudeAiOauth":{"accessToken":""}}' > "$CP_T_TMP/w/.credentials.json"
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
assert_eq '{"claudeAiOauth":{"accessToken":""}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'an empty-string primary token is not swapped'
assert_eq 'false' "$([ -e "$CP_T_TMP/w/.credentials.json.bak" ] && echo true || echo false)" \
  'an empty-string primary token takes no backup'
rm -f "$CP_T_TMP/w/.credentials.json"
printf '%s' 'not a credential blob' > "$KCD/$(cp_keychain_service "$CP_T_TMP/w")"
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
assert_eq 'not a credential blob' "$(cat "$KCD/$(cp_keychain_service "$CP_T_TMP/w")")" \
  'a malformed primary keychain item is not swapped'
assert_eq 'false' "$([ -f "$KCD/$(cp_keychain_service "$CP_T_TMP/w")-bak" ] && echo true || echo false)" \
  'a malformed primary keychain item takes no backup'
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'a malformed primary keychain item writes no marker'
rm -f "$KCD/$(cp_keychain_service "$CP_T_TMP/w")"
printf '{"claudeAiOauth":{"accessToken":"tok-work"}}' > "$CP_T_TMP/w/.credentials.json"

# --- a keychain backup-write failure leaves the primary keychain item alone -
rm -f "$CP_T_TMP/w/.credentials.json"
CP_KEYCHAIN_SERVICE_SAVE="$CP_KEYCHAIN_SERVICE"
CP_KEYCHAIN_SERVICE="FAIL-Claude Code-credentials"
service="$(cp_keychain_service "$CP_T_TMP/w")"
printf '%s' '{"claudeAiOauth":{"accessToken":"tok-work-kc2"}}' > "$KCD/$service"
STDERR_OUT="$(cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w" 2>&1 1>/dev/null)"
assert_eq '{"claudeAiOauth":{"accessToken":"tok-work-kc2"}}' "$(cat "$KCD/$service")" \
  'a keychain backup-write failure leaves the primary keychain item untouched'
case "$STDERR_OUT" in *'could not back up the keychain item'*) assert_eq ok ok 'the backup-write failure itself is what stopped the swap' ;;
                      *) assert_eq 'cprof: fallback: could not back up the keychain item ...' "$STDERR_OUT" 'the backup-write failure itself is what stopped the swap' ;; esac
assert_eq 'false' "$([ -f "$KCD/$service-bak" ] && echo true || echo false)" \
  'a keychain backup-write failure leaves no backup item behind'
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'a keychain backup-write failure writes no marker'
rm -f "$KCD/$service" "$KCD/$service-bak"
CP_KEYCHAIN_SERVICE="$CP_KEYCHAIN_SERVICE_SAVE"
printf '{"claudeAiOauth":{"accessToken":"tok-work"}}' > "$CP_T_TMP/w/.credentials.json"

# --- no fallback configured: no-op -----------------------------------------
cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","dir":"$CP_T_TMP/w"},{"name":"personal","dir":"$CP_T_TMP/p"}],"rules":[],"repos":{}}
JSON
CFG="$(cp_config_read)"
printf '{"claudeAiOauth":{"accessToken":"tok-work"}}' > "$CP_T_TMP/w/.credentials.json"
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'no swap with no fallback configured'

# --- primary has no existing credentials at all: refuses, no marker -------
cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","dir":"$CP_T_TMP/w","fallback":"personal"},{"name":"personal","dir":"$CP_T_TMP/p"}],"rules":[],"repos":{}}
JSON
CFG="$(cp_config_read)"
rm -f "$CP_T_TMP/w/.credentials.json"
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'no swap when the primary has nothing to back up'

# --- forced failure before the final write leaves the primary untouched ---
printf '{"claudeAiOauth":{"accessToken":"tok-work"}}' > "$CP_T_TMP/w/.credentials.json"
chmod 500 "$CP_T_TMP/w"
STDERR_OUT="$(cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w" 2>&1 1>/dev/null)"
chmod 700 "$CP_T_TMP/w"
assert_eq '{"claudeAiOauth":{"accessToken":"tok-work"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'a write failure leaves the primary credentials untouched'
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'a write failure writes no marker'
case "$STDERR_OUT" in
  *'could not back up'*) result=true ;;
  *) result=false ;;
esac
assert_eq 'true' "$result" 'a write failure warns that the backup could not be made'

# ==========================================================================
# Swap-back
# ==========================================================================
cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","dir":"$CP_T_TMP/w","fallback":"personal"},{"name":"personal","dir":"$CP_T_TMP/p"}],"rules":[],"repos":{}}
JSON
CFG="$(cp_config_read)"
# CP_T_TMP itself is never exported by cp_t_setup (only the derived paths
# under it are). The curl stubs below run as separate child processes and
# need to see it to write their call/auth-log files.
export CP_T_TMP

# --- no marker: no-op -------------------------------------------------------
rm -f "$(cp_fallback_marker_file work)"
cp_fallback_swap_back "$CFG" work
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'no-op with no marker (still absent)'

# --- marker present but resets_at is empty: warns, marker stays ------------
mkdir -p "$(dirname "$(cp_fallback_marker_file work)")"
cat > "$(cp_fallback_marker_file work)" <<JSON
{"fallback":"personal","backup":"$CP_T_TMP/w/.credentials.json.bak","backup_kind":"file","swapped_at":1,"resets_at":""}
JSON
STDERR_OUT="$(cp_fallback_swap_back "$CFG" work 2>&1 1>/dev/null)"
case "$STDERR_OUT" in
  *'no resets_at recorded'*) result=true ;;
  *) result=false ;;
esac
assert_eq 'true' "$result" 'an empty resets_at warns instead of silently wedging forever'
assert_eq 'true' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'an empty resets_at leaves the marker in place for a manual look'
rm -f "$(cp_fallback_marker_file work)"

# --- marker present but resets_at is unparseable: warns, marker stays -----
cat > "$(cp_fallback_marker_file work)" <<JSON
{"fallback":"personal","backup":"$CP_T_TMP/w/.credentials.json.bak","backup_kind":"file","swapped_at":1,"resets_at":"not-a-date"}
JSON
STDERR_OUT="$(cp_fallback_swap_back "$CFG" work 2>&1 1>/dev/null)"
case "$STDERR_OUT" in
  *'unparseable resets_at'*) result=true ;;
  *) result=false ;;
esac
assert_eq 'true' "$result" 'an unparseable resets_at warns instead of silently wedging forever'
assert_eq 'true' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'an unparseable resets_at leaves the marker in place for a manual look'
rm -f "$(cp_fallback_marker_file work)"

# --- marker present, resets_at not yet passed: no-op, marker stays, and the
# gate genuinely blocks the fetch (curl is never invoked at all) -----------
printf '{"claudeAiOauth":{"accessToken":"tok-work-original"}}' > "$CP_T_TMP/w/.credentials.json.bak"
printf '{"claudeAiOauth":{"accessToken":"tok-personal"}}' > "$CP_T_TMP/w/.credentials.json"
mkdir -p "$(dirname "$(cp_fallback_marker_file work)")"
cat > "$(cp_fallback_marker_file work)" <<JSON
{"fallback":"personal","backup":"$CP_T_TMP/w/.credentials.json.bak","backup_kind":"file","swapped_at":1,"resets_at":"2099-01-01T00:00:00Z"}
JSON
cat > "$CP_CURL_BIN" <<'STUB'
#!/usr/bin/env bash
echo "called" >> "$CP_T_TMP/curl-calls"
cat <<'JSON'
{"five_hour":{"utilization":12,"resets_at":"2026-09-15T00:00:00Z"},
 "seven_day":{"utilization":10,"resets_at":"2026-09-20T00:00:00Z"},"limits":[]}
JSON
STUB
chmod +x "$CP_CURL_BIN"
rm -f "$CP_T_TMP/curl-calls"
cp_fallback_swap_back "$CFG" work
assert_eq '{"claudeAiOauth":{"accessToken":"tok-personal"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'no restore before resets_at has passed'
assert_eq 'true' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'marker stays while resets_at has not passed'
assert_eq 'false' "$([ -f "$CP_T_TMP/curl-calls" ] && echo true || echo false)" \
  'resets_at not yet passed: curl is never invoked (the gate genuinely blocks the fetch)'

# --- resets_at passed, fresh fetch still over threshold: no-op, retry later
cat > "$(cp_fallback_marker_file work)" <<JSON
{"fallback":"personal","backup":"$CP_T_TMP/w/.credentials.json.bak","backup_kind":"file","swapped_at":1,"resets_at":"2020-01-01T00:00:00Z"}
JSON
cat > "$CP_CURL_BIN" <<'STUB'
#!/usr/bin/env bash
echo "called" >> "$CP_T_TMP/curl-calls"
config="$(cat)"
printf '%s\n' "$config" | grep -o 'Authorization: Bearer [^"]*' >> "$CP_T_TMP/curl-auth-log"
cat <<'JSON'
{"five_hour":{"utilization":91,"resets_at":"2026-09-15T00:00:00Z"},
 "seven_day":{"utilization":10,"resets_at":"2026-09-20T00:00:00Z"},"limits":[]}
JSON
STUB
chmod +x "$CP_CURL_BIN"
rm -f "$CP_T_TMP/curl-calls" "$CP_T_TMP/curl-auth-log"
cp_fallback_swap_back "$CFG" work
assert_eq '{"claudeAiOauth":{"accessToken":"tok-personal"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'still over threshold after the confirming fetch: no restore'
assert_eq 'true' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'marker stays when the confirming fetch is still over threshold'

# --- CPROF_NO_USAGE=1: the confirming fetch is skipped, nothing is sent ---
rm -f "$CP_T_TMP/curl-called"
cat > "$CP_CURL_BIN" <<'STUB'
#!/usr/bin/env bash
echo 'should not be called' >> "$CP_T_TMP/curl-called"
exit 1
STUB
chmod +x "$CP_CURL_BIN"
CPROF_NO_USAGE=1 cp_fallback_swap_back "$CFG" work
assert_eq 'false' "$([ -f "$CP_T_TMP/curl-called" ] && echo true || echo false)" \
  'CPROF_NO_USAGE=1 never sends the primary token to the endpoint'
assert_eq 'true' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'CPROF_NO_USAGE=1 leaves the marker for when fetching is allowed again'
assert_eq '{"claudeAiOauth":{"accessToken":"tok-personal"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'CPROF_NO_USAGE=1 leaves the fallback credentials live'

# --- resets_at passed, fetch fails: no-op, marker stays for a later retry -
cat > "$CP_CURL_BIN" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$CP_CURL_BIN"
cp_fallback_swap_back "$CFG" work
assert_eq 'true' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'a failed confirming fetch leaves the marker for a later retry'

# --- resets_at passed, fetch confirms under threshold: restores -----------
# The backup's token (tok-work-original) is deliberately distinct from the
# fallback's live token (tok-personal) currently sitting in the credential
# file, so a successful restore here proves the confirming fetch
# authenticated as the backed-up PRIMARY account, not the live fallback one.
cat > "$CP_CURL_BIN" <<'STUB'
#!/usr/bin/env bash
echo "called" >> "$CP_T_TMP/curl-calls"
config="$(cat)"
printf '%s\n' "$config" | grep -o 'Authorization: Bearer [^"]*' >> "$CP_T_TMP/curl-auth-log"
cat <<'JSON'
{"five_hour":{"utilization":12,"resets_at":"2026-09-15T00:00:00Z"},
 "seven_day":{"utilization":10,"resets_at":"2026-09-20T00:00:00Z"},"limits":[]}
JSON
STUB
chmod +x "$CP_CURL_BIN"
rm -f "$CP_T_TMP/curl-calls" "$CP_T_TMP/curl-auth-log"
# While the swap was active, list/doctor cached the FALLBACK's numbers under
# the primary's name; the restore must replace them with the confirming
# response, or the swap-out check that follows in the same cprof env call
# would read 95% and swap straight back.
mkdir -p "$CP_T_TMP/state/usage"
cat > "$CP_T_TMP/state/usage/work.json" <<'JSON'
{"fetched_at":1,"five_hour":{"utilization":95,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":10},"limits":[]}
JSON
cp_fallback_swap_back "$CFG" work
assert_eq '{"claudeAiOauth":{"accessToken":"tok-work-original"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'restore writes back the original primary credentials'
assert_eq '12' "$(jq -r '.five_hour.utilization' "$CP_T_TMP/state/usage/work.json")" \
  'restore caches the confirming response under the primary name'
assert_eq 'true' "$([ "$(jq -r '.fetched_at' "$CP_T_TMP/state/usage/work.json")" -gt $(( $(date +%s) - 60 )) ] && echo true || echo false)" \
  'the cached confirming response is stamped fresh'
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
assert_eq '{"claudeAiOauth":{"accessToken":"tok-work-original"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'a swap-out right after the restore sees the fresh numbers and does nothing'
assert_eq 'false' "$([ -f "$CP_T_TMP/w/.credentials.json.bak" ] && echo true || echo false)" \
  'restore deletes the backup file'
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'restore deletes the marker'
assert_eq 'true' "$(grep -q 'Bearer tok-work-original' "$CP_T_TMP/curl-auth-log" && echo true || echo false)" \
  'the confirming fetch authenticated as the backed-up primary token'
assert_eq 'false' "$(grep -q 'Bearer tok-personal' "$CP_T_TMP/curl-auth-log" && echo true || echo false)" \
  'the confirming fetch never authenticated as the live fallback token'

# --- restore succeeds but the cache cannot be written: credentials are
# restored, marker and backup stay so the next call finishes the job -------
printf '{"claudeAiOauth":{"accessToken":"tok-personal"}}' > "$CP_T_TMP/w/.credentials.json"
printf '{"claudeAiOauth":{"accessToken":"tok-work-original"}}' > "$CP_T_TMP/w/.credentials.json.bak"
cat > "$(cp_fallback_marker_file work)" <<JSON
{"fallback":"personal","backup":"$CP_T_TMP/w/.credentials.json.bak","backup_kind":"file","swapped_at":1,"resets_at":"2020-01-01T00:00:00Z"}
JSON
# The immutable flag on the cache dir blocks file creation and survives the
# writer's own chmod 700 (a plain read-only mode would not).
chflags uchg "$CP_T_TMP/state/usage"
cp_fallback_swap_back "$CFG" work
assert_eq '{"claudeAiOauth":{"accessToken":"tok-work-original"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'cache write failure: credentials are still restored'
assert_eq 'true' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'cache write failure: the marker stays for a retry'
assert_eq 'true' "$([ -f "$CP_T_TMP/w/.credentials.json.bak" ] && echo true || echo false)" \
  'cache write failure: the backup stays for a retry'
chflags nouchg "$CP_T_TMP/state/usage"
cp_fallback_swap_back "$CFG" work
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'the retried restore completes and drops the marker'
assert_eq 'false' "$([ -f "$CP_T_TMP/w/.credentials.json.bak" ] && echo true || echo false)" \
  'the retried restore drops the backup'

# --- restore done but the backup cannot be deleted: marker stays, flagged
# restored, and the next call finishes the cleanup without a re-restore -----
printf '{"claudeAiOauth":{"accessToken":"tok-personal"}}' > "$CP_T_TMP/w/.credentials.json"
printf '{"claudeAiOauth":{"accessToken":"tok-work-original"}}' > "$CP_T_TMP/w/.credentials.json.bak"
cat > "$(cp_fallback_marker_file work)" <<JSON
{"fallback":"personal","backup":"$CP_T_TMP/w/.credentials.json.bak","backup_kind":"file","swapped_at":1,"resets_at":"2020-01-01T00:00:00Z"}
JSON
chflags uchg "$CP_T_TMP/w/.credentials.json.bak"
cp_fallback_swap_back "$CFG" work
assert_eq '{"claudeAiOauth":{"accessToken":"tok-work-original"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'backup delete failure: credentials are restored'
assert_eq 'true' "$(jq -r '.restored // false' "$(cp_fallback_marker_file work)" 2>/dev/null)" \
  'backup delete failure: the marker stays and records that the restore is done'
chflags nouchg "$CP_T_TMP/w/.credentials.json.bak"
rm -f "$CP_T_TMP/curl-calls"
cp_fallback_swap_back "$CFG" work
assert_eq 'false' "$([ -f "$CP_T_TMP/w/.credentials.json.bak" ] && echo true || echo false)" \
  'the retry deletes the backup'
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'the retry deletes the marker'
assert_eq 'false' "$([ -f "$CP_T_TMP/curl-calls" ] && echo true || echo false)" \
  'the retry does not fetch or re-restore, only cleans up'

# --- restore done but the marker itself cannot be updated: it stays as-is
# with the backup, and the next call redoes the (idempotent) restore ---------
printf '{"claudeAiOauth":{"accessToken":"tok-personal"}}' > "$CP_T_TMP/w/.credentials.json"
printf '{"claudeAiOauth":{"accessToken":"tok-work-original"}}' > "$CP_T_TMP/w/.credentials.json.bak"
cat > "$(cp_fallback_marker_file work)" <<JSON
{"fallback":"personal","backup":"$CP_T_TMP/w/.credentials.json.bak","backup_kind":"file","swapped_at":1,"resets_at":"2020-01-01T00:00:00Z"}
JSON
chflags uchg "$(cp_fallback_marker_file work)"
cp_fallback_swap_back "$CFG" work
assert_eq '{"claudeAiOauth":{"accessToken":"tok-work-original"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'marker update failure: credentials are restored'
assert_eq 'true' "$([ -f "$CP_T_TMP/w/.credentials.json.bak" ] && echo true || echo false)" \
  'marker update failure: the backup stays'
chflags nouchg "$(cp_fallback_marker_file work)"
cp_fallback_swap_back "$CFG" work
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'the retry after a marker update failure completes'

# --- a malformed marker is left alone and reported, never acted on: an
# empty backup would make the keychain calls default to the NATIVE item -----
printf '%s' 'native-login-blob' > "$KCD/Claude Code-credentials"
cat > "$(cp_fallback_marker_file work)" <<JSON
{"fallback":"personal","backup":"","backup_kind":"keychain","swapped_at":1,"resets_at":"2020-01-01T00:00:00Z","restored":true}
JSON
STDERR_OUT="$(cp_fallback_swap_back "$CFG" work 2>&1 1>/dev/null)"
assert_eq 'native-login-blob' "$(cat "$KCD/Claude Code-credentials")" \
  'a restored marker with an empty backup never touches the native keychain item'
assert_eq 'true' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'a malformed marker is kept for inspection'
case "$STDERR_OUT" in *'malformed'*) assert_eq ok ok 'a malformed marker is reported' ;;
                      *) assert_eq 'cprof: fallback: marker ... malformed' "$STDERR_OUT" 'a malformed marker is reported' ;; esac
cat > "$(cp_fallback_marker_file work)" <<JSON
{"fallback":"personal","backup":"$CP_T_TMP/w/.credentials.json.bak","backup_kind":"bogus","swapped_at":1,"resets_at":"2020-01-01T00:00:00Z"}
JSON
printf '{"claudeAiOauth":{"accessToken":"tok-personal"}}' > "$CP_T_TMP/w/.credentials.json"
cp_fallback_swap_back "$CFG" work
assert_eq '{"claudeAiOauth":{"accessToken":"tok-personal"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'an unknown backup_kind restores nothing'
assert_eq 'true' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'an unknown backup_kind keeps the marker'
assert_eq 'native-login-blob' "$(cat "$KCD/Claude Code-credentials")" \
  'an unknown backup_kind never touches the native keychain item'
rm -f "$(cp_fallback_marker_file work)" "$KCD/Claude Code-credentials"
printf '{"claudeAiOauth":{"accessToken":"tok-work-original"}}' > "$CP_T_TMP/w/.credentials.json"

# --- the restore lands where the backup was taken, even if the profile was
# re-pointed at another directory mid-swap --------------------------------
mkdir -p "$CP_T_TMP/w2"
printf '{"claudeAiOauth":{"accessToken":"tok-personal"}}' > "$CP_T_TMP/w/.credentials.json"
printf '{"claudeAiOauth":{"accessToken":"tok-work-original"}}' > "$CP_T_TMP/w/.credentials.json.bak"
cat > "$(cp_fallback_marker_file work)" <<JSON
{"fallback":"personal","backup":"$CP_T_TMP/w/.credentials.json.bak","backup_kind":"file","swapped_at":1,"resets_at":"2020-01-01T00:00:00Z"}
JSON
cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","dir":"$CP_T_TMP/w2","fallback":"personal"},{"name":"personal","dir":"$CP_T_TMP/p"}],"rules":[],"repos":{}}
JSON
cp_fallback_swap_back "$(cp_config_read)" work
assert_eq '{"claudeAiOauth":{"accessToken":"tok-work-original"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'file restore writes to the directory the backup came from'
assert_eq 'false' "$([ -e "$CP_T_TMP/w2/.credentials.json" ] && echo true || echo false)" \
  'file restore writes nothing into the re-pointed directory'
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'file restore to the original directory completes'
service="$(cp_keychain_service "$CP_T_TMP/w")"
printf '%s' '{"claudeAiOauth":{"accessToken":"tok-work-kc"}}' > "$KCD/$service-bak"
printf '%s' '{"claudeAiOauth":{"accessToken":"tok-personal-kc"}}' > "$KCD/$service"
rm -f "$CP_T_TMP/w/.credentials.json"
cat > "$(cp_fallback_marker_file work)" <<JSON
{"fallback":"personal","backup":"$service-bak","backup_kind":"keychain","swapped_at":1,"resets_at":"2020-01-01T00:00:00Z"}
JSON
cp_fallback_swap_back "$(cp_config_read)" work
assert_eq '{"claudeAiOauth":{"accessToken":"tok-work-kc"}}' "$(cat "$KCD/$service")" \
  'keychain restore writes to the service the backup shadows'
assert_eq 'false' "$([ -f "$KCD/$(cp_keychain_service "$CP_T_TMP/w2")" ] && echo true || echo false)" \
  'keychain restore writes nothing under the re-pointed directory service'
rm -f "$KCD/$service" "$KCD/$service-bak" "$(cp_fallback_marker_file work)"
cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","dir":"$CP_T_TMP/w","fallback":"personal"},{"name":"personal","dir":"$CP_T_TMP/p"}],"rules":[],"repos":{}}
JSON
CFG="$(cp_config_read)"
printf '{"claudeAiOauth":{"accessToken":"tok-work-original"}}' > "$CP_T_TMP/w/.credentials.json"

# --- keychain-backed restore ------------------------------------------------
# Same proof, keychain-backed: the backup item's token (tok-work-kc) is
# distinct from the live fallback token (tok-personal-kc) currently sitting
# in the primary's keychain slot.
service="$(cp_keychain_service "$CP_T_TMP/w")"
printf '%s' '{"claudeAiOauth":{"accessToken":"tok-work-kc"}}' > "$KCD/$service-bak"
printf '%s' '{"claudeAiOauth":{"accessToken":"tok-personal-kc"}}' > "$KCD/$service"
rm -f "$CP_T_TMP/w/.credentials.json"
cat > "$(cp_fallback_marker_file work)" <<JSON
{"fallback":"personal","backup":"$service-bak","backup_kind":"keychain","swapped_at":1,"resets_at":"2020-01-01T00:00:00Z"}
JSON
cat > "$CP_CURL_BIN" <<'STUB'
#!/usr/bin/env bash
echo "called" >> "$CP_T_TMP/curl-calls"
config="$(cat)"
printf '%s\n' "$config" | grep -o 'Authorization: Bearer [^"]*' >> "$CP_T_TMP/curl-auth-log"
cat <<'JSON'
{"five_hour":{"utilization":12,"resets_at":"2026-09-15T00:00:00Z"},
 "seven_day":{"utilization":10,"resets_at":"2026-09-20T00:00:00Z"},"limits":[]}
JSON
STUB
chmod +x "$CP_CURL_BIN"
rm -f "$CP_T_TMP/curl-calls" "$CP_T_TMP/curl-auth-log"
cp_fallback_swap_back "$CFG" work
assert_eq '{"claudeAiOauth":{"accessToken":"tok-work-kc"}}' "$(cat "$KCD/$service")" 'keychain restore writes back the original value'
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'keychain restore deletes the marker'
assert_eq 'true' "$(grep -q 'Bearer tok-work-kc' "$CP_T_TMP/curl-auth-log" && echo true || echo false)" \
  'the confirming fetch authenticated as the backed-up primary keychain token'
assert_eq 'false' "$(grep -q 'Bearer tok-personal-kc' "$CP_T_TMP/curl-auth-log" && echo true || echo false)" \
  'the confirming fetch never authenticated as the live fallback keychain token'

# --- keychain: -bak cannot be deleted after the restore: marker stays
# flagged restored, retry finishes ---------------------------------------------
printf '%s' '{"claudeAiOauth":{"accessToken":"tok-work-kc"}}' > "$KCD/$service-bak"
printf '%s' '{"claudeAiOauth":{"accessToken":"tok-personal-kc"}}' > "$KCD/$service"
cat > "$(cp_fallback_marker_file work)" <<JSON
{"fallback":"personal","backup":"$service-bak","backup_kind":"keychain","swapped_at":1,"resets_at":"2020-01-01T00:00:00Z"}
JSON
: > "$KCD/$service-bak.nodelete"
cp_fallback_swap_back "$CFG" work
assert_eq '{"claudeAiOauth":{"accessToken":"tok-work-kc"}}' "$(cat "$KCD/$service")" \
  'keychain -bak delete failure: the primary item is restored'
assert_eq 'true' "$(jq -r '.restored // false' "$(cp_fallback_marker_file work)" 2>/dev/null)" \
  'keychain -bak delete failure: the marker stays, flagged restored'
assert_eq 'true' "$([ -f "$KCD/$service-bak" ] && echo true || echo false)" \
  'keychain -bak delete failure: the -bak item stays for the retry'
rm -f "$KCD/$service-bak.nodelete"
# ... and while the keychain cannot even be read, cleanup waits rather than
# assuming the -bak item is gone
: > "$KCD/$service-bak.readfail"
STDERR_OUT="$(cp_fallback_swap_back "$CFG" work 2>&1 1>/dev/null)"
assert_eq 'true' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'an unreadable keychain during cleanup keeps the marker'
assert_eq 'true' "$([ -f "$KCD/$service-bak" ] && echo true || echo false)" \
  'an unreadable keychain during cleanup leaves the -bak item'
case "$STDERR_OUT" in *'could not be read to confirm'*) assert_eq ok ok 'an unreadable keychain during cleanup is reported' ;;
                      *) assert_eq 'cprof: fallback: ... could not be read to confirm ...' "$STDERR_OUT" 'an unreadable keychain during cleanup is reported' ;; esac
rm -f "$KCD/$service-bak.readfail"
cp_fallback_swap_back "$CFG" work
assert_eq 'false' "$([ -f "$KCD/$service-bak" ] && echo true || echo false)" 'the retry deletes the -bak item'
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" 'the retry deletes the marker'

# --- second keychain cycle: the -bak item must not survive a restore ------
service="$(cp_keychain_service "$CP_T_TMP/w")"
printf '%s' '{"claudeAiOauth":{"accessToken":"tok-work-real-2"}}' > "$KCD/$service"
cat > "$CP_T_TMP/state/usage/work.json" <<'JSON'
{"fetched_at":1,"five_hour":{"utilization":95,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":10,"resets_at":"2026-09-20T00:00:00Z"},"limits":[]}
JSON
printf '{"claudeAiOauth":{"accessToken":"tok-personal-2"}}' > "$CP_T_TMP/p/.credentials.json"
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
assert_eq 'tok-personal-2' "$(printf '%s' "$(cat "$KCD/$service")" | jq -r .claudeAiOauth.accessToken 2>/dev/null)" \
  'second cycle: swap-out fires again on a keychain profile that already completed one cycle'
assert_eq 'true' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'second cycle: marker written'
cat > "$CP_CURL_BIN" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"five_hour":{"utilization":10,"resets_at":"2026-09-15T00:00:00Z"},
 "seven_day":{"utilization":10,"resets_at":"2026-09-20T00:00:00Z"},"limits":[]}
JSON
STUB
chmod +x "$CP_CURL_BIN"
cat > "$(cp_fallback_marker_file work)" <<JSON
{"fallback":"personal","backup":"$service-bak","backup_kind":"keychain","swapped_at":1,"resets_at":"2020-01-01T00:00:00Z"}
JSON
cp_fallback_swap_back "$CFG" work
assert_eq 'tok-work-real-2' "$(printf '%s' "$(cat "$KCD/$service")" | jq -r .claudeAiOauth.accessToken 2>/dev/null)" \
  'second cycle: restore succeeds'
assert_eq 'false' "$([ -f "$KCD/$service-bak" ] && echo true || echo false)" \
  'second cycle: the -bak keychain item is deleted after a successful restore'

# --- restore write failure: marker stays for a retry, nothing is deleted --
printf '{"claudeAiOauth":{"accessToken":"tok-work"}}' > "$CP_T_TMP/w/.credentials.json.bak"
printf '{"claudeAiOauth":{"accessToken":"tok-personal"}}' > "$CP_T_TMP/w/.credentials.json"
cat > "$(cp_fallback_marker_file work)" <<JSON
{"fallback":"personal","backup":"$CP_T_TMP/w/.credentials.json.bak","backup_kind":"file","swapped_at":1,"resets_at":"2020-01-01T00:00:00Z"}
JSON
chmod 500 "$CP_T_TMP/w"
cp_fallback_swap_back "$CFG" work
chmod 700 "$CP_T_TMP/w"
assert_eq 'true' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'a restore-write failure leaves the marker in place for a retry'
assert_eq 'true' "$([ -f "$CP_T_TMP/w/.credentials.json.bak" ] && echo true || echo false)" \
  'a restore-write failure leaves the backup in place for a retry'
chmod 700 "$CP_T_TMP/w"
rm -f "$CP_T_TMP/w/.credentials.json.bak" "$(cp_fallback_marker_file work)"

# ==========================================================================
# Wired into cprof env
# ==========================================================================
cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","dir":"$CP_T_TMP/w","fallback":"personal"},{"name":"personal","dir":"$CP_T_TMP/p"}],"rules":[],"repos":{}}
JSON
printf '{"claudeAiOauth":{"accessToken":"tok-work"}}' > "$CP_T_TMP/w/.credentials.json"
printf '{"claudeAiOauth":{"accessToken":"tok-personal"}}' > "$CP_T_TMP/p/.credentials.json"
cat > "$CP_T_TMP/state/usage/work.json" <<'JSON'
{"fetched_at":1,"five_hour":{"utilization":95,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":10,"resets_at":"2026-09-20T00:00:00Z"},"limits":[]}
JSON
out="$("$CLI" env 2>/dev/null)"
assert_eq "export CLAUDE_CONFIG_DIR=$(cp_shquote "$CP_T_TMP/w")" "$out" \
  'cprof env still points at the primary directory after a swap'
assert_eq '{"claudeAiOauth":{"accessToken":"tok-personal"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'cprof env triggered the swap-out as a side effect'
rc=0
"$CLI" env >/dev/null 2>&1 || rc=$?
assert_eq '0' "$rc" 'cprof env still exits 0 with a swap active'

# --- a swapped profile re-pointed at a missing directory is still restored
# by cprof env once its window resets: the restore goes to the marker's
# recorded store, and runs before the directory check -----------------------
jq '.resets_at = "2020-01-01T00:00:00Z"' "$(cp_fallback_marker_file work)" > "$(cp_fallback_marker_file work).tmp" \
  && mv "$(cp_fallback_marker_file work).tmp" "$(cp_fallback_marker_file work)"
cat > "$CP_CURL_BIN" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"five_hour":{"utilization":12,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":10},"limits":[]}
JSON
STUB
chmod +x "$CP_CURL_BIN"
cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","dir":"$CP_T_TMP/gone","fallback":"personal"},{"name":"personal","dir":"$CP_T_TMP/p"}],"rules":[],"repos":{}}
JSON
rc=0; out="$("$CLI" env 2>/dev/null)" || rc=$?
assert_eq '0' "$rc" 'cprof env exits 0 for a swapped profile whose directory is missing'
assert_eq '{"claudeAiOauth":{"accessToken":"tok-work"}}' "$(cat "$CP_T_TMP/w/.credentials.json")" \
  'cprof env restores the original store even though the profile now points at a missing directory'
assert_eq 'false' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'the restore through cprof env completes and drops the marker'
case "$out" in *'unset CLAUDE_CONFIG_DIR'*) assert_eq ok ok 'cprof env still degrades to stock for the missing directory' ;;
                *) assert_eq 'unset CLAUDE_CONFIG_DIR' "$out" 'cprof env still degrades to stock for the missing directory' ;; esac
cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","dir":"$CP_T_TMP/w","fallback":"personal"},{"name":"personal","dir":"$CP_T_TMP/p"}],"rules":[],"repos":{}}
JSON

# ==========================================================================
# Visibility: list, which
# ==========================================================================
cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","dir":"$CP_T_TMP/w","fallback":"personal"},{"name":"personal","dir":"$CP_T_TMP/p"}],"rules":[],"repos":{}}
JSON
printf '{"claudeAiOauth":{"accessToken":"tok-work"}}' > "$CP_T_TMP/w/.credentials.json"
printf '{"claudeAiOauth":{"accessToken":"tok-personal"}}' > "$CP_T_TMP/p/.credentials.json"
cat > "$CP_CLAUDE_BIN" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = auth ] && [ "${2:-}" = status ] && printf '{"loggedIn":true,"email":"me@x.com","subscriptionType":"max"}\n'
STUB
chmod +x "$CP_CLAUDE_BIN"
mkdir -p "$CP_T_TMP/state/fallback-active"
cat > "$CP_T_TMP/state/fallback-active/work.json" <<JSON
{"fallback":"personal","backup":"$CP_T_TMP/w/.credentials.json.bak","backup_kind":"file","swapped_at":1,"resets_at":"2026-09-14T18:30:00Z"}
JSON
out="$(NO_COLOR=1 "$CLI" list 2>/dev/null)"
case "$out" in *'work→personal'*) assert_eq ok ok 'list annotates the swapped row' ;;
                *) assert_eq 'work→personal' "$out" 'list annotates the swapped row' ;; esac
# doctor reports the swap even when the (fallback's) live credentials no
# longer authenticate — that is exactly when the user needs to know
cat > "$CP_CLAUDE_BIN" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = auth ] && [ "${2:-}" = status ] && printf '{"loggedIn":false}\n'
STUB
chmod +x "$CP_CLAUDE_BIN"
out="$(cd "$CP_T_TMP" && NO_COLOR=1 "$CLI" doctor 2>&1)"
case "$out" in *'work: not logged in'*'work: fallback active (using personal'*) assert_eq ok ok 'doctor shows the active swap for a profile that is not logged in' ;;
                *) assert_eq 'work: not logged in ... work: fallback active (using personal' "$out" 'doctor shows the active swap for a profile that is not logged in' ;; esac
cat > "$CP_CLAUDE_BIN" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = auth ] && [ "${2:-}" = status ] && printf '{"loggedIn":true,"email":"me@x.com","subscriptionType":"max"}\n'
STUB
chmod +x "$CP_CLAUDE_BIN"
rm -f "$CP_T_TMP/state/fallback-active/work.json"

# --- which: would-fire note, only when no swap is active yet --------------
rm -f "$CP_T_TMP/state/usage/work.json"
cat > "$CP_T_TMP/state/usage/work.json" <<'JSON'
{"fetched_at":1,"five_hour":{"utilization":95,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":10,"resets_at":"2026-09-20T00:00:00Z"},"limits":[]}
JSON
out="$(cd "$CP_T_TMP" && NO_COLOR=1 "$CLI" which 2>/dev/null)"
case "$out" in *'personal'*) assert_eq ok ok 'which notes the fallback would fire' ;;
                *) assert_eq '...personal...' "$out" 'which notes the fallback would fire' ;; esac

# ==========================================================================
# remove: warns on an active fallback marker, but still cleans it up
# ==========================================================================
cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","dir":"$CP_T_TMP/w","fallback":"personal"},{"name":"personal","dir":"$CP_T_TMP/p"}],"rules":[],"repos":{}}
JSON
mkdir -p "$CP_T_TMP/state/fallback-active"
cat > "$(cp_fallback_marker_file work)" <<JSON
{"fallback":"personal","backup":"$CP_T_TMP/w/.credentials.json.bak","backup_kind":"file","swapped_at":1,"resets_at":"2020-01-01T00:00:00Z"}
JSON
# --purge is refused while the swap is active: the directory holds the only
# copy of the primary's own credentials (the .bak), and a keychain-backed
# swap's -bak item would go with it too
printf 'orig' > "$CP_T_TMP/w/.credentials.json.bak"
rc=0; printf 'y\n' | "$CLI" remove work --purge >/dev/null 2>&1 || rc=$?
assert_eq '1' "$rc" 'purge is refused while a file-backed swap is active'
assert_eq 'true' "$([ -d "$CP_T_TMP/w" ] && echo true || echo false)" 'refused purge leaves the directory'
assert_eq 'orig' "$(cat "$CP_T_TMP/w/.credentials.json.bak")" 'refused purge leaves the backup'
assert_eq 'work' "$(jq -r '.profiles[] | select(.name == "work") | .name' "$CPROF_CONFIG")" \
  'refused purge leaves the profile registered'
cat > "$(cp_fallback_marker_file work)" <<JSON
{"fallback":"personal","backup":"$(cp_keychain_service "$CP_T_TMP/w")-bak","backup_kind":"keychain","swapped_at":1,"resets_at":"2020-01-01T00:00:00Z"}
JSON
rc=0; printf 'y\n' | "$CLI" remove work --purge >/dev/null 2>&1 || rc=$?
assert_eq '1' "$rc" 'purge is refused while a keychain-backed swap is active'
assert_eq 'true' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" 'refused purge leaves the marker'
rm -f "$CP_T_TMP/w/.credentials.json.bak"
cat > "$(cp_fallback_marker_file work)" <<JSON
{"fallback":"personal","backup":"$CP_T_TMP/w/.credentials.json.bak","backup_kind":"file","swapped_at":1,"resets_at":"2020-01-01T00:00:00Z"}
JSON
rc=0; STDERR_OUT="$("$CLI" remove work 2>&1 1>/dev/null)" || rc=$?
case "$STDERR_OUT" in
  *'fallback swap'*'personal'*"$CP_T_TMP/w/.credentials.json.bak"*) result=true ;;
  *) result=false ;;
esac
assert_eq 'true' "$result" 'remove refuses an active fallback swap, naming the fallback and backup'
assert_eq '1' "$rc" 'remove exits 1 while a swap is active'
assert_eq 'true' "$([ -f "$(cp_fallback_marker_file work)" ] && echo true || echo false)" \
  'refused remove keeps the marker, so the restore can still run'
assert_eq 'work' "$(jq -r '.profiles[] | select(.name == "work") | .name' "$CPROF_CONFIG")" \
  'refused remove keeps the profile registered'
# remove runs under the same lock as the swaps: a held lock makes it back off
lock="$(cp_fallback_lock_dir work)"
mkdir -p "$lock"; printf '%s' "$$" > "$lock/pid"
rc=0; STDERR_OUT="$("$CLI" remove work 2>&1 1>/dev/null)" || rc=$?
assert_eq '1' "$rc" 'remove fails while another cprof holds the profile lock'
case "$STDERR_OUT" in *'another cprof'*) assert_eq ok ok 'remove reports the held lock' ;;
                      *) assert_eq 'cprof: remove: another cprof ...' "$STDERR_OUT" 'remove reports the held lock' ;; esac
assert_eq 'work' "$(jq -r '.profiles[] | select(.name == "work") | .name' "$CPROF_CONFIG")" 'a lock-blocked remove keeps the profile'
cp_fallback_unlock work
rm -f "$(cp_fallback_marker_file work)"
assert_ok "$CLI" remove work

cp_t_summary
