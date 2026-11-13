#!/usr/bin/env bash
set -u
# A shared profile drifting away from ~/.claude (#52): a link replaced by a
# regular file, an asset created upstream after the profile was shared, or a
# link that points somewhere else. Each one means the profile silently stops
# getting what ~/.claude has -- hooks and permission rules included -- so
# doctor fails on it, the SessionStart hook warns, and re-running share both
# repairs it and says what the replaced file had that ~/.claude does not.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
for lib in config resolve profiles auth output color usage statusline fallback share update; do
  # shellcheck source=/dev/null
  . "$(dirname "$0")/../scripts/lib/$lib.sh"
done
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CLI="$ROOT/scripts/cprof"
HOOK="$ROOT/hooks/session-start.sh"
TAB="$(printf '\t')"

S="$HOME/.claude"
mkdir -p "$S/plugins" "$S/skills" "$S/hooks"
printf '{"theme":"dark","model":"opus","permissions":{"deny":["Bash(rm:*)"]}}\n' > "$S/settings.json"
P="$HOME/.claude-profiles/personal"
cp_t_write_config <<JSON
{"default":"work",
 "profiles":[{"name":"work","native":true},{"name":"personal","dir":"$P"},
             {"name":"walled","dir":"$HOME/.claude-profiles/walled"}],
 "rules":[],"repos":{}}
JSON
"$CLI" share personal >/dev/null 2>&1
mkdir -p "$HOME/.claude-profiles/walled"
printf '{"theme":"light"}\n' > "$HOME/.claude-profiles/walled/settings.json"

# state_of <dir> <asset>: the state cp_share_check gives one asset, or "none".
state_of() {
  local row
  row="$(cp_share_check "$1" | grep "^$2$TAB" || true)"
  printf '%s\n' "${row#*"$TAB"}" | sed 's/^$/none/'
}

# ---------------------------------------------------------- cp_share_check
assert_eq 'ok' "$(state_of "$P" settings.json)" 'a fresh share is ok'
assert_eq 'ok' "$(state_of "$P" plugins)" 'directories too'
assert_eq 'none' "$(state_of "$P" agents)" 'an asset ~/.claude does not have is not listed'
assert_eq '' "$(cp_share_check "$P" | grep -v "${TAB}ok$")" 'nothing but ok rows when nothing drifted'

# The link replaced by a regular file: what Claude Code's settings save did.
rm "$P/settings.json"; printf '{"theme":"dark","model":"opus[1m]"}\n' > "$P/settings.json"
assert_eq 'drifted' "$(state_of "$P" settings.json)" 'a file where the link was is drifted'

# Created upstream after the share: never linked.
printf '# rules\n' > "$S/CLAUDE.md"
assert_eq 'missing' "$(state_of "$P" CLAUDE.md)" 'an asset added to ~/.claude later is missing'

# A link, but not to ~/.claude.
rm "$P/hooks"; mkdir -p "$CP_T_TMP/elsewhere"; ln -s "$CP_T_TMP/elsewhere" "$P/hooks"
assert_eq 'foreign' "$(state_of "$P" hooks)" 'a link somewhere else is foreign'

# Not shared at all: no link into ~/.claude, so there is nothing to drift from.
assert_eq '' "$(cp_share_check "$HOME/.claude-profiles/walled")" 'an unshared profile reports nothing'
# The source itself, and a directory that does not exist, report nothing.
assert_eq '' "$(cp_share_check "$S")" 'the source directory is not checked against itself'
assert_eq '' "$(cp_share_check "$CP_T_TMP/nope")" 'a missing directory reports nothing'
assert_ok cp_share_check "$CP_T_TMP/nope"

# ------------------------------------------------------ cp_share_drift_summary
assert_eq 'settings.json (replaced by a file), CLAUDE.md (not linked), hooks (links elsewhere)' \
  "$(cp_share_drift_summary "$P")" 'one phrase per drifted asset, in CP_SHARED_ASSETS order'
assert_eq '' "$(cp_share_drift_summary "$HOME/.claude-profiles/walled")" 'nothing for an unshared profile'

# ------------------------------------------------------------------- doctor
cat > "$CP_CLAUDE_BIN" <<'STUB'
#!/usr/bin/env bash
printf '{"loggedIn":true,"account":{"email":"you@example.com"}}\n'
STUB
chmod +x "$CP_CLAUDE_BIN"
out="$("$CLI" doctor 2>&1)"; rc=$?
case "$out" in
  *"personal: not following ~/.claude: settings.json (replaced by a file), CLAUDE.md (not linked), hooks (links elsewhere) - run: cprof share personal"*) r=yes ;;
  *) r="no: $out" ;;
esac
assert_eq 'yes' "$r" 'doctor names the profile, every drifted asset and the fix'
assert_eq '1' "$rc" 'and fails: a profile without the shared rules is a defect'
case "$out" in *'walled: not following'*) r=no ;; *) r=yes ;; esac
assert_eq 'yes' "$r" 'doctor says nothing about an unshared profile'

