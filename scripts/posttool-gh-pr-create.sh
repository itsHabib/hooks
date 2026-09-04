#!/usr/bin/env bash
# PostToolUse hook: auto artifact_link on gh pr create when PR body links a dossier task.
set -uo pipefail

# Fast path first — see the extended rationale in posttool-gate-verdict.sh.
# This hook fires on every Bash tool call but acts only on `gh pr create`, so
# the common case must reach its exit without forking: read with the builtin,
# match on the raw event text, and only then pay for lib sourcing and jq.
# Substring matching here only widens the candidate set; the authoritative
# parse below still decides.
IFS= read -r -d '' _event || true
[ -n "$_event" ] || exit 0
[[ $_event == *'"tool_name"'*'"Bash"'* ]] || exit 0
[[ $_event == *create* ]] || exit 0

HOOK_NAME="posttool-gh-pr-create"
# Pure-expansion path derivation; see posttool-gate-verdict.sh for why this
# appends `/..` instead of stripping a second path component.
HOOK_DIR="${BASH_SOURCE[0]%/*}"
[ "$HOOK_DIR" = "${BASH_SOURCE[0]}" ] && HOOK_DIR="."
ROOT_DIR="$HOOK_DIR/.."

# shellcheck source=lib/dossier-cli.sh
source "$ROOT_DIR/lib/dossier-cli.sh"
# shellcheck source=lib/pr-lookup.sh
source "$ROOT_DIR/lib/pr-lookup.sh"
# shellcheck source=lib/hook-event.sh
source "$ROOT_DIR/lib/hook-event.sh"

_warn() {
  printf '%s: %s\n' "$HOOK_NAME" "$*" >&2
}

_soft_fail() {
  _warn "$*"
  exit 0
}

_read_event() {
  # stdin was already drained by the fast-path read at the top; validate that
  # buffer instead of re-reading a closed pipe.
  #
  # Validate JSON upfront so malformed/truncated payloads exit clean (silent)
  # rather than cascading `jq: parse error` to stderr through every later
  # read. Mirrors the same guard in the ship hooks.
  jq -e '.' <<<"$_event" >/dev/null 2>&1 || exit 0
  printf '%s' "$_event"
}

_tool_command() {
  hook_event_tool_command "$1"
}

_tool_output() {
  hook_event_tool_output "$1"
}

_tool_exit_code() {
  hook_event_tool_exit_code "$1"
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
    */hooks|*/hooks/*)
      printf '%s' "hooks"
      ;;
    */mcp-workstation|*/mcp-workstation/*)
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
    # Reminder, not an error → stdout (the model-context channel), not stderr
    # (swallowed by the dispatcher, which is why the old _warn never showed).
    printf 'Reminder: PR #%s has no dossier task linkage. If it maps to a task, add a line like: Closes task `<slug>` (or: Closes task tsk_...) so the gh-pr-merge hook auto-closes it on merge. If not, ignore.\n' "$pr"
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
  # Bounds the `gh` calls in _main. Reached only after the fast-path bail-out
  # above, so the common no-op path never pays this second bash startup.
  # stdin is already drained, so hand the event to the timed leg explicitly.
  #
  # Invoke via `bash "$0"` rather than "$0" so the timed leg does not depend on
  # the file's executable bit (a 100644 checkout would die on "Permission
  # denied"), matching posttool-gate-verdict.sh.
  timeout 5 bash "$0" --no-timeout "$@" <<<"$_event" || exit 0
else
  _main "$@" || exit 0
fi
