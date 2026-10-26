#!/usr/bin/env bash
set -u
# Every atomic state write stages through a temporary file beside its target.
# A temp name an attacker can predict is a temp name they can pre-empt with a
# symlink: the redirect then writes through it and the following `chmod 600`
# changes the mode of whatever it points at. `mkdir -p` and `chmod 700` on the
# state directory do not close the window, because the symlink can predate
# both.
#
# `$$` is the shell's PID and a sourced function shares it, so these tests can
# name `<target>.tmp.$$` exactly as the old code did and plant a symlink there.
# Each assertion below fails against that spelling and passes against mktemp,
# which refuses an existing name.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
for lib in config resolve profiles auth output color usage fallback; do
  # shellcheck source=/dev/null
  . "$(dirname "$0")/../scripts/lib/$lib.sh"
done

# A file outside the state dir standing in for whatever an attacker aims the
# symlink at -- another user's dotfile, an authorized_keys, anything writable
# by the account running cprof.
VICTIM="$CP_T_TMP/victim"
plant() {   # $1 = the temp path the old code would have used; $2 = victim
  local v="${2:-$VICTIM}"
  printf 'untouched\n' > "$v"
  rm -f "$1"
  ln -s "$v" "$1"
}
victim() { cat "${1:-$VICTIM}" 2>/dev/null; }

# --------------------------------------------------------------- the config
# The worst of the targets: the config decides which account every directory
# resolves to, so a write through a planted symlink is a rewrite of that
# mapping.
cp_t_write_config <<'JSON'
{"default":"personal","profiles":[{"name":"personal","native":true}],"rules":[],"repos":{}}
JSON
plant "$CPROF_CONFIG.tmp.$$"
printf '{"default":"work","profiles":[{"name":"work","native":true}],"rules":[],"repos":{}}' \
  | cp_config_write
assert_eq 'untouched' "$(victim)" 'a planted config temp name is not written through'
assert_eq 'work' "$(cp_config_read | jq -r '.default')" 'and the config write still lands'
rm -f "$CPROF_CONFIG.tmp.$$"

# ---------------------------------------------------------- the usage cache
USAGE_BODY='{"five_hour":{"utilization":42,"resets_at":"2026-09-14T18:30:00Z"}}'
ucache="$(cp_usage_cache_file work)"
mkdir -p "$(dirname "$ucache")"
plant "$ucache.tmp.$$"
cp_usage_cache_write work "$USAGE_BODY"
assert_eq 'untouched' "$(victim)" 'a planted usage temp name is not written through'
assert_eq '42' "$(cp_usage_pct "$(cat "$ucache")" five_hour)" \
  'and the usage cache write still lands'
rm -f "$ucache.tmp.$$"

# ------------------------------------------------- the fallback swap-out
# One swap-out stages a marker and overwrites a credential file, each through
# its own temp name. A credential file is the highest-value target of the set,
# so both are checked here.
mkdir -p "$CP_T_TMP/w" "$CP_T_TMP/p"
cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","dir":"$CP_T_TMP/w","fallback":"personal"},{"name":"personal","dir":"$CP_T_TMP/p"}],"rules":[],"repos":{}}
JSON
CFG="$(cp_config_read)"
printf '{"claudeAiOauth":{"accessToken":"tok-personal"}}' > "$CP_T_TMP/p/.credentials.json"
printf '{"claudeAiOauth":{"accessToken":"tok-work"}}' > "$CP_T_TMP/w/.credentials.json"
mkdir -p "$CP_T_TMP/state/usage"
# Over the threshold, so the swap actually happens.
cat > "$CP_T_TMP/state/usage/work.json" <<'JSON'
{"fetched_at":1,"five_hour":{"utilization":92,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":10,"resets_at":"2026-09-20T00:00:00Z"},"limits":[]}
JSON

CRED="$CP_T_TMP/w/.credentials.json"
MARKER="$(cp_fallback_marker_file work)"
mkdir -p "$(dirname "$MARKER")"
CRED_VICTIM="$CP_T_TMP/cred-victim"
MARKER_VICTIM="$CP_T_TMP/marker-victim"
plant "$CRED.tmp.$$" "$CRED_VICTIM"
plant "$MARKER.tmp.$$" "$MARKER_VICTIM"
cp_fallback_swap_out "$CFG" work "$CP_T_TMP/w"
assert_eq 'untouched' "$(victim "$CRED_VICTIM")" \
  'a planted credential temp name is not written through'
assert_eq 'untouched' "$(victim "$MARKER_VICTIM")" \
  'a planted marker temp name is not written through'
# And the swap itself still happened, so the two above are about the symlink
# and not about a swap that silently declined to run.
assert_eq '{"claudeAiOauth":{"accessToken":"tok-personal"}}' "$(cat "$CRED")" \
  'and the swap still installs the fallback credentials'
assert_eq 'personal' "$(jq -r .fallback "$MARKER" 2>/dev/null)" 'and still writes the marker'
rm -f "$CRED.tmp.$$" "$MARKER.tmp.$$"

# -------------------------------------------------- the fallback restore
# The mirror of the swap-out: restoring writes the primary's own credentials
# back over the fallback's and then stamps the marker, each through its own
# temp name.
cat > "$CP_CURL_BIN" <<'STUB'
#!/usr/bin/env bash
# The confirming fetch: the primary's window has room again.
printf '%s' '{"five_hour":{"utilization":5,"resets_at":"2030-01-01T00:00:00Z"}}'
STUB
chmod +x "$CP_CURL_BIN"
# Remove these paths outright rather than writing over them. Against the
# vulnerable spelling the section above leaves $CRED a symlink, and writing
# "through" it would both corrupt the victim and leave the restore reading
# something that is not a credential blob -- which made the two assertions
# below pass without testing the restore at all.
rm -f "$CRED" "$CRED.bak" "$MARKER"
printf '{"claudeAiOauth":{"accessToken":"tok-work"}}' > "$CRED.bak"
printf '{"claudeAiOauth":{"accessToken":"tok-personal"}}' > "$CRED"
# resets_at in the past, so the window the swap was made for has closed.
cat > "$MARKER" <<JSON
{"fallback":"personal","backup":"$CRED.bak","backup_kind":"file","swapped_at":1,"resets_at":"2020-01-01T00:00:00Z"}
JSON
plant "$CRED.tmp.$$" "$CRED_VICTIM"
plant "$MARKER.tmp.$$" "$MARKER_VICTIM"
cp_fallback_swap_back "$CFG" work >/dev/null 2>&1
assert_eq 'untouched' "$(victim "$CRED_VICTIM")" \
  'a planted temp name is not written through on restore either'
assert_eq 'untouched' "$(victim "$MARKER_VICTIM")" \
  'nor the one beside the marker being stamped'
assert_eq '{"claudeAiOauth":{"accessToken":"tok-work"}}' "$(cat "$CRED")" \
  'and the restore still puts the primary credentials back'
# A restore that wrote the credentials back but stopped before cleaning up
# would satisfy the assertion above while leaving the marker in place, which
# keeps swap-out away for good. Both are removed only on the success path --
# a failed cleanup deliberately keeps them so the next call can retry.
assert_eq 'gone' "$([ -e "$MARKER" ] && echo present || echo gone)" \
  'and the finished restore removes the marker'
assert_eq 'gone' "$([ -e "$CRED.bak" ] && echo present || echo gone)" \
  'and removes the backup it restored from'
rm -f "$CRED.tmp.$$" "$MARKER.tmp.$$"

cp_t_summary
