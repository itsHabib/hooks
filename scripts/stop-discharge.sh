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
# is the first check for that reason, before anything can cost time. Both
# envelope shapes are matched so the Codex camelCase form takes the fast path
# too instead of falling through to the jq check every time.
[[ $_event == *'"stop_hook_active":true'* || $_event == *'"stopHookActive":true'* ]] && exit 0

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

# The whole hook is bounded by this many seconds (see the tail of this file).
# The optional fold below is the one step that can run long, so its own budget
# is clamped to leave room for the dossier write that follows it. A fold that
# outlives the hook takes the mark with it, which is the one thing that must
# not happen — the mark is the point, the fold is the garnish.
DISCHARGE_HOOK_TIMEOUT=10

# Stop fires after EVERY assistant response, not only at session close, and
# each time it sees the cumulative transcript. Without a record of what this
# session already discharged, a long session would append the same note to the
# same task once per turn. One line per task id, under a per-session file.
DISCHARGE_STATE_DIR="${HOOKS_STATE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/hooks}/stop-discharge"

_warn() {
  printf '%s: %s\n' "$HOOK_NAME" "$*" >&2
}

# _join renders stdin lines as one comma-separated line, with $HOME collapsed to
# `~`. Note `paste -sd', '` does NOT do this: paste treats its delimiter string
# as a LIST to cycle through, so a two-character delimiter alternates between
# them and produces "a,b c,d".
_join() {
  sed "s|^${HOME:-/tmp}|~|" | tr '\n' '\001' | sed 's/\x01$//; s/\x01/, /g'
}

# _summarize renders the mechanical facts. Nothing here depends on the model
# having cooperated, which is the whole point: these are true whether or not the
# session remembered to say anything.
_summarize() {
  local transcript="$1" turns files prs written_count listed
  turns="$(transcript_turn_count "$transcript")"
  files="$(transcript_files_written "$transcript")"
  prs="$(transcript_pr_urls "$transcript")"

  printf 'After %s assistant turns.' "$turns"

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
  local transcript="$1" budget
  [ -n "${DISCHARGE_FOLD_CMD:-}" ] || return 0
  # Same absent-timeout caveat as the tail of this file. Without the binary the
  # fold runs unbounded, so it stays opt-in and the caller keeps the mark.
  if command -v timeout >/dev/null 2>&1; then
    budget="$(_fold_budget)"
    timeout "$budget" \
      env DISCHARGE_TRANSCRIPT="$transcript" sh -c "$DISCHARGE_FOLD_CMD" 2>/dev/null
    return 0
  fi
  env DISCHARGE_TRANSCRIPT="$transcript" sh -c "$DISCHARGE_FOLD_CMD" 2>/dev/null
}

# _fold_budget prints the fold's deadline in seconds: the configured value,
# clamped below the hook's own deadline so the write after it still runs.
_fold_budget() {
  local want="${DISCHARGE_FOLD_TIMEOUT:-5}" ceiling=$((DISCHARGE_HOOK_TIMEOUT - 3))
  [[ $want =~ ^[0-9]+$ ]] || want="$ceiling"
  [ "$want" -le "$ceiling" ] || want="$ceiling"
  printf '%s' "$want"
}

# _already_discharged reports whether this session has already written a
# discharge to $task_id (exit 0) or still owes one (exit 1). A session with no
# id cannot be tracked and is treated as owing.
_already_discharged() {
  local session_id="$1" task_id="$2"
  [ -n "$session_id" ] || return 1
  [ -r "$DISCHARGE_STATE_DIR/$session_id" ] || return 1
  grep -qxF "$task_id" "$DISCHARGE_STATE_DIR/$session_id"
}

_remember_discharged() {
  local session_id="$1" task_id="$2"
  [ -n "$session_id" ] || return 0
  mkdir -p "$DISCHARGE_STATE_DIR" 2>/dev/null || return 0
  printf '%s\n' "$task_id" >>"$DISCHARGE_STATE_DIR/$session_id" 2>/dev/null || true
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

  # Each task gets one discharge per session. Later Stops in the same session
  # see the same task ids again and must not write again.
  local -a owed=() id
  for id in "${task_ids[@]}"; do
    _already_discharged "$session_id" "$id" || owed+=("$id")
  done
  [ "${#owed[@]}" -gt 0 ] || exit 0

  body="$(_summarize "$transcript")"
  distilled="$(_distill "$transcript")"
  [ -n "$distilled" ] && body="$distilled"$'\n\n'"$body"

  local wrote=0
  for id in "${owed[@]}"; do
    if dossier_task_update "$id" "[session ${short}] ${body}" "hook:${HOOK_NAME}"; then
      _remember_discharged "$session_id" "$id"
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
  timeout "$DISCHARGE_HOOK_TIMEOUT" bash "$0" --no-timeout "$@" <<<"$_event" || exit 0
  exit 0
fi
_main "$@" || exit 0
exit 0
