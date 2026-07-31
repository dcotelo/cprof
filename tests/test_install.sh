#!/usr/bin/env bash
# install.sh against a tarball built from the working tree — no network, no
# touching the real ~/.local. CPROF_INSTALL_PREFIX and CPROF_INSTALL_TARBALL
# exist for exactly this.
set -u
cd "$(dirname "$0")" || exit 1
. ./lib.sh

REPO_ROOT="$(cd .. && pwd -P)"
INSTALLER="$REPO_ROOT/install.sh"

cp_t_setup
PREFIX="$CP_T_TMP/prefix"

# A tarball shaped like GitHub's: one top-level directory the installer strips.
mkdir -p "$CP_T_TMP/pkg/cprof-src"
for d in scripts statusline hooks commands; do
  cp -R "$REPO_ROOT/$d" "$CP_T_TMP/pkg/cprof-src/$d"
done
tar -czf "$CP_T_TMP/src.tar.gz" -C "$CP_T_TMP/pkg" cprof-src

# --- install from a local tarball ---
out="$(CPROF_INSTALL_TARBALL="$CP_T_TMP/src.tar.gz" \
       CPROF_INSTALL_PREFIX="$PREFIX" bash "$INSTALLER" 2>&1)"
assert_eq 0 $? 'installer exits zero'

assert_ok test -L "$PREFIX/bin/cprof"
assert_ok test -f "$PREFIX/share/cprof/scripts/lib/config.sh"

manifest_version="$(jq -r .version "$REPO_ROOT/.claude-plugin/plugin.json")"
assert_eq "cprof $manifest_version" "$("$PREFIX/bin/cprof" version)" \
  'installed cprof runs through the symlink and finds lib/'

case "$out" in
  *'claude() { eval'*) assert_eq ok ok 'caveats include the shell function' ;;
  *) assert_eq "caveats include the shell function" "missing" 'caveats include the shell function' ;;
esac

# The sandbox prefix is never on PATH, so the warning must appear.
case "$out" in
  *'is not on your PATH'*) assert_eq ok ok 'warns when bin dir is not on PATH' ;;
  *) assert_eq "PATH warning" "missing" 'warns when bin dir is not on PATH' ;;
esac

# --- re-run replaces the previous install ---
touch "$PREFIX/share/cprof/scripts/lib/stale.sh"
CPROF_INSTALL_TARBALL="$CP_T_TMP/src.tar.gz" \
  CPROF_INSTALL_PREFIX="$PREFIX" bash "$INSTALLER" >/dev/null 2>&1
assert_eq 0 $? 'installer is idempotent'
assert_fail test -e "$PREFIX/share/cprof/scripts/lib/stale.sh"

# --- version pin that disagrees with the tarball fails loudly ---
assert_fail env CPROF_INSTALL_TARBALL="$CP_T_TMP/src.tar.gz" \
  CPROF_INSTALL_PREFIX="$PREFIX" CPROF_VERSION='cprof--v0.0.1' \
  bash "$INSTALLER"

# --- a tarball that is not cprof fails before touching the prefix ---
mkdir -p "$CP_T_TMP/junk/not-cprof"
touch "$CP_T_TMP/junk/not-cprof/README"
tar -czf "$CP_T_TMP/junk.tar.gz" -C "$CP_T_TMP/junk" not-cprof
assert_fail env CPROF_INSTALL_TARBALL="$CP_T_TMP/junk.tar.gz" \
  CPROF_INSTALL_PREFIX="$CP_T_TMP/prefix2" bash "$INSTALLER"
assert_fail test -e "$CP_T_TMP/prefix2/bin/cprof"

cp_t_teardown
cp_t_summary
