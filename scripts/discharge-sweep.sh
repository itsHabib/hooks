#!/usr/bin/env bash
# Operator-invoked sweep: find sessions that owed a discharge and never paid it.
set -euo pipefail

HOOK_NAME="discharge-sweep"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/dossier-cli.sh
source "$ROOT_DIR/lib/dossier-cli.sh"
# shellcheck source=lib/transcript.sh
source "$ROOT_DIR/lib/transcript.sh"
# shellcheck source=lib/discharge.sh
source "$ROOT_DIR/lib/discharge.sh"

ACTOR="hook:discharge-sweep"

# Where Claude Code keeps session transcripts, one `<session-id>.jsonl` per
# session, under a per-working-directory slug.
TRANSCRIPT_ROOT="${DISCHARGE_TRANSCRIPT_ROOT:-$HOME/.claude/projects}"
CORPUS="${DOSSIER_CORPUS:-$HOME/dev/dossier-state}"

# A transcript still being appended to belongs to a session that may not be
# over. Sixty minutes is well past any turn's think time and well short of the
# gap between working sessions.
QUIET_MINUTES=60

# Bound the backlog. The transcript directory holds every session ever run, and
# the first useful question is about recent behaviour, not about 2026-05.
SINCE_DAYS=14

WRITE=0

_usage() {
  cat <<'EOF'
Usage: discharge-sweep.sh [--quiet-minutes N] [--since-days N] [--write] [--dry-run]

Find sessions that touched dossier tasks but recorded no discharge against
them, and optionally backfill one from the transcript.

Two jobs, one pass:
  * a safety net — a session whose Stop hook never fired (usage-limit hold,
    crash, kill -9) is indistinguishable at the task from a session that
    concluded nothing. This is what tells them apart.
  * the measurement — the coverage line is the discharge rate GATE B needs,
    and it is a read over data that already exists.

Reports by default. Unlike sweep-merged, whose writes reconcile against an
external truth (GitHub says MERGED), a backfill here is a bulk historical
write into a note log, so it is opt-in via --write.

Exits non-zero only on infrastructure errors.
EOF
}

_die_infra() {
  printf '%s: %s\n' "$HOOK_NAME" "$*" >&2
  exit 1
}

# _sessions prints the transcripts worth considering, newest last.
#
# `subagents/` holds workflow and subagent journals. Those are not sessions:
# they have no Stop hook, no session id of their own in the marker sense, and
# counting them would deflate every coverage number this script prints.
_sessions() {
  [ -d "$TRANSCRIPT_ROOT" ] || return 0
  find "$TRANSCRIPT_ROOT" \
    -type f \
    -name '*.jsonl' \
    -not -path '*/subagents/*' \
    -mmin "+$QUIET_MINUTES" \
    -mtime "-$SINCE_DAYS" \
    2>/dev/null
}

_last_active() {
  local path="$1"
  # BSD stat (macOS). GNU stat uses -c; this repo's hooks run on the operator's
  # Mac and CI, so try BSD first and fall back rather than probing uname.
  stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$path" 2>/dev/null \
    || stat -c '%y' "$path" 2>/dev/null | cut -c1-16
}

# _backfill writes one discharge, attributed to the sweep rather than to the
# hook. The distinction is the point: a sweep-attributed note means the session
# ended without discharging, which is itself the finding.
_backfill() {
  local task_id="$1" short="$2" body="$3"
  dossier_task_update "$task_id" "[session ${short}] (backfilled by sweep) ${body}" "$ACTOR"
}

_main() {
  local transcript short body row
  local -a summary=()
  local owed=0 covered=0 gaps=0 backfilled=0 failed=0 sessions_seen=0

  command -v jq >/dev/null 2>&1 || _die_infra "jq not found"
  [ -d "$CORPUS/projects" ] || _die_infra "no dossier corpus at $CORPUS"

  while IFS= read -r transcript; do
    [ -n "$transcript" ] || continue

    local -a task_ids=()
    while IFS= read -r id; do
      [ -n "$id" ] && task_ids+=("$id")
    done < <(discharge_owed_task_ids "$transcript")

    # A session that named no task owes nothing — the same rule the hook
    # applies, from the same function, so the two cannot drift apart.
    [ "${#task_ids[@]}" -gt 0 ] || continue

    sessions_seen=$((sessions_seen + 1))
    short="$(discharge_session_short "$transcript")"
    body=""

    local id state
    for id in "${task_ids[@]}"; do
      owed=$((owed + 1))

      if discharge_recorded "$CORPUS" "$id" "$short"; then
        covered=$((covered + 1))
        state="discharged"
      elif [ "$WRITE" -eq 0 ]; then
        gaps=$((gaps + 1))
        state="gap"
      else
        # Summarizing costs a full jq pass over a transcript that can be
        # megabytes, so it is paid once per session and only when a write is
        # actually going to happen.
        [ -n "$body" ] || body="$(discharge_summarize "$transcript")"
        if _backfill "$id" "$short" "$body"; then
          backfilled=$((backfilled + 1))
          state="backfilled"
        else
          failed=$((failed + 1))
          state="dossier-update-failed"
        fi
      fi

      summary+=( "$(printf '%s | %s | %s | %s' \
        "$short" "$id" "$(_last_active "$transcript")" "$state")" )
    done
  done < <(_sessions)

  printf 'session | task | last-active | state\n'
  if [ "${#summary[@]}" -eq 0 ]; then
    printf '(no session in the last %s days both quiet and holding a task)\n' "$SINCE_DAYS"
    return 0
  fi
  printf '%s\n' "${summary[@]}"

  # The coverage line is the deliverable. `owed` counts session-task pairs a
  # discharge was due on; `covered` counts the ones that have one.
  local pct=0
  [ "$owed" -gt 0 ] && pct=$(( covered * 100 / owed ))
  printf '\n%s sessions owed a discharge on %s task(s); %s recorded (%s%%).\n' \
    "$sessions_seen" "$owed" "$covered" "$pct"
  [ "$gaps" -gt 0 ] && printf '%s gap(s) — re-run with --write to backfill.\n' "$gaps"
  [ "$backfilled" -gt 0 ] && printf '%s backfilled.\n' "$backfilled"

  # Contract, matching sweep-merged: a failed dossier write is an
  # infrastructure error and must not exit green with the rows buried.
  if [ "$failed" -gt 0 ]; then
    printf '%s: %s dossier write failure(s) — see rows above\n' "$HOOK_NAME" "$failed" >&2
    return 1
  fi
  return 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --quiet-minutes)
      QUIET_MINUTES="${2:-}"
      [ -n "$QUIET_MINUTES" ] || _die_infra "--quiet-minutes needs a value"
      shift 2
      ;;
    --since-days)
      SINCE_DAYS="${2:-}"
      [ -n "$SINCE_DAYS" ] || _die_infra "--since-days needs a value"
      shift 2
      ;;
    --write)
      WRITE=1
      shift
      ;;
    --dry-run)
      # Already the default; accepted so the muscle memory from sweep-merged
      # does the harmless thing here rather than erroring.
      WRITE=0
      shift
      ;;
    -h|--help)
      _usage
      exit 0
      ;;
    *)
      _die_infra "unknown argument: $1"
      ;;
  esac
done

_main
