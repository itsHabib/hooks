#!/usr/bin/env bash
# PostToolUse hook: auto artifact_link on gh pr create when PR body links a dossier task.
set -uo pipefail

HOOK_NAME="posttool-gh-pr-create"
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

_is_gh_pr_create_command() {
  local command="$1"
  # Match `gh pr create` at a real command boundary — start-of-string OR
  # after a separator (`;`, `&&`, `||`, `|`, `&`), optionally with a
  # leading env-var assignment (`GH_TOKEN=… gh pr create …`) or `cd …`.
  # The hook is idempotent at the dossier layer, so a tolerable false-
  # positive rate trades off against missing common workflows like
  # `cd repo && gh pr create …`.
  [[ "$command" =~ (^|[&|;])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$) ]]
}

_extract_pr_from_create_output() {
  local output="$1"
  local pr="" pr_url=""

  if [[ "$output" =~ (https?://[^[:space:]]+/pull/([0-9]+)) ]]; then
    pr_url="${BASH_REMATCH[1]}"
    pr="${BASH_REMATCH[2]}"
  elif [[ "$output" =~ [Pp]ull[[:space:]]+[Rr]equest[[:space:]]+#([0-9]+) ]]; then
    pr="${BASH_REMATCH[1]}"
  fi

  if [[ -n "$pr" ]]; then
    printf '%s\t%s' "$pr" "${pr_url:-}"
  fi
}

_create_succeeded() {
  local output="$1"
  local exit_code="$2"

  if [[ "$output" =~ https?://[^[:space:]]+/pull/[0-9]+ ]]; then
    return 0
  fi
  if [[ "$output" =~ [Pp]ull[[:space:]]+[Rr]equest[[:space:]]+#([0-9]+) ]]; then
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

_main() {
  local event tool_name command output exit_code pr pr_url project_hint
  local lookup project_slug task_id task_slug pr_body pr_title

  if ! command -v jq >/dev/null 2>&1; then
    _soft_fail "jq not found"
  fi

  event="$(_read_event)"
  tool_name="$(jq -r '.tool_name // ""' <<<"$event")"
  if [[ "$tool_name" != "Bash" ]]; then
    exit 0
  fi

  command="$(_tool_command "$event")"
  if [[ -z "$command" ]] || ! _is_gh_pr_create_command "$command"; then
    exit 0
  fi

  output="$(_tool_output "$event")"
  exit_code="$(_tool_exit_code "$event")"
  if ! _create_succeeded "$output" "$exit_code"; then
    exit 0
  fi

  if ! IFS=$'\t' read -r pr pr_url <<<"$(_extract_pr_from_create_output "$output")"; then
    exit 0
  fi
  if [[ -z "$pr" ]]; then
    exit 0
  fi

  if ! command -v gh >/dev/null 2>&1; then
    _soft_fail "gh not found"
  fi

  # Prefer the PR URL when available — `gh pr view <number>` resolves
  # against the current repo (CWD), but `gh pr create --repo foo/bar`
  # may target a different repo, so the local number can be wrong.
  # `gh pr view <url>` is repo-correct.
  local pr_ref="${pr_url:-$pr}"

  if ! pr_body="$(gh pr view "$pr_ref" --json body -q '.body' 2>/dev/null)"; then
    _soft_fail "could not fetch PR body for PR #$pr"
  fi

  if ! pr_title="$(gh pr view "$pr_ref" --json title -q '.title' 2>/dev/null)"; then
    _soft_fail "could not fetch PR title for PR #$pr"
  fi
  if [[ -z "$pr_title" || "$pr_title" == "null" ]]; then
    pr_title="PR #$pr"
  fi

  if [[ -z "$pr_url" ]]; then
    if ! pr_url="$(gh pr view "$pr" --json url -q '.url' 2>/dev/null)"; then
      _soft_fail "could not fetch PR URL for PR #$pr"
    fi
  fi
  if [[ -z "$pr_url" || "$pr_url" == "null" ]]; then
    _soft_fail "PR URL missing for PR #$pr"
  fi

  project_hint="$(_infer_project_slug || true)"
  if ! lookup="$(pr_lookup_task "$pr_body" "$project_hint")"; then
    _warn "no task linkage in PR body"
    exit 0
  fi

  IFS=$'\t' read -r project_slug task_id task_slug <<<"$lookup"

  if ! dossier_artifact_link "$project_slug" "$task_id" "pr" "$pr_url" "$pr_title" "hook:gh-pr-create"; then
    _soft_fail "artifact_link failed for PR #$pr"
  fi

  printf 'Auto-linked PR #%s to dossier task %s.\n' "$pr" "$task_slug"
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
