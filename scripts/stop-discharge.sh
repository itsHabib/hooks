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
# shellcheck source=lib/discharge.sh
source "$ROOT_DIR/lib/discharge.sh"

_warn() {
  printf '%s: %s\n' "$HOOK_NAME" "$*" >&2
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

  # The "owes a discharge" rule lives in lib/discharge.sh so that the sweep,
  # which counts what this hook failed to write, applies the identical test.
  while IFS= read -r id; do
    [ -n "$id" ] && task_ids+=("$id")
  done < <(discharge_owed_task_ids "$transcript")

  # No task touched is the common case for a chat or exploration session. Say
  # nothing: a hook that comments on every exit is a hook people turn off.
  [ "${#task_ids[@]}" -gt 0 ] || exit 0

  session_id="$(hook_event_session_id "$event")"
  short="$(discharge_session_short "$session_id")"
  [ -n "$short" ] || short="unknown"

  body="$(discharge_summarize "$transcript")"
  distilled="$(_distill "$transcript")"
  [ -n "$distilled" ] && body="$distilled"$'\n\n'"$body"

  local wrote=0 id
  for id in "${task_ids[@]}"; do
    if dossier_task_update "$id" "$(discharge_marker "$short") ${body}" "hook:${HOOK_NAME}"; then
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
