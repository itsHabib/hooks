#!/usr/bin/env bash
# Read linked artifacts from the dossier corpus on disk.
# Used by operator-invoked sweep scripts when artifact_list is not on the CLI.

set -euo pipefail

# shellcheck disable=SC2317
_artifact_lookup_stub() {
  :
}

# Usage: artifact_list_for_project <project_slug>
# Prints a JSON array of artifacts on stdout. Missing file → `[]`.
artifact_list_for_project() {
  local project="$1"
  local corpus="${DOSSIER_CORPUS:-}"
  local path=""

  if [[ -z "$corpus" ]]; then
    return 1
  fi

  path="$corpus/projects/$project/artifacts.jsonl"
  if [[ ! -f "$path" ]]; then
    printf '[]\n'
    return 0
  fi

  jq -R -s '
    split("\n")
    | map(select(length > 0))
    | map(try fromjson)   # tolerate a corrupt line rather than aborting the sweep
  ' "$path"
}
