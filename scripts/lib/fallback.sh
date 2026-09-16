#!/usr/bin/env bash
# shellcheck shell=bash
# Fallback account: config field, active-swap marker, both swap directions.

# cp_fallback_marker_file <name> -> path (may not exist)
cp_fallback_marker_file() {
  printf '%s/fallback-active/%s.json\n' "$CP_STATE_DIR" "$(cp_state_key "${1:-}")"
}

# cp_fallback_threshold -> the 5h percentage at which a swap fires: 1-100
# from CPROF_FALLBACK_THRESHOLD, else 90. Zero is excluded on purpose: swap-out
# fires at pct >= threshold and swap-back restores at pct < threshold, so a
# threshold of 0 would swap on any reading and never restore. Anything else
# would reach `[ -ge ]` raw and turn into a shell "integer expression
# expected" error on every cprof env call, so it is reported here and the
# default used instead.
cp_fallback_threshold() {
  local t="${CPROF_FALLBACK_THRESHOLD:-}"
  case "$t" in
    '') printf '90\n'; return 0 ;;
    *[!0-9]*) ;;
    *) if [ "$t" -ge 1 ] && [ "$t" -le 100 ]; then printf '%s\n' "$t"; return 0; fi ;;
  esac
  cp_warn "CPROF_FALLBACK_THRESHOLD=$t is not a percentage from 1 to 100; using 90"
  printf '90\n'
}

# Per-profile lock around both swap directions. Two `cprof env` calls can
# run at once (two `claude` launches, a statusline refresh racing a launch),
# and each direction is a check-then-act on the marker and the backup: two
# swap-outs passing both checks would take two backups, the second of them a
# copy of the fallback's credentials, and a restore that started before a
# new swap-out could finish after it and undo it. mkdir is atomic on every
# filesystem cprof runs on, so a directory is the lock; the pid inside lets
# a lock left by a crashed process be reclaimed.
cp_fallback_lock_dir() {
  printf '%s/fallback-lock/%s\n' "$CP_STATE_DIR" "$(cp_state_key "${1:-}")"
}

# cp_fallback_lock <name> -> 0 with the lock held, 1 if another live cprof
# holds it (or the holder cannot be determined, which is treated as live).
cp_fallback_lock() {
  local lock pid
  lock="$(cp_fallback_lock_dir "$1")"
  mkdir -p "$(dirname "$lock")" 2>/dev/null
  chmod 700 "$(dirname "$lock")" 2>/dev/null
  if mkdir "$lock" 2>/dev/null; then
    printf '%s' "$$" > "$lock/pid" 2>/dev/null
    return 0
  fi
  pid="$(cat "$lock/pid" 2>/dev/null)"
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null && return 1
  # The holder is gone. Reclaim atomically: rename the dead lock aside first —
  # rename is atomic, so of two processes that both saw the dead pid only one
  # succeeds here and owns the reclaim; the other treats the lock as held and
  # comes back next call. Deleting in place would let the second process tear
  # down the first one's fresh lock.
  mv "$lock" "$lock.stale.$$" 2>/dev/null || return 1
  rm -f "$lock.stale.$$/pid"
  rmdir "$lock.stale.$$" 2>/dev/null
  mkdir "$lock" 2>/dev/null || return 1
  printf '%s' "$$" > "$lock/pid" 2>/dev/null
  return 0
}

cp_fallback_unlock() {
  local lock
  lock="$(cp_fallback_lock_dir "$1")"
  rm -f "$lock/pid"
  rmdir "$lock" 2>/dev/null
}

# cp_fallback_window_open <cached-usage-json> -> the five_hour resets_at on
# stdout when it parses AND lies in the future; nothing with return 1
# otherwise. The cache is served regardless of age (that is what lets the
# statusline stay cheap), so a high number in it may describe a window that
# has since reset — and a swap on that would be a swap on nothing. Shared by
# swap-out and `which`, so the two never disagree about whether a swap
# would fire.
cp_fallback_window_open() {
  cp_usage_window_open "${1:-}" five_hour
}

