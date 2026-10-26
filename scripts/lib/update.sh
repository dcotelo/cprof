#!/usr/bin/env bash
# shellcheck shell=bash
# Self-update: refresh the plugin's marketplace listing, then update the
# plugin itself.
#
# Always runs with CLAUDE_CONFIG_DIR unset, regardless of the active or
# default profile. This is not a profile choice: share.sh links every
# profile's plugins/ back to ~/.claude/plugins, so a plugin's recorded
# installLocation is always relative to the native ~/.claude, and
# 'claude plugin marketplace update' rejects that recorded path from any
# directory that resolves to a non-native profile ("corrupted
# installLocation"). Unsetting the variable runs the update as if no profile
# were active at all, which is the one place the path always matches.

cp_cmd_update() {
  local rc=0
  if ! env -u CLAUDE_CONFIG_DIR "$CP_CLAUDE_BIN" plugin marketplace update "$CP_MARKETPLACE"; then
    cp_warn "marketplace update failed for $CP_MARKETPLACE"
    rc=1
  fi
  if ! env -u CLAUDE_CONFIG_DIR "$CP_CLAUDE_BIN" plugin update "$CP_PLUGIN_SCOPED"; then
    cp_warn "plugin update failed for $CP_PLUGIN_SCOPED"
    rc=1
  fi
  [ "$rc" -eq 0 ] && printf 'restart Claude Code to apply the update\n'
  return "$rc"
}

# Version skew between the cprof on PATH and the newest installed plugin.
#
# The two halves update through different channels — the CLI through Homebrew
# or the curl installer, the plugin through `cprof update` — so they drift, and
# the drift is invisible: an interactive shell may reach the plugin's own copy
# through a resolver function while every subprocess Claude Code spawns gets
# whatever `PATH` holds. A statusline wired to `cprof statusline` then renders
# nothing at all when the CLI on PATH predates that subcommand.

# True when a version is a plain dotted number, the only shape worth comparing.
# A dev build or a pre-release tag is deliberately not comparable, so it never
# produces advice.
cp_ver_parseable() {
  case "${1:-}" in
    ''|*[!0-9.]*|*..*|.*|*.) return 1 ;;
    *) return 0 ;;
  esac
}

