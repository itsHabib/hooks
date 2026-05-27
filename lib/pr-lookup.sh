#!/usr/bin/env bash
# Find the dossier task linked to a pull request body.
# Populated by gh-pr-merge-hook (wave-2).

set -euo pipefail

# shellcheck source=lib/dossier-cli.sh
if [[ -z "${_DOSSIER_CLI_LOADED:-}" ]]; then
  _lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=/dev/null
  source "$_lib_dir/dossier-cli.sh"
  _DOSSIER_CLI_LOADED=1
fi

# shellcheck disable=SC2317
_pr_lookup_stub() {
  :
}

# Usage: pr_lookup_task <pr_body> [project_slug]
# On success prints: project_slug<TAB>task_id<TAB>task_slug
# Returns 0 when a linked task is found, 1 otherwise.
pr_lookup_task() {
  local pr_body="$1"
  local project_hint="${2:-}"
  local task_slug=""
  local task_id=""
  local project_slug=""
  local tasks_json=""

  # Backtick form is held in a variable so the literal `s aren't interpreted
  # as command substitution inside the `[[ =~ ]]` pattern position.
  local _backtick_re='Closes[[:space:]]+task[[:space:]]+`([a-zA-Z0-9_-]+)`'

  if [[ "$pr_body" =~ Closes[[:space:]]+task[[:space:]]+(tsk_[A-Z0-9]+) ]]; then
    task_id="${BASH_REMATCH[1]}"
  elif [[ "$pr_body" =~ task:[[:space:]]*(tsk_[A-Z0-9]+) ]]; then
    task_id="${BASH_REMATCH[1]}"
  elif [[ "$pr_body" =~ $_backtick_re ]]; then
    local cap="${BASH_REMATCH[1]}"
    if [[ "$cap" =~ ^tsk_[A-Z0-9]+$ ]]; then
      task_id="$cap"
    else
      task_slug="$cap"
    fi
  elif [[ "$pr_body" =~ Closes[[:space:]]+task/([a-zA-Z0-9_-]+) ]]; then
    task_slug="${BASH_REMATCH[1]}"
  else
    return 1
  fi

  if [[ -n "$task_id" ]]; then
    if ! tasks_json="$(dossier_task_list "" 100)"; then
      return 1
    fi
    project_slug="$(printf '%s' "$tasks_json" | jq -r --arg id "$task_id" '
      .[] | select(.id == $id) | .project_slug
    ' | head -n 1)"
    task_slug="$(printf '%s' "$tasks_json" | jq -r --arg id "$task_id" '
      .[] | select(.id == $id) | .slug
    ' | head -n 1)"
    if [[ -z "$project_slug" || "$project_slug" == "null" ]]; then
      return 1
    fi
    printf '%s\t%s\t%s\n' "$project_slug" "$task_id" "$task_slug"
    return 0
  fi

  if [[ -n "$project_hint" ]]; then
    if ! tasks_json="$(dossier_task_list "$project_hint" 100)"; then
      return 1
    fi
    task_id="$(printf '%s' "$tasks_json" | jq -r --arg slug "$task_slug" '
      .[] | select(.slug == $slug) | .id
    ' | head -n 1)"
    if [[ -n "$task_id" && "$task_id" != "null" ]]; then
      printf '%s\t%s\t%s\n' "$project_hint" "$task_id" "$task_slug"
      return 0
    fi
  fi

  if ! tasks_json="$(dossier_task_list "" 100)"; then
    return 1
  fi
  task_id="$(printf '%s' "$tasks_json" | jq -r --arg slug "$task_slug" '
    .[] | select(.slug == $slug) | .id
  ' | head -n 1)"
  project_slug="$(printf '%s' "$tasks_json" | jq -r --arg slug "$task_slug" '
    .[] | select(.slug == $slug) | .project_slug
  ' | head -n 1)"
  if [[ -z "$task_id" || "$task_id" == "null" || -z "$project_slug" || "$project_slug" == "null" ]]; then
    return 1
  fi

  printf '%s\t%s\t%s\n' "$project_slug" "$task_id" "$task_slug"
}
