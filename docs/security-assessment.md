# Security assessment

Satisfies OSPS-SA-03.01: the most likely and most impactful potential security
problems for cprof, and what stands between them and a user. Last reviewed
2026-08-28 against v0.8.x. Re-review when the attack surface changes — a new
credential path, a new remote fetch, or a new place cprof writes outside its
own directories.

## What cprof protects

cprof's whole job is routing Claude Code at per-profile credential stores:

- **Profile directories** (`~/.claude-profiles/<name>` by default), each a full
  `CLAUDE_CONFIG_DIR` holding `.credentials.json` and session data.
- **macOS keychain items** — Claude Code stores tokens under a service name
  derived from `CLAUDE_CONFIG_DIR` (`scripts/lib/auth.sh`); cprof reads status,
  never writes keychain items itself.
- **The config file** (`~/.config/cprof/config.json`) — controls which
  credentials a directory resolves to. Whoever writes it decides which account
  every repo bills and authenticates as.

The impactful failures, in order: credential theft, silent account
mis-routing (work code on a personal account or the reverse), and arbitrary
code execution via the installer or hooks.

## Attack surface and mitigations

| Surface | Threat | Mitigation |
|---------|--------|------------|
| `install.sh` (remote fetch) | Tampered or truncated installer executes | Docs instruct download → review → run, never `curl \| bash`; TLS to github.com; installer runs `set -eu`. Release tarballs ship with `checksums.txt` (release.yml) — verify with `shasum -a 256 -c checksums.txt` next to the downloaded tarball. The checksum covers release archives only; see accepted risks for the installer fetch itself |
| Config file | Malicious or corrupt JSON reroutes credentials or breaks resolution | `cp_config_read` validates with `jq -e` and refuses malformed input; `cp_config_write` is atomic (temp + `mv`), refuses invalid or empty JSON; file lives under the user's own `$HOME` — writing it already requires user-level access |
| Profile directories | Other local users read credentials | Created `chmod 700`; `~/.claude` refused as a profile dir (`cp_forbidden_dir`) so cprof never manages or purges the native store |
| `remove --purge` | Destructive deletion of a credential store | Interactive y/N confirmation; refuses `~/.claude` outright |
| Environment (`CLAUDE_PROFILE`, `CPROF_CONFIG`, `CP_CLAUDE_BIN`, `CP_SECURITY_BIN`) | PATH/env hijack substitutes binaries or config | Same trust domain as the user's shell: anything able to set these can already run code as the user. Overrides exist for tests; no privilege boundary is claimed or crossed — cprof never runs as root and never writes outside `$HOME` |
| stdout eval (`cprof env`) | Injected output evaluated by the shell | stdout is reserved for shell-eval lines; all human messages go to stderr (`cp_warn`); values are shell-quoted (`cp_shquote`) |
| CI / release pipeline | Compromised action or leaked token publishes a malicious release | All third-party actions pinned to commit SHAs; workflows default `permissions: contents: read`, escalating per-job; checkouts that never push set `persist-credentials: false`; tap dispatch uses a separate token scoped to the tap repo only; secret scanning + Scorecard + Dependabot alerts enabled |
| Keychain reads | Credential exposure through cprof output | cprof reads auth *status* via `claude auth status --json` and `security`(1) lookups; token values are never printed — status output carries plan/account, not secrets |

## Accepted risks

- **The installer fetch has no independent digest.** `install.sh` is fetched
  from `main` over TLS and has no out-of-band checksum or signature; its
  integrity rests on GitHub's TLS plus the documented review-before-run step.
  The tarball it then downloads comes from the GitHub API rather than the
  checksummed release asset. Homebrew remains the verified-install path — the
  formula pins a checksum.
- **Local same-user malware** can do everything cprof can. No sandbox is
  claimed; cprof is a convenience layer inside the user's own account.
- **`claude` binary trust** — cprof execs whatever `claude` resolves to
  (or `CP_CLAUDE_BIN`). It does not verify that binary; that is Claude Code's
  installer's job.
- **No commit signing / DCO** — solo-maintainer repo; merges require PR +
  passing checks under an active ruleset with no bypass actors.

## Reporting

Vulnerabilities: see [SECURITY.md](../SECURITY.md) — GitHub private
vulnerability reporting, 7-day acknowledgement.
