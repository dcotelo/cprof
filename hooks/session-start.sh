#!/usr/bin/env bash
# SessionStart: warn when the live session's account no longer matches what this
# directory resolves to. Never fails a session.
set -u

root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
cli="$root/scripts/cprof"
[ -x "$cli" ] || exit 0

# A shared profile whose links into ~/.claude have broken runs without what
# ~/.claude has gained since, hooks and permission rules included. Only the
# session's own profile is checked, by link state alone (a few stat calls, no
# jq), and the hook only warns: replacing files in a profile is the user's
# call, made with `cprof share`, which keeps what it replaces.
if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ -r "$root/scripts/lib/share.sh" ]; then
  # shellcheck source=../scripts/lib/share.sh
  . "$root/scripts/lib/share.sh"
  drift="$(cp_share_drift_summary "$CLAUDE_CONFIG_DIR" 2>/dev/null)"
  if [ -n "$drift" ]; then
    name="$(NO_COLOR=1 "$cli" status 2>/dev/null | head -1)"
    case "$name" in '' | unknown) name='<name>' ;; esac
    printf 'cprof: profile %s is not following ~/.claude: %s. Hooks and permission rules added there do not apply in this session. Run: cprof share %s\n' \
      "$name" "$drift" "$name"
  fi
fi

want="$("$cli" env 2>/dev/null)"
have="${CLAUDE_CONFIG_DIR:+export CLAUDE_CONFIG_DIR=$(printf "'%s'" "$CLAUDE_CONFIG_DIR")}"
[ -n "$have" ] || have='unset CLAUDE_CONFIG_DIR'

if [ "$want" = "$have" ]; then
  exit 0
fi

detail="$("$cli" which 2>/dev/null | head -1)"
printf 'cprof: this session does not match this directory. Expected: %s. Relaunch claude here to switch.\n' \
  "${detail:-unknown}"
exit 0
