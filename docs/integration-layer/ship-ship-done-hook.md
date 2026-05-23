**Status**: draft
**Owner**: human:michael
**Date**: 2026-05-19
**Related**: dossier task `ship-ship-done-hook` (id: `tsk_01KS6R3A51BE3CR6YS8DJ4DBDS`), phase `mcp-workstation/integration-layer`
**Repo**: `pers/hooks`
**Branch**: `integration-layer/ship-ship-done-hook`
**Depends on**: `dossier-cli-subcommands` (merged PR #38), scaffold (merged via PR #1 — original `stop-hook-done-check` task cancelled mid-flight)

# ship-ship-done-hook — design spec

## Scope

| Bucket | Files | Est. LOC | Weighted |
|---|---|---|---|
| `scripts/posttool-ship-ship-dispatch.sh` | dispatch hook | ~70-90 | ~70-90 |
| `scripts/posttool-ship-getrun.sh` | terminal hook | ~80-100 | ~80-100 |
| `lib/ship-task-lookup.sh` | spec-doc-to-task resolution (extends scaffold stub) | ~50-70 | ~50-70 |
| Tests | bats fixtures | ~80 | ~40 |
| **Total** | | | **~280-380** |

Band: **amazing** (<500 weighted).

## Goal

Auto-link ship workflow runs to their dossier tasks. Two hooks because `ship.ship` is async — the dispatch and the terminal-state observation are separate events. Together they record "run X was dispatched against task Y" and "run X reached terminal Z."

## Behavior

### `scripts/posttool-ship-ship-dispatch.sh`

Runs on `PostToolUse` where `tool_name=mcp__ship__ship`.

1. Parse event. Extract `workflowRunId` from `tool_output`, `docPath` from `tool_input`.
2. Resolve task via `lib/ship-task-lookup.sh`:
   - **Primary:** parse the spec doc for the line `**Related**: dossier task \`<slug>\` (id: \`tsk_XXX\`)` — this is the canonical header convention used by `/work-driver-prep` output. Regex `\(id: \`(tsk_[A-Z0-9]+)\`\)` is enough.
   - **Fallback:** docPath filename matches a task slug pattern (e.g. `<slug>.md` where `<slug>` matches a known task).
   - Neither → exit 0 silent.
3. Append note:
   ```
   dossier task_update --id <id> --note "ship run <runId> dispatched against <docPath>" --actor "hook:ship-dispatch"
   ```

### `scripts/posttool-ship-getrun.sh`

Runs on `PostToolUse` where `tool_name=mcp__ship__get_workflow_run`.

1. Parse event. Extract `workflowRunId` + terminal status from `tool_output`.
2. **Not terminal yet** (status=running): exit 0 silent. This hook can fire many times during polling; must be cheap on repeated calls.
3. Resolve task via same `lib/ship-task-lookup.sh`.
4. **Link the run:**
   ```
   dossier artifact_link --project <slug> --task <id> --kind run --ref <runId> --label "ship workflow run — <status>" --actor "hook:ship-getrun"
   ```
   Idempotent — already-linked run is no-op (safe for repeated polling).
5. **If failed/cancelled:** also append a note:
   ```
   dossier task_update --id <id> --note "ship run <runId> reached terminal: <status>" --actor "hook:ship-getrun"
   ```

## Implementation notes

- Both scripts share `lib/ship-task-lookup.sh`. Stub created by scaffold task; populated here.
- Critical: `get_workflow_run` polling can fire the hook many times. Idempotency from `dossier-cli-subcommands` makes this safe.
- Spec-doc convention: `**Related**: dossier task \`<slug>\` (id: \`tsk_XXX\`)` in the bold-markdown header block at the top of the spec. This matches what `/work-driver-prep` actually writes (verified against the integration-layer phase's own specs). NOT YAML frontmatter — the portfolio's spec docs use bold-markdown headers, not YAML.
- `timeout 5` wraps each script.

## Acceptance

- Dispatch ship.ship against a spec containing `**Related**: dossier task \`<slug>\` (id: \`tsk_XXX\`)` in its header. Task gets dispatch note within seconds.
- Poll `get_workflow_run` while running: artifact-link hook does nothing.
- Run reaches terminal succeeded: artifact appears in dossier as `kind: run`.
- **Idempotency:** call `get_workflow_run` again post-terminal → no duplicate.
- **Failure case:** run fails → task gets explanation note + run linked.

## Test plan

- bats: PostToolUse event JSONs for dispatch + various terminal states + still-running.
- Integration: actual ship.ship run against a test spec.

## Non-goals

- Modifying ship MCP.
- Subscribing to ship events (poll-based, same as today).
- Cancel-handling (`cancel_workflow_run` could be a future hook).
