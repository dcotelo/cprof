#!/usr/bin/env bash
set -u
# Guards the release automation. The bump workflow decides, unattended, what
# version a merge publishes and what the release notes say — so the decision
# has to be exercised here rather than discovered on a tag nobody can unpush.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cp_t_setup
trap cp_t_teardown EXIT
SCRIPT="$(cd "$(dirname "$0")/.." && pwd -P)/.github/scripts/release-version.sh"

# next <current-version>, commit subjects on stdin -> the version to release,
# or nothing when no commit warrants one.
next() { printf '%s\n' "$2" | bash "$SCRIPT" next "$1" 2>/dev/null; }

# --- what the commit types mean ----------------------------------------------
assert_eq '0.9.0' "$(next 0.8.0 'feat: curl installer')"        'feat bumps the minor'
assert_eq '0.8.1' "$(next 0.8.0 'fix: symlink lookup')"         'fix bumps the patch'
assert_eq '0.8.1' "$(next 0.8.0 'perf: fewer jq calls')"        'perf bumps the patch'
assert_eq '1.0.0' "$(next 0.8.0 'feat!: rename the CLI')"       'a bang bumps the major'
assert_eq '1.0.0' "$(next 0.8.0 'fix(env)!: stop exporting')"   'a bang on a scoped fix still majors'
assert_eq '0.9.0' "$(next 0.8.0 'feat(pin): confirm on stderr')" 'a scope does not hide the type'

# --- what does not warrant a release -----------------------------------------
assert_eq '' "$(next 0.8.0 'docs(readme): fix a typo')"  'docs alone releases nothing'
assert_eq '' "$(next 0.8.0 'chore: bump linter')"        'chore alone releases nothing'
assert_eq '' "$(next 0.8.0 'test: cover the pin path')"  'test alone releases nothing'
assert_eq '' "$(next 0.8.0 'ci: pin the actions')"       'ci alone releases nothing'
assert_eq '' "$(next 0.8.0 'refactor: split resolve')"   'refactor alone releases nothing'
assert_eq '' "$(next 0.8.0 '')"                          'no commits release nothing'
assert_eq '' "$(next 0.8.0 'merged main into the branch')" 'a non-conventional subject is ignored'

# Conventional Commits wants `: ` and something after it. Accepting less lets a
# typo publish: `fix:broken` would ship a patch, and `fix:` an empty note.
assert_eq '' "$(next 0.8.0 'fix:broken')"  'a missing space after the colon is not a release'
assert_eq '' "$(next 0.8.0 'fix:')"        'a bare type and colon is not a release'
assert_eq '' "$(next 0.8.0 'fix: ')"       'an empty description is not a release'
assert_eq '' "$(next 0.8.0 'feat!:no space')" 'a bang does not excuse the missing space'

# The workflow re-runs on every push to the branch, and its own bump commit is
# on the branch by then. Counting it would ratchet the version on each push.
assert_eq '' "$(next 0.9.0 'chore(release): 0.9.0')" 'its own bump commit does not warrant another'

# --- the strongest commit wins -----------------------------------------------
assert_eq '0.9.0' "$(next 0.8.0 'docs: tidy
feat: add a flag')" 'a feat outranks a docs'
assert_eq '0.9.0' "$(next 0.8.0 'fix: a bug
feat: a flag')" 'a feat outranks a fix'
assert_eq '1.0.0' "$(next 0.8.0 'feat: a flag
feat!: a breaking one')" 'a bang outranks everything'

# --- version arithmetic zeroes the lower parts -------------------------------
assert_eq '0.9.0' "$(next 0.8.7 'feat: x')" 'a minor bump zeroes the patch'
assert_eq '2.0.0' "$(next 1.4.2 'feat!: x')" 'a major bump zeroes minor and patch'