cp_cmd_fallback() {
  local name="${1:-}" target cfg
  [ -n "$name" ] || { cp_warn 'fallback: missing profile name'; return 2; }
  shift
  if [ "$#" -gt 1 ]; then
    cp_warn "fallback: too many arguments ($*); expected <primary> [<name>|--clear]"
    return 2
  fi
  cfg="$(cp_config_read)" || return 1
  cp_profile_exists "$cfg" "$name" || { cp_warn "unknown profile $name"; return 1; }

  target="${1:-}"
  if [ -z "$target" ]; then
    target="$(cp_profile_field "$cfg" "$name" fallback)"
    printf '%s\n' "${target:-none}"
    return 0
  fi

  if [ "$target" = '--clear' ]; then
    printf '%s' "$cfg" | jq --arg n "$name" \
      '.profiles |= map(if .name == $n then del(.fallback) else . end)' | cp_config_write
    return $?
  fi

  cp_profile_exists "$cfg" "$target" || { cp_warn "unknown profile $target"; return 1; }
  if [ "$target" = "$name" ]; then
    cp_warn 'fallback: a profile cannot be its own fallback'
    return 2
  fi
  # cprof env exports nothing for a native profile and returns before either
  # swap runs, so a mapping on one could never fire; refuse it rather than
  # store a setting that silently does nothing.
  if cp_profile_is_native "$cfg" "$name"; then
    cp_warn "fallback: $name is native; only a directory-backed profile can have a fallback"
    return 2
  fi
  # No chains: a profile is a primary or a fallback target, never both. If
  # `personal` were both work's fallback and a primary with its own fallback,
  # a swap of `work` while `personal` is itself swapped would copy the third
  # profile's credentials into `work`.
  if [ -n "$(cp_profile_field "$cfg" "$target" fallback)" ]; then
    cp_warn "fallback: $target already has a fallback of its own; a profile cannot be both a fallback and a primary"
    return 2
  fi
  if printf '%s' "$cfg" | jq -e --arg n "$name" 'any(.profiles[]?; .fallback == $n)' >/dev/null 2>&1; then
    cp_warn "fallback: $name is already another profile's fallback; a profile cannot be both a fallback and a primary"
    return 2
  fi
  printf '%s' "$cfg" | jq --arg n "$name" --arg t "$target" \
    '.profiles |= map(if .name == $n then .fallback = $t else . end)' | cp_config_write
}

# cp_fallback_recover_pending <name>: finish or undo a swap-out that died
# between staging its marker and committing it. The staged marker sits at
# <marker>.pending from before the credentials change hands until after; if
# a process is killed in that window, the next call (under the same lock)
# looks at what actually happened. Backup identical to the live store: the
# overwrite never ran, so drop backup and pending — nothing changed. Backup
# differs: the overwrite ran, so promote pending to the marker and let the
# normal restore take over. Nothing is ever guessed at with a malformed
# pending file: it is left in place and reported.
cp_fallback_recover_pending() {
  local name="$1" marker pending backup kind live service
  marker="$(cp_fallback_marker_file "$name")"
  pending="$marker.pending"
  [ -f "$pending" ] || return 0
  if [ -f "$marker" ]; then
    rm -f "$pending"
    return 0
  fi
  backup="$(jq -r '.backup // empty' "$pending" 2>/dev/null)"
  kind="$(jq -r '.backup_kind // empty' "$pending" 2>/dev/null)"
  case "$kind" in file|keychain) ;; *) kind='' ;; esac
  if [ -z "$backup" ] || [ -z "$kind" ]; then
    cp_warn "fallback: an interrupted swap left a malformed pending marker for $name; not touching anything — inspect and remove $(cp_path_display "$pending") by hand"
    return 0
  fi
  if [ "$kind" = file ]; then
    live="${backup%.bak}"
    if [ ! -f "$backup" ]; then
      rm -f "$pending"
      cp_warn "fallback: an interrupted swap of $name never got as far as its backup; nothing changed"
      return 0
    fi
    if cmp -s "$backup" "$live"; then
      rm -f "$backup" "$pending"
      cp_warn "fallback: an interrupted swap of $name never changed its credentials; backup discarded, nothing to restore"
    elif mv "$pending" "$marker" 2>/dev/null; then
      cp_warn "fallback: an interrupted swap of $name had already changed its credentials; marker recovered, the restore will run as usual"
    fi
  else
    service="${backup%-bak}"
    cp_keychain_status "$backup"
    case $? in
      1) rm -f "$pending"
         cp_warn "fallback: an interrupted swap of $name never got as far as its backup; nothing changed"
         return 0 ;;
      0) ;;
      *) cp_warn "fallback: an interrupted swap of $name cannot be recovered while the keychain cannot be read; leaving $(cp_path_display "$pending") in place"
         return 0 ;;
    esac
    if [ "$(cp_keychain_read "$backup")" = "$(cp_keychain_read "$service")" ]; then
      cp_keychain_delete "$backup"
      rm -f "$pending"
      cp_warn "fallback: an interrupted swap of $name never changed its credentials; backup discarded, nothing to restore"
    elif mv "$pending" "$marker" 2>/dev/null; then
      cp_warn "fallback: an interrupted swap of $name had already changed its credentials; marker recovered, the restore will run as usual"
    fi
  fi
}

