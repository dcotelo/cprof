# Security Policy

## Supported versions

Only the latest release receives security fixes. cprof has no LTS branches;
update with `brew upgrade cprof` or by re-running the installer.

## Reporting a vulnerability

Report vulnerabilities privately through GitHub:
**[Security → Report a vulnerability](https://github.com/dcotelo/cprof/security/advisories/new)**.

Do not open a public issue for anything security-sensitive. cprof manages
Claude account credentials and keychain entries, so treat anything touching
`scripts/lib/auth.sh`, profile directories, or the installer as sensitive.

## Response expectations

- Acknowledgement within **7 days**.
- Assessment and a fix or mitigation plan within **30 days** of acknowledgement.
- Coordinated disclosure: fixed vulnerabilities are published as GitHub
  Security Advisories on this repository once a patched release is out,
  normally within **90 days** of the report.

## Scope

In scope: the `cprof` CLI, its library scripts, the shell hooks and
statusline segment, and `install.sh`. Out of scope: Claude Code itself,
Homebrew, and vulnerabilities requiring an already-compromised local account.
