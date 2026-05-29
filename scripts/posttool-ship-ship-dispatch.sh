#!/usr/bin/env bash
# PostToolUse hook for mcp__ship__ship dispatch — append a dossier task note,
# and (cloud runs only) ferry the Cursor agent watch URL into dossier as a
# kind:url artifact so the corpus has a clickable handle on the live run.

set -uo pipefail

HOOK_NAME="posttool-ship-ship-dispatch"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/ship-task-lookup.sh
source "$ROOT_DIR/lib/ship-task-lookup.sh"

DOSSIER="${DOSSIER:-dossier}"

hook__tool_output_json() {
  local event="$1"
  # Claude Code's actual PostToolUse event uses `.tool_response` (see the
  # gh-pr-merge / gh-pr-create hooks in this repo, which already handle
  # both). `.tool_output` is the alternate name some specs use; accept
  # either so the hook is robust regardless of which shape lands. Either
  # may be a JSON-encoded string OR an object.
  jq -c '
    (.tool_response // .tool_output // {}) as $raw
    | if ($raw | type) == "string" then ($raw | try fromjson catch {})
      else $raw
      end
  ' <<<"$event"
}

hook__workflow_run_id() {
  local output_json="$1"
  jq -r '.workflowRunId // .id // empty' <<<"$output_json"
}

# True when the dispatch is a cursor *cloud* run. Only cloud runs spawn a
# `bc-` background agent (and therefore a watch URL); local runs must skip
# the events.ndjson poll entirely so they pay zero latency.
hook__is_cloud_run() {
  local event="$1"
  jq -e '(.tool_input.runtime == "cloud") or (.tool_input.cloud != null)' \
    <<<"$event" >/dev/null 2>&1
}

# Where ship persists per-run state:
#   Windows (Git Bash): $APPDATA/ship/runs
#   POSIX:              ${XDG_CONFIG_HOME:-$HOME/.config}/ship/runs
# SHIP_RUNS_DIR overrides both (tests point it at a fixture dir).
hook__ship_runs_dir() {
  if [[ -n "${SHIP_RUNS_DIR:-}" ]]; then
    printf '%s' "$SHIP_RUNS_DIR"
  elif [[ -n "${APPDATA:-}" ]]; then
    printf '%s/ship/runs' "$APPDATA"
  else
    printf '%s/ship/runs' "${XDG_CONFIG_HOME:-$HOME/.config}"
  fi
}

# Resolve the Cursor agent watch URL for a cloud run. The `bc-` agent id
# lands in the run's events.ndjson — empirically in the very first `status`
# event's `agent_id`. Poll briefly (bounded ≈1.75s) to cover the race
# between the ship tool returning and that first event being written; the
# cap keeps a cloud dispatch from blocking the agent past the hook's
# settings.json `timeout: 5`. Prints the URL on success; non-zero otherwise.
#
# Forward-compat: once ship's `expose-cursor-watch-url` lands, the watch URL
# arrives in the tool response and this poll can be dropped.
hook__cursor_watch_url() {
  local run_id="$1"
  local events_file bc_id attempt
  events_file="$(hook__ship_runs_dir)/$run_id/events.ndjson"
  for ((attempt = 1; attempt <= 8; attempt++)); do
    if [[ -f "$events_file" ]]; then
      bc_id="$(grep -oiE 'bc-[a-f0-9-]{8,}' "$events_file" 2>/dev/null | head -n 1 || true)"
      if [[ -n "$bc_id" ]]; then
        printf 'https://cursor.com/agents/%s' "$bc_id"
        return 0
      fi
    fi
    ((attempt < 8)) && sleep 0.25
  done
  return 1
}

main() {
  local event output_json run_id doc_path workdir tool_name watch_url

  event="$(cat)"
  # Validate JSON upfront so malformed/truncated payloads exit clean (silent)
  # rather than triggering jq parser errors on every later read.
  jq -e '.' <<<"$event" >/dev/null 2>&1 || return 0
  tool_name="$(jq -r '.tool_name // empty' <<<"$event")"
  [[ "$tool_name" == "mcp__ship__ship" ]] || return 0

  output_json="$(hook__tool_output_json "$event")"
  run_id="$(hook__workflow_run_id "$output_json")"
  doc_path="$(jq -r '.tool_input.docPath // empty' <<<"$event")"
  workdir="$(jq -r '.tool_input.workdir // empty' <<<"$event")"

  [[ -n "$run_id" && -n "$doc_path" ]] || return 0
  ship_task_lookup "$doc_path" "$workdir" || return 0

  dossier_task_update \
    "$SHIP_TASK_ID" \
    "ship run ${run_id} dispatched against ${doc_path}" \
    "hook:ship-dispatch" \
    2>/dev/null || true

  # Cloud runs only: link the Cursor agent watch URL as a kind:url artifact.
  # Guarded on a resolved project slug (artifact_link needs it) and the cloud
  # signal (so local runs never poll). artifact_link is idempotent, so a
  # re-fired dispatch is a no-op on the dossier side.
  if [[ -n "${SHIP_PROJECT_SLUG:-}" ]] && hook__is_cloud_run "$event"; then
    if watch_url="$(hook__cursor_watch_url "$run_id")"; then
      dossier_artifact_link \
        "$SHIP_PROJECT_SLUG" \
        "$SHIP_TASK_ID" \
        url \
        "$watch_url" \
        "Cursor agent watch URL" \
        "hook:ship-dispatch" \
        2>/dev/null || true
    fi
  fi
}

main "$@"
