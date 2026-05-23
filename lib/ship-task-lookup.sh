#!/usr/bin/env bash
# Resolve spec-doc paths to dossier task identifiers.

set -euo pipefail

DOSSIER="${DOSSIER:-dossier}"

ship_task_lookup__resolve_doc_file() {
  local doc_path="$1"
  local workdir="${2:-}"

  if [[ -z "$doc_path" ]]; then
    return 1
  fi

  if [[ "$doc_path" == /* && -f "$doc_path" ]]; then
    printf '%s\n' "$doc_path"
    return 0
  fi

  if [[ -n "$workdir" && -f "${workdir%/}/$doc_path" ]]; then
    printf '%s\n' "${workdir%/}/$doc_path"
    return 0
  fi

  if [[ -f "$doc_path" ]]; then
    printf '%s\n' "$doc_path"
    return 0
  fi

  return 1
}

ship_task_lookup__project_for_task() {
  local task_id="$1"
  local task_slug="${2:-}"
  local project

  project="$(
    "$DOSSIER" task_list --limit 200 2>/dev/null \
      | jq -r --arg id "$task_id" --arg slug "$task_slug" '
          .[]
          | select(.id == $id or ($slug != "" and .slug == $slug))
          | .project
        ' \
      | head -n 1
  )" || return 1

  [[ -n "$project" ]] || return 1
  SHIP_PROJECT_SLUG="$project"
  return 0
}

ship_task_lookup__from_related_header() {
  local doc_file="$1"

  local related_line task_id task_slug
  related_line="$(grep -m1 -E '\*\*Related\*\*:' "$doc_file" 2>/dev/null || true)"
  if [[ -z "$related_line" ]]; then
    return 1
  fi

  task_id="$(sed -n 's/.*(id: `\([^`]*\)`).*/\1/p' <<<"$related_line")"
  if [[ ! "$task_id" =~ ^tsk_[A-Z0-9]+$ ]]; then
    return 1
  fi

  task_slug="$(sed -n 's/.*dossier task `\([^`]*\)`.*/\1/p' <<<"$related_line")"

  SHIP_TASK_ID="$task_id"
  SHIP_TASK_SLUG="$task_slug"
  SHIP_PROJECT_SLUG=""
  ship_task_lookup__project_for_task "$task_id" "$task_slug" || true
  return 0
}

ship_task_lookup__slug_from_doc_path() {
  local doc_path="$1"
  local base="${doc_path##*/}"
  base="${base%.md}"
  if [[ -z "$base" ]]; then
    return 1
  fi
  printf '%s\n' "$base"
}

ship_task_lookup__from_filename_slug() {
  local doc_path="$1"
  local slug task_row

  slug="$(ship_task_lookup__slug_from_doc_path "$doc_path")" || return 1

  task_row="$(
    "$DOSSIER" task_list --limit 200 2>/dev/null \
      | jq -r --arg slug "$slug" '.[] | select(.slug == $slug) | "\(.id)\t\(.project)"' \
      | head -n 1
  )" || return 1

  if [[ -z "$task_row" ]]; then
    return 1
  fi

  SHIP_TASK_ID="${task_row%%$'\t'*}"
  SHIP_PROJECT_SLUG="${task_row#*$'\t'}"
  SHIP_TASK_SLUG="$slug"
  [[ -n "$SHIP_TASK_ID" && -n "$SHIP_PROJECT_SLUG" ]] || return 1
  return 0
}

# Resolve a spec doc to dossier task metadata.
# Usage: ship_task_lookup <docPath> [workdir]
# Sets SHIP_TASK_ID, SHIP_TASK_SLUG, and SHIP_PROJECT_SLUG on success.
ship_task_lookup() {
  local doc_path="$1"
  local workdir="${2:-}"
  local doc_file=""

  SHIP_TASK_ID=""
  SHIP_TASK_SLUG=""
  SHIP_PROJECT_SLUG=""

  if doc_file="$(ship_task_lookup__resolve_doc_file "$doc_path" "$workdir" 2>/dev/null)"; then
    if ship_task_lookup__from_related_header "$doc_file"; then
      [[ -n "$SHIP_TASK_ID" ]] && return 0
    fi
  fi

  ship_task_lookup__from_filename_slug "$doc_path"
}
