#!/usr/bin/env bash
# Operator-invoked sweep: close dossier tasks whose linked PRs merged via the web UI.
set -euo pipefail

HOOK_NAME="sweep-merged"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/dossier-cli.sh
source "$ROOT_DIR/lib/dossier-cli.sh"
# shellcheck source=lib/artifact-lookup.sh
source "$ROOT_DIR/lib/artifact-lookup.sh"
# shellcheck source=lib/pr-ref.sh
source "$ROOT_DIR/lib/pr-ref.sh"

ACTOR="hook:sweep-merged"
OPEN_STATUSES="todo,claimed,in_progress"
DRY_RUN=0

_usage() {
  cat <<'EOF'
Usage: sweep-merged.sh [--dry-run]

Reconcile open dossier tasks against web-UI-merged GitHub PRs.
Prints a summary table and exits non-zero only on infrastructure errors.
EOF
}

_die_infra() {
  printf 'sweep-merged: %s\n' "$*" >&2
  exit 1
}

_task_has_commit_artifact() {
  local project="$1"
  local task_id="$2"
  local sha="$3"
  local artifacts=""

  if ! artifacts="$(artifact_list_for_project "$project")"; then
    return 1
  fi

  jq -e --arg task "$task_id" --arg sha "$sha" '
    [.[] | select(.task == $task and .kind == "commit" and .ref == $sha)] | length > 0
  ' <<<"$artifacts" >/dev/null
}

_sweep_merged_task() {
  local project_slug="$1"
  local task_id="$2"
  local task_slug="$3"
  local pr_num="$4"
  local repo="$5"
  local merge_sha="$6"
  local task_status="$7"
  local note label action

  note="merged in $merge_sha (PR #$pr_num, swept)"
  label="PR #$pr_num merge commit (swept)"
  action="swept"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '%s | #%s | MERGED | would-sweep\n' "$task_slug" "$pr_num"
    return 0
  fi

  # Link the merge commit FIRST — the durable fact lands before any status
  # mutation. A crash between link and complete is then resumable: the task is
  # still open, the next sweep finds the artifact and skips straight to the
  # close-out instead of stranding a done-but-unlinked task.
  if _task_has_commit_artifact "$project_slug" "$task_id" "$merge_sha"; then
    action="swept-resumed"
  elif ! dossier_artifact_link "$project_slug" "$task_id" "commit" "$merge_sha" "$label" "$ACTOR"; then
    printf '%s | #%s | MERGED | dossier-link-failed\n' "$task_slug" "$pr_num"
    return 0
  fi

  # Claim only from `todo` — a claimed/in_progress task is held by another
  # actor and cross-actor claim errors by design; update/complete carry their
  # own actor attribution and proceed without stealing the claim.
  if [[ "$task_status" == "todo" ]]; then
    if ! dossier_task_claim "$task_id" "$ACTOR"; then
      printf '%s | #%s | MERGED | dossier-claim-failed\n' "$task_slug" "$pr_num"
      return 0
    fi
  fi

  if [[ "$task_status" != "in_progress" ]]; then
    if ! dossier_task_update_status "$task_id" "in_progress" "sweep-merged: advancing to in_progress" "$ACTOR"; then
      printf '%s | #%s | MERGED | dossier-update-failed\n' "$task_slug" "$pr_num"
      return 0
    fi
  fi

  if ! dossier_task_complete "$task_id" "$note" "$ACTOR"; then
    printf '%s | #%s | MERGED | dossier-complete-failed\n' "$task_slug" "$pr_num"
    return 0
  fi

  printf '%s | #%s | MERGED | %s\n' "$task_slug" "$pr_num" "$action"
}