# cp_fallback_swap_out <cfg> <name> <dir> -> always returns 0. Overwrites
# <name>'s own credential storage with its configured fallback's blob, once
# the cached 5h usage is at/above threshold. No-ops (with a cp_warn) whenever
# it cannot proceed safely. Holds the per-profile lock for the whole
# check-then-act; a call that finds it held skips — the next cprof env
# checks again.
cp_fallback_swap_out() {
  local cfg="$1" name="$2" fallback
  fallback="$(cp_profile_field "$cfg" "$name" fallback)"
  [ -n "$fallback" ] || return 0
  if ! cp_fallback_lock "$name"; then
    cp_warn "fallback: another cprof is working on $name's credentials (lock $(cp_path_display "$(cp_fallback_lock_dir "$name")")); skipping this check"
    return 0
  fi
  cp_fallback_swap_out_locked "$@"
  cp_fallback_unlock "$name"
  return 0
}

cp_fallback_swap_out_locked() {
  local cfg="$1" name="$2" dir="$3"
  local fallback cached pct marker file service before blob kind backup resets_at

  fallback="$(cp_profile_field "$cfg" "$name" fallback)"
  [ -n "$fallback" ] || return 0
  [ "$fallback" != "$name" ] || return 0

  marker="$(cp_fallback_marker_file "$name")"
  cp_fallback_recover_pending "$name"
  [ -f "$marker" ] && return 0

  cached="$(cp_usage_read_cached_only "$name")"
  [ -n "$cached" ] || return 0
  pct="$(cp_usage_pct "$cached" five_hour)"
  case "$pct" in ''|*[!0-9]*) return 0 ;; esac
  [ "$pct" -ge "$(cp_fallback_threshold)" ] || return 0
  # The marker's resets_at is what swap-back keys the restore on: a marker
  # without a parseable one is the state it refuses to act on, and a window
  # that has already reset is not worth swapping for. Never create either.
  resets_at="$(cp_fallback_window_open "$cached")" || return 0

  cp_profile_exists "$cfg" "$fallback" || {
    cp_warn "fallback: $name's fallback profile $fallback no longer exists"
    return 0
  }
  # Enforced again here, for configs edited by hand: the target must not be
  # a primary itself, and must not be swapped right now — its live store
  # would hold someone else's credentials, not its own.
  if [ -n "$(cp_profile_field "$cfg" "$fallback" fallback)" ]; then
    cp_warn "fallback: $fallback has a fallback of its own; chained fallbacks are not supported, not swapping $name"
    return 0
  fi
  if [ -f "$(cp_fallback_marker_file "$fallback")" ]; then
    cp_warn "fallback: $fallback is itself swapped to a fallback right now; not swapping $name"
    return 0
  fi

  file="$(cp_creds_file "$cfg" "$name")"
  service="$(cp_keychain_service "$dir")"
  # What gets backed up must be a credential blob with a token in it, for
  # either store: swap-back parses the backup and refuses to restore
  # anything else, so an empty or malformed primary would be swapped out and
  # never swapped back.
  # The keychain item is read exactly once: the value that passed validation
  # is the value that gets backed up, so a transient read failure in between
  # can never produce an empty backup that swap-back would later reject.
  if [ -n "$file" ] && [ -s "$file" ] \
      && jq -e '.claudeAiOauth.accessToken | strings | length > 0' "$file" >/dev/null 2>&1; then
    kind='file'
  else
    before="$(cp_keychain_read "$service")"
    if printf '%s' "$before" | jq -e '.claudeAiOauth.accessToken | strings | length > 0' >/dev/null 2>&1; then
      kind='keychain'
    else
      unset before
      cp_warn "fallback: $name has no existing credentials to back up; skipping swap"
      return 0
    fi
  fi

  blob="$(cp_creds_read "$cfg" "$fallback")"
  if [ -z "$blob" ]; then
    cp_warn "fallback: $fallback has no credentials to swap in"
    unset before
    return 0
  fi
  # Whatever is about to replace the primary's live credentials must at least
  # be a credential blob with a token in it; otherwise the swap trades a
  # working account for a broken one.
  if ! printf '%s' "$blob" | jq -e '.claudeAiOauth.accessToken | strings | length > 0' >/dev/null 2>&1; then
    cp_warn "fallback: $fallback's credentials carry no access token; not swapping"
    unset blob before
    return 0
  fi

  if [ "$kind" = file ]; then
    backup="$file.bak"
    [ -e "$backup" ] && { cp_warn "fallback: a backup already exists at $(cp_path_display "$backup") for $name; refusing to overwrite it — investigate manually"; unset blob before; return 0; }
  else
    backup="$service-bak"
    # An empty read is not proof of absence; only "not found" is.
    cp_keychain_status "$backup"
    case $? in
      0) cp_warn "fallback: a backup already exists at keychain service $backup for $name; refusing to overwrite it — investigate manually"; unset blob before; return 0 ;;
      1) ;;
      *) cp_warn "fallback: could not tell whether a backup keychain item exists for $name; not swapping"; unset blob before; return 0 ;;
    esac
  fi

  # Stage the marker before any credential changes hands, at a fixed name
  # (<marker>.pending) rather than a per-process temp file: if this process
  # dies between the credential overwrite and the commit below, the next
  # call finds the pending file and finishes or undoes the swap
  # (cp_fallback_recover_pending) instead of leaving a swapped profile with
  # no record of it. If the marker cannot even be staged, nothing is swapped.
  mkdir -p "$(dirname "$marker")" 2>/dev/null
  chmod 700 "$(dirname "$marker")" 2>/dev/null
  if ! { jq -n --arg fb "$fallback" --arg backup "$backup" --arg kind "$kind" \
      --argjson swapped_at "$(date +%s)" \
      --arg resets_at "$resets_at" \
      '{fallback: $fb, backup: $backup, backup_kind: $kind,
        swapped_at: $swapped_at, resets_at: $resets_at}' \
      > "$marker.tmp.$$" 2>/dev/null \
      && chmod 600 "$marker.tmp.$$" 2>/dev/null \
      && mv "$marker.tmp.$$" "$marker.pending" 2>/dev/null; }; then
    rm -f "$marker.tmp.$$"
    cp_warn "fallback: cannot write a swap marker under $(cp_path_display "$(dirname "$marker")") for $name; not swapping"
    unset blob before
    return 0
  fi

  if [ "$kind" = file ]; then
    if ! { ( umask 077; cp "$file" "$backup" ) 2>/dev/null && chmod 600 "$backup" 2>/dev/null; }; then
      rm -f "$backup" "$marker.pending"
      cp_warn "fallback: could not back up $(cp_path_display "$file")"
      unset blob
      return 0
    fi
    if ! { ( umask 077; printf '%s' "$blob" > "$file.tmp.$$" ) 2>/dev/null \
        && chmod 600 "$file.tmp.$$" 2>/dev/null \
        && mv "$file.tmp.$$" "$file" 2>/dev/null; }; then
      rm -f "$file.tmp.$$" "$backup" "$marker.pending"
      cp_warn "fallback: could not write $fallback's credentials for $name"
      unset blob
      return 0
    fi
  else
    if ! cp_keychain_create "$before" "$backup"; then
      rm -f "$marker.pending"
      cp_warn "fallback: could not back up the keychain item for $name"
      unset blob before
      return 0
    fi
    if ! cp_keychain_write "$blob" "$service"; then
      # The backup was just taken; leaving it would make every later swap-out
      # refuse on "a backup already exists" after one transient keychain
      # error. Remove it while the primary item is provably unchanged.
      rm -f "$marker.pending"
      unset blob
      if [ "$(cp_keychain_read "$service")" = "$before" ]; then
        cp_keychain_delete "$backup"
        cp_warn "fallback: could not write $fallback's credentials for $name; nothing changed"
      else
        cp_warn "fallback: could not write $fallback's credentials for $name and its keychain item no longer matches the backup — backup kept at keychain service $backup; recover manually"
      fi
      unset before
      return 0
    fi
  fi
  unset blob

  # Commit the marker. Same directory as the pending file, so this only
  # fails when the directory itself changed under us; roll the swap back
  # rather than leave a swapped profile with no record of it.
  if ! mv "$marker.pending" "$marker" 2>/dev/null; then
    rm -f "$marker.pending"
    if [ "$kind" = file ]; then
      if mv "$backup" "$file" 2>/dev/null; then
        cp_warn "fallback: marker could not be committed for $name; swap rolled back, nothing changed"
      else
        cp_warn "fallback: marker could not be committed for $name and the roll-back failed — $name is running as $fallback, its own credentials are at $(cp_path_display "$backup"); recover manually"
      fi
    else
      if cp_keychain_write "$before" "$service" && cp_keychain_delete "$backup"; then
        cp_warn "fallback: marker could not be committed for $name; swap rolled back, nothing changed"
      else
        cp_warn "fallback: marker could not be committed for $name and the roll-back failed — $name is running as $fallback, its own credentials are at keychain service $backup; recover manually"
      fi
      unset before
    fi
    return 0
  fi
  unset before
  cp_warn "profile $name: swapped to fallback $fallback (5h at ${pct}%)"
}