# ---------------------------------------------------- share repairs and diffs
out="$("$CLI" share personal 2>&1)"
case "$out" in
  *'settings.json.moved-'*'differs from ~/.claude in: model'*) r=yes ;;
  *) r="no: $out" ;;
esac
assert_eq 'yes' "$r" 'share names the keys the replaced settings.json had differently'
case "$out" in *'opus[1m]'*) r='printed a value' ;; *) r='keys only' ;; esac
assert_eq 'keys only' "$r" 'values are never printed: settings can hold secrets'
assert_eq "$S/settings.json" "$(readlink "$P/settings.json")" 'settings.json is a link again'
assert_eq "$S/CLAUDE.md" "$(readlink "$P/CLAUDE.md")" 'CLAUDE.md is linked'
assert_eq "$S/hooks" "$(readlink "$P/hooks")" 'hooks points back at ~/.claude'
assert_eq '' "$(cp_share_check "$P" | grep -v "${TAB}ok$")" 'nothing left drifted after share'

out="$("$CLI" doctor 2>&1)"; rc=$?
assert_eq '0' "$rc" 'doctor passes once the profile is repaired'

# Keys only in the old copy, and an old copy identical to ~/.claude.
rm "$P/settings.json"; printf '{"theme":"dark","model":"opus","permissions":{"deny":["Bash(rm:*)"]},"env":{"TOKEN":"s3cret"}}\n' > "$P/settings.json"
out="$("$CLI" share personal 2>&1)"
case "$out" in *'only in the old copy: env'*) r=yes ;; *) r="no: $out" ;; esac
assert_eq 'yes' "$r" 'share names keys the old copy had that ~/.claude lacks'
case "$out" in *s3cret*|*TOKEN*) r=leaked ;; *) r=clean ;; esac
assert_eq 'clean' "$r" 'nested names and values stay out of the report'

rm "$P/settings.json"; cp "$S/settings.json" "$P/settings.json"
out="$("$CLI" share personal 2>&1)"
case "$out" in *'matches ~/.claude'*) r=yes ;; *) r="no: $out" ;; esac
assert_eq 'yes' "$r" 'an old copy identical to ~/.claude says so'

# An old copy missing keys ~/.claude has does not "match" it.
rm "$P/settings.json"; printf '{}\n' > "$P/settings.json"
out="$("$CLI" share personal 2>&1)"
case "$out" in
  *'matches ~/.claude'*) r="claimed a match: $out" ;;
  *'only in ~/.claude: model, permissions, theme'*) r=yes ;;
  *) r="no: $out" ;;
esac
assert_eq 'yes' "$r" 'share names keys only ~/.claude has, and does not call that a match'
case "$out" in *'Bash(rm'*|*opus*|*dark*) r=leaked ;; *) r=clean ;; esac
assert_eq 'clean' "$r" 'the source side stays keys-only too'

# A key carrying a control character is not echoed into the terminal.
rm "$P/settings.json"
printf '{"theme":"dark","bad\\u001b[31mkey":1}\n' > "$P/settings.json"
out="$("$CLI" share personal 2>&1)"
case "$out" in *"$(printf '\033')"*) r=leaked ;; *) r=clean ;; esac
assert_eq 'clean' "$r" 'a key with an escape byte is not printed raw'

# An old copy that is not JSON gets no diff, and share still succeeds.
rm "$P/settings.json"; printf 'not json\n' > "$P/settings.json"
assert_ok "$CLI" share personal
assert_eq "$S/settings.json" "$(readlink "$P/settings.json")" 'relinked even when the old copy was not JSON'

# ------------------------------------------------------------- SessionStart
export CLAUDE_PLUGIN_ROOT="$ROOT"
out="$(cd "$CP_T_TMP" && CLAUDE_CONFIG_DIR="$P" bash "$HOOK" 2>&1)"
case "$out" in *'not following'*) r="warned: $out" ;; *) r=silent ;; esac
assert_eq 'silent' "$r" 'no drift warning for a healthy profile'

rm "$P/settings.json"; printf '{}\n' > "$P/settings.json"
out="$(cd "$CP_T_TMP" && CLAUDE_CONFIG_DIR="$P" bash "$HOOK" 2>&1)"; rc=$?
case "$out" in
  *'cprof: profile personal is not following ~/.claude: settings.json (replaced by a file)'*'cprof share personal'*) r=yes ;;
  *) r="no: $out" ;;
esac
assert_eq 'yes' "$r" 'the hook warns once, naming the profile, the asset and the fix'
assert_eq '1' "$(printf '%s\n' "$out" | grep -c 'not following')" 'exactly one drift line'
assert_eq '0' "$rc" 'and never fails the session'
assert_eq 'drifted' "$(state_of "$P" settings.json)" 'the hook only warns; it never relinks'

out="$(cd "$CP_T_TMP" && bash "$HOOK" 2>&1)"
case "$out" in *'not following'*) r=warned ;; *) r=silent ;; esac
assert_eq 'silent' "$r" 'a native session (no CLAUDE_CONFIG_DIR) is not checked'

cp_t_summary
