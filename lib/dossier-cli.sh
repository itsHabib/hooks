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
# Destination: HOOKS_ERROR_LOG. If unset, defaults to
# `${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/hooks-errors.log`. Note the `-`
# (not `:-`) — an empty-string HOOKS_ERROR_LOG sets log="" and the
# `[[ -z "$log" ]]` check below suppresses logging. Used by bats setup so
# test runs don't write to the operator's real cache. The default is built
# with `${HOME:-/tmp}` so an unset HOME under `set -u` doesn't abort.
_dossier_log_failure() {
  local verb="$1"
  local rc="$2"
  local stderr_file="$3"
  local default_dir="${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}"
  local log="${HOOKS_ERROR_LOG-$default_dir/hooks-errors.log}"

  [[ -z "$log" ]] && return 0

  local hook_name="${HOOK_NAME:-unknown-hook}"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local stderr_msg=""
  if [[ -f "$stderr_file" ]]; then
    # 200-char cap keeps a runaway stderr from blowing up the log line.
    # Head FIRST so `tr` reads a bounded stream — closing the pipe early
    # from the other direction would otherwise SIGPIPE `tr` under pipefail
    # and abort logging on the very failures we most want to capture.
    # ANSI-C $'\n\t' is two literal control chars (LF + TAB), portable
    # across coreutils / busybox / MSYS unlike '\n\t' which some `tr`s
    # don't interpret.
    stderr_msg="$(head -c 200 <"$stderr_file" 2>/dev/null | tr $'\n\t' '  ' 2>/dev/null || true)"
  fi

  mkdir -p "$(dirname "$log")" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$ts" "$hook_name" "$verb" "$rc" "$stderr_msg" \
    >>"$log" 2>/dev/null || true
}

# Internal helper: run a dossier command, capture stderr, log failures.
# Preserves stdout (task_list needs it). Returns the underlying exit
# code so callers' existing `|| true` patterns keep working.
#
# Uses the `if cmd; then ...` pattern rather than toggling `set -e` so
# the caller's errexit state isn't mutated — `if` suppresses errexit for
# its own condition automatically.
_dossier_run() {
  local verb="$1"
  shift
  local stderr_file rc
  stderr_file="$(mktemp 2>/dev/null \
    || printf '%s/hooks-dossier-stderr.%d.%d' "${TMPDIR:-/tmp}" "$$" "$RANDOM")"

  if "$@" 2>"$stderr_file"; then
    rc=0
  else
    rc=$?
  fi

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

# Usage: dossier_task_claim <id> [actor]
# Returns 0 on success (including idempotent re-claim). Non-zero on failure.
dossier_task_claim() {
  local id="$1"
  local actor="${2:-}"
  local -a cmd=( "$DOSSIER_BIN" )
  local arg

  while IFS= read -r -d '' arg; do
    cmd+=( "$arg" )
  done < <(_dossier_corpus_args)

  cmd+=( task_claim --id "$id" )
  [[ -n "$actor" ]] && cmd+=( --actor "$actor" )

  _dossier_run task_claim "${cmd[@]}" >/dev/null
}

# Usage: dossier_task_update_status <id> <status> [note] [actor]
# Sets task status via dossier task_update. Returns 0 on success.
dossier_task_update_status() {
  local id="$1"
  local status="$2"
  local note="${3:-}"
  local actor="${4:-}"
  local -a cmd=( "$DOSSIER_BIN" )
  local arg

  while IFS= read -r -d '' arg; do
    cmd+=( "$arg" )
  done < <(_dossier_corpus_args)

  cmd+=( task_update --id "$id" --status "$status" )
  [[ -n "$note" ]] && cmd+=( --note "$note" )
  [[ -n "$actor" ]] && cmd+=( --actor "$actor" )

  _dossier_run task_update "${cmd[@]}" >/dev/null
}

# Usage: dossier_task_list [project_slug] [limit] [statuses]
# `statuses` is an optional comma-separated list (e.g. `todo,in_progress`).
# Prints matching tasks as a JSON array on stdout.
dossier_task_list() {
  local project="${1:-}"
  local limit="${2:-}"
  local statuses="${3:-}"
  local -a cmd=( "$DOSSIER_BIN" )
  local arg
  local -a status_arr=()
  local s

  while IFS= read -r -d '' arg; do
    cmd+=( "$arg" )
  done < <(_dossier_corpus_args)

  cmd+=( task_list )
  [[ -n "$limit" ]] && cmd+=( --limit "$limit" )
  [[ -n "$project" ]] && cmd+=( --project "$project" )
  if [[ -n "$statuses" ]]; then
    IFS=',' read -ra status_arr <<<"$statuses"
    for s in "${status_arr[@]}"; do
      cmd+=( --status "$s" )
    done
  fi

  _dossier_run task_list "${cmd[@]}"
}
