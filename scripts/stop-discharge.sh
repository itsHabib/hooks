#!/usr/bin/env bash
# Stop hook: record what a session did against the dossier tasks it touched.
set -uo pipefail

# Fast path first — see posttool-gate-verdict.sh for the rationale. This fires
# once per session end rather than once per tool call, so the budget is looser,
# but the shape is kept identical: read with the builtin, cheap-match, and only
# then pay for lib sourcing and jq.
IFS= read -r -d '' _event || true
[ -n "$_event" ] || exit 0

# A Stop hook that acts on its own continuation drives an unbounded loop. This
# is the first check for that reason, before anything can cost time.
[[ $_event == *'"stop_hook_active":true'* ]] && exit 0

HOOK_NAME="stop-discharge"
HOOK_DIR="${BASH_SOURCE[0]%/*}"
[ "$HOOK_DIR" = "${BASH_SOURCE[0]}" ] && HOOK_DIR="."
ROOT_DIR="$HOOK_DIR/.."

# shellcheck source=lib/dossier-cli.sh
source "$ROOT_DIR/lib/dossier-cli.sh"
# shellcheck source=lib/hook-event.sh
source "$ROOT_DIR/lib/hook-event.sh"
# shellcheck source=lib/transcript.sh
source "$ROOT_DIR/lib/transcript.sh"

# At most this many tasks receive a discharge from one session. A session that
# touched nine tasks did not conclude something about nine tasks, and writing to
# all of them turns the note log into noise — which is how a store stops being
# read, and a store that stops being read stops being written.
DISCHARGE_MAX_TASKS="${DISCHARGE_MAX_TASKS:-3}"

_warn() {
  printf '%s: %s\n' "$HOOK_NAME" "$*" >&2
}

# _join renders stdin lines as one comma-separated line, with $HOME collapsed to
# `~`. Note `paste -sd', '` does NOT do this: paste treats its delimiter string
# as a LIST to cycle through, so a two-character delimiter alternates between
# them and produces "a,b c,d".
_join() {
  sed "s|^$HOME|~|" | tr '\n' '\001' | sed 's/\x01$//; s/\x01/, /g'
}

# _summarize renders the mechanical facts. Nothing here depends on the model
# having cooperated, which is the whole point: these are true whether or not the
# session remembered to say anything.
_summarize() {
  local transcript="$1" turns files prs written_count listed
  turns="$(transcript_turn_count "$transcript")"
  files="$(transcript_files_written "$transcript")"
  prs="$(transcript_pr_urls "$transcript")"

  printf 'Session ended after %s assistant turns.' "$turns"

  if [ -n "$files" ]; then
    written_count="$(printf '%s\n' "$files" | wc -l | tr -d ' ')"
    listed="$(printf '%s\n' "$files" | head -5 | _join)"
    printf ' Wrote %s file(s): %s' "$written_count" "$listed"
    [ "$written_count" -gt 5 ] && printf ' (+%s more)' "$((written_count - 5))"
    printf '.'
  fi

  if [ -n "$prs" ]; then
    printf ' PRs touched: %s.' "$(printf '%s\n' "$prs" | head -5 | _join)"
  fi
}

# _distill is the seam for a real conclusion — what the session DECIDED, which
# no amount of mechanical observation can produce.
#
# It is deliberately optional and strictly best-effort. A model call at session
# exit is the one thing that can make this hook delay a person, so it runs only
# when explicitly configured, under its own timeout, and its failure is silent.
# The mark is written either way.
_distill() {
  local transcript="$1"
  [ -n "${DISCHARGE_FOLD_CMD:-}" ] || return 0
  # Same absent-timeout caveat as the tail of this file. Without the binary the
  # fold runs unbounded, so it stays opt-in and the caller keeps the mark.
  if command -v timeout >/dev/null 2>&1; then
    timeout "${DISCHARGE_FOLD_TIMEOUT:-20}" \
      env DISCHARGE_TRANSCRIPT="$transcript" sh -c "$DISCHARGE_FOLD_CMD" 2>/dev/null
    return 0
  fi
  env DISCHARGE_TRANSCRIPT="$transcript" sh -c "$DISCHARGE_FOLD_CMD" 2>/dev/null
}

_main() {
  local event="$_event" transcript session_id short body distilled
  local -a task_ids=()

  [ "$(hook_event_stop_is_reentrant "$event")" = "no" ] || exit 0

  transcript="$(hook_event_transcript_path "$event")"
  [ -n "$transcript" ] && [ -r "$transcript" ] || exit 0

  # Resolution needs no mapping table and no inference: a session that called
  # task_update or task_complete named the task in the call. Claiming at the
  # END is a report about what happened; claiming at the start would be a
  # prediction, and predictions are what agents skip.
  while IFS= read -r id; do
    [ -n "$id" ] && task_ids+=("$id")
  done < <(transcript_task_ids "$transcript" | head -n "$DISCHARGE_MAX_TASKS")

  # No task touched is the common case for a chat or exploration session. Say
  # nothing: a hook that comments on every exit is a hook people turn off.
  [ "${#task_ids[@]}" -gt 0 ] || exit 0

  session_id="$(hook_event_session_id "$event")"
  short="${session_id:0:8}"
  [ -n "$short" ] || short="unknown"

  body="$(_summarize "$transcript")"
  distilled="$(_distill "$transcript")"
  [ -n "$distilled" ] && body="$distilled"$'\n\n'"$body"

  local wrote=0 id
  for id in "${task_ids[@]}"; do
    if dossier_task_update "$id" "[session ${short}] ${body}" "hook:${HOOK_NAME}"; then
      wrote=$((wrote + 1))
      continue
    fi
    _warn "could not append a discharge to ${id}"
  done

  [ "$wrote" -gt 0 ] || exit 0
  printf 'Recorded what this session did against %s dossier task(s).\n' "$wrote"
}

if [ "${1:-}" = "--no-timeout" ]; then
  shift
  _main "$@" || exit 0
  exit 0
fi

# A Stop hook runs between a person and their prompt returning. It may never be
# the reason that wait is longer, so the whole body is bounded where it can be.
#
# The `command -v` guard is not defensive padding: `timeout` is GNU coreutils and
# is ABSENT on a stock macOS, so an unguarded `timeout ... || exit 0` degrades to
# a hook that silently never runs its body — which looks exactly like a hook
# that ran and found nothing.
if command -v timeout >/dev/null 2>&1; then
  timeout 10 bash "$0" --no-timeout "$@" <<<"$_event" || exit 0
  exit 0
fi
_main "$@" || exit 0
exit 0