_process_candidate() {
  local project_slug="$1"
  local task_id="$2"
  local task_slug="$3"
  local pr_url="$4"
  local task_status="$5"
  local parsed repo pr_num pr_json state merge_sha action

  if ! parsed="$(parse_github_pr_ref "$pr_url")"; then
    printf '%s | ? | ? | invalid-pr-url\n' "$task_slug"
    return 0
  fi

  IFS=$'\t' read -r repo pr_num <<<"$parsed"

  if ! pr_json="$(gh pr view "$pr_num" -R "$repo" --json state,mergeCommit 2>/dev/null)"; then
    printf '%s | #%s | ? | gh-view-failed\n' "$task_slug" "$pr_num"
    return 0
  fi

  state="$(jq -r '.state // "UNKNOWN"' <<<"$pr_json")"
  state="${state%$'\r'}"
  merge_sha="$(jq -r '.mergeCommit.oid // empty' <<<"$pr_json")"
  merge_sha="${merge_sha%$'\r'}"

  if [[ "$state" == "MERGED" ]]; then
    if [[ -z "$merge_sha" ]]; then
      printf '%s | #%s | MERGED | missing-merge-sha\n' "$task_slug" "$pr_num"
      return 0
    fi
    _sweep_merged_task "$project_slug" "$task_id" "$task_slug" "$pr_num" "$repo" "$merge_sha" "$task_status"
    return 0
  fi

  action="untouched"
  printf '%s | #%s | %s | %s\n' "$task_slug" "$pr_num" "$state" "$action"
}

_main() {
  local tasks_json artifacts_json
  local -a rows=()
  local -a summary=()
  local row project_slug task_id task_slug pr_rows pr_url line

  if ! command -v jq >/dev/null 2>&1; then
    _die_infra "jq not found"
  fi

  if ! command -v gh >/dev/null 2>&1; then
    _die_infra "gh not found"
  fi

  if ! tasks_json="$(dossier_task_list "" "" "$OPEN_STATUSES")"; then
    _die_infra "dossier task_list failed"
  fi

  if ! jq -e 'type == "array"' <<<"$tasks_json" >/dev/null 2>&1; then
    _die_infra "dossier task_list returned invalid JSON"
  fi

  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    rows+=( "$row" )
  done < <(jq -r '
    .[] | [.project_slug, .id, .slug, .status] | @tsv
  ' <<<"$tasks_json")

  local task_status
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r project_slug task_id task_slug task_status <<<"$row"
    # Windows jq emits CRLF; the stray \r rides on the last TSV field.
    task_status="${task_status%$'\r'}"

    if [[ -z "$project_slug" || "$project_slug" == "null" ]]; then
      continue
    fi

    if ! artifacts_json="$(artifact_list_for_project "$project_slug")"; then
      _die_infra "could not read artifacts for project $project_slug"
    fi

    pr_rows="$(jq -r --arg task "$task_id" '
      [.[] | select(.task == $task and .kind == "pr") | .ref] | unique | .[]
    ' <<<"$artifacts_json")"

    if [[ -z "$pr_rows" ]]; then
      continue
    fi

    while IFS= read -r pr_url; do
      pr_url="${pr_url%$'\r'}"
      [[ -z "$pr_url" ]] && continue
      line="$(_process_candidate "$project_slug" "$task_id" "$task_slug" "$pr_url" "$task_status")"
      summary+=( "$line" )
    done <<<"$pr_rows"
  done

  printf 'task_slug | PR | state | action-taken\n'
  if [[ "${#summary[@]}" -eq 0 ]]; then
    printf '(no open tasks with PR artifacts)\n'
    return 0
  fi

  printf '%s\n' "${summary[@]}"

  # Contract: exit non-zero on infrastructure errors. Rows whose action ends
  # in `-failed` (gh unreachable, dossier write failures) are exactly those —
  # cron/operators must see a failing exit, not a green sweep with buried rows.
  local failures=0
  for line in "${summary[@]}"; do
    [[ "$line" == *"-failed" ]] && failures=$((failures + 1))
  done
  if [[ "$failures" -gt 0 ]]; then
    printf 'sweep-merged: %s infrastructure failure(s) — see rows above\n' "$failures" >&2
    return 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
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
