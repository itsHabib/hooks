#!/usr/bin/env bash
# tests/smoke.sh — live-corpus end-to-end smoke for hooks.
#
# Fires each of the four hooks against a real dossier binary against a
# tmp corpus. Catches mock-reality drift that the bats suite cannot —
# bats uses hand-rolled stubs that mirror what the test author *thought*
# dossier returned, which silently drifted from real wire shape between
# the integration-layer rollout and the first live test (zero hook
# artifacts ever landed in the operator's real corpus through that gap).
#
# Usage:
#   DOSSIER_BIN=/path/to/dossier tests/smoke.sh
#   # or just: tests/smoke.sh   (probes ../dossier/target/release/dossier)
#
# Exit codes:
#   0 = all four hooks ferried correctly
#   non-zero = first assertion failure (message on stderr)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# -----------------------------------------------------------------------
# Locate dossier binary.
# -----------------------------------------------------------------------

DOSSIER="${DOSSIER_BIN:-}"
if [[ -z "$DOSSIER" ]]; then
  for candidate in \
    "$ROOT_DIR/../dossier/target/release/dossier" \
    "$ROOT_DIR/../dossier/target/release/dossier.exe" \
    "$ROOT_DIR/../dossier/target/debug/dossier" \
    "$ROOT_DIR/../dossier/target/debug/dossier.exe" \
    "$HOME/.cargo/bin/dossier" \
    "$HOME/.cargo/bin/dossier.exe"; do
    if [[ -x "$candidate" ]]; then
      DOSSIER="$candidate"
      break
    fi
  done
fi
if [[ -z "$DOSSIER" ]] || { ! [[ -x "$DOSSIER" ]] && ! command -v "$DOSSIER" >/dev/null 2>&1; }; then
  echo "smoke: dossier binary not found. Set DOSSIER_BIN, build itsHabib/dossier as a sibling, or cargo install it." >&2
  exit 1
fi
echo "smoke: using dossier at $DOSSIER"

# -----------------------------------------------------------------------
# Per-run tmp dirs.
# -----------------------------------------------------------------------

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

CORPUS="$TMP_ROOT/corpus"
GH_MOCK="$TMP_ROOT/bin"
HOOKS_ERROR_LOG="$TMP_ROOT/hooks-errors.log"

mkdir -p "$CORPUS/.dossier" "$CORPUS/projects" "$GH_MOCK"

export DOSSIER_BIN="$DOSSIER"
export DOSSIER_CORPUS="$CORPUS"
export HOOKS_ERROR_LOG
export PATH="$GH_MOCK:$PATH"

# -----------------------------------------------------------------------
# Seed data — IDs are hardcoded ULID-shaped so we can address tasks
# without re-querying. Crockford base32 alphabet (no I/L/O/U).
# -----------------------------------------------------------------------

ACTOR="smoke"
PROJECT_SLUG="hooks-smoke"
PHASE_SLUG="initial"
PR_TASK_SLUG="pr-flow-task"
SHIP_TASK_SLUG="ship-flow-task"
PROJECT_ID="prj_01SMKHPRJ000000000000000K"
PHASE_ID="phs_01SMKHPHS000000000000000K"
PR_TASK_ID="tsk_01SMKHPRTASK0000000000000"
SHIP_TASK_ID="tsk_01SMKHSHIPTASK00000000000"

PR_NUMBER=4242
PR_URL="https://github.com/itsHabib/hooks-smoke/pull/$PR_NUMBER"
MERGE_SHA="deadbeefcafebabedeadbeefcafebabedeadbeef"
WF_ID="wf_01SMKHWORKFLOWRUN0000000000"

NOW="2026-01-01T00:00:00Z"

# -----------------------------------------------------------------------
# Seed corpus directly on disk. The dossier CLI doesn't expose project_create
# / task_create yet (read-mostly verb set for hook integration), so the
# smoke writes the on-disk LAYOUT.md format and dossier loads it from
# there. If the loader ever rejects a hand-written file, that's also a
# real signal worth catching.
# -----------------------------------------------------------------------

write_file() {
  local path="$1"; shift
  mkdir -p "$(dirname "$path")"
  printf '%s' "$*" >"$path"
}

write_file "$CORPUS/projects/$PROJECT_SLUG/project.md" "---
id: $PROJECT_ID
slug: $PROJECT_SLUG
title: Hooks smoke
status: planning
created_at: '$NOW'
updated_at: '$NOW'
created_by: $ACTOR
---

Seed for tests/smoke.sh.
"

write_file "$CORPUS/projects/$PROJECT_SLUG/phases/01-$PHASE_SLUG.md" "---
id: $PHASE_ID
project: $PROJECT_ID
slug: $PHASE_SLUG
title: Initial
order: 1
status: active
created_at: '$NOW'
updated_at: '$NOW'
created_by: $ACTOR
---

