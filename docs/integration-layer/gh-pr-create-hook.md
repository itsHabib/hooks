**Status**: draft
**Owner**: human:michael
**Date**: 2026-05-19
**Related**: dossier task `gh-pr-create-hook` (id: `tsk_01KS6R2FW5YQ0D3XQWTATW9E1A`), phase `mcp-workstation/integration-layer`
**Repo**: `pers/hooks`
**Branch**: `integration-layer/gh-pr-create-hook`
**Depends on**: `dossier-cli-subcommands` (merged PR #38), scaffold (merged via PR #1), `gh-pr-merge-hook` (merged via PR #2 — populates `lib/pr-lookup.sh` + `lib/dossier-cli.sh` wrappers this hook uses).

# gh-pr-create-hook — design spec

## Scope

| Bucket | Files | Est. LOC | Weighted |
|---|---|---|---|
| `scripts/posttool-gh-pr-create.sh` | the hook | ~80-120 | ~80-120 |
| `lib/pr-lookup.sh` | extends scaffold stub (sharable with merge hook — see Conflict notes) | ~20-30 | ~20-30 |
| Tests | bats fixtures | ~50 | ~25 |
| **Total** | | | **~150-180** |

Band: **amazing** (<500 weighted).

## Goal

Counterpart to `gh-pr-merge-hook` at PR-open. Pre-stamps the dossier artifact_link when a PR is created so the merge hook later has a deterministic lookup path (query dossier instead of falling back to body parsing).

## Behavior

`scripts/posttool-gh-pr-create.sh` runs on `PostToolUse` matching `tool_name=Bash` where command matches `gh pr create`.

1. **Detect trigger.** Confirm Bash + `gh pr create` command (handle variants: `--title`, `--body`, `--draft`, multi-line bodies).
2. **Extract PR URL/number.** Parse `tool_output` for the URL `gh pr create` prints on success. Non-zero exit or parse failure → exit 0 silent.
3. **Find linked task** via `lib/pr-lookup.sh`:
   - Parse PR body (`gh pr view <n> --json body`) for `Closes task/<slug>` or `task: <task-id>`.
   - No ref → exit 0 with soft warning "no task linkage in PR body".
4. **Auto-link artifact** via `lib/dossier-cli.sh`:
   ```bash
   dossier_artifact_link "$project" "$task_id" pr "$pr_url" "$pr_title" "hook:gh-pr-create"
   ```
   Idempotent (the underlying CLI dedupes on `(project, task, kind, ref)`).
5. **Surface to context:**
   ```
   Auto-linked PR #N to dossier task <slug>.
   ```

## Implementation notes

- **All dossier interactions MUST go through the wrappers in `lib/dossier-cli.sh`** (`dossier_artifact_link`, `dossier_task_complete`, `dossier_task_update`, `dossier_task_list`). These wrappers honor `DOSSIER_CORPUS` via `--corpus`. **Do not call `"$DOSSIER" artifact_link ...` or any other `dossier` subcommand directly** — that bypasses the corpus-aware path and silently no-ops in operator environments that set `DOSSIER_CORPUS`. (PR #3's `ship-ship-done-hook` burned 4 codex review cycles converging on this; don't repeat it.)
- Source the wrapper at the top of the script: `source "$ROOT_DIR/lib/dossier-cli.sh"`. If the script needs the lookup, also source `lib/pr-lookup.sh` and `lib/dossier-cli.sh` — `pr-lookup.sh` is already populated by `gh-pr-merge-hook` (now on main).
- Shares `lib/pr-lookup.sh` with `gh-pr-merge-hook`. The merge hook's `pr_lookup_task` is already on main; this task may extend it (e.g. add parsing variants for new PR-body conventions) but should not re-implement the same function from scratch.
- `timeout 5` wraps the script.
- Same fail-silent discipline as merge hook.

## Acceptance

- `gh pr create` from a worktree with PR body containing `Closes task/<slug>`: artifact appears in dossier within seconds.
- **Idempotency:** re-fire hook → no duplicate artifact.
- **Missing ref:** PR without `Closes task/` → soft warning, no error.
- After both this + merge hook land: full flow (create → review → merge) runs without any explicit `dossier.*` calls from the agent.

## Test plan

- bats: fixture PostToolUse event JSONs for: PR create with linked task, without linked task, with malformed body.
- Integration: real PR create against a sandbox repo.

## Non-goals

- PR template enforcement (write-pr skill change, not a hook).
- Auto-updating PR body to add task ref if missing.
- Web UI PR creation (no hook fires).
