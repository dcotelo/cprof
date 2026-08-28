#!/usr/bin/env bash
# Installs the cprof CLI without Homebrew:
#
#   curl -fsSLO https://raw.githubusercontent.com/dcotelo/cprof/main/install.sh && less install.sh
#   bash install.sh   # after review
#
# Mirrors what the Homebrew formula does: the release tarball's scripts,
# statusline, hooks and commands directories go to ~/.local/share/cprof, and
# ~/.local/bin/cprof is a symlink into it — scripts/cprof follows symlinks to
# find its lib directory, which is what makes the link work. Re-running
# installs the latest release over the previous one; uninstalling is removing
# those two paths.
#
# Environment:
#   CPROF_VERSION          install a specific tag, e.g. cprof--v0.8.0
#   CPROF_INSTALL_PREFIX   somewhere other than ~/.local (the tests use this)
#   CPROF_INSTALL_TARBALL  a local tarball instead of a download (tests again)
set -eu

CP_REPO='dcotelo/cprof'
CP_PREFIX="${CPROF_INSTALL_PREFIX:-$HOME/.local}"
CP_SHARE="$CP_PREFIX/share/cprof"
CP_BIN="$CP_PREFIX/bin"

cp_fail() { printf 'cprof install: %s\n' "$*" >&2; exit 1; }

# The CLI itself is macOS-only — credentials live in the macOS keychain — so
# refuse early rather than install something that cannot work.
[ "$(uname -s)" = Darwin ] || cp_fail 'cprof supports macOS only'
command -v curl >/dev/null 2>&1 || cp_fail 'curl is required'
command -v tar  >/dev/null 2>&1 || cp_fail 'tar is required'
# jq is a runtime dependency, not an install-time one, but a cprof that cannot
# read its config degrades to stock Claude Code on every launch — better to
# stop here than to install something silently inert.
# shellcheck disable=SC2016 # the backticks are display, not expansion
command -v jq >/dev/null 2>&1 \
  || cp_fail 'jq is required — `brew install jq`, or see https://jqlang.org/download/'

cp_tag="${CPROF_VERSION:-}"
cp_tarball="${CPROF_INSTALL_TARBALL:-}"
if [ -z "$cp_tag" ] && [ -z "$cp_tarball" ]; then
  cp_tag="$(curl -fsSL "https://api.github.com/repos/$CP_REPO/releases/latest" \
    | jq -r '.tag_name // empty')" || cp_fail 'could not reach the GitHub API'
  [ -n "$cp_tag" ] || cp_fail 'could not resolve the latest release'
fi

cp_tmp="$(mktemp -d "${TMPDIR:-/tmp}/cprof-install.XXXXXX")"
trap 'rm -rf "$cp_tmp"' EXIT

if [ -z "$cp_tarball" ]; then
  cp_tarball="$cp_tmp/src.tar.gz"
  curl -fsSL -o "$cp_tarball" \
    "https://github.com/$CP_REPO/archive/refs/tags/$cp_tag.tar.gz" \
    || cp_fail "download failed for $cp_tag"
fi

mkdir "$cp_tmp/src"
tar -xzf "$cp_tarball" -C "$cp_tmp/src" --strip-components 1 \
  || cp_fail 'could not extract the tarball'
[ -f "$cp_tmp/src/scripts/cprof" ] || cp_fail 'tarball does not look like cprof'

# Replace the previous install wholesale so a lib file removed upstream does
# not linger. rm -rf on a variable earns a shape check first, same as the
# tests' teardown.
case "$CP_SHARE" in
  */share/cprof) rm -rf "$CP_SHARE" ;;
  *) cp_fail "refusing to replace suspicious install dir: $CP_SHARE" ;;
esac
mkdir -p "$CP_SHARE" "$CP_BIN"
for cp_dir in scripts statusline hooks commands; do
  cp -R "$cp_tmp/src/$cp_dir" "$CP_SHARE/$cp_dir"
done
ln -sf "$CP_SHARE/scripts/cprof" "$CP_BIN/cprof"

# Verify through the symlink, not the copied file: the failure this catches is
# the CLI not finding lib/ beside its resolved self, which only the link path
# exercises.
cp_got="$("$CP_BIN/cprof" version)" || cp_fail 'the installed cprof does not run'
if [ -n "$cp_tag" ]; then
  cp_want="cprof ${cp_tag#cprof--v}"
  [ "$cp_got" = "$cp_want" ] \
    || cp_fail "version mismatch: installed [$cp_got], expected [$cp_want]"
fi

printf 'installed %s to %s\n' "$cp_got" "$CP_BIN/cprof"

case ":$PATH:" in
  *":$CP_BIN:"*) ;;
  *)
    printf '\n%s is not on your PATH. Add it first:\n\n' "$CP_BIN"
    # shellcheck disable=SC2016 # $PATH must reach the user unexpanded
    printf '  export PATH="%s:$PATH"\n' "$CP_BIN"
    ;;
esac

cat <<EOF

Route \`claude\` through cprof by adding this to your shell config:

  claude() { eval "\$(cprof env)"; command claude "\$@"; }

Then adopt the account you already use and add a second:

  cprof add work --native
  cprof add personal
  cprof login personal

This installs the CLI only. The Claude Code plugin adds the SessionStart
warning, the /profile command, and the statusline badge:

  claude plugin marketplace add dcotelo/cprof
  claude plugin install cprof@dcotelo
EOF
