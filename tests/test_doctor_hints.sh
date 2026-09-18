#!/usr/bin/env bash
set -u
# Version skew between the cprof on PATH and the installed plugin, and what
# `statusLine` is wired to. Both are advisory: a user can run a stale CLI or
# another statusline on purpose, but neither should be invisible.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
for lib in config resolve profiles auth output color usage statusline fallback share update; do
  # shellcheck source=/dev/null
  . "$(dirname "$0")/../scripts/lib/$lib.sh"
done
CLI="$(cd "$(dirname "$0")/.." && pwd -P)/scripts/cprof"
ESC="$(printf '\033')"

# --------------------------------------------------------- cp_ver_lt ordering
# String comparison is the bug being guarded against: "0.9.0" sorts after
# "0.13.0" lexically, which is how a stale CLI looked current.
assert_ok   cp_ver_lt 0.9.0 0.13.0
assert_fail cp_ver_lt 0.13.0 0.9.0
assert_fail cp_ver_lt 0.13.0 0.13.0
assert_ok   cp_ver_lt 0.13.0 0.13.1
assert_ok   cp_ver_lt 0.13.9 0.14.0
assert_fail cp_ver_lt 1.0.0 0.99.99
assert_ok   cp_ver_lt 0.99.99 1.0.0
# A missing component reads as zero, so these are equal, not less. The
# single-component cases are the ones `cut` got wrong: without -s it prints the
# whole line when the delimiter is absent, so "1" answered "1" for every field.
assert_fail cp_ver_lt 0.13 0.13.0
assert_fail cp_ver_lt 0.13.0 0.13
assert_fail cp_ver_lt 1 1.0
assert_fail cp_ver_lt 1.0 1
assert_ok   cp_ver_lt 1 1.0.1
assert_fail cp_ver_lt 1.0.1 1
assert_ok   cp_ver_lt 1 2
# More components than a release ever carries still compare, rather than
# reading as equal because the loop stopped early.
assert_ok   cp_ver_lt 1.2.3.4.5 1.2.3.4.6
assert_fail cp_ver_lt 1.2.3.4.6 1.2.3.4.5
assert_fail cp_ver_lt 1.2.3.4.5 1.2.3.4.5
# Nothing comparable is never "less".
for bad in '' x 1.2.x '0.13.0-rc1' '1..2' ' 1.2.3'; do
  assert_fail cp_ver_lt "$bad" 9.9.9
  assert_fail cp_ver_lt 9.9.9 "$bad"
done

# ------------------------------------------------------- cp_skew_report lines
out="$(cp_skew_report 0.9.0 0.13.0 /opt/homebrew/bin/cprof)"
assert_eq '1' "$(printf '%s' "$out" | grep -c .)" 'a stale CLI reports one line'
case "$out" in
  *'0.9.0'*'0.13.0'*'brew upgrade'*) r=yes ;;
  *) r="no: $out" ;;
esac
assert_eq 'yes' "$r" 'the stale-CLI line names both versions and the fix'

out="$(cp_skew_report 0.13.0 0.12.0 /opt/homebrew/bin/cprof)"
case "$out" in
  *'0.12.0'*'cprof update'*) r=yes ;;
  *) r="no: $out" ;;
esac
assert_eq 'yes' "$r" 'a stale plugin points at cprof update instead'

assert_eq '' "$(cp_skew_report 0.13.0 0.13.0 /bin/cprof)" 'agreement is silent'

# The status, not the output, is what decides whether doctor fails.
assert_fail cp_skew_report 0.9.0 0.13.0 /bin/cprof
assert_fail cp_skew_report 0.13.0 0.12.0 /bin/cprof
assert_ok   cp_skew_report 0.13.0 0.13.0 /bin/cprof
assert_ok   cp_skew_report 'weird output' 0.13.0 /bin/cprof
assert_ok   cp_skew_report '' 0.13.0 ''

# Paths shown to users go through cp_path_display, so the one line that names
# the CLI shortens a path under HOME the way every other cprof message does.
out="$(cp_skew_report 'weird output' 0.13.0 "$HOME/.local/bin/cprof")"
case "$out" in
  *'~/.local/bin/cprof'*) r=yes ;;
  *"$HOME"*) r="unshortened: $out" ;;
  *) r="no: $out" ;;
esac
assert_eq 'yes' "$r" 'the CLI path is displayed the way every other path is'
assert_eq '' "$(cp_skew_report '' 0.13.0 '')"  'no cprof on PATH is silent'
assert_eq '' "$(cp_skew_report 0.13.0 '' /bin/cprof)" 'no plugin installed is silent'

out="$(cp_skew_report 'weird output' 0.13.0 /bin/cprof)"
case "$out" in
  *'could not read'*'/bin/cprof'*) r=yes ;;
  *) r="no: $out" ;;
