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
  # Validate JSON upfront so malformed/truncated payloads exit clean (silent)
  # rather than cascading `jq: parse error` to stderr through every later
  # read. Mirrors the same guard in the ship hooks.
  jq -e '.' <<<"$event" >/dev/null 2>&1 || exit 0
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

_short_sha() {
  local sha="$1"
  printf '%s' "${sha:0:7}"
}

# The authorized merge always carries `--match-head-commit <sha>` (the
# pretool-guard rejects any merge without it), so the head gate judged is on
# the command line. This is the join key to the verdict artifact.
_extract_head_sha() {
  local command="$1"
  if [[ "$command" =~ --match-head-commit[[:space:]=]+([0-9a-fA-F]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# Resolve the authorizing verdict's art_ id by matching its meta.head_sha to
# the head sha on the merge command. Best-effort: prints nothing if no verdict
# row exists (e.g. the verdict emitter has not run for this merge) — the
# receipt still writes and stays joinable on head_sha later.
_lookup_verdict_id() {
  local project="$1"
  local head_sha="$2"
  [[ -z "$head_sha" ]] && return 0
  dossier_artifact_list "$project" "verdict" 2>/dev/null \
    | jq -r --arg h "$head_sha" \
        'map(select(.meta.head_sha == $h)) | (last // {}) | .id // empty' \
        2>/dev/null
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

  # Substrate receipt — the merge event, driver-agnostic (fires for any executor
  # that clears gate + the guard). The FK to the authorizing verdict is joined
  # on head_sha; if no verdict row exists yet the receipt still writes and stays
  # joinable later (best-effort, never blocks — this is a post-merge hook).
  local head_sha pr_url verdict_id receipt_linked=""
  local -a receipt_meta
  head_sha="$(_extract_head_sha "$command")"
  # `gh pr view --json url` already returns the canonical PR URL (lowercase
  # host, owner/repo in their real casing) — the receipt ref convention. Do
  # NOT lowercase it wholesale: that would mangle a mixed-case owner/repo.
  pr_url="$(gh pr view "$pr" --json url -q '.url' 2>/dev/null)"
  if [[ -n "$pr_url" ]]; then
    verdict_id="$(_lookup_verdict_id "$project_slug" "$head_sha")"
    receipt_meta=( "event=merge" "pr=$pr" "merge_sha=$merge_sha" )
    # Always record head_sha when known — it is the join key back to the
    # verdict. A squash/rebase merge_sha differs from head_sha, so without it a
    # receipt written before its verdict lands (P2 not run yet) can never be
    # joined; the FK id is the fast path, head_sha is the durable fallback.
    [[ -n "$head_sha" ]] && receipt_meta+=( "head_sha=$head_sha" )
    [[ -n "$verdict_id" ]] && receipt_meta+=( "verdict=$verdict_id" )
    if dossier_artifact_link "$project_slug" "$task_id" "receipt" "$pr_url" \
        "merged PR #$pr" "hook:gh-pr-merge" "${receipt_meta[@]}"; then
      receipt_linked=1
    else
      _warn "receipt link failed for PR #$pr"
    fi
  else
    _warn "could not resolve canonical PR URL for PR #$pr receipt"
  fi

  # Report only what actually happened — the commit always linked (or we
  # soft-failed above); the receipt is conditional.
  if [[ -n "$receipt_linked" ]]; then
    printf 'Auto-closed dossier task %s on PR #%s merge (sha: %s).\nCommit + receipt linked%s.\n' \
      "$task_slug" "$pr" "$short_sha" \
      "$([[ -n "${verdict_id:-}" ]] && printf ' (verdict %s)' "$verdict_id")"
  else
    printf 'Auto-closed dossier task %s on PR #%s merge (sha: %s).\nCommit linked; receipt link failed (see warnings).\n' \
      "$task_slug" "$pr" "$short_sha"
  fi
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
