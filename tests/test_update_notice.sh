#!/usr/bin/env bash
set -u
# `doctor` reporting that a newer cprof has been published. Advisory on
# purpose: the skew check catches the two halves of an install disagreeing,
# this catches both being old together, and neither being current is a reason
# to fail doctor.
#
# Everything here runs against a curl stub. The real endpoint is never
# contacted, and a test that loses its stub must go silent rather than reach
# the network — which is itself asserted below.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
for lib in config resolve profiles auth output color usage statusline fallback share update; do
  # shellcheck source=/dev/null
  . "$(dirname "$0")/../scripts/lib/$lib.sh"
done

# A curl that answers every URL with one release tag.
stub_release() {
  cat > "$CP_CURL_BIN" <<STUB
#!/usr/bin/env bash
printf '%s' '{"tag_name":"$1"}'
STUB
  chmod +x "$CP_CURL_BIN"
}
# A curl that behaves like an unreachable host.
stub_fail() {
  printf '#!/usr/bin/env bash\nexit 7\n' > "$CP_CURL_BIN"
  chmod +x "$CP_CURL_BIN"
}
forget_cache() { rm -f "$CPROF_STATE_DIR"/update.json*; }
# The suite runs on macOS in CI and on Linux locally for some contributors, and
# the two stats disagree about how to ask for a mode.
file_mode() { stat -f '%OLp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null; }
cached() { [ -f "$CPROF_STATE_DIR/update.json" ] && echo 1 || echo 0; }
drop_plugin() { rm -rf "${HOME:?}/.claude/plugins/cache/m"; }
add_plugin() {
  mkdir -p "$HOME/.claude/plugins/cache/m/cprof/$1"
  printf '{"version":"%s"}\n' "$1" > "$HOME/.claude/plugins/cache/m/cprof/$1/plugin.json"
}

# ------------------------------------------------- the tag is the only source
assert_eq '0.15.0' "$(cp_update_tag_version 'cprof--v0.15.0')" 'a release tag yields its version'
assert_eq '' "$(cp_update_tag_version 'v0.15.0')"      'a tag without the project prefix is not ours'
assert_eq '' "$(cp_update_tag_version '0.15.0')"       'a bare version is not a tag'
assert_eq '' "$(cp_update_tag_version 'other--v1.0.0')" 'another project sharing the repo is ignored'
assert_eq '' "$(cp_update_tag_version 'cprof--v1.0.0-rc1')" 'a pre-release tag is not comparable'
assert_eq '' "$(cp_update_tag_version '')"             'an empty tag yields nothing'

# ------------------------------------------------------------- what it prints
assert_eq 'cprof 0.14.0 is installed; 0.15.0 is available' \
  "$(cp_update_report 0.14.0 0.15.0 | head -1)" 'an older install is reported'
assert_eq '    run: cprof update (and brew upgrade dcotelo/tap/cprof once the tap has it)' \
  "$(cp_update_report 0.14.0 0.15.0 | sed -n 2p)" \
  'the advice leads with the command that always works'
assert_eq '' "$(cp_update_report 0.15.0 0.15.0)" 'the current version reports nothing'
assert_eq '' "$(cp_update_report 0.16.0 0.15.0)" 'an install ahead of the release reports nothing'
assert_eq '' "$(cp_update_report '' 0.15.0)"     'an unreadable install reports nothing'
assert_eq '' "$(cp_update_report 0.14.0 '')"     'an unreadable release reports nothing'
# String order would rank 0.9.0 above 0.15.0, which is the whole point of
# comparing segment by segment.
assert_eq 'cprof 0.9.0 is installed; 0.15.0 is available' \
  "$(cp_update_report 0.9.0 0.15.0 | head -1)" 'two-digit minors sort as numbers'

# ------------------------------------------------------------ fetch and cache
forget_cache
stub_release 'cprof--v0.15.0'
assert_eq '0.15.0' "$(cp_update_latest)" 'a fetch yields the published version'
assert_eq '1' "$(cached)" 'and caches it'
assert_eq '0.15.0' "$(jq -r .latest "$CPROF_STATE_DIR/update.json")" 'the cache holds the version'
# The write goes through a mktemp name, so nothing may be left behind beside
# the cache -- a leaked temp file would also mean the atomic rename did not
# happen.
assert_eq '1' "$(find "$CPROF_STATE_DIR" -maxdepth 1 -name 'update.json*' | wc -l | tr -d ' ')" \
  'the write leaves no temp file behind'
assert_eq '600' "$(file_mode "$CPROF_STATE_DIR/update.json")" 'and the cache is not world-readable'

# The cache is what makes this safe to call from doctor: once written, the
# second call must not touch the network at all. A failing stub cannot show
# that -- the stale-cache fallback would return the same value either way -- so
# the stub answers with a different version. Getting the cached one back is the
# only proof the fetch did not happen.
stub_release 'cprof--v0.99.0'
assert_eq '0.15.0' "$(cp_update_latest)" 'a fresh cache is served without fetching'
assert_eq '0.15.0' "$(jq -r .latest "$CPROF_STATE_DIR/update.json")" \
  'and the cache is left as it was'
stub_fail

# A stale cache still answers rather than going silent — a day-old version
# beats no advice, and the advice is only ever advisory.
jq '.fetched_at = 1' "$CPROF_STATE_DIR/update.json" > "$CPROF_STATE_DIR/u.tmp" \
  && mv "$CPROF_STATE_DIR/u.tmp" "$CPROF_STATE_DIR/update.json"
assert_eq '0.15.0' "$(cp_update_latest)" 'a stale cache is used when the refetch fails'

# But a stale cache must not block a successful refetch.
stub_release 'cprof--v0.16.0'
assert_eq '0.16.0' "$(cp_update_latest)" 'a stale cache is replaced by a fresh fetch'
assert_eq '0.16.0' "$(jq -r .latest "$CPROF_STATE_DIR/update.json")" 'and the cache is updated'

# ------------------------------------------------------- every failure is mute
forget_cache
stub_fail
assert_eq '' "$(cp_update_latest)" 'an unreachable host yields nothing'

forget_cache
printf '#!/usr/bin/env bash\nprintf "<html>not json</html>"\n' > "$CP_CURL_BIN"
chmod +x "$CP_CURL_BIN"
assert_eq '' "$(cp_update_latest)" 'an HTML error page yields nothing'
assert_eq '0' "$(cached)" 'and nothing is cached from it'

forget_cache
stub_release 'cprof--v0.1.0-not-a-number'
assert_eq '' "$(cp_update_latest)" 'a tag that is not a dotted number yields nothing'

forget_cache
rm -f "$CP_CURL_BIN"
assert_eq '' "$(cp_update_latest)" 'no curl at all yields nothing'

# A non-https URL is refused before curl runs. The tag is public so no
# credential is at stake, but a redirected or misconfigured URL must not
# become a plaintext request.
forget_cache
stub_release 'cprof--v0.15.0'
assert_eq '' "$(CP_UPDATE_URL='http://example.invalid/releases' cp_update_latest)" \
  'a plaintext URL is refused'
assert_eq '0' "$(cached)" 'and nothing is cached from a refused URL'

# ------------------------------------------------------------------- opt-out
forget_cache
stub_release 'cprof--v9.9.9'
# An installed version has to exist, or the check returns early for having
# nothing to compare and the opt-out is never reached.
add_plugin 0.9.0
assert_eq '0.9.0' "$(CP_CPROF_BIN='' cp_update_installed)" 'precondition: a version to compare'
assert_eq '' "$(CP_CPROF_BIN='' CPROF_NO_UPDATE_CHECK=1 cp_update_problems)" \
  'CPROF_NO_UPDATE_CHECK silences the check'
assert_eq '0' "$(cached)" 'and makes no request'
# With no cache, the opt-out inside the fetch would hide a missing one here.
# A fresh cache needs no fetch, so this is the case that proves the check
# itself is skipped rather than merely starved of data.
cp_update_cache_write 0.99.0
assert_eq '' "$(CP_CPROF_BIN='' CPROF_NO_UPDATE_CHECK=1 cp_update_problems)" \
  'the opt-out is honoured even with a fresh cache to report from'
# And the same state without the opt-out does report, so the assertion above
# is about the opt-out rather than about an empty cache.
assert_eq 'cprof 0.9.0 is installed; 0.99.0 is available' \
  "$(CP_CPROF_BIN='' cp_update_problems | head -1)" 'the same state reports without it'
forget_cache
drop_plugin

# ------------------------------------------- the newest half is what counts
# A current plugin beside an old CLI is skew, which the other check reports.
# This one must stay quiet: something on this machine is current.
add_plugin 0.15.0
printf '#!/usr/bin/env bash\necho "cprof 0.9.0"\n' > "$CP_T_TMP/bin/oldcprof"
chmod +x "$CP_T_TMP/bin/oldcprof"
OLD_CLI="$CP_T_TMP/bin/oldcprof"
assert_eq '0.15.0' "$(CP_CPROF_BIN="$OLD_CLI" cp_update_installed)" \
  'the newer half is the installed version'
forget_cache
stub_release 'cprof--v0.15.0'
assert_eq '' "$(CP_CPROF_BIN="$OLD_CLI" cp_update_problems)" \
  'a current plugin keeps the update check quiet'

# And the other way round: a CLI ahead of the plugin is the newest thing here,
# so it is what gets compared. Without both directions, taking the plugin
# unconditionally would pass.
printf '#!/usr/bin/env bash\necho "cprof 0.16.0"\n' > "$CP_T_TMP/bin/newcprof"
chmod +x "$CP_T_TMP/bin/newcprof"
NEW_CLI="$CP_T_TMP/bin/newcprof"
assert_eq '0.16.0' "$(CP_CPROF_BIN="$NEW_CLI" cp_update_installed)" \
  'a CLI ahead of the plugin is the installed version'
forget_cache
stub_release 'cprof--v0.16.0'
assert_eq '' "$(CP_CPROF_BIN="$NEW_CLI" cp_update_problems)" \
  'and a current CLI keeps the check quiet too'

forget_cache
stub_release 'cprof--v0.16.0'
assert_eq 'cprof 0.15.0 is installed; 0.16.0 is available' \
  "$(CP_CPROF_BIN="$OLD_CLI" cp_update_problems | head -1)" \
  'both halves behind is reported once'

# No cprof resolvable at all leaves nothing to compare. Set-and-empty is the
# seam's way of saying "no cprof on PATH", which a machine that has one
# installed cannot otherwise arrange.
drop_plugin
assert_eq '' "$(CP_CPROF_BIN='' cp_update_installed)" 'nothing installed yields no version'
assert_eq '' "$(CP_CPROF_BIN='' cp_update_problems)" 'and no report'

# ---------------------------------------------- advisory, never a failed doctor
forget_cache
add_plugin 0.9.0
stub_release 'cprof--v9.9.9'
cp_update_problems >/dev/null
assert_eq '0' "$?" 'a reported update still returns success'
stub_fail
forget_cache
cp_update_problems >/dev/null
assert_eq '0' "$?" 'a failed check returns success too'

# ------------------------------------ a state dir that cannot be secured
# chmod failing means the directory is not ours to lock down. The same
# directory holds the config that decides which account a directory resolves
# to, so the write is refused rather than left in an unsecured dir. Only a
# stub can arrange this: a real chmod only fails for a dir another user owns.
mkdir -p "$CP_T_TMP/badchmod"
cat > "$CP_T_TMP/badchmod/chmod" <<'STUB'
#!/usr/bin/env bash
case "$1" in 700) exit 1 ;; esac
exec /bin/chmod "$@"
STUB
chmod +x "$CP_T_TMP/badchmod/chmod"
forget_cache
PATH="$CP_T_TMP/badchmod:$PATH" cp_update_cache_write 0.15.0
assert_eq '1' "$?" 'a state dir that cannot be secured refuses the write'
assert_eq '0' "$(cached)" 'and leaves nothing behind in it'
# The same call with a working chmod succeeds, so the assertion above is about
# the failure and not about some other refusal.
cp_update_cache_write 0.15.0
assert_eq '0' "$?" 'the same write succeeds with a chmod that works'
forget_cache

