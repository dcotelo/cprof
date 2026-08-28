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

## What a contribution needs

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

## Error-handling convention

Scripts use `set -u` (with `set -eu` in the installer) rather than
`set -euo pipefail`. This is deliberate: the CLI's library functions return
status codes that callers check explicitly, and `set -e` semantics differ
subtly across the bash 3.2/5.x boundary this project straddles. Match the
existing style; do not add `set -e` to the CLI scripts in a drive-by.

## Releasing

Maintainer-only; the process is documented in
[README → Releasing](README.md#releasing).
