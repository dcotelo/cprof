# Install details

What [Quickstart](../README.md#quickstart) steps 1 and 2 are doing, and why —
the plugin-only path, what the installer writes, and how to update or remove it.

Requires macOS and bash 3.2+ (the system shell). Homebrew pulls in `jq`; the
usage feature also needs `curl`, which every supported macOS ships.

**Two pieces, and you can take either alone.** `brew` installs the CLI on
`PATH`; the plugin installs the parts that only exist inside a Claude Code
session — the `SessionStart` warning, `/profile`, and the statusline segment.
The CLI is what the shell function needs, so brew alone is a working setup; the
plugin alone is not.

**The curl installer** is the CLI piece without Homebrew, in the same layout
the formula uses: the latest release's `scripts`, `statusline`, `hooks` and
`commands` land in `~/.local/share/cprof`, with `~/.local/bin/cprof` a symlink
into it. It refuses to run without `jq` and warns when `~/.local/bin` is not
on `PATH`. Pin a version with `CPROF_VERSION=cprof--v0.8.0 bash install.sh`;
uninstall by deleting those two paths.

**Verifying a release.** Each release ships `cprof-<version>.tar.gz` and a
`checksums.txt`, both attested by the release workflow. To check that a
download is the artifact CI built from the tagged commit:

```bash
gh attestation verify cprof-<version>.tar.gz --repo dcotelo/cprof
shasum -a 256 -c checksums.txt
```

The first line proves provenance (built by `release.yml` in this repository,
from this tag); the second proves the bytes match the manifest. The curl
installer does not do this for you — see
[the security assessment](security-assessment.md) for what it trusts.

<details id="plugin-without-homebrew">
<summary><strong>Installing the plugin without Homebrew</strong></summary>

The plugin puts nothing on `PATH` — the CLI lives inside a versioned cache
directory — so reaching it takes a resolver function:

```bash
cprof() {
  local cli
  cli=$({ ls -1 "$HOME"/.claude/plugins/cache/*/cprof/*/scripts/cprof ; } 2>/dev/null | sort -V | tail -1)
  [ -x "$cli" ] || { print -u2 'cprof: plugin not installed'; return 127; }
  "$cli" "$@"
}
```

Resolving at call time means plugin updates need no edit; `sort -V` keeps
`0.10.0` ahead of `0.9.0`; and the braces around `ls` put zsh's own "no matches
found" on the suppressed stream when nothing is installed. Install `jq` yourself
(`brew install jq`).

With both installed, `PATH` wins and this function is unnecessary.

</details>

Skipping the wrapper is always available: `command claude` ignores profiles and
uses stock keychain behaviour. That is also the silent failure mode worth knowing
— if `cprof` cannot be reached, `eval` of a failed command is a no-op, so
`claude` starts stock with only one line on stderr to say so.

## Updating

Two pieces installed, two things to update:

```bash
brew upgrade dcotelo/tap/cprof   # the CLI on PATH
cprof update                     # the plugin
```

Then restart Claude Code — a running session keeps the version it started with.

A curl install updates its CLI by running the installer again — it
replaces `~/.local/share/cprof` with the latest release — with `cprof update`
still covering the plugin.

Brew-only installs — the CLI from Homebrew, no plugin — have nothing for
`cprof update` to act on and should stop at the first line. Plugin-only
installs — the CLI reached through the resolver function described under
[Installing the plugin without Homebrew](#plugin-without-homebrew) instead of
Homebrew — should stop at the second.

`cprof update` is exactly the two commands below, run in order. Reach for them
directly only when `cprof` itself is unreachable, or when you want to see what
each step reported:

```bash
env -u CLAUDE_CONFIG_DIR claude plugin marketplace update dcotelo
env -u CLAUDE_CONFIG_DIR claude plugin update cprof@dcotelo
```

Both details in those commands are load-bearing, and neither is obvious:

**`env -u CLAUDE_CONFIG_DIR`.** Marketplace commands fail from a directory that
resolves to a non-native profile:

```
Failed to refresh marketplace 'dcotelo': corrupted installLocation
(~/.claude/plugins/marketplaces/dcotelo) — expected a path inside
~/.claude-profiles/<name>/plugins/marketplaces
```

This is `cprof`'s own doing. `share` links `plugins` into the profile directory,
and Claude Code checks that the recorded `installLocation` sits under the config
directory's plugins path — a check the stored `~/.claude/…` string fails even
though the symlink resolves to exactly that place. Unsetting the variable for one
command runs it as the native profile, where the path matches.

**`cprof@dcotelo`, not `cprof`.** `plugin update` does not resolve the bare name
and reports `Plugin "cprof" not found`, which reads like a broken install rather
than a naming rule. `plugin list` and `marketplace update` both accept the short
form, so the inconsistency is in Claude Code, not in this plugin.

Confirm with:

```bash
cprof version                                  # the version you expected
env -u CLAUDE_CONFIG_DIR claude plugin list    # cprof@dcotelo, enabled
```

`failed to load` rather than `enabled` means the plugin is installed but its
hooks did not register, so the `SessionStart` warning and `/profile` are missing
even though the CLI still works.
