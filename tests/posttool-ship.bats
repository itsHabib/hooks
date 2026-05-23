#!/usr/bin/env bats

load test_helper

@test "dispatch appends task_update note for linked spec doc" {
  substitute_workdir "$BATS_TEST_DIRNAME/fixtures/ship-dispatch-event.json" \
    | "$DISPATCH_HOOK"

  run dossier_calls
  [ "$status" -eq 0 ]
  [[ "$output" == *"task_update --id tsk_01KS6R3A51BE3CR6YS8DJ4DBDS --note ship run wf_01ARZ3NDEKTSV4RRFFQ69G5FAV dispatched against docs/integration-layer/ship-ship-done-hook.md --actor hook:ship-dispatch"* ]]
}

@test "dispatch exits silent when spec doc has no linked task" {
  substitute_workdir "$BATS_TEST_DIRNAME/fixtures/ship-dispatch-no-task-event.json" \
    | "$DISPATCH_HOOK"

  run dossier_calls
  [ "$status" -eq 0 ]
  [[ "$output" != *"task_update"* ]]
}

@test "getrun ignores still-running workflow" {
  substitute_workdir "$BATS_TEST_DIRNAME/fixtures/getrun-running-event.json" \
    | "$GETRUN_HOOK"

  run dossier_calls
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "getrun links terminal succeeded run" {
  substitute_workdir "$BATS_TEST_DIRNAME/fixtures/getrun-succeeded-event.json" \
    | "$GETRUN_HOOK"

  run dossier_calls
  [ "$status" -eq 0 ]
  [[ "$output" == *"artifact_link --project mcp-workstation --task tsk_01KS6R3A51BE3CR6YS8DJ4DBDS --kind run --ref wf_01ARZ3NDEKTSV4RRFFQ69G5FAV --label ship workflow run — succeeded --actor hook:ship-getrun"* ]]
  [[ "$output" != *"task_update"* ]]
}

@test "getrun links failed run and appends terminal note" {
  substitute_workdir "$BATS_TEST_DIRNAME/fixtures/getrun-failed-event.json" \
    | "$GETRUN_HOOK"

  run dossier_calls
  [ "$status" -eq 0 ]
  [[ "$output" == *"artifact_link --project mcp-workstation --task tsk_01KS6R3A51BE3CR6YS8DJ4DBDS --kind run --ref wf_01ARZ3NDEKTSV4RRFFQ69G5FAV --label ship workflow run — failed --actor hook:ship-getrun"* ]]
  [[ "$output" == *"task_update --id tsk_01KS6R3A51BE3CR6YS8DJ4DBDS --note ship run wf_01ARZ3NDEKTSV4RRFFQ69G5FAV reached terminal: failed --actor hook:ship-getrun"* ]]
}

@test "getrun is idempotent on repeated terminal polls" {
  local event
  event="$(substitute_workdir "$BATS_TEST_DIRNAME/fixtures/getrun-succeeded-event.json")"

  printf '%s\n' "$event" | "$GETRUN_HOOK"
  printf '%s\n' "$event" | "$GETRUN_HOOK"

  run dossier_calls
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c 'artifact_link')" -eq 2 ]
}

@test "ship_task_lookup resolves Related header" {
  # shellcheck source=../lib/ship-task-lookup.sh
  source "$HOOKS_ROOT/lib/ship-task-lookup.sh"

  ship_task_lookup "docs/integration-layer/ship-ship-done-hook.md" "$TEST_TMP"
  [ "$SHIP_TASK_ID" = "tsk_01KS6R3A51BE3CR6YS8DJ4DBDS" ]
  [ "$SHIP_PROJECT_SLUG" = "mcp-workstation" ]
}