# cp_fallback_swap_back <cfg> <name> -> always returns 0. Restores <name>'s
# original credentials once its marker's resets_at has passed AND a fresh
# fetch confirms it is back under threshold. Leaves the marker in place (for
# a retry on the next call) whenever it cannot confirm or cannot restore.
# Same per-profile lock as swap-out, held from before the marker is read
# until the restore and its cleanup are done.
cp_fallback_swap_back() {
  local name="$2"
  [ -f "$(cp_fallback_marker_file "$name")" ] || [ -f "$(cp_fallback_marker_file "$name").pending" ] || return 0
  if ! cp_fallback_lock "$name"; then
    cp_warn "fallback: another cprof is working on $name's credentials (lock $(cp_path_display "$(cp_fallback_lock_dir "$name")")); skipping this check"
    return 0
  fi
  cp_fallback_swap_back_locked "$@"
  cp_fallback_unlock "$name"
  return 0
}

# cp_fallback_doctor_line <name> -> the one line doctor prints for an active
# swap, or nothing. Printed whether or not the profile authenticates: an
# expired fallback credential is exactly when the user needs to see it.
cp_fallback_doctor_line() {
  local marker
  marker="$(cp_fallback_marker_file "${1:-}")"
  if [ ! -f "$marker" ] && [ -f "$marker.pending" ]; then
    printf '%s: fallback swap interrupted; recovered on the next cprof env\n' "$1"
    return 0
  fi
  [ -f "$marker" ] || return 0
  if [ "$(jq -r '.restored // false' "$marker" 2>/dev/null)" = 'true' ]; then
    printf '%s: fallback restore done, cleanup pending (backup %s)\n' "$1" \
      "$(cp_path_display "$(jq -r '.backup // "unknown"' "$marker" 2>/dev/null)")"
  else
    printf '%s: fallback active (using %s, restores after it resets ~%s)\n' "$1" \
      "$(jq -r '.fallback // "unknown"' "$marker" 2>/dev/null)" \
      "$(jq -r '.resets_at // "unknown"' "$marker" 2>/dev/null)"
  fi
}

