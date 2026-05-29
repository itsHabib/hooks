#!/usr/bin/env bash
# PreToolUse(Bash) hook: block broad `git add` — `-A`, `--all`, or a bare `.`.
# Explicit-path adds (`git add path/to/file`, `git add .gitignore`, `git add ./src`)
# pass through. Rationale: a `git add -A` swept a `.keys~` credentials backup
# toward a public repo (2026-05-29). See memory feedback_no_git_add_all.md.
set -uo pipefail

# Boundary-aware: `git add` at start / after a separator (`;`, `&&`, `||`, `|`),
# optionally preceded by env assignments, then within the SAME segment
# (no separators) a broad pathspec — `-A`, `--all`, or a bare `.` as a whole
# token (so `.gitignore` / `./src` / `src/a.ts` are NOT matched).
_is_broad_git_add() {
  local command="$1"
  local re='(^|[&|;])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*git[[:space:]]+add[[:space:]]+([^&|;]*[[:space:]])?(-A|--all|[.])([[:space:]]|$|[&|;])'
  [[ "$command" =~ $re ]]
}

_main() {
  command -v jq >/dev/null 2>&1 || exit 0 # no jq → don't interfere

  local event command
  event="$(cat)"
  [[ -z "$event" ]] && exit 0
  jq -e '.' <<<"$event" >/dev/null 2>&1 || exit 0

  command="$(jq -r '
    if (.tool_input.command? // "") != "" then .tool_input.command
    elif (.tool_input | type) == "string" then .tool_input
    else "" end
  ' <<<"$event")"
  [[ -z "$command" ]] && exit 0

  if _is_broad_git_add "$command"; then
    printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Broad git add is blocked — stage explicit file paths instead (git add path/to/file). See memory feedback_no_git_add_all.md."}}'
  fi
  exit 0
}

_main "$@"