# --- apply ---------------------------------------------------------------------
# A fixture repo, because apply rewrites files in place and the real ones are
# the release it would be editing.
fixture() {
  rm -rf "$CP_T_TMP/repo"
  mkdir -p "$CP_T_TMP/repo/.claude-plugin" "$CP_T_TMP/repo/scripts"
  printf '{"name":"cprof","version":"0.8.0"}\n' > "$CP_T_TMP/repo/.claude-plugin/plugin.json"
  printf '{"metadata":{"version":"0.8.0"},"plugins":[{"name":"cprof","version":"0.8.0"}]}\n' \
    > "$CP_T_TMP/repo/.claude-plugin/marketplace.json"
  printf "#!/usr/bin/env bash\nset -u\n\nCP_VERSION='0.8.0'\nCP_MARKETPLACE='dcotelo'\n" \
    > "$CP_T_TMP/repo/scripts/cprof"
  { printf '# Changelog\n\n'
    printf 'Notable changes per release.\n\n'
    printf '## [Unreleased]\n\n'
    printf '%s\n' "$1"
    printf '## [0.8.0]\n\n### Added\n\n- Something older.\n'
  } > "$CP_T_TMP/repo/CHANGELOG.md"
}
apply() { ( cd "$CP_T_TMP/repo" && printf '%s\n' "$2" | bash "$SCRIPT" apply "$1" ) >/dev/null 2>&1; }
changelog() { cat "$CP_T_TMP/repo/CHANGELOG.md"; }

fixture ''
apply 0.9.0 'feat: curl installer'
assert_eq '0.9.0' "$(jq -r .version "$CP_T_TMP/repo/.claude-plugin/plugin.json")" \
  'apply writes plugin.json'
assert_eq '0.9.0' "$(jq -r .metadata.version "$CP_T_TMP/repo/.claude-plugin/marketplace.json")" \
  'apply writes the marketplace metadata'
assert_eq '0.9.0' "$(jq -r '.plugins[0].version' "$CP_T_TMP/repo/.claude-plugin/marketplace.json")" \
  'apply writes the marketplace plugin entry'
assert_eq "CP_VERSION='0.9.0'" "$(grep '^CP_VERSION=' "$CP_T_TMP/repo/scripts/cprof")" \
  'apply writes CP_VERSION, the fourth place the version lives'

# The release workflow reads its notes from the section matching the tag, so a
# missing section publishes an empty release.
assert_eq '1' "$(changelog | grep -c '^## \[0.9.0\]')" 'apply opens a section for the version'
assert_eq '1' "$(changelog | grep -c '^## \[Unreleased\]')" 'apply keeps the Unreleased heading'
assert_eq '1' "$(changelog | grep -c 'curl installer')" 'a generated section carries the subject'
assert_eq 'Added' "$(changelog | sed -n '/^## \[0.9.0\]/,/^## \[0/p' | grep '^### ' | head -1 | sed 's/^### //')" \
  'a feat files under Added'

# A breaking change of any type still has to appear in the notes. release.yml
# aborts on an empty section, so a major release whose only subject fell through
# the grouping would fail at publish time.
fixture ''
apply 1.0.0 'docs!: drop the legacy setup guide'
assert_eq '1.0.0' "$(next 0.8.0 'docs!: drop the legacy setup guide')" \
  'a breaking docs commit is still a major'
assert_eq '1' "$(changelog | grep -c 'drop the legacy setup guide')" \
  'a breaking commit outside the usual types still gets a note'
assert_eq 'Changed' "$(changelog | sed -n '/^## \[1.0.0\]/,/^## \[0/p' | grep '^### ' | head -1 | sed 's/^### //')" \
  'an ungrouped breaking commit files under Changed'

# Prose already written by hand beats anything generated from subject lines.
fixture 'Hand-written prose that explains why.
'
apply 0.9.0 'feat: curl installer'
assert_eq '1' "$(changelog | grep -c 'Hand-written prose')" 'apply promotes existing Unreleased prose'
assert_eq '0' "$(changelog | grep -c 'curl installer')" 'promoted prose is not padded with subjects'
assert_eq '1' "$(changelog | sed -n '/^## \[0.9.0\]/,/^## \[0.8/p' | grep -c 'Hand-written prose')" \
  'the promoted prose lands under the new version'
assert_eq '0' "$(changelog | sed -n '/^## \[Unreleased\]/,/^## \[0.9/p' | grep -c 'Hand-written prose')" \
  'and is gone from Unreleased'

# Re-running on the same branch must converge, not stack sections.
fixture ''
apply 0.9.0 'feat: curl installer'
apply 0.9.0 'feat: curl installer'
assert_eq '1' "$(changelog | grep -c '^## \[0.9.0\]')" 'apply twice leaves one section'
assert_eq '0.9.0' "$(jq -r .version "$CP_T_TMP/repo/.claude-plugin/plugin.json")" \
  'apply twice leaves the version alone'

cp_t_summary