esac
assert_eq 'yes' "$r" 'an unreadable CLI version says so, naming the path'

# A version string is data: it must not carry control bytes into the report.
out="$(cp_skew_report "0.9.0${ESC}[31m" 0.13.0 /bin/cprof)"
assert_eq '' "$(printf '%s' "$out" | LC_ALL=C tr -d '\040-\176\n')" \
  'no control byte survives a hostile version string'
assert_eq '1' "$(printf '%s' "$out" | grep -c .)" 'and it still reports one line'

# ------------------------------------------------- cp_skew_problems, resolved
mk_path_cprof() {   # $1 = what `cprof version` prints; '' = no binary at all
  rm -f "$CP_T_TMP/bin/cprof"
  [ -n "${1:-}" ] || return 0
  printf '#!/usr/bin/env bash\nprintf "%%s\\\\n" %s\n' "$(printf '%q' "$1")" \
    > "$CP_T_TMP/bin/cprof"
  chmod +x "$CP_T_TMP/bin/cprof"
}
mk_plugin() {       # $@ = versions to install in the plugin cache
  rm -rf "$HOME/.claude/plugins/cache"
  for v in "$@"; do
    mkdir -p "$HOME/.claude/plugins/cache/dcotelo/cprof/$v"
    printf '{"name":"cprof","version":"%s"}\n' "$v" \
      > "$HOME/.claude/plugins/cache/dcotelo/cprof/$v/plugin.json"
  done
}
PATH="$CP_T_TMP/bin:$PATH"

mk_path_cprof 'cprof 0.9.0'; mk_plugin 0.13.0
out="$(cp_skew_problems)"
case "$out" in
  *'0.9.0'*'0.13.0'*) r=yes ;;
  *) r="no: $out" ;;
esac
assert_eq 'yes' "$r" 'probe finds a stale PATH CLI against a newer plugin'

mk_plugin 0.9.0 0.11.0 0.13.0
out="$(cp_skew_problems)"
case "$out" in
  *'0.13.0'*) r=yes ;;
  *) r="no: $out" ;;
esac
assert_eq 'yes' "$r" 'the newest installed plugin wins, not the last globbed'

mk_path_cprof 'cprof 0.13.0'; mk_plugin 0.13.0
assert_eq '' "$(cp_skew_problems)" 'matching versions report nothing'

mk_plugin
assert_eq '' "$(cp_skew_problems)" 'a brew-only install reports nothing'

mk_plugin 0.13.0
assert_eq '' "$(CP_CPROF_BIN='' cp_skew_problems)" \
  'a plugin-only install reports nothing'

mk_path_cprof 'cprof 0.9.0'; mk_plugin 0.13.0
printf 'not json\n' > "$HOME/.claude/plugins/cache/dcotelo/cprof/0.13.0/plugin.json"
assert_eq '' "$(cp_skew_problems)" 'an unparseable plugin.json advises nothing'

mk_path_cprof 'cprof (dev build)'; mk_plugin 0.13.0
out="$(cp_skew_problems)"
case "$out" in
  *'could not read'*) r=yes ;;
  *) r="no: $out" ;;
esac
assert_eq 'yes' "$r" 'a CLI with no parseable version is reported, not ignored'

# ------------------------------------------------------ cp_sl_wiring_problems
SETTINGS="$CP_T_TMP/settings.json"
rm -f "$SETTINGS"
assert_eq '' "$(cp_sl_wiring_problems "$SETTINGS")" 'a missing settings file is silent'

printf '{"model":"opus"}\n' > "$SETTINGS"
assert_eq '' "$(cp_sl_wiring_problems "$SETTINGS")" 'no statusLine key is silent'

printf '{"statusLine":{"type":"command","command":"bash /nowhere/other.sh"}}\n' > "$SETTINGS"
assert_eq '1' "$(cp_sl_wiring_problems "$SETTINGS" | grep -c .)" \
  'a command naming neither cprof nor a readable script is reported'

# The documented setup: statusLine runs a wrapper of the user's own whose
# command line never says "cprof". Following it one level is what keeps the
# project's own recommendation from being reported as foreign.
WRAP="$HOME/.claude/statusline.sh"
mkdir -p "$HOME/.claude"
cat > "$WRAP" <<'SL'
#!/usr/bin/env bash
seg=$({ ls -1 "$HOME"/.claude/plugins/cache/*/cprof/*/statusline/segment.sh ; } 2>/dev/null | sort -V | tail -1)
[ -r "$seg" ] && bash "$seg" --full
exit 0
SL
jq -n --arg c 'bash "$HOME/.claude/statusline.sh"' \
  '{statusLine:{type:"command",command:$c}}' > "$SETTINGS"
