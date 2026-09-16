# Security assessment

Satisfies OSPS-SA-03.01: the most likely and most impactful potential security
problems for cprof, and what stands between them and a user. Last reviewed
2026-09-15 against v0.10.0, which adds two things this review exists to
catch: a new remote fetch (the OAuth usage endpoint, below) and a new
credential path (the fallback swap, the one place cprof writes a profile's
live credential store — below). Re-review again when the attack surface
changes further — another credential path, another remote fetch, or a new
place cprof writes outside its own directories.

## What cprof protects

cprof's whole job is routing Claude Code at per-profile credential stores:

- **Profile directories** (`~/.claude-profiles/<name>` by default), each a full
  `CLAUDE_CONFIG_DIR` holding `.credentials.json` and session data.
- **macOS keychain items** — Claude Code stores tokens under a service name
  derived from `CLAUDE_CONFIG_DIR` (`scripts/lib/auth.sh`); cprof mostly reads
  status, but does write keychain items in three narrow cases: `cp_cmd_login`'s
  safety-net restore (if `claude auth login` writes to the shared keychain
  item instead of the profile-specific one), `cp_fallback_swap_out`'s
  backup-then-overwrite of a keychain-backed profile's credentials, and
  `cp_fallback_swap_back`'s restore of that backed-up blob into the primary's
  own service once its window resets (both in `scripts/lib/fallback.sh`).
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
| Version-bump automation (`release-bump.yml`) | A pull request steers a write-capable token, or the bot pushes unreviewed code | The versioning script is read from the base revision (`git show "$BASE_SHA:…"`), so a branch cannot choose what the token executes; the job pushes only to the pull request branch it runs on, never to `main`, and skips fork pull requests, whose token is read-only. Residual: the workflow file itself comes from the branch, as `pull_request` always runs the head's definition — so the trust boundary is write access to this repository, which a same-repo pull request already implies |
| Keychain reads | Credential exposure through cprof output | cprof reads auth *status* via `claude auth status --json` and `security`(1) lookups; token values are never printed — status output carries plan/account, not secrets |
| Usage endpoint fetch (`list`/`doctor`/`usage`) | Token exposure over the network, or via `ps` | TLS to `api.anthropic.com`; the bearer token is sent only in a request header, never in a URL or body; passed to curl via a `-K -` stdin config block, not argv, so it never appears in `ps`. `CPROF_NO_USAGE=1` disables the call entirely. The statusline never triggers this fetch, only reads a local cache |
| Fallback swap (`cprof env`) | A live session's credentials change to a different account without the session restarting | Opt-in per profile (`cprof fallback`); the primary's original credentials are backed up (sibling file or `-bak` keychain item) before any overwrite; the overwrite itself is atomic (tmp+chmod+mv, or a single keychain write), and the primary is restored automatically once usage resets and a fresh fetch confirms it. A write failure before the final mv/keychain-write leaves the primary's live credentials untouched |

## Accepted risks

- **The installer fetch has no independent digest.** `install.sh` is fetched
  from `main` over TLS and has no out-of-band checksum or signature; its
  integrity rests on GitHub's TLS plus the documented review-before-run step.
  The tarball it then downloads comes from GitHub's tag archive endpoint rather than the
  checksummed release asset. Homebrew remains the verified-install path — the
  formula pins a checksum.
- **The usage-fetch token passes through one shell variable.** `cp_usage_fetch`
  (`scripts/lib/usage.sh`) has to interpolate the OAuth token into a string to
  build curl's `-K -` config block, so — unlike `cp_creds_read`'s callers,
  which pipe credentials straight into `jq` — the token briefly exists in a
  local variable. It never reaches argv (invisible to `ps`) and the variable
  is `unset` immediately after use.
- **Local same-user malware** can do everything cprof can. No sandbox is
  claimed; cprof is a convenience layer inside the user's own account.
- **`cp_fallback_swap_out`'s and `cp_fallback_swap_back`'s keychain paths pass
  a live token through `security`'s argv.** Writing the fallback's blob into
  the primary's keychain item (swap-out) or writing the backed-up primary
  blob back into it (swap-back's restore) both go through
  `cp_keychain_write`, which invokes `security add-generic-password ...
  -w <value>` — the token is an argument to that subprocess and so is
  visible to anything reading its argv (e.g. `ps`) for its short lifetime.
  This is an existing property of `cp_keychain_write` itself, already used
  the same way (and accepted the same way) by `cp_cmd_login`'s
  keychain-restore path; the fallback feature just exercises it
  automatically, in both directions, instead of only during an interactive
  login. Redesigning `cp_keychain_write` to avoid argv is tracked separately,
  not fixed here.
- **A fallback swap changes a live session's credentials underneath it.**
  This is a deliberate reversal of cprof's normal "directory decides, a
  session's credentials never change after launch" model, opt-in per
  profile via `cprof fallback`. If a session with a fallback swapped in
  never exits cleanly before the primary's window resets, the restore
  still runs on the next `cprof env` call from *any* session (including a
  fresh one), and the backup is never deleted until a restore actually
  succeeds — but there is no guarantee a restore runs promptly if `cprof
  env` is never invoked again for that profile.
- **`claude` binary trust** — cprof execs whatever `claude` resolves to
  (or `CP_CLAUDE_BIN`). It does not verify that binary; that is Claude Code's
  installer's job.
- **No commit signing / DCO** — solo-maintainer repo; merges require a pull
  request and passing checks under the active `main-protection` ruleset. The
  repository admin role can bypass it, which is how a sole maintainer merges
  their own work; no automation holds that bypass, so no workflow can commit to
  `main`.

## Reporting

Vulnerabilities: see [SECURITY.md](../SECURITY.md) — GitHub private
vulnerability reporting, 7-day acknowledgement.
