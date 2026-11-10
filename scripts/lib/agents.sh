#!/usr/bin/env bash
# shellcheck shell=bash
# The `agents` statusline segment: a session's subagents, one line each. This
# file owns reading a session's subagent records and shortening what it finds
# for a narrow terminal. It never opens the parent transcript, which can run
# to megabytes and is re-read by Claude Code itself every few seconds.

# cp_agents_now: prints the current epoch seconds. $CP_AGENTS_NOW stands in for
# the clock when it is all digits, so tests can pin "now"; anything else is
# ignored rather than trusted.
cp_agents_now() {
  case "${CP_AGENTS_NOW:-}" in
    '' | *[!0-9]*) date +%s ;;
    *) printf '%s\n' "$CP_AGENTS_NOW" ;;
  esac
}

# cp_agents_model_short: a model id -> its short form, e.g.
# claude-haiku-4-5-20251001 -> haiku-4.5. Drops the claude- prefix and a
# trailing 8-digit date, takes the leading non-numeric parts as the family and
# joins the all-digit parts after it with dots. An id that does not fit that
# shape (an alias like "haiku", or a version before the family) prints as given.
cp_agents_model_short() {
  local id="${1:-}" rest family="" ver="" part last
  rest="${id#claude-}"
  [ -n "$rest" ] || { printf '%s\n' "$id"; return 0; }
  last="${rest##*-}"
  case "$last" in
    *[!0-9]*) ;;
    ????????) [ "$last" != "$rest" ] && rest="${rest%-*}" ;;
  esac
  local IFS=-
  # shellcheck disable=SC2086  # splitting on - is the point
  set -- $rest
  for part in "$@"; do
    case "$part" in
      '' | *[!0-9]*)
        # A word: part of the family only while no version digit has been seen.
        [ -z "$ver" ] || { printf '%s\n' "$id"; return 0; }
        family="${family:+$family-}$part"
        ;;
      *) ver="${ver:+$ver.}$part" ;;
    esac
  done
  # Without a family or without a version there is nothing to reshape.
  if [ -z "$family" ] || [ -z "$ver" ]; then
    printf '%s\n' "$id"
    return 0
  fi
  printf '%s-%s\n' "$family" "$ver"
}

# cp_agents_duration: whole seconds -> "Ns", "Mm Ss" or "Hh Mm" (seconds are
# noise once an hour is on the clock, and there is no day unit). Anything that
# is not all digits prints nothing and returns 1.
cp_agents_duration() {
  local s="${1:-}"
  case "$s" in
    '' | *[!0-9]*) return 1 ;;
  esac
  if [ "$s" -lt 60 ]; then
    printf '%ss\n' "$s"
  elif [ "$s" -lt 3600 ]; then
    printf '%sm %ss\n' $((s / 60)) $((s % 60))
  else
    printf '%sh %sm\n' $((s / 3600)) $((s % 3600 / 60))
  fi
}

# cp_agents_inspect <jsonl> <meta> <whole>: one subagent's own files -> one
# line of five tab-joined fields, state, agentType, model, description and
# meta_finished (1 or 0), or nothing and status 1 when <meta> is missing or is
# not a single JSON object. <whole> is 1 when <jsonl> is at most 64 KiB, so
# the tail read below is the whole file and its first line is complete; with 0
# the first line may be cut mid-record and is dropped. Only the tail is read:
# a transcript runs to megabytes and the state is in its last few records.
# Stderr from tail and jq is discarded; a failing jq means print nothing.
cp_agents_inspect() {
  local jsonl="${1:-}" meta="${2:-}" whole="${3:-0}"
  case "$whole" in 0 | 1) ;; *) whole=0 ;; esac
  [ -f "$meta" ] || return 1
  local prog
  # shellcheck disable=SC2016  # a jq program, not shell
  prog='
    # The text a subagent returns as its last act, byte for byte. Equality, not
    # a substring match: a tool_result that merely quotes it must not count.
    def hb: "{\"success\":true,\"message\":\"Report delivered to your caller.\"}";
    # Strip characters below 32 (ESC, tab, newline) so nothing in a transcript or
    # meta file can drive the terminal or break the tab-joined line, then cut to
    # 60 characters: keep 59 and an ellipsis. Anything not a string is empty.
    def clean: if type == "string"
      then (explode | map(select(. >= 32)) | implode) | if length > 60 then .[0:59] + "…" else . end
      else "" end;
    # message.content as a list of items; a plain string is one text item. A
    # record whose message is not an object has no items rather than failing.
    def items: (.message | objects | .content)
      | if type == "array" then .
        elif type == "string" then [{type: "text", text: .}]
        else [] end;
    # A handback is a user record holding a tool_result whose content is exactly
    # the handback text, as a string or as a list of text items.
    def is_hb: .type == "user" and ([items[]
      | select(type == "object" and .type == "tool_result")
      | .content
      | if type == "string" then [.]
        elif type == "array" then [.[] | select(type == "object" and .type == "text") | .text]
        else [] end
      | .[] | select(. == hb)] | length > 0);
    # All the text a user record carries, for spotting an interrupt.
    def utext: [items[] | select(type == "object" and .type == "text") | .text | strings] | join("");
    # Index of the last element for which f holds, or -1.
    def lastidx(f): [to_entries[] | select(.value | f) | .key] | if length > 0 then .[-1] else -1 end;

    if ($m | length) != 1 or ($m[0] | type) != "object" then error("meta is not one object") else . end
    | $m[0] as $meta
    # Records: split the tail on newlines, drop the first line when the tail may
    # begin mid-record, keep what parses to an object.
    | (split("\n") | if $whole == 0 then .[1:] else . end
       | map(try fromjson catch null | select(type == "object"))) as $recs
    | ($recs | lastidx(.type == "assistant")) as $ia
    | ($recs | lastidx(is_hb)) as $ih
    | ($recs | lastidx(.type == "user")) as $iu
    # State, first match wins: the user stopped it, meta says it finished, a
    # handback came after its last assistant activity, its last user record is
    # an interrupt, else it is running.
    | (if $meta.stoppedByUser == true then "stopped"
       elif $meta.finished == true then "finished"
       elif $ih >= 0 and $ih > $ia then "finished"
       elif $iu >= 0 and ($recs[$iu] | utext | startswith("[Request interrupted by user")) then "stopped"
       else "running" end) as $state
    # Model, in order: the last assistant record in the tail, the effort model
    # meta recorded at spawn, the meta alias, nothing.
    | ((if $ia >= 0 then (($recs[$ia].message | objects | .model) // null) else null end) as $tm
       | if ($tm | type) == "string" and $tm != "" then $tm
         elif ($meta.pickedEffortModel | type) == "string" and $meta.pickedEffortModel != "" then $meta.pickedEffortModel
         elif ($meta.model | type) == "string" then $meta.model
         else "" end) as $model
    # Joined with a tab by hand: @tsv would double any backslash.
    | [$state, ($meta.agentType | clean), ($model | clean), ($meta.description | clean),
       (if $meta.finished == true then "1" else "0" end)] | join("\t")'
  tail -c 65536 "$jsonl" 2>/dev/null \
    | jq -R -s -r --slurpfile m "$meta" --argjson whole "$whole" "$prog" 2>/dev/null
  [ "${PIPESTATUS[1]}" -eq 0 ] || return 1
}
