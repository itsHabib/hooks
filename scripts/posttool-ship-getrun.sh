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
  # Validate JSON upfront so malformed/truncated payloads exit clean (silent)
  # rather than cascading parser errors through later reads. Mirrors the same
  # guard in posttool-ship-ship-dispatch.sh.
  jq -e '.' <<<"$event" >/dev/null 2>&1 || return 0
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

  dossier_artifact_link \
    "$SHIP_PROJECT_SLUG" \
    "$SHIP_TASK_ID" \
    run \
    "$run_id" \
    "ship workflow run — ${status}" \
    "hook:ship-getrun" \
    2>/dev/null || true

  case "$status" in
    failed | cancelled)
      dossier_task_update \
        "$SHIP_TASK_ID" \
        "ship run ${run_id} reached terminal: ${status}" \
        "hook:ship-getrun" \
        2>/dev/null || true
      ;;
  esac
}

main "$@"
