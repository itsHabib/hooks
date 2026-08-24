#!/usr/bin/env bash

# The discharge rule, shared by the Stop hook and the sweep.
#
# These two must not drift. The hook decides what a live session owes; the
# sweep counts what past sessions failed to pay and backfills it. If they
# disagree about "owes", the sweep's coverage number measures the disagreement
# rather than the thing GATE B is asking about.

set -euo pipefail

# At most this many tasks receive a discharge from one session. A session that
# touched nine tasks did not conclude something about nine tasks, and writing to
# all of them turns the note log into noise — which is how a store stops being
# read, and a store that stops being read stops being written.
: "${DISCHARGE_MAX_TASKS:=3}"

# discharge_marker prints the string that identifies a session's discharge in a
# task's note log. It is the ONLY way to ask "did this session conclude
# anything here", so it is defined once and both writers use it.
discharge_marker() {
  printf '[session %s]' "$1"
}

# discharge_session_short prints the short form of a session id used in the
# marker. Transcripts are named `<session-id>.jsonl`, so a filename is a valid
# input here and needs no lookup.
discharge_session_short() {
  local id="${1:-}"
  id="${id##*/}"
  id="${id%.jsonl}"
  printf '%s' "${id:0:8}"
}

# discharge_owed_task_ids prints the dossier task ids a session owes a discharge
# to, one per line, capped at $DISCHARGE_MAX_TASKS.
#
# Resolution needs no mapping table and no inference: a session that called
# task_update or task_complete named the task in the call. Claiming at the END
# is a report about what happened; claiming at the start would be a prediction,
# and predictions are what agents skip.
#
# Requires lib/transcript.sh to be sourced.
discharge_owed_task_ids() {
  local transcript="$1"
  local max="${2:-$DISCHARGE_MAX_TASKS}"
  transcript_task_ids "$transcript" | head -n "$max"
}

# discharge_join renders stdin lines as one comma-separated line, with $HOME
# collapsed to `~`. Note `paste -sd', '` does NOT do this: paste treats its
# delimiter string as a LIST to cycle through, so a two-character delimiter
# alternates between them and produces "a,b c,d".
discharge_join() {
  sed "s|^${HOME:-/tmp}|~|" | tr '\n' '\001' | sed 's/\x01$//; s/\x01/, /g'
}

# discharge_summarize renders the mechanical facts about a session. Nothing here
# depends on the model having cooperated, which is the whole point: these are
# true whether or not the session remembered to say anything — and they are
# still true weeks later, which is what lets the sweep backfill a session that
# ended without its Stop hook ever firing.
#
# Requires lib/transcript.sh to be sourced.
discharge_summarize() {
  local transcript="$1" turns files prs written_count listed
  turns="$(transcript_turn_count "$transcript")"
  files="$(transcript_files_written "$transcript")"
  prs="$(transcript_pr_urls "$transcript")"

  printf 'Session ended after %s assistant turns.' "$turns"

  if [ -n "$files" ]; then
    written_count="$(printf '%s\n' "$files" | wc -l | tr -d ' ')"
    listed="$(printf '%s\n' "$files" | head -5 | discharge_join)"
    printf ' Wrote %s file(s): %s' "$written_count" "$listed"
    [ "$written_count" -gt 5 ] && printf ' (+%s more)' "$((written_count - 5))"
    printf '.'
  fi

  if [ -n "$prs" ]; then
    printf ' PRs touched: %s.' "$(printf '%s\n' "$prs" | head -5 | discharge_join)"
  fi
}

# discharge_recorded reports whether a discharge for $session_short already
# exists on $task_id. Exit 0 means recorded, 1 means the session owes one.
#
# This reads the corpus files directly, and that is a deliberate, isolated
# coupling. Nothing on the CLI can answer the question: `task_list` returns a
# task's `body` but NOT its `## Notes` section, and no other CLI verb reads a
# note. The MCP's `task_get` does return notes — but it takes one id per call,
# walks the whole corpus to find it, and is not reachable from bash anyway.
#
# Every substrate-dependent line in the discharge path is in this one function
# — when the corpus stops being markdown on disk, this is what changes.
discharge_recorded() {
  local corpus="$1" task_id="$2" session_short="$3"
  local marker
  marker="$(discharge_marker "$session_short")"

  [ -d "$corpus/projects" ] || return 1

  # -F: the marker contains brackets, which are a character class to grep -E.
  # -q with -r over the id-prefixed filename: task files are named
  # `<task-id>-<slug>.md`, so the glob finds the file without a corpus walk.
  local -a files=()
  while IFS= read -r f; do
    [ -n "$f" ] && files+=("$f")
  done < <(find "$corpus/projects" -type f -name "${task_id}-*.md" 2>/dev/null)

  [ "${#files[@]}" -gt 0 ] || return 1

  grep -qF "$marker" "${files[@]}" 2>/dev/null
}
