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

# Append one tab-separated line per failed dossier call so silent fails
# leave a trail operators can `tail`. Columns:
#   ts (RFC3339)  hook_name  verb  exit_code  stderr (truncated, newlines→spaces)
#
# Destination: HOOKS_ERROR_LOG (defaults to ~/.cache/hooks-errors.log).
# Set HOOKS_ERROR_LOG to the empty string to disable — used by bats setup
# so test runs don't write to the operator's real cache.
_dossier_log_failure() {
  local verb="$1"
  local rc="$2"
  local stderr_file="$3"
  local log="${HOOKS_ERROR_LOG-$HOME/.cache/hooks-errors.log}"

  [[ -z "$log" ]] && return 0

  local hook_name="${HOOK_NAME:-unknown-hook}"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local stderr_msg=""
  if [[ -f "$stderr_file" ]]; then
    # 200-char cap keeps a runaway stderr from blowing up the log line.
    stderr_msg="$(tr '\n\t' '  ' <"$stderr_file" | head -c 200)"
  fi

  mkdir -p "$(dirname "$log")" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$ts" "$hook_name" "$verb" "$rc" "$stderr_msg" \
    >>"$log" 2>/dev/null || true
}

# Internal helper: run a dossier command, capture stderr, log failures.
# Preserves stdout (task_list needs it). Returns the underlying exit
# code so callers' existing `|| true` patterns keep working.
_dossier_run() {
  local verb="$1"
  shift
  local stderr_file rc
  stderr_file="$(mktemp 2>/dev/null \
    || printf '%s/hooks-dossier-stderr.%d.%d' "${TMPDIR:-/tmp}" "$$" "$RANDOM")"

  set +e
  "$@" 2>"$stderr_file"
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    _dossier_log_failure "$verb" "$rc" "$stderr_file"
  fi
  rm -f "$stderr_file" 2>/dev/null || true
  return $rc
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

  _dossier_run task_complete "${cmd[@]}" >/dev/null
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

  _dossier_run artifact_link "${cmd[@]}" >/dev/null
}

# Usage: dossier_task_update <id> <note> [actor]
# Appends a structured note to the task's progress log. Returns 0 on success.
dossier_task_update() {
  local id="$1"
  local note="$2"
  local actor="${3:-}"
  local -a cmd=( "$DOSSIER_BIN" )
  local arg

  while IFS= read -r -d '' arg; do
    cmd+=( "$arg" )
  done < <(_dossier_corpus_args)

  cmd+=( task_update --id "$id" --note "$note" )
  [[ -n "$actor" ]] && cmd+=( --actor "$actor" )

  _dossier_run task_update "${cmd[@]}" >/dev/null
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

  _dossier_run task_list "${cmd[@]}"
}
