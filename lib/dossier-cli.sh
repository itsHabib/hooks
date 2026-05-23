#!/usr/bin/env bash
# Shared dossier CLI wrapper for integration-layer hooks.
# Populated by gh-pr-merge-hook (wave-2).

set -euo pipefail

: "${DOSSIER_BIN:=dossier}"

_dossier_cli_stub() {
  :
}

_dossier_corpus_args() {
  if [[ -n "${DOSSIER_CORPUS:-}" ]]; then
    printf '%s\0' --corpus "$DOSSIER_CORPUS"
  fi
}

# Usage: dossier_task_complete <id> [note] [actor]
# Returns 0 on success (including dossier idempotent no-op). Non-zero on failure.
dossier_task_complete() {
  local id="$1"
  local note="${2:-}"
  local actor="${3:-}"
  local -a cmd=( "$DOSSIER_BIN" )
  local arg

  while IFS= read -r -d '' arg; do
    cmd+=( "$arg" )
  done < <(_dossier_corpus_args)

  cmd+=( task_complete --id "$id" )
  [[ -n "$note" ]] && cmd+=( --note "$note" )
  [[ -n "$actor" ]] && cmd+=( --actor "$actor" )

  "${cmd[@]}" >/dev/null
}

# Usage: dossier_artifact_link <project> <task> <kind> <ref> [label] [actor]
# Returns 0 on success (including dossier idempotent no-op). Non-zero on failure.
dossier_artifact_link() {
  local project="$1"
  local task="$2"
  local kind="$3"
  local ref="$4"
  local label="${5:-}"
  local actor="${6:-}"
  local -a cmd=( "$DOSSIER_BIN" )
  local arg

  while IFS= read -r -d '' arg; do
    cmd+=( "$arg" )
  done < <(_dossier_corpus_args)

  cmd+=(
    artifact_link
    --project "$project"
    --task "$task"
    --kind "$kind"
    --ref "$ref"
  )
  [[ -n "$label" ]] && cmd+=( --label "$label" )
  [[ -n "$actor" ]] && cmd+=( --actor "$actor" )

  "${cmd[@]}" >/dev/null
}

# Usage: dossier_task_list [project_slug] [limit]
# Prints matching tasks as a JSON array on stdout.
dossier_task_list() {
  local project="${1:-}"
  local limit="${2:-}"
  local -a cmd=( "$DOSSIER_BIN" )
  local arg

  while IFS= read -r -d '' arg; do
    cmd+=( "$arg" )
  done < <(_dossier_corpus_args)

  cmd+=( task_list )
  [[ -n "$limit" ]] && cmd+=( --limit "$limit" )
  [[ -n "$project" ]] && cmd+=( --project "$project" )

  "${cmd[@]}"
}