assert_eq '' "$(cp_sl_wiring_problems "$SETTINGS")" \
  'the documented wrapper script is accepted through its contents'

jq -n --arg c 'bash ~/.claude/statusline.sh' \
  '{statusLine:{type:"command",command:$c}}' > "$SETTINGS"
assert_eq '' "$(cp_sl_wiring_problems "$SETTINGS")" \
  'and the same wrapper written with a tilde'

printf '#!/usr/bin/env bash\nprintf "something else\\n"\n' > "$WRAP"
assert_eq '1' "$(cp_sl_wiring_problems "$SETTINGS" | grep -c .)" \
  'a wrapper that mentions cprof nowhere is still reported'
rm -f "$WRAP"

printf '{"statusLine":{"type":"command","command":"cprof statusline --stdin"}}\n' > "$SETTINGS"
assert_eq '' "$(cp_sl_wiring_problems "$SETTINGS")" 'the documented direct command is accepted'

printf '{"statusLine":"whatever"}\n' > "$SETTINGS"
assert_eq '1' "$(cp_sl_wiring_problems "$SETTINGS" | grep -c .)" \
  'a malformed statusLine is reported once'

# The configured command is data — a JSON string can hold anything — so the
# report names the file and never echoes the command back.
jq -n --arg c "run${ESC}[2K me" '{statusLine:{type:"command",command:$c}}' > "$SETTINGS"
out="$(cp_sl_wiring_problems "$SETTINGS")"
assert_eq '' "$(printf '%s' "$out" | LC_ALL=C tr -d '\040-\176\n')" \
  'no control byte from the configured command reaches the report'
assert_eq '1' "$(printf '%s' "$out" | grep -c .)" 'and the report stays one line'
case "$out" in
  *'run'*) r='echoed the command' ;;
  *) r='named the file only' ;;
esac
assert_eq 'named the file only' "$r" 'the report does not quote the command back'

# -------------------------------------------------------- doctor integration
mkdir -p "$CP_T_TMP/state/usage"
cp_t_write_config <<JSON
{"default":"work","profiles":[{"name":"work","native":true}],"rules":[],"repos":{}}
JSON
cat > "$CP_CLAUDE_BIN" <<'STUB'
#!/usr/bin/env bash
printf '{"loggedIn":true,"account":{"email":"you@example.com"}}\n'
STUB
chmod +x "$CP_CLAUDE_BIN"
mkdir -p "$HOME/.claude"

mk_path_cprof 'cprof 0.9.0'; mk_plugin 0.13.0
out="$("$CLI" doctor 2>&1)"; rc=$?
case "$out" in
  *'0.9.0'*'0.13.0'*) r=yes ;;
  *) r="no: $out" ;;
esac
assert_eq 'yes' "$r" 'doctor surfaces version skew'
assert_eq '1' "$rc" 'and fails, because a stale CLI is actionable'

# A version it could not read is a diagnostic: reported, but not a failure,
# or a dev build would fail doctor forever.
mk_path_cprof 'cprof (dev build)'; mk_plugin 0.13.0
out="$("$CLI" doctor 2>&1)"; rc=$?
case "$out" in
  *'could not read'*) r=yes ;;
  *) r="no: $out" ;;
esac
assert_eq 'yes' "$r" 'doctor reports a CLI whose version it cannot read'
assert_eq '0' "$rc" 'and does not fail for it'

# A stale plugin is the mirror of a stale CLI, and just as actionable.
mk_path_cprof 'cprof 0.13.0'; mk_plugin 0.12.0
out="$("$CLI" doctor 2>&1)"; rc=$?
case "$out" in
  *'cprof update'*) r=yes ;;
  *) r="no: $out" ;;
esac
assert_eq 'yes' "$r" 'doctor surfaces a plugin older than the CLI'
assert_eq '1' "$rc" 'and fails for it too'

mk_path_cprof 'cprof 0.13.0'; mk_plugin 0.13.0
printf '{"statusLine":{"type":"command","command":"bash /somewhere/else.sh"}}\n' \
  > "$HOME/.claude/settings.json"
out="$("$CLI" doctor 2>&1)"; rc=$?
case "$out" in
  *statusLine*) r=yes ;;
  *) r="no: $out" ;;
esac
assert_eq 'yes' "$r" 'doctor reports a statusLine pointing away from cprof'
assert_eq '0' "$rc" 'but does not fail: another statusline is a choice'

rm -f "$HOME/.claude/settings.json"
out="$("$CLI" doctor 2>&1)"; rc=$?
assert_eq '0' "$rc" 'a clean setup still exits zero'
case "$out" in
  *statusLine*|*'0.9.0'*) r="noisy: $out" ;;
  *) r=quiet ;;
esac
assert_eq 'quiet' "$r" 'and says nothing about either hint'

cp_t_summary
