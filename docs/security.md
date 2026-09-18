# Safety

`cprof login` snapshots the shared keychain item to `~/.cprof/keychain.bak`
(mode 600) before signing in, then verifies that `claude auth status` reports the
profile signed in and that the shared item went untouched. If a login overwrites
the shared item instead of the profile's own, it is restored from the snapshot
and the command fails loudly. Your working account cannot be lost to a profile
login.

`cprof doctor` reads credentials only to extract the refresh token's expiry, and
pipes them straight into `jq` so a live token never lands in a shell variable. If
the store cannot be read, the expiry is reported as unknown rather than guessed.

`cprof env` never exits non-zero and always prints one assignment. A
missing `jq`, a malformed config, or a missing profile directory degrades to
stock Claude Code behaviour rather than a broken shell.

`cprof list`, `cprof doctor`, and `cprof usage [<name>]` fetch usage data from
`api.anthropic.com/api/oauth/usage` using the profile's own OAuth token,
cached for 5 minutes under `~/.cprof/usage/`. `cprof usage --render <name>` is
the exception: it is what the statusline calls, and it only reads that cache,
so the statusline never makes the request and never blocks on it. Set
`CPROF_NO_USAGE=1` to turn fetching off everywhere; existing cached data (or a
plain `-`) is shown instead. A response is cached only when it has the shape
the renderers read — anything else is treated as a failed fetch, and the
previous cache stands.

Per-profile state under `~/.cprof/` (the usage cache, a fallback marker) is
filed under a filename-safe key derived from the profile name, so no name —
however it got into the config — can address a path outside that directory.
`add` also refuses a name that is `.`, `..`, contains `/`, or contains a
control character.

For the threat model, the trust boundaries and the findings of the last audit,
see [the security assessment](security-assessment.md).
