#!/usr/bin/env bash
# Mock dossier CLI for hook tests.

set -euo pipefail

log="${DOSSIER_MOCK_LOG:?DOSSIER_MOCK_LOG is required}"

printf '%s\n' "$*" >>"$log"

# Strip leading --corpus <path> if present (lib/dossier-cli.sh prepends it
# when DOSSIER_CORPUS env is set). Hooks/tests may run with or without
# DOSSIER_CORPUS — accept both shapes.
if [[ "${1:-}" == "--corpus" ]]; then
  shift 2
fi

case "${1:-}" in
  task_update)
    printf '{"id":"%s"}\n' "$(printf '%s\n' "$@" | sed -n 's/.*--id \([^ ]*\).*/\1/p')"
    ;;
  artifact_link)
    printf '{"kind":"run","reference":"%s"}\n' "$(printf '%s\n' "$@" | sed -n 's/.*--ref \([^ ]*\).*/\1/p')"
    ;;
  task_list)
    # Real dossier returns `project` as the project id (prj_…) and
    # `project_slug` as the slug. Mirror that so the lookup helpers exercise
    # the correct field.
    cat <<'EOF'
[
  {
    "id": "tsk_01KS6R3A51BE3CR6YS8DJ4DBDS",
    "project": "prj_FIXTURE03SHIP3FIXTURE03SH",
    "project_slug": "mcp-workstation",
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
