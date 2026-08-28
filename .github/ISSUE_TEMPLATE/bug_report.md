---
name: Bug report
about: Something behaves wrong
labels: bug
---

**What happened**

**What you expected**

**Reproduce**

```console
$ cprof status
# paste output — it shows resolution, config path, and active profile
```

**Environment**
- macOS version:
- `bash --version` (first line):
- `cprof version`:
- Install method: brew / curl installer / plugin

**Notes**
`cprof status` and `cprof list` output never contains credentials, but check
before pasting anyway. Never paste keychain output or config JSON containing
tokens. Security issues go to [private reporting](../../security/advisories/new),
not here.