# --------------------------------------------- through the doctor command
# Everything above calls the functions directly, which cannot see whether
# doctor still calls them: deleting the call from cp_cmd_doctor would leave
# all of it passing. This runs the real command.
CLI="$(cd "$(dirname "$0")/.." && pwd -P)/scripts/cprof"
cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","native":true}],"rules":[],"repos":{}}
JSON
cat > "$CP_CLAUDE_BIN" <<'STUB'
#!/usr/bin/env bash
printf '{"loggedIn":true,"account":{"email":"you@example.com"}}\n'
STUB
chmod +x "$CP_CLAUDE_BIN"
# Both halves at the same version, so the skew check stays quiet and the only
# version line doctor can print is this one.
drop_plugin
add_plugin 0.9.0
printf '#!/usr/bin/env bash\necho "cprof 0.9.0"\n' > "$CP_T_TMP/bin/samecprof"
chmod +x "$CP_T_TMP/bin/samecprof"
SAME_CLI="$CP_T_TMP/bin/samecprof"
forget_cache
stub_release 'cprof--v9.9.9'
out="$(CP_CPROF_BIN="$SAME_CLI" "$CLI" doctor 2>&1)"; rc=$?
case "$out" in
  *'cprof 0.9.0 is installed; 9.9.9 is available'*) r=yes ;;
  *) r="no: $out" ;;
esac
assert_eq 'yes' "$r" 'doctor prints the update notice'
assert_eq '0' "$rc" 'and still exits zero, because an update is not a defect'

# The opt-out reaches the command too, and the same run says nothing else
# about a version -- so the line above came from the update check.
forget_cache
out="$(CP_CPROF_BIN="$SAME_CLI" CPROF_NO_UPDATE_CHECK=1 "$CLI" doctor 2>&1)"; rc=$?
case "$out" in
  *'is available'*) r="still reported: $out" ;;
  *) r=quiet ;;
esac
assert_eq 'quiet' "$r" 'CPROF_NO_UPDATE_CHECK silences doctor'
assert_eq '0' "$rc" 'and leaves the rest of doctor passing'

cp_t_summary
