#!/usr/bin/env bash
set -u
# Guards the marketplace contract. A release is a git tag plus whatever these
# files claim, so a disagreement between them ships broken metadata that only
# surfaces when someone tries to install.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PLUGIN="$ROOT/.claude-plugin/plugin.json"
MARKET="$ROOT/.claude-plugin/marketplace.json"

pj() { jq -r "$1" "$PLUGIN"; }
mj() { jq -r "$1" "$MARKET"; }

# --- both manifests parse ----------------------------------------------------
assert_ok jq -e . "$PLUGIN"
assert_ok jq -e . "$MARKET"

# --- fields a marketplace listing renders ------------------------------------
for field in name version description author homepage repository license keywords; do
  assert_eq 'true' "$(pj "has(\"$field\")")" "plugin.json has $field"
done
assert_eq 'claudeprofile' "$(pj .name)"     'plugin name is claudeprofile'
assert_eq 'MIT'           "$(pj .license)"  'license matches LICENSE'
assert_eq 'true'          "$(pj '.keywords | length > 0')" 'keywords are not empty'

version="$(pj .version)"
case "$version" in
  [0-9]*.[0-9]*.[0-9]*) assert_eq ok ok 'version is semver' ;;
  *) assert_eq 'x.y.z' "$version" 'version is semver' ;;
esac

# --- the two manifests agree --------------------------------------------------
assert_eq "$version" "$(mj .metadata.version)"      'marketplace metadata version matches'
assert_eq "$version" "$(mj '.plugins[0].version')"  'marketplace plugin entry version matches'
assert_eq "$(pj .name)" "$(mj '.plugins[0].name')"  'marketplace names the same plugin'
assert_eq './'    "$(mj '.plugins[0].source')"      'plugin source is the repository root'

# --- referenced files exist --------------------------------------------------
hooks="$(pj '.hooks // empty')"
if [ -n "$hooks" ]; then
  assert_ok test -f "$ROOT/${hooks#./}"
fi
for cmd in $(pj '.commands[]? // empty'); do
  assert_ok test -f "$ROOT/${cmd#./}"
done

# --- the release tag reads its notes from here -------------------------------
assert_ok test -f "$ROOT/CHANGELOG.md"
assert_eq "$version" "$(sed -n 's/^## \[\([0-9][^]]*\)\].*/\1/p' "$ROOT/CHANGELOG.md" | head -1)" \
  'CHANGELOG names this version first'

# --- anything a session executes stays executable ----------------------------
assert_ok test -x "$ROOT/scripts/claudeprofile"
assert_ok test -x "$ROOT/statusline/segment.sh"
assert_ok test -x "$ROOT/hooks/session-start.sh"

cp_t_summary
