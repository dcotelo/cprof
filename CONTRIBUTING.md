# Contributing to cprof

## Maintainers

- [@dcotelo](https://github.com/dcotelo) — sole maintainer; owns releases,
  reviews, and repository settings.

## Process

1. Open an issue first for anything beyond a small fix, so the approach is
   agreed before you write it.
2. Branch from `main`, keep the change focused, open a PR. CI (shellcheck,
   the test suite on macOS, manifest checks) must pass; `main` requires a PR
   with passing checks.
3. Bugs are reported through
   [GitHub Issues](https://github.com/dcotelo/cprof/issues); security issues go
   through [private vulnerability reporting](https://github.com/dcotelo/cprof/security/advisories/new)
   instead — see [SECURITY.md](SECURITY.md).

## Development

```bash
bash tests/run.sh                    # run the suite
shellcheck -x -P scripts -P tests scripts/cprof scripts/lib/*.sh hooks/*.sh \
  statusline/*.sh tests/*.sh .github/scripts/*.sh docs/demo/*.sh docs/demo/bin/* \
  docs/demo/statusline-bin/* docs/demo/usage-bin/* install.sh
claude plugin validate .             # check the manifests
```

CI runs all three on every pull request: shellcheck and the manifest checks on
Ubuntu, the suite on macOS, where `/bin/bash` is the 3.2 the code targets.

Targets bash 3.2 (macOS system bash). Its external dependencies are `jq`,
`curl` (for usage data) and `git` (for repository-root resolution and the
statusline's branch field); only `jq` is hard.

Tests sandbox `HOME`, the config path, the `claude` binary, and the `security`
binary. No test touches the real keychain or a real account.

The README GIFs are recorded with [VHS](https://github.com/charmbracelet/vhs)
from `docs/demo/*.tape`; `vhs docs/demo/demo.tape`, `vhs docs/demo/usage.tape`
and `vhs docs/demo/statusline.tape` regenerate them. The usage and statusline
ones run the real CLI against a throwaway `HOME` with stubbed `claude`, `curl`
and `date`, so what they show is the actual rendering, not canned text.

## What a contribution needs

- **A sign-off on every commit.** `git commit -s` adds
  `Signed-off-by: Your Name <you@example.com>`, which asserts the
  [Developer Certificate of Origin](https://developercertificate.org): that
  you wrote the change or otherwise have the right to submit it under this
  project's license. `format.signOff true` (below) does it for you; edits made
  in the GitHub web UI are required to carry it.
- **Tests.** Every behavior change carries an assertion in `tests/`. The suite
  is plain bash: see `tests/lib.sh` for `assert_eq` / `assert_ok` /
  `assert_fail`, and run it with `bash tests/run.sh`.
- **shellcheck clean.** CI pins shellcheck and runs
  `shellcheck -x` over every script; run it locally before pushing.
- **bash 3.2 compatibility.** The target shell is macOS system bash. No
  associative arrays, no `${var,,}`, nothing newer than 3.2.
- **Conventions.** User-facing messages go to stderr via `cp_warn`; stdout is
  reserved for shell-eval output (`cprof env`). Paths shown to users go through
  `cp_path_display`; stored paths stay absolute via `cp_path_normalize`.
- **[Conventional Commits](https://www.conventionalcommits.org) subjects.** These
  are load-bearing, not just tidy: CI reads them to decide whether merging your
  branch publishes a release, and at what version. `feat:` is a minor, `fix:`
  and `perf:` are patches, a `!` before the colon is a major, and `docs:`,
  `chore:`, `test:`, `ci:` and `refactor:` publish nothing. See
  [Releasing](#releasing).

## Error-handling convention

Scripts use `set -u` (with `set -eu` in the installer) rather than
`set -euo pipefail`. This is deliberate: the CLI's library functions return
status codes that callers check explicitly, and `set -e` semantics differ
subtly across the bash 3.2/5.x boundary this project straddles. Match the
existing style; do not add `set -e` to the CLI scripts in a drive-by.

## Recommended git configuration

Contributor-side settings the repository cannot enforce, so this is the
recommendation rather than a check. Set them globally once; each one closes a
class of mistake or attack that the platform-side controls do not reach.

```bash
git config --global transfer.fsckObjects true   # reject malformed or malicious objects on fetch/push
git config --global user.useConfigOnly true     # fail when identity is unset instead of guessing a wrong email
git config --global protocol.file.allow user    # limit file:// submodule tricks (CVE-2022-39253 class)
git config --global protocol.ext.allow never    # block the ext:: transport, a command-execution vector
git config --global commit.gpgsign true         # cryptographic commit provenance; SSH signing via gpg.format=ssh is fine
git config --global format.signOff true         # adds the Signed-off-by trailer automatically
git config --global pull.ff only                # no surprise merge commits; main requires linear history anyway
```

## Dependencies

Runtime, dev, and CI dependencies are chosen and tracked like this:

- **Runtime: `jq`, the only hard dependency.** It reads and validates the
  JSON config; bash 3.2 has no safe way to do that alone. Any `jq` 1.5 or
  newer works, so it is not version-pinned. Homebrew installs it through the
  formula; the curl installer refuses to run without it. Adding a runtime
  dependency is a design decision, not a convenience — open an issue first.
- **Runtime: `git`, softly.** Consulted in two places. Repository-root
  resolution has always asked it for the top level (`git rev-parse
  --show-toplevel`), and a repository pin is keyed on that answer; the
  statusline's branch field asks it for the branch and whether the tree is
  clean. Neither is a hard requirement, and the installer does not check for
  it, but the consequences differ. Without `git` the branch field is simply
  skipped while every other field renders — and repository-root resolution
  falls back to the working directory, so a pin made at a repository root
  stops matching from a subdirectory of it and whatever rule or default
  applies there resolves instead. Worth knowing before pinning a repository
  on a machine with no `git`.
- **Dev: `shellcheck`.** Pinned by version in `.github/workflows/ci.yml`
  (`SHELLCHECK_VERSION`), downloaded from its GitHub release rather than taken
  from the runner image, so local and CI findings agree. Bumped by hand,
  deliberately, in its own commit.
- **CI: `@anthropic-ai/claude-code`.** Installed from npm at a pinned version
  for `claude plugin validate` only; bumped by hand when the manifest format
  changes.
- **GitHub Actions.** Every third-party action is pinned to a full commit SHA
  with the version as a trailing comment. Bumps are reviewed like any other
  change.

## Releasing

Merging a release-worthy pull request is releasing. Open one as usual;
`release-bump.yml` reads the
[Conventional Commits](https://www.conventionalcommits.org) subjects on the
branch, works out whether they warrant a release, and if they do, commits the
version bump and a `CHANGELOG.md` section to the branch:

| Commit type on the branch | Effect |
|---|---|
| `feat!:`, or any type with `!` | major |
| `feat:` | minor |
| `fix:`, `perf:` | patch |
| `docs:`, `chore:`, `test:`, `ci:`, `refactor:` | no release |

The bump lands in the pull request, so it is reviewable and editable before it
ships — **rewrite the generated CHANGELOG entries into prose before merging**,
since generated notes read like a commit log. Anything already written by hand
under `## [Unreleased]` is promoted as-is instead of being generated over.

Merging then puts the manifest change on `main`, where `tag.yml` tags
`cprof--v<version>` and calls the release workflow: it re-verifies the tag
against the manifests, runs the suite on macOS, and publishes a GitHub release
with that CHANGELOG section as its notes and a `checksums.txt` beside the
tarball. Both assets carry a [Sigstore provenance attestation](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations)
signed by the release workflow's own identity, which is what makes the checksum
manifest trustworthy rather than merely present.

The version lives in four places that must agree — `CP_VERSION` in
`scripts/cprof`, `plugin.json`, the `marketplace.json` metadata, and its plugin
entry. The bump writes all four; `tests/test_manifest.sh` and
`tests/test_cli.sh` fail when they drift, or when `CHANGELOG.md` has no section
for the version.

`release-bump.yml` runs `.github/scripts/release-version.sh` as it exists on the
*base* revision, never the branch's copy, so that a pull request cannot choose
what a write-capable token executes. A change to that script therefore takes
effect once it merges, not in the pull request making it.

To release by hand instead — a fork's pull request cannot be bumped by CI, since
its token is read-only:

```bash
bash .github/scripts/release-version.sh apply <version>   # or edit the four by hand
bash tests/run.sh && claude plugin validate .
```

then merge, or tag directly with `claude plugin tag . --push`.

Installs track the marketplace, so consumers update with:

```bash
claude plugin marketplace update cprof
claude plugin update cprof     # restart Claude Code to apply
```

The plugin cache is keyed by version, so a release without a version bump gives
`plugin update` nothing to act on.

## Project repositories

- [dcotelo/cprof](https://github.com/dcotelo/cprof) — this repository: the
  CLI, the plugin, hooks, statusline segment, installer, tests, and release
  automation.
- [dcotelo/homebrew-tap](https://github.com/dcotelo/homebrew-tap) — the
  Homebrew formula. The release workflow dispatches a `cprof-released` event to
  it so the formula bumps on every release; it also polls daily as a backstop.
