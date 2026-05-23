#!/usr/bin/env bash
# PostToolUse hook for mcp__ship__get_workflow_run — link terminal runs to dossier tasks.

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

hook__is_terminal_status() {
  local status="$1"
  case "$status" in
    succeeded | failed | cancelled) return 0 ;;
    *) return 1 ;;
  esac
}

main() {
  local event output_json run_id status doc_path workdir tool_name

  event="$(cat)"
  tool_name="$(jq -r '.tool_name // empty' <<<"$event")"
  [[ "$tool_name" == "mcp__ship__get_workflow_run" ]] || return 0

  output_json="$(hook__tool_output_json "$event")"
  run_id="$(hook__workflow_run_id "$output_json")"
  status="$(jq -r '.status // empty' <<<"$output_json")"
  doc_path="$(jq -r '.docPath // empty' <<<"$output_json")"
  workdir="$(jq -r '.worktree.path // empty' <<<"$output_json")"

  [[ -n "$run_id" && -n "$status" && -n "$doc_path" ]] || return 0
  hook__is_terminal_status "$status" || return 0

  ship_task_lookup "$doc_path" "$workdir" || return 0
  [[ -n "$SHIP_PROJECT_SLUG" ]] || return 0

  "$DOSSIER" artifact_link \
    --project "$SHIP_PROJECT_SLUG" \
    --task "$SHIP_TASK_ID" \
    --kind run \
    --ref "$run_id" \
    --label "ship workflow run — ${status}" \
    --actor "hook:ship-getrun" \
    >/dev/null 2>&1 || true

  case "$status" in
    failed | cancelled)
      "$DOSSIER" task_update \
        --id "$SHIP_TASK_ID" \
        --note "ship run ${run_id} reached terminal: ${status}" \
        --actor "hook:ship-getrun" \
        >/dev/null 2>&1 || true
      ;;
  esac
}

main "$@"
