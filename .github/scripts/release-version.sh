#!/usr/bin/env bash
set -eu
# Decides what a merge publishes, and writes it down.
#
#   release-version.sh next <current-version>   # subjects on stdin -> version
#   release-version.sh apply <version>          # subjects on stdin -> files
#
# Split in two so the decision can be tested without touching a file, and so a
# workflow can ask "is there anything to release?" before it writes anything.
# Conventional Commits decides: feat is a minor, fix and perf are patches, a `!`
# before the colon is a major, and everything else — docs, chore, test, ci,
# refactor — publishes nothing at all.

usage() {
  printf 'usage: release-version.sh next <current-version>\n' >&2
  printf '       release-version.sh apply <version>\n' >&2
  exit 2
}

# cp_rank <subject> -> 3 major, 2 minor, 1 patch, 0 nothing.
# The type is read up to the first colon, so a scope and a bang both survive it.
#
# `: ` and a description are both required, because the near-misses are the
# dangerous ones: `fix:broken` would otherwise publish a patch off a typo, and
# `fix:` a release whose only note is an empty bullet.
cp_rank() {
  local subject="$1" head type
  case "$subject" in
    *': '*) ;;
    *) printf '0\n'; return 0 ;;
  esac
  [ -n "${subject#*: }" ] || { printf '0\n'; return 0; }
  head="${subject%%:*}"
  case "$head" in
    *' '*) printf '0\n'; return 0 ;;   # prose, not a conventional subject
    *'!')  printf '3\n'; return 0 ;;
  esac
  type="${head%%(*}"
  case "$type" in
    feat)      printf '2\n' ;;
    fix|perf)  printf '1\n' ;;
    *)         printf '0\n' ;;
  esac
}

# cp_bucket <subject> -> the section heading it belongs under, or nothing when
# the subject warrants no release. Everything that does warrant one lands
# somewhere: a breaking change of an otherwise silent type (`docs!:`) still has
# to appear, since release.yml aborts on an empty section.
cp_bucket() {
  local subject="$1" head type
  [ "$(cp_rank "$subject")" -gt 0 ] || return 0
  head="${subject%%:*}"
  type="${head%%(*}"
  type="${type%!}"
  case "$type" in
    feat) printf 'Added\n' ;;
    fix)  printf 'Fixed\n' ;;
    *)    printf 'Changed\n' ;;
  esac
}

cp_next() {
  local current="$1" line rank best=0 major minor patch
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    rank="$(cp_rank "$line")"
    [ "$rank" -gt "$best" ] && best="$rank"
  done
  [ "$best" -gt 0 ] || return 0

  case "$current" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) printf 'not a version: %s\n' "$current" >&2; return 1 ;;
  esac
  major="${current%%.*}"
  patch="${current##*.}"
  minor="${current#*.}"; minor="${minor%%.*}"

  case "$best" in
    3) major=$((major + 1)); minor=0; patch=0 ;;
    2) minor=$((minor + 1)); patch=0 ;;
    1) patch=$((patch + 1)) ;;
  esac
  printf '%s.%s.%s\n' "$major" "$minor" "$patch"
}

# Strips `type(scope)!: ` so a generated note reads as a note, not as a log line.
cp_summary() { printf '%s\n' "${1#*: }"; }

# cp_generated <version> <subjects-file> -> a section body on stdout.
cp_generated() {
  local version="$1" file="$2" heading subject printed
  printf '## [%s]\n' "$version"
  for heading in Added Fixed Changed; do
    printed=0
    while IFS= read -r subject; do
      [ -n "$subject" ] || continue
      [ "$(cp_bucket "$subject")" = "$heading" ] || continue
      [ "$printed" -eq 1 ] || { printf '\n### %s\n\n' "$heading"; printed=1; }
      printf -- '- %s\n' "$(cp_summary "$subject")"
    done < "$file"
  done
}

# The Unreleased section is split out rather than rewritten in place: prose
# written by hand there is the release note, and beats anything generated.
cp_changelog_part() {
  awk -v part="$2" '
    /^## \[Unreleased\]/ { seen = 1; if (part == "head") print; next }
    seen && !rest && /^## \[/ { rest = 1 }
    part == "head" && !seen { print }
    part == "unreleased" && seen && !rest { print }
    part == "rest" && rest { print }
  ' "$1"
}

cp_apply_changelog() {
  local version="$1" subjects="$2" tmp body
  # Converging, not stacking: the workflow re-runs on every push to the branch.
  if grep -q "^## \[$version\]" CHANGELOG.md; then
    return 0
  fi
  body="$(cp_changelog_part CHANGELOG.md unreleased)"
  tmp="$(mktemp)"
  {
    cp_changelog_part CHANGELOG.md head
    printf '\n'
    if printf '%s' "$body" | grep -q '[^[:space:]]'; then
      printf '## [%s]\n' "$version"
      printf '%s\n' "$body" | sed -e '/./,$!d'
    else
      cp_generated "$version" "$subjects"
      printf '\n'
    fi
    cp_changelog_part CHANGELOG.md rest
  } > "$tmp"
  mv "$tmp" CHANGELOG.md
}

cp_apply() {
  local version="$1" subjects tmp
  subjects="$(mktemp)"
  cat > "$subjects"

  tmp="$(mktemp)"
  jq --arg v "$version" '.version = $v' .claude-plugin/plugin.json > "$tmp"
  mv "$tmp" .claude-plugin/plugin.json

  tmp="$(mktemp)"
  jq --arg v "$version" '.metadata.version = $v | .plugins[0].version = $v' \
    .claude-plugin/marketplace.json > "$tmp"
  mv "$tmp" .claude-plugin/marketplace.json

  # CP_VERSION is the fourth place the version lives, and the one a user reads
  # back with `cprof version`; test_cli.sh fails when it disagrees.
  tmp="$(mktemp)"
  sed "s/^CP_VERSION='.*'\$/CP_VERSION='$version'/" scripts/cprof > "$tmp"
  cat "$tmp" > scripts/cprof     # preserve the mode rather than mv over it
  rm -f "$tmp"

  cp_apply_changelog "$version" "$subjects"
  rm -f "$subjects"
  printf 'applied %s\n' "$version"
}

case "${1:-}" in
  next)  [ "$#" -eq 2 ] || usage; cp_next "$2" ;;
  apply) [ "$#" -eq 2 ] || usage; cp_apply "$2" ;;
  *)     usage ;;
esac
