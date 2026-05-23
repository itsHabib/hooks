**Status**: draft
**Owner**: human:michael
**Date**: 2026-05-19
**Related**: dossier task `gh-pr-merge-hook` (id: `tsk_01KS6R20NB3QWFEQRPFMCQFBRV`), phase `mcp-workstation/integration-layer`
**Repo**: `pers/hooks`
**Branch**: `integration-layer/gh-pr-merge-hook`
**Depends on**: `dossier-cli-subcommands` (merged PR #38), scaffold (merged via PR #1 — original `stop-hook-done-check` task cancelled mid-flight)

# gh-pr-merge-hook — design spec

## Scope

| Bucket | Files | Est. LOC | Weighted |
|---|---|---|---|
| `scripts/posttool-gh-pr-merge.sh` | the hook | ~100-130 | ~100-130 |
| `lib/dossier-cli.sh` | shared dossier wrapper (extends scaffold stub) | ~40-60 | ~40-60 |
| `lib/pr-lookup.sh` | shared "find task linked to PR" helper (extends scaffold stub) | ~40-60 | ~40-60 |
| Tests | fixture-driven bats tests | ~80 | ~40 |
| **Total** | | | **~220-290** |

Band: **amazing** (<500 weighted).

## Goal

The keystone of the integration layer. When a PR merges via `gh pr merge`, the dossier task it represents auto-completes and the commit auto-links. Closes the friction-log #1 forgetting pattern (agent merges, forgets task_complete + artifact_link).

## Behavior

`scripts/posttool-gh-pr-merge.sh` runs on `PostToolUse` matching `tool_name=Bash` where `tool_input.command` matches `gh pr merge` (variants: `--squash --admin --delete-branch`, with/without PR number, etc.).

1. **Detect trigger.** Confirm tool was Bash + command matches `gh pr merge`.
2. **Verify success.** Parse `tool_output` for merge confirmation (`✓ Merged pull request #N`). If non-zero exit or error message, exit 0 silent.
3. **Identify PR.** Extract PR number from command/output. Fetch merge SHA: `gh pr view <n> --json mergeCommit -q '.mergeCommit.oid'`.
4. **Find linked task** via `lib/pr-lookup.sh`:
   - Parse PR body for `Closes task/<slug>` or `Closes task <tsk_id>`. Pull via `gh pr view <n> --json body`.
   - Resolve `<slug>` → task ID via `dossier task_list --project <inferred> --limit 100` and matching by slug. (For `<tsk_id>` form, no lookup needed.)
   - Not found: exit 0 with soft warning "no task linkage found for PR #N".
   - *(Future optimization: when dossier exposes an `artifact_list --ref <pr-url>` query, the hook can do a direct reverse-lookup from a PR pre-stamped by `gh-pr-create-hook`. Not in v1.)*
5. **Auto-complete task** (via `lib/dossier-cli.sh`):
   ```
   dossier task_complete --id <id> --note "merged in <sha> (PR #<n>)" --actor "hook:gh-pr-merge"
   ```
   Idempotent — already-done task is no-op.
6. **Auto-link commit:**
   ```
   dossier artifact_link --project <slug> --task <id> --kind commit --ref <sha> --label "PR #<n> merge commit on main" --actor "hook:gh-pr-merge"
   ```
   Idempotent — same tuple is no-op.
7. **Surface to context:**
   ```
   Auto-closed dossier task <slug> on PR #N merge (sha: <short-sha>).
   Commit linked.
   ```

## Implementation notes

- `timeout 5` wraps the whole script (network calls to gh).
- Fail-silent discipline: any sub-step error → exit 0 with stderr message; never block the agent's flow.
- `lib/dossier-cli.sh` populates the scaffold stub: thin wrapper providing `dossier_task_complete`, `dossier_artifact_link`, `dossier_task_list` functions with consistent arg handling + error normalization.
- `lib/pr-lookup.sh` populates the scaffold stub: `pr_lookup_task(pr_body, project_slug)` parses the body for `Closes task/<slug>` (or `Closes task tsk_XXX`) and resolves the slug to a task ID via `dossier task_list`. Returns `(project_slug, task_id)` or empty.

## Acceptance

End-to-end test:
1. Create a dossier task, note its id.
2. Worktree + work + push + `gh pr create` with body containing `Closes task/<slug>`.
3. Verify pre-merge: task `claimed`/`in_progress`, no commit artifact.
4. `gh pr merge <n> --squash --admin --delete-branch`.
5. Verify within seconds: task `done`, commit artifact in `artifacts.jsonl`.
6. **Idempotency:** re-fire hook with same event JSON → no duplicates.
7. **Failure mode:** PR with no `Closes task/` ref → hook surfaces warning, no error/block.

## Test plan

- bats: fixture PostToolUse event JSONs for: successful merge with linked task, successful merge without linked task, failed merge command.
- Integration: actual gh merge against a test PR in a sandbox repo.

## Non-goals

- `gh pr create` hook (separate task).
- `ship.ship` done hook (separate task).
- Modifying ship MCP.
- GitHub web UI merges (no hook fires; document limitation in README).
