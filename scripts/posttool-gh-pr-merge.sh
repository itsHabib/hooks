#!/usr/bin/env bash
# PostToolUse hook: auto task_complete + commit artifact_link on gh pr merge.
set -uo pipefail

HOOK_NAME="posttool-gh-pr-merge"
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HOOK_DIR/.." && pwd)"

# shellcheck source=lib/dossier-cli.sh
source "$ROOT_DIR/lib/dossier-cli.sh"
# shellcheck source=lib/pr-lookup.sh
source "$ROOT_DIR/lib/pr-lookup.sh"

_warn() {
  printf '%s: %s\n' "$HOOK_NAME" "$*" >&2
}

_soft_fail() {
  _warn "$*"
  exit 0
}

_read_event() {
  local event=""
  event="$(cat)"
  if [[ -z "$event" ]]; then
    exit 0
  fi
  printf '%s' "$event"
}

_tool_command() {
  local event="$1"
  jq -r '
    if (.tool_input.command? // "") != "" then .tool_input.command
    elif (.tool_input | type) == "string" then .tool_input
    else empty end
  ' <<<"$event"
}

_tool_output() {
  local event="$1"
  jq -r '
    if (.tool_output? // "") != "" then .tool_output
    else
      [
        (.tool_response.stdout // ""),
        (.tool_response.stderr // "")
      ] | join("")
    end
  ' <<<"$event"
}

_tool_exit_code() {
  local event="$1"
  jq -r '
    if (.tool_response.exitCode? // null) != null then .tool_response.exitCode
    elif (.tool_response.exit_code? // null) != null then .tool_response.exit_code
    else 0 end
  ' <<<"$event"
}

_is_gh_pr_merge_command() {
  local command="$1"
  # Match only when `gh pr merge` is the actual command being run — at the
  # start of the command string (allowing leading whitespace), not embedded
  # in a quoted string, echoed arg, or piped value.
  [[ "$command" =~ ^[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$) ]]
}

_extract_pr_number() {
  local command="$1"
  local output="$2"
  local pr=""

  if [[ "$command" =~ gh[[:space:]]+pr[[:space:]]+merge[[:space:]]+([0-9]+) ]]; then
    pr="${BASH_REMATCH[1]}"
  elif [[ "$output" =~ [Mm]erged[[:space:]]+pull[[:space:]]+request[[:space:]]+#([0-9]+) ]]; then
    pr="${BASH_REMATCH[1]}"
  elif [[ "$output" =~ pull[[:space:]]+request[[:space:]]+#([0-9]+)[[:space:]]+merged ]]; then
    pr="${BASH_REMATCH[1]}"
  fi

  [[ -n "$pr" ]] && printf '%s' "$pr"
}

_merge_succeeded() {
  local output="$1"
  local exit_code="$2"

  if [[ "$output" =~ [Mm]erged[[:space:]]+pull[[:space:]]+request[[:space:]]+#([0-9]+) ]]; then
    return 0
  fi
  if [[ "$output" =~ pull[[:space:]]+request[[:space:]]+#([0-9]+)[[:space:]]+merged ]]; then
    return 0
  fi
  if [[ "$output" =~ GraphQL:|[Ee]rror|[Ff]ailed ]]; then
    return 1
  fi
  [[ "$exit_code" -eq 0 ]]
}

_infer_project_slug() {
  if [[ -n "${DOSSIER_PROJECT:-}" ]]; then
    printf '%s' "$DOSSIER_PROJECT"
    return 0
  fi

  local root=""
  root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "$root" ]]; then
    return 0
  fi

  case "$root" in
    */hooks|*/hooks/*|*/mcp-workstation|*/mcp-workstation/*)
      printf '%s' "mcp-workstation"
      ;;
    */dossier|*/dossier/*)
      printf '%s' "dossier"
      ;;
    */ship|*/ship/*)
      printf '%s' "ship"
      ;;
    */huddle|*/huddle/*)
      printf '%s' "huddle"
      ;;
    *)
      basename "$root"
      ;;
  esac
}

_short_sha() {
  local sha="$1"
  printf '%s' "${sha:0:7}"
}

_main() {
  local event tool_name command output exit_code pr merge_sha project_hint
  local lookup project_slug task_id task_slug note label short_sha

  if ! command -v jq >/dev/null 2>&1; then
    _soft_fail "jq not found"
  fi

  event="$(_read_event)"
  tool_name="$(jq -r '.tool_name // ""' <<<"$event")"
  if [[ "$tool_name" != "Bash" ]]; then
    exit 0
  fi

  command="$(_tool_command "$event")"
  if [[ -z "$command" ]] || ! _is_gh_pr_merge_command "$command"; then
    exit 0
  fi

  output="$(_tool_output "$event")"
  exit_code="$(_tool_exit_code "$event")"
  if ! _merge_succeeded "$output" "$exit_code"; then
    exit 0
  fi

  pr="$(_extract_pr_number "$command" "$output")"
  if [[ -z "$pr" ]]; then
    _soft_fail "could not determine PR number after merge"
  fi

  if ! command -v gh >/dev/null 2>&1; then
    _soft_fail "gh not found"
  fi

  if ! merge_sha="$(gh pr view "$pr" --json mergeCommit -q '.mergeCommit.oid' 2>/dev/null)"; then
    _soft_fail "could not fetch merge commit for PR #$pr"
  fi
  if [[ -z "$merge_sha" || "$merge_sha" == "null" ]]; then
    _soft_fail "merge commit missing for PR #$pr"
  fi

  local pr_body=""
  if ! pr_body="$(gh pr view "$pr" --json body -q '.body' 2>/dev/null)"; then
    _soft_fail "could not fetch PR body for PR #$pr"
  fi

  project_hint="$(_infer_project_slug || true)"
  if ! lookup="$(pr_lookup_task "$pr_body" "$project_hint")"; then
    _warn "no task linkage found for PR #$pr"
    exit 0
  fi

  IFS=$'\t' read -r project_slug task_id task_slug <<<"$lookup"
  short_sha="$(_short_sha "$merge_sha")"
  note="merged in $merge_sha (PR #$pr)"
  label="PR #$pr merge commit on main"

  if ! dossier_task_complete "$task_id" "$note" "hook:gh-pr-merge"; then
    _soft_fail "task_complete failed for $task_id"
  fi

  if ! dossier_artifact_link "$project_slug" "$task_id" "commit" "$merge_sha" "$label" "hook:gh-pr-merge"; then
    _soft_fail "artifact_link failed for PR #$pr"
  fi

  printf 'Auto-closed dossier task %s on PR #%s merge (sha: %s).\nCommit linked.\n' \
    "$task_slug" "$pr" "$short_sha"
}

if [[ "${1:-}" == "--no-timeout" ]]; then
  shift
  _main "$@" || exit 0
  exit 0
fi

if command -v timeout >/dev/null 2>&1; then
  timeout 5 "$0" --no-timeout "$@" || exit 0
else
  _main "$@" || exit 0
fi