# cp_fallback_finish_restore <name> <marker> <backup> <kind> <fallback> [<pct>]
# The cleanup half of a restore, run only once the marker records
# restored:true — delete the backup, then the marker, each step checked. A
# failure leaves the marker so the next call retries from here without
# fetching or rewriting credentials, so cleanup itself cannot leave a backup
# without a marker (swap-out would refuse forever) or a marker without its
# backup (swap-back would give up). The README's stuck states remain
# reachable only when a marker commit and its rollback both fail.
cp_fallback_finish_restore() {
  local name="$1" marker="$2" backup="$3" kind="$4" fallback="$5" pct="${6:-}"
  # Belt and braces: the caller validated the marker, but an empty backup
  # here would address the shared native keychain item.
  [ -n "$backup" ] || return 0
  case "$kind" in file|keychain) ;; *) return 0 ;; esac
  if [ "$kind" = file ]; then
    if [ -e "$backup" ] && ! rm -f "$backup" 2>/dev/null; then
      cp_warn "fallback: $name is restored but its backup $(cp_path_display "$backup") could not be deleted; keeping the marker to retry"
      return 0
    fi
  else
    cp_keychain_status "$backup"
    case $? in
      0) if ! cp_keychain_delete "$backup"; then
           cp_warn "fallback: $name is restored but its backup keychain item $backup could not be deleted; keeping the marker to retry"
           return 0
         fi ;;
      1) ;;
      *) cp_warn "fallback: $name is restored but the keychain could not be read to confirm its backup item is gone; keeping the marker to retry"
         return 0 ;;
    esac
  fi
  if ! rm -f "$marker" 2>/dev/null; then
    cp_warn "fallback: $name is restored but its marker $(cp_path_display "$marker") could not be deleted; will retry"
    return 0
  fi
  if [ -n "$pct" ]; then
    cp_warn "profile $name: restored from fallback $fallback (5h back to ${pct}%)"
  else
    cp_warn "profile $name: restored from fallback $fallback"
  fi
}

