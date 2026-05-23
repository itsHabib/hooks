#!/usr/bin/env bash
# Mock dossier CLI for hook tests.

set -euo pipefail

log="${DOSSIER_MOCK_LOG:?DOSSIER_MOCK_LOG is required}"

printf '%s\n' "$*" >>"$log"

case "${1:-}" in
  task_update)
    printf '{"id":"%s"}\n' "$(printf '%s\n' "$@" | sed -n 's/.*--id \([^ ]*\).*/\1/p')"
    ;;
  artifact_link)
    printf '{"kind":"run","reference":"%s"}\n' "$(printf '%s\n' "$@" | sed -n 's/.*--ref \([^ ]*\).*/\1/p')"
    ;;
  task_list)
    cat <<'EOF'
[
  {
    "id": "tsk_01KS6R3A51BE3CR6YS8DJ4DBDS",
    "project": "mcp-workstation",
    "slug": "ship-ship-done-hook",
    "title": "ship-ship-done-hook"
  }
]
EOF
    ;;
  *)
    echo "unknown command: ${1:-}" >&2
    exit 1
    ;;
esac
