## Summary

<!-- What does this PR change, and why? -->

## Type

<!-- These are load-bearing, not tidy: CI reads the commit subjects to decide
     whether merging publishes a release, and at what version. `feat:` is a
     minor, `fix:`/`perf:` a patch, `!` a major; `docs:`, `chore:`, `test:`,
     `ci:` and `refactor:` publish nothing. -->

- [ ] feat
- [ ] fix
- [ ] perf
- [ ] docs
- [ ] test
- [ ] chore
- [ ] ci
- [ ] refactor

## Surface(s) touched

- [ ] CLI (`scripts/cprof`, `scripts/lib/*.sh`)
- [ ] statusline (`scripts/lib/statusline.sh`, `statusline/segment.sh`)
- [ ] plugin (`hooks/`, `commands/`, manifests)
- [ ] installer (`install.sh`)
- [ ] docs (`README.md`, `docs/`, `CONTRIBUTING.md`)
- [ ] CI and release automation (`.github/`)

## Test evidence

<!-- The commands you ran and what they reported, e.g.:
     bash tests/run.sh            -> ALL TESTS PASSED, 1130 assertions
     shellcheck -x ...            -> clean
     bash tests/test_manifest.sh  -> pass -->

## Checklist

- [ ] `bash tests/run.sh` passes, and CI is green.
- [ ] shellcheck is clean over the file list CI uses
      (`.github/workflows/ci.yml`; a new script must be added to it).
- [ ] New behavior carries an assertion in `tests/`.
- [ ] **My tests can FAIL**: I can name the single change to the code that
      each new or changed assertion would catch, and I have watched it fail.
      An assertion that passes whether or not the code works has tested
      nothing — this has been caught here more than once.
- [ ] **bash 3.2**: no associative arrays, no `${var,,}`, nothing newer than
      the macOS system shell. `cut -d. -f<n>` without `-s` prints the whole
      line when the delimiter is absent; prefer `IFS=. read -r -a`.
- [ ] Conventional Commits subject on every commit, matching the Type above.
- [ ] Every commit carries a DCO sign-off (`git commit -s`).
- [ ] No AI attribution anywhere in the commits or this PR (no "Generated
      with", no `Co-authored-by:` trailers for an AI tool or agent).
- [ ] Docs updated if this changes user-facing behavior, output or commands —
      including the topic doc under `docs/`, not only the README.
- [ ] User-facing output follows the conventions: diagnostics to stderr via
      `cp_warn`, `cprof env` stdout reserved for shell-eval output, paths
      through `cp_path_display`.
- [ ] Nothing that renders inside a Claude Code session can fail it: a missing
      `jq`, an unreadable config, an absent `git` or a missing CLI prints
      nothing, or as much as it can, and exits 0.
- [ ] **Breaking changes declared**: if this changes a published contract — a
      `~/.cprof.json` key, a `statusline` segment or setting name, a
      subcommand or flag, the shape of `cprof env` output, or a cache path —
      the summary says so explicitly and gives the upgrade note. Write "None"
      if there are none.