Initial phase for smoke.
"

# The PR task is pre-set to in_progress + assigned so the gh-pr-merge
# hook's task_complete call has a valid transition (todo→done would
# error; only in_progress→done is allowed).
write_file "$CORPUS/projects/$PROJECT_SLUG/tasks/${PR_TASK_ID}-${PR_TASK_SLUG}.md" "---
id: $PR_TASK_ID
project: $PROJECT_ID
phase: $PHASE_ID
slug: $PR_TASK_SLUG
title: PR flow
status: in_progress
assignee: $ACTOR
claimed_at: '$NOW'
created_at: '$NOW'
updated_at: '$NOW'
---

Synthetic task for PR-flow hooks.
"

# Ship task stays in todo — the ship-* hooks only append notes / link
# artifacts, neither requires a specific state, and seeding `todo` keeps
# the test surface minimal (no over-specified frontmatter).
write_file "$CORPUS/projects/$PROJECT_SLUG/tasks/${SHIP_TASK_ID}-${SHIP_TASK_SLUG}.md" "---
id: $SHIP_TASK_ID
project: $PROJECT_ID
phase: $PHASE_ID
slug: $SHIP_TASK_SLUG
title: Ship flow
status: todo
created_at: '$NOW'
updated_at: '$NOW'
---

Synthetic task for ship-flow hooks.
"

# -----------------------------------------------------------------------
# Sanity: dossier task_list returns both tasks with project_slug set.
# -----------------------------------------------------------------------

# Pass --corpus explicitly even though DOSSIER_CORPUS is in env — clap
# would pick it up via `env = "DOSSIER_CORPUS"`, but the explicit flag
# removes any ambiguity about which corpus we're hitting if a stray
# env var bleeds in from the runner.
TASKS_JSON="$("$DOSSIER" --corpus "$CORPUS" task_list --project "$PROJECT_SLUG")"
if ! jq -e --arg s "$PR_TASK_SLUG" '.[] | select(.slug==$s) | .project_slug == "'"$PROJECT_SLUG"'"' <<<"$TASKS_JSON" >/dev/null; then
  echo "smoke: dossier task_list missing project_slug for pr task — was #40 deployed?" >&2
  echo "$TASKS_JSON" | jq . >&2
  exit 1
fi

# -----------------------------------------------------------------------
# Mock gh binary — handles the few calls the gh hooks make.
# -----------------------------------------------------------------------

cat >"$GH_MOCK/gh" <<EOF_GH_MOCK
#!/usr/bin/env bash
case "\$*" in
  *"pr view $PR_NUMBER"*"mergeCommit"*)
    printf '%s' "$MERGE_SHA" ;;
  *"pr view $PR_NUMBER"*"body"* | *"pr view "*"pull/$PR_NUMBER"*"body"*)
    printf 'Closes task \`%s\`\\n' "$PR_TASK_SLUG" ;;
  *"pr view $PR_NUMBER"*"title"* | *"pr view "*"pull/$PR_NUMBER"*"title"*)
    printf '%s' "Smoke PR" ;;
  *"pr view $PR_NUMBER"*"url"* | *"pr view "*"pull/$PR_NUMBER"*"url"*)
    printf '%s' "$PR_URL" ;;
  *)
    echo "smoke gh-mock: unexpected invocation: \$*" >&2
    exit 1 ;;
esac
EOF_GH_MOCK
chmod +x "$GH_MOCK/gh"

# -----------------------------------------------------------------------
# Helpers.
# -----------------------------------------------------------------------

count_artifacts_of_kind() {
  local kind="$1"
  if [[ ! -f "$CORPUS/projects/$PROJECT_SLUG/artifacts.jsonl" ]]; then
    echo 0; return
  fi
  jq -s --arg k "$kind" \
    '[.[] | select(.kind == $k and (.actor | startswith("hook:")))] | length' \
    <"$CORPUS/projects/$PROJECT_SLUG/artifacts.jsonl"
}

task_status() {
  local id="$1"
  # --include-terminal: task_list defaults to live tasks only, and the very
  # state this helper asserts (done, after gh-pr-merge completes the task)
  # is terminal — without the flag the readback is empty and smoke fails.
  "$DOSSIER" --corpus "$CORPUS" task_list --project "$PROJECT_SLUG" --include-terminal \
    | jq -r --arg id "$id" '.[] | select(.id == $id) | .status'
}

fail() {
  echo "smoke FAIL: $*" >&2
  echo
  echo "=== HOOKS_ERROR_LOG ===" >&2
  cat "$HOOKS_ERROR_LOG" >&2 2>/dev/null || echo "(no log)" >&2
  echo "=== artifacts.jsonl ===" >&2
  cat "$CORPUS/projects/$PROJECT_SLUG/artifacts.jsonl" >&2 2>/dev/null || echo "(no artifacts)" >&2
  exit 1
}

