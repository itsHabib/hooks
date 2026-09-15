#!/usr/bin/env bash
# Read-only inventory. Never sources settings or executes hook commands.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
claude="${HOME}/.claude/settings.json"
codex="${HOME}/.codex/hooks.json"
while (($#)); do
  case "$1" in
    --claude|--codex)
      if (($# < 2)); then echo "missing path for $1" >&2; exit 2; fi
      case "$1" in --claude) claude=$2 ;; --codex) codex=$2 ;; esac
      shift 2 ;;
    -h|--help)
      echo 'Usage: bash scripts/audit-wiring.sh [--claude settings.json] [--codex hooks.json]'
      echo 'Reports textual hook references only; does not test trust, matchers or execution.'
      exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
names=$(printf '%s\n' "$root"/scripts/pretool-*.sh "$root"/scripts/posttool-*.sh |
  while IFS= read -r path; do basename "$path"; done | jq -Rsc 'split("\n") | map(select(length > 0))')
result=0
for harness in claude codex; do
  path=$claude
  if [[ $harness == codex ]]; then path=$codex; fi
  if [[ ! -f $path ]]; then
    printf '%s\tconfig-missing\n' "$harness"
    result=1
    continue
  fi
  if ! jq -r --arg harness "$harness" --argjson names "$names" -f "$root/lib/audit-wiring.jq" "$path"; then
    printf '%s\tconfig-invalid\n' "$harness" >&2
    result=1
  fi
done
exit "$result"
