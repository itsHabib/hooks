#!/usr/bin/env bash
# PostToolUse hook for mcp__ship__ship dispatch — append a dossier task note.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/ship-task-lookup.sh
source "$ROOT_DIR/lib/ship-task-lookup.sh"

DOSSIER="${DOSSIER:-dossier}"

hook__tool_output_json() {
  local event="$1"
  jq -c '
    if (.tool_output | type) == "string" then
      (.tool_output | try fromjson catch {})
    else
      (.tool_output // {})
    end
  ' <<<"$event"
}

hook__workflow_run_id() {
  local output_json="$1"
  jq -r '.workflowRunId // .id // empty' <<<"$output_json"
}

main() {
  local event output_json run_id doc_path workdir tool_name

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

  "$DOSSIER" task_update \
    --id "$SHIP_TASK_ID" \
    --note "ship run ${run_id} dispatched against ${doc_path}" \
    --actor "hook:ship-dispatch" \
    >/dev/null 2>&1 || true
}

main "$@"