cp_fallback_swap_back_locked() {
  local cfg="$1" name="$2"
  local marker resets_at resets_epoch now_epoch
  local fallback backup kind file service
  local backup_blob primary_token fresh pct

  marker="$(cp_fallback_marker_file "$name")"
  cp_fallback_recover_pending "$name"
  [ -f "$marker" ] || return 0

  # Validate the marker before either path acts on it. An empty backup
  # would make cp_keychain_read/delete fall back to the shared NATIVE item
  # (their default service), and an unknown kind would be treated as
  # keychain — so a malformed marker is left in place and reported, never
  # acted on.
  fallback="$(jq -r '.fallback // empty' "$marker" 2>/dev/null)"
  backup="$(jq -r '.backup // empty' "$marker" 2>/dev/null)"
  kind="$(jq -r '.backup_kind // empty' "$marker" 2>/dev/null)"
  case "$kind" in file|keychain) ;; *) kind='' ;; esac
  if [ -z "$backup" ] || [ -z "$kind" ]; then
    cp_warn "fallback: marker for $name is malformed (missing backup or unknown backup_kind); not touching anything — inspect and remove $(cp_path_display "$marker") by hand"
    return 0
  fi

  # A previous call restored the credentials but could not finish cleaning
  # up: no fetch, no rewrite — just retry the cleanup.
  if [ "$(jq -r '.restored // false' "$marker" 2>/dev/null)" = 'true' ]; then
    cp_fallback_finish_restore "$name" "$marker" "$backup" "$kind" "$fallback"
    return 0
  fi

  resets_at="$(jq -r '.resets_at // empty' "$marker" 2>/dev/null)"
  if [ -z "$resets_at" ]; then
    cp_warn "fallback: marker for $name has no resets_at recorded; cannot auto-restore, remove $(cp_path_display "$marker") manually to retry"
    return 0
  fi
  if ! resets_epoch="$(cp_time_epoch "$resets_at")"; then
    cp_warn "fallback: marker for $name has an unparseable resets_at ($resets_at); cannot auto-restore, remove $(cp_path_display "$marker") manually to retry"
    return 0
  fi
  now_epoch="$(date +%s)"
  [ "$now_epoch" -ge "$resets_epoch" ] || return 0

  # Read the backup once: used both to authenticate the confirming fetch as
  # the PRIMARY's own account (not the fallback's, which is what's currently
  # live in the primary's storage) and, on success, to restore it.
  if [ "$kind" = file ]; then
    if [ ! -f "$backup" ]; then
      cp_warn "fallback: backup $(cp_path_display "$backup") missing for $name; leaving $fallback active"
      return 0
    fi
    backup_blob="$(cat "$backup" 2>/dev/null)"
  else
    backup_blob="$(cp_keychain_read "$backup")"
    if [ -z "$backup_blob" ]; then
      cp_warn "fallback: backup keychain item $backup missing for $name; leaving $fallback active"
      return 0
    fi
  fi

  primary_token="$(printf '%s' "$backup_blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)"
  if [ -z "$primary_token" ]; then
    unset backup_blob
    cp_warn "fallback: backup for $name has no usable token; leaving $fallback active"
    return 0
  fi
  fresh="$(cp_usage_fetch_raw "$primary_token")" || { unset primary_token backup_blob; return 0; }
  unset primary_token
  pct="$(cp_usage_pct "$fresh" five_hour)"
  case "$pct" in ''|*[!0-9]*) unset backup_blob; return 0 ;; esac
  [ "$pct" -lt "$(cp_fallback_threshold)" ] || { unset backup_blob; return 0; }

  # Restore to where the backup was taken from, not to wherever the profile
  # points now: the backup sits beside the file (or service) it shadows, so
  # if the directory was re-pointed mid-swap, the original store still holds
  # the fallback's credentials and is the one that needs its own back.
  if [ "$kind" = file ]; then
    file="${backup%.bak}"
    if [ "$file" = "$backup" ]; then
      unset backup_blob
      cp_warn "fallback: marker for $name records a backup path without a .bak suffix ($(cp_path_display "$backup")); not touching anything — inspect and remove $(cp_path_display "$marker") by hand"
      return 0
    fi
    if ! { ( umask 077; printf '%s' "$backup_blob" > "$file.tmp.$$" ) 2>/dev/null \
        && chmod 600 "$file.tmp.$$" 2>/dev/null \
        && mv "$file.tmp.$$" "$file" 2>/dev/null; }; then
      rm -f "$file.tmp.$$"
      unset backup_blob
      cp_warn "fallback: restore failed for $name; leaving $fallback active"
      return 0
    fi
  else
    service="${backup%-bak}"
    if [ "$service" = "$backup" ]; then
      unset backup_blob
      cp_warn "fallback: marker for $name records a backup service without a -bak suffix ($backup); not touching anything — inspect and remove $(cp_path_display "$marker") by hand"
      return 0
    fi
    if ! cp_keychain_write "$backup_blob" "$service"; then
      unset backup_blob
      cp_warn "fallback: restore failed for $name; leaving $fallback active"
      return 0
    fi
  fi
  unset backup_blob

  # The primary's own credentials are live again. Before the marker goes,
  # cache the confirming response under the primary's name: while the swap
  # was active, list/doctor cached the FALLBACK's numbers under this name,
  # and the swap-out check that runs right after this in the same cprof env
  # call would read them and swap straight back. If the write fails, keep
  # marker and backup — the restore is idempotent, so the next call redoes
  # it and retries the write; meanwhile the marker keeps swap-out away.
  if ! cp_usage_cache_write "$name" "$fresh"; then
    cp_warn "fallback: $name's credentials are restored but its usage cache could not be written; keeping the marker so the next call can finish"
    return 0
  fi

  # Record that the restore itself is done before touching backup or marker,
  # so a cleanup failure below can be retried without another restore.
  if ! { ( umask 077; jq '. + {restored: true}' "$marker" > "$marker.tmp.$$" ) 2>/dev/null \
      && mv "$marker.tmp.$$" "$marker" 2>/dev/null; }; then
    rm -f "$marker.tmp.$$"
    cp_warn "fallback: $name's credentials are restored but its marker could not be updated; keeping it so the next call can finish"
    return 0
  fi
  cp_fallback_finish_restore "$name" "$marker" "$backup" "$kind" "$fallback" "$pct"
}
