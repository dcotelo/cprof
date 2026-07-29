#!/usr/bin/env bash
set -u
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
CLI="$(cd "$(dirname "$0")/.." && pwd -P)/scripts/cprof"

# A stock config directory with customisations in it, which is what a native
# profile is: plugins, skills, hooks and settings all live here, not in the
# keychain, so a profile pointed elsewhere starts with none of them.
mkdir -p "$HOME/.claude/plugins/cache" "$HOME/.claude/skills/demo" "$HOME/.claude/hooks"
printf '{"theme":"dark"}\n'  > "$HOME/.claude/settings.json"
printf '# memory\n'          > "$HOME/.claude/CLAUDE.md"
printf 'echo hi\n'           > "$HOME/.claude/hooks/demo.sh"
# things that identify an account or record its history: never shared
printf '{"tok":1}\n'         > "$HOME/.claude/.credentials.json"
printf '{"userID":"abc"}\n'  > "$HOME/.claude/.claude.json"
printf 'past\n'              > "$HOME/.claude/history.jsonl"
mkdir -p "$HOME/.claude/projects/one"

P="$HOME/.claude-profiles/personal"
cp_t_write_config <<JSON
{"default":"work",
 "profiles":[{"name":"work","native":true},{"name":"personal","dir":"$P"}],
 "rules":[],"repos":{}}
JSON

# --- what share links --------------------------------------------------------
assert_ok "$CLI" share personal
for asset in settings.json CLAUDE.md plugins skills hooks; do
  assert_ok test -L "$P/$asset"
  assert_eq "$HOME/.claude/$asset" "$(readlink "$P/$asset")" "$asset points at the stock directory"
done

# a shared plugin directory means installing once serves every profile
mkdir -p "$HOME/.claude/plugins/cache/later"
assert_ok test -d "$P/plugins/cache/later"

# --- what share must never link ----------------------------------------------
for private in .credentials.json .claude.json history.jsonl projects; do
  if [ -e "$P/$private" ]; then
    assert_eq 'absent' "present: $private" "$private stays out of the profile"
  else
    assert_eq ok ok "$private stays out of the profile"
  fi
done

# --- idempotent --------------------------------------------------------------
assert_ok "$CLI" share personal
assert_eq "$HOME/.claude/skills" "$(readlink "$P/skills")" 'a second share leaves the link alone'

out="$("$CLI" share personal 2>/dev/null)"
case "$out" in *kept*) assert_eq ok ok 'repeat run reports the links as kept' ;;
                *) assert_eq 'kept' "$out" 'repeat run reports the links as kept' ;; esac

# --- existing content is moved aside, never destroyed ------------------------
rm "$P/settings.json"
printf '{"theme":"light"}\n' > "$P/settings.json"
assert_ok "$CLI" share personal
assert_ok test -L "$P/settings.json"
for candidate in "$P"/settings.json.moved-*; do
  [ -e "$candidate" ] && moved="$(basename "$candidate")"
done
assert_eq '{"theme":"light"}' "$(cat "$P/$moved")" 'the replaced file is kept, not deleted'

# --- guards ------------------------------------------------------------------
assert_fail "$CLI" share work       # native profile is the source
assert_fail "$CLI" share nope       # unknown profile
assert_fail "$CLI" share            # missing argument

# --- unshare leaves real content in place ------------------------------------
assert_ok "$CLI" unshare personal
for asset in settings.json plugins skills; do
  if [ -L "$P/$asset" ]; then
    assert_eq 'unlinked' "still linked: $asset" "unshare removed the $asset link"
  else
    assert_eq ok ok "unshare removed the $asset link"
  fi
done
# the source is untouched: unshare drops links, it does not delete what they point to
assert_ok test -f "$HOME/.claude/settings.json"
assert_ok test -d "$HOME/.claude/skills/demo"
# a file that was moved aside stays where it is
assert_ok test -f "$P/$moved"

# --- add wires a new profile up by default -----------------------------------
assert_ok "$CLI" add fresh
assert_ok test -L "$HOME/.claude-profiles/fresh/skills"

assert_ok "$CLI" add walled --isolated
if [ -L "$HOME/.claude-profiles/walled/skills" ]; then
  assert_eq 'no link' 'linked' '--isolated leaves a profile unshared'
else
  assert_eq ok ok '--isolated leaves a profile unshared'
fi

cp_t_summary