# -----------------------------------------------------------------------
# Fire each hook.
# -----------------------------------------------------------------------

echo "smoke: firing posttool-ship-ship-dispatch.sh"
# ship.ship dispatch reads docPath/workdir from .tool_input (the args
# that went in), not .tool_response — only the workflowRunId comes back
# in the response. That asymmetry vs ship.get_workflow_run is the
# specific shape this hook listens for.
HOOK_NAME="posttool-ship-ship-dispatch" \
  bash "$ROOT_DIR/scripts/posttool-ship-ship-dispatch.sh" --no-timeout <<EOF
{
  "hook_event_name": "PostToolUse",
  "tool_name": "mcp__ship__ship",
  "tool_input": {
    "docPath": "docs/$SHIP_TASK_SLUG.md",
    "workdir": "$TMP_ROOT/ship-worktree"
  },
  "tool_response": {
    "workflowRunId": "$WF_ID"
  }
}
EOF

echo "smoke: firing posttool-ship-getrun.sh"
HOOK_NAME="posttool-ship-getrun" \
  bash "$ROOT_DIR/scripts/posttool-ship-getrun.sh" --no-timeout <<EOF
{
  "hook_event_name": "PostToolUse",
  "tool_name": "mcp__ship__get_workflow_run",
  "tool_response": {
    "id": "$WF_ID",
    "docPath": "docs/$SHIP_TASK_SLUG.md",
    "status": "succeeded",
    "worktree": { "path": "$TMP_ROOT/ship-worktree" }
  }
}
EOF

echo "smoke: firing posttool-gh-pr-create.sh"
HOOK_NAME="posttool-gh-pr-create" \
  bash "$ROOT_DIR/scripts/posttool-gh-pr-create.sh" --no-timeout <<EOF
{
  "hook_event_name": "PostToolUse",
  "tool_name": "Bash",
  "tool_input": {
    "command": "gh pr create --title 'Smoke PR' --body 'Closes task \`$PR_TASK_SLUG\`'"
  },
  "tool_response": {
    "stdout": "$PR_URL\n",
    "stderr": "",
    "exitCode": 0
  }
}
EOF

echo "smoke: firing posttool-gh-pr-merge.sh"
HOOK_NAME="posttool-gh-pr-merge" \
  bash "$ROOT_DIR/scripts/posttool-gh-pr-merge.sh" --no-timeout <<EOF
{
  "hook_event_name": "PostToolUse",
  "tool_name": "Bash",
  "tool_input": {
    "command": "gh pr merge $PR_NUMBER --squash --admin --delete-branch"
  },
  "tool_response": {
    "stdout": "Merged pull request #$PR_NUMBER (squash)\n",
    "stderr": "",
    "exitCode": 0
  }
}
EOF

# -----------------------------------------------------------------------
# Assert outcomes.
# -----------------------------------------------------------------------

echo "smoke: asserting"

# 1. Ship-dispatch hook → task note appended to ship task.
# 2. Ship-getrun (succeeded) → kind:run artifact.
# 3. gh-pr-create → kind:pr artifact.
# 4. gh-pr-merge → kind:commit artifact + pr task status = done.

# (1) Note on ship task.
SHIP_TASK_BODY="$(cat "$CORPUS/projects/$PROJECT_SLUG/tasks/${SHIP_TASK_ID}-${SHIP_TASK_SLUG}.md")"
case "$SHIP_TASK_BODY" in
  *"ship run $WF_ID dispatched against"*) ;;
  *) fail "ship-dispatch hook did not append note (expected 'ship run $WF_ID dispatched against ...' on $SHIP_TASK_SLUG)" ;;
esac

# (2) kind:run artifact present.
if [[ "$(count_artifacts_of_kind run)" -lt 1 ]]; then
  fail "ship-getrun hook did not write kind:run artifact"
fi

# (3) kind:pr artifact present.
if [[ "$(count_artifacts_of_kind pr)" -lt 1 ]]; then
  fail "gh-pr-create hook did not write kind:pr artifact"
fi

# (4) kind:commit artifact + pr task status = done.
if [[ "$(count_artifacts_of_kind commit)" -lt 1 ]]; then
  fail "gh-pr-merge hook did not write kind:commit artifact"
fi
PR_STATUS="$(task_status "$PR_TASK_ID")"
if [[ "$PR_STATUS" != "done" ]]; then
  fail "gh-pr-merge hook did not complete pr task (status=$PR_STATUS, expected done)"
fi

# Sanity: HOOKS_ERROR_LOG should be empty — every hook should have run clean.
if [[ -s "$HOOKS_ERROR_LOG" ]]; then
  fail "unexpected hook failures logged"
fi

echo "smoke: all 4 hooks ferried successfully ✓"
