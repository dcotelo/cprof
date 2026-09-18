---
name: Bug report
about: Something cprof does wrong
title: ''
labels: bug
assignees: ''
---

<!-- Security problems go through GitHub private vulnerability reporting, not a
     public issue — see SECURITY.md. -->

## Environment

- **cprof version:** <!-- `cprof version` -->
- **Install method:** <!-- brew / install.sh / plugin only -->
- **Plugin installed:** <!-- `env -u CLAUDE_CONFIG_DIR claude plugin list` -->
- **macOS version:**
- **bash version:** <!-- `/bin/bash --version | head -1` -->
- **jq version:** <!-- `jq --version` -->

## Steps to reproduce

1.
2.
3.

## Expected behavior

<!-- What you expected to happen -->

## Actual behavior

<!-- What actually happened -->

## Diagnostics

<!-- `cprof status` shows the resolution, the config path and the active
     profile; `cprof doctor` adds login state, usage windows, statusline
     config problems and version skew. Both are safe to paste. -->

```console
$ cprof status

$ cprof doctor

```

<!-- Before pasting anything else: `status`, `list` and `doctor` never print
     credentials, but keychain output and a config file can contain tokens.
     Do not paste those. -->