# cp_ver_lt <a> <b> — true when a is strictly older than b, compared segment
# by segment as numbers. String order would rank 0.9.0 above 0.13.0, which is
# exactly the skew this check exists to catch.
cp_ver_lt() {
  local a="${1:-}" b="${2:-}" i=0 n ai bi
  local -a av bv
  cp_ver_parseable "$a" || return 1
  cp_ver_parseable "$b" || return 1
  # Split rather than `cut -d. -f<n>`: without -s, cut prints the whole line
  # when the delimiter is absent, so a single-component "1" reported "1" for
  # every field and compared as though it were 1.1.1.
  IFS=. read -r -a av <<< "$a"
  IFS=. read -r -a bv <<< "$b"
  n=${#av[@]}
  [ "${#bv[@]}" -gt "$n" ] && n=${#bv[@]}
  while [ "$i" -lt "$n" ]; do
    # A missing component reads as zero, so 0.13 and 0.13.0 are equal. The
    # 10# prefix keeps a zero-padded component decimal rather than octal.
    ai=$((10#0${av[$i]:-0}))
    bi=$((10#0${bv[$i]:-0}))
    [ "$ai" -lt "$bi" ] && return 0
    [ "$ai" -gt "$bi" ] && return 1
    i=$((i + 1))
  done
  return 1
}

# The newest cprof version installed as a plugin, or empty when none is.
# Reads each manifest rather than trusting the directory name, and ignores one
# it cannot parse: a corrupt manifest is not evidence of a version.
cp_plugin_version() {
  local f v newest=''
  for f in "$HOME"/.claude/plugins/cache/*/cprof/*/plugin.json; do
    [ -r "$f" ] || continue
    v="$(jq -r '.version // empty' "$f" 2>/dev/null)" || continue
    cp_ver_parseable "$v" || continue
    if [ -z "$newest" ] || cp_ver_lt "$newest" "$v"; then
      newest="$v"
    fi
  done
  printf '%s' "$newest"
}

# cp_skew_report <path-version> <plugin-version> <path-to-cli>
#
# Prints at most one advisory line. Both versions reach this from outside — one
# from a binary's stdout, one from a JSON file — so neither is echoed unless it
# parsed as a dotted number, which is what keeps a control byte in either from
# reaching the report.
#
# Returns non-zero only for a real skew. A version it could not read is a
# diagnostic, not a defect: a dev build would otherwise fail doctor forever.
cp_skew_report() {
  local pv="${1:-}" gv="${2:-}" where="${3:-}"
  where="$(printf '%s' "$where" | LC_ALL=C tr -d '\000-\037\177')"
  where="$(cp_path_display "$where")"
  # No cprof on PATH is a supported install (the plugin carries its own), and
  # no plugin installed leaves nothing to compare against.
  [ -n "$where" ] || return 0
  cp_ver_parseable "$gv" || return 0
  if ! cp_ver_parseable "$pv"; then
    printf 'could not read the version of the cprof at %s - skipping the version check\n' \
      "$where"
    return 0
  fi
  if cp_ver_lt "$pv" "$gv"; then
    printf 'cprof on PATH is %s; the installed plugin is %s - run: brew upgrade dcotelo/tap/cprof\n' \
      "$pv" "$gv"
    return 1
  elif cp_ver_lt "$gv" "$pv"; then
    printf 'the installed plugin is %s; cprof on PATH is %s - run: cprof update\n' \
      "$gv" "$pv"
    return 1
  fi
  return 0
}

# Resolves both versions and reports. `type -P` deliberately ignores functions
# and aliases: the question is what a subprocess would run, not what this
# shell resolves.
#
# CP_CPROF_BIN overrides the lookup, the same seam CP_CLAUDE_BIN and
# CP_CURL_BIN provide for their tools. Set and empty means "no cprof on PATH",
# which a test cannot otherwise arrange on a machine that has one installed.
cp_skew_problems() {
  local bin pv
  bin="${CP_CPROF_BIN-$(type -P cprof 2>/dev/null)}" || bin=''
  [ -n "$bin" ] || return 0
  pv="$("$bin" version 2>/dev/null | head -1 | awk '{print $2}')" || pv=''
  cp_skew_report "$pv" "$(cp_plugin_version)" "$bin"
}

# --- is a newer cprof published? ---------------------------------------------
#
# The skew check above compares the two halves of an install against each
# other, so it is silent when both are equally old: a 0.9.0 CLI beside a 0.9.0
# plugin is internally consistent while the docs describe features neither has.
# Nothing else in cprof knows what the latest published version is, so this
# asks — at most once a day, and never from the statusline.
#
# Advisory by construction. Being a release behind is not a defect in the
# install, so nothing here returns non-zero and nothing here can fail doctor.
# No network, no cache, a malformed response or a timeout all mean silence,
# exactly as a failed usage fetch does.

# Overridable for the suite, which points it at a local file:// fixture. A
# release tag is public, so unlike the usage endpoint no credential is ever
# sent — but the scheme is still checked, so a redirected or misconfigured URL
# cannot turn this into a plaintext request.
CP_UPDATE_URL="${CP_UPDATE_URL:-https://api.github.com/repos/dcotelo/cprof/releases/latest}"
CP_UPDATE_TTL=86400

cp_update_url_ok() {
  case "$CP_UPDATE_URL" in https://*) return 0 ;; *) return 1 ;; esac
}

cp_update_cache_file() { printf '%s/update.json\n' "$CP_STATE_DIR"; }

# cp_update_tag_version <tag> -> the dotted version inside a release tag, or
# nothing. Tags are `cprof--v0.15.0`; the prefix is required, so a tag from
# another project sharing the repo cannot be read as a cprof version.
cp_update_tag_version() {
  local tag="${1:-}" v
  case "$tag" in cprof--v*) v="${tag#cprof--v}" ;; *) return 1 ;; esac
  cp_ver_parseable "$v" || return 1
  printf '%s' "$v"
}

# cp_update_cache_write <version> — installs the version atomically, stamped
# with the time it was learned. A failure leaves any existing cache alone.
# The temp name comes from mktemp rather than the `$file.tmp.$$` the rest of
# this project uses. A PID is guessable, so that spelling can be pre-empted by
# a symlink planted before the write: jq would then write through it and chmod
# would change the mode of whatever it pointed at. The `chmod 700` above does
# not close that window, because the symlink can predate it. mktemp refuses to
# reuse an existing name and creates the file 600 to begin with.
cp_update_cache_write() {
  local v="${1:-}" file tmp
  cp_ver_parseable "$v" || return 1
  file="$(cp_update_cache_file)"
  mkdir -p "$CP_STATE_DIR" 2>/dev/null || return 1
  # A state dir we cannot lock down is one we decline to write into: the same
  # directory holds the config that decides which account a directory
  # resolves to, and cp_cmd_login (auth.sh) already refuses on this condition.
  chmod 700 "$CP_STATE_DIR" 2>/dev/null || return 1
  tmp="$(mktemp "$file.XXXXXX" 2>/dev/null)" || return 1
  jq -n --arg v "$v" --argjson now "$(date +%s)" '{latest: $v, fetched_at: $now}' \
    > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# cp_update_fetch -> the published version on stdout, also cached. The short
# timeout matters: doctor is interactive, and an unreachable host must not
# hold it open.
cp_update_fetch() {
  local body tag v
  [ "${CPROF_NO_UPDATE_CHECK:-0}" = '1' ] && return 1
  cp_update_url_ok || return 1
  body="$("$CP_CURL_BIN" -sS --max-time 3 "$CP_UPDATE_URL" 2>/dev/null)" || return 1
  [ -n "$body" ] || return 1
  tag="$(printf '%s' "$body" | jq -r '.tag_name // empty' 2>/dev/null)" || return 1
  v="$(cp_update_tag_version "$tag")" || return 1
  cp_update_cache_write "$v" || return 1
  printf '%s' "$v"
}

# cp_update_latest -> the published version: the cache while it is fresh, then
# a fetch, then a stale cache rather than nothing. A day-old answer still beats
# silence, and the comparison it feeds is advisory either way.
cp_update_latest() {
  local file latest fetched_at age
  file="$(cp_update_cache_file)"
  if [ -f "$file" ]; then
    latest="$(jq -r '.latest // empty' "$file" 2>/dev/null)"
    fetched_at="$(jq -r '.fetched_at // 0' "$file" 2>/dev/null)"
    case "$fetched_at" in ''|*[!0-9]*) fetched_at=0 ;; esac
    age=$(( $(date +%s) - fetched_at ))
    if cp_ver_parseable "$latest" && [ "$age" -lt "$CP_UPDATE_TTL" ]; then
      printf '%s' "$latest"
      return 0
    fi
  fi
  if cp_update_fetch; then
    return 0
  fi
  cp_ver_parseable "${latest:-}" || return 1
  printf '%s' "$latest"
}

# cp_update_installed -> the newest cprof on this machine, CLI or plugin.
# The newest is the right side of the comparison: if either half is current,
# nothing here is behind, and the half that is older is the skew check's
# business rather than this one's.
cp_update_installed() {
  local bin pv gv newest=''
  bin="${CP_CPROF_BIN-$(type -P cprof 2>/dev/null)}" || bin=''
  if [ -n "$bin" ]; then
    pv="$("$bin" version 2>/dev/null | head -1 | awk '{print $2}')" || pv=''
    cp_ver_parseable "$pv" && newest="$pv"
  fi
  gv="$(cp_plugin_version)"
  if cp_ver_parseable "$gv"; then
    if [ -z "$newest" ] || cp_ver_lt "$newest" "$gv"; then newest="$gv"; fi
  fi
  printf '%s' "$newest"
}

# cp_update_report <installed> <latest> — at most one advisory, and only when
# the installed version is strictly older. Both sides are echoed only after
# parsing as dotted numbers, so a control byte from a release tag or a manifest
# cannot reach the report.
#
# The tap's formula can lag a published release by up to a day, so the advice
# leads with `cprof update`, which is always available, and qualifies the brew
# half rather than naming a command that may not work yet.
cp_update_report() {
  local installed="${1:-}" latest="${2:-}"
  cp_ver_parseable "$installed" || return 0
  cp_ver_parseable "$latest" || return 0
  cp_ver_lt "$installed" "$latest" || return 0
  printf 'cprof %s is installed; %s is available\n' "$installed" "$latest"
  printf '    run: cprof update (and brew upgrade dcotelo/tap/cprof once the tap has it)\n'
}

# Always returns 0: an available release is news, not a broken install.
cp_update_problems() {
  local installed latest
  [ "${CPROF_NO_UPDATE_CHECK:-0}" = '1' ] && return 0
  installed="$(cp_update_installed)"
  [ -n "$installed" ] || return 0
  latest="$(cp_update_latest)" || return 0
  cp_update_report "$installed" "$latest"
  return 0
}
