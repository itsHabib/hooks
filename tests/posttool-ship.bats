#!/usr/bin/env bats

load test_helper

@test "dispatch appends task_update note for linked spec doc" {
  substitute_workdir "$BATS_TEST_DIRNAME/fixtures/ship-dispatch-event.json" \
    | "$DISPATCH_HOOK"

  run dossier_calls
  [ "$status" -eq 0 ]
  [[ "$output" == *"task_update --id tsk_01KS6R3A51BE3CR6YS8DJ4DBDS --note ship run wf_01ARZ3NDEKTSV4RRFFQ69G5FAV dispatched against docs/integration-layer/ship-ship-done-hook.md --actor hook:ship-dispatch"* ]]
}

@test "dispatch accepts Codex structuredContent response" {
  substitute_workdir "$BATS_TEST_DIRNAME/fixtures/ship-dispatch-event.json" \
    | jq '.tool_response = {structuredContent:.tool_response}' \
    | "$DISPATCH_HOOK"

  run dossier_calls
  [ "$status" -eq 0 ]
  [[ "$output" == *"task_update --id tsk_01KS6R3A51BE3CR6YS8DJ4DBDS --note ship run wf_01ARZ3NDEKTSV4RRFFQ69G5FAV dispatched"* ]]
}

@test "dispatch exits silent when spec doc has no linked task" {
  substitute_workdir "$BATS_TEST_DIRNAME/fixtures/ship-dispatch-no-task-event.json" \
    | "$DISPATCH_HOOK"

  run dossier_calls
  [ "$status" -eq 0 ]
  [[ "$output" != *"task_update"* ]]
}

@test "dispatch links Cursor watch URL for a cloud run" {
  # Seed the run's events.ndjson with a `bc-` agent id (first status event),
  # mirroring what cursor cloud writes seconds after dispatch.
  export SHIP_RUNS_DIR="$TEST_TMP/ship-runs"
  mkdir -p "$SHIP_RUNS_DIR/wf_01ARZ3NDEKTSV4RRFFQ69G5FAV"
  printf '%s\n' \
    '{"type":"status","agent_id":"bc-18d74228-8176-4c00-ac9e-0eb10abb1405"}' \
    >"$SHIP_RUNS_DIR/wf_01ARZ3NDEKTSV4RRFFQ69G5FAV/events.ndjson"

  substitute_workdir "$BATS_TEST_DIRNAME/fixtures/ship-dispatch-cloud-event.json" \
    | "$DISPATCH_HOOK"

  run dossier_calls
  [ "$status" -eq 0 ]
  # Still appends the dispatch note...
  [[ "$output" == *"task_update --id tsk_01KS6R3A51BE3CR6YS8DJ4DBDS"* ]]
  # ...and ferries the watch URL as a kind:url artifact on the same task.
  [[ "$output" == *"artifact_link --project mcp-workstation --task tsk_01KS6R3A51BE3CR6YS8DJ4DBDS --kind url --ref https://cursor.com/agents/bc-18d74228-8176-4c00-ac9e-0eb10abb1405 --label Cursor agent watch URL --actor hook:ship-dispatch"* ]]
}

@test "dispatch does not link a watch URL for a local run" {
  # A local dispatch has no cloud signal in tool_input. Even with a stray
  # events.ndjson carrying a bc- id present, the cloud gate must short-circuit
  # before any poll or link.
  export SHIP_RUNS_DIR="$TEST_TMP/ship-runs"
  mkdir -p "$SHIP_RUNS_DIR/wf_01ARZ3NDEKTSV4RRFFQ69G5FAV"
  printf '%s\n' \
    '{"type":"status","agent_id":"bc-deadbeefcafe-0000"}' \
    >"$SHIP_RUNS_DIR/wf_01ARZ3NDEKTSV4RRFFQ69G5FAV/events.ndjson"

  substitute_workdir "$BATS_TEST_DIRNAME/fixtures/ship-dispatch-event.json" \
    | "$DISPATCH_HOOK"

  run dossier_calls
  [ "$status" -eq 0 ]
  [[ "$output" == *"task_update --id tsk_01KS6R3A51BE3CR6YS8DJ4DBDS"* ]]
  [[ "$output" != *"--kind url"* ]]
}

@test "dispatch cloud gate fires on a bare cloud object (no runtime field)" {
  # hook__is_cloud_run is an OR: runtime == "cloud" OR cloud != null. This
  # fixture omits runtime and sets only the cloud block, exercising the
  # second arm — the path that fires if ship dispatches cloud without an
  # explicit runtime field.
  export SHIP_RUNS_DIR="$TEST_TMP/ship-runs"
  mkdir -p "$SHIP_RUNS_DIR/wf_01ARZ3NDEKTSV4RRFFQ69G5FAV"
  printf '%s\n' \
    '{"type":"status","agent_id":"bc-18d74228-8176-4c00-ac9e-0eb10abb1405"}' \
    >"$SHIP_RUNS_DIR/wf_01ARZ3NDEKTSV4RRFFQ69G5FAV/events.ndjson"

  substitute_workdir "$BATS_TEST_DIRNAME/fixtures/ship-dispatch-cloud-no-runtime-event.json" \
    | "$DISPATCH_HOOK"

  run dossier_calls
  [ "$status" -eq 0 ]
  [[ "$output" == *"artifact_link --project mcp-workstation --task tsk_01KS6R3A51BE3CR6YS8DJ4DBDS --kind url --ref https://cursor.com/agents/bc-18d74228-8176-4c00-ac9e-0eb10abb1405"* ]]
}

@test "dispatch skips the watch URL when no bc- id is present" {
  # Cloud run, but the events file has no agent_id yet (or never gets one).
  # hook__cursor_watch_url returns non-zero; the hook must quietly skip the
  # artifact_link and still exit 0 (the dispatch note still lands).
  export SHIP_RUNS_DIR="$TEST_TMP/ship-runs"
  mkdir -p "$SHIP_RUNS_DIR/wf_01ARZ3NDEKTSV4RRFFQ69G5FAV"
  printf '%s\n' \
    '{"type":"status","message":"queued"}' \
    >"$SHIP_RUNS_DIR/wf_01ARZ3NDEKTSV4RRFFQ69G5FAV/events.ndjson"

  substitute_workdir "$BATS_TEST_DIRNAME/fixtures/ship-dispatch-cloud-event.json" \
    | "$DISPATCH_HOOK"

  run dossier_calls
  [ "$status" -eq 0 ]
  [[ "$output" == *"task_update --id tsk_01KS6R3A51BE3CR6YS8DJ4DBDS"* ]]
  [[ "$output" != *"--kind url"* ]]
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

@test "getrun accepts Codex structuredContent response" {
  substitute_workdir "$BATS_TEST_DIRNAME/fixtures/getrun-succeeded-event.json" \
    | jq '.tool_response = {structuredContent:.tool_response}' \
    | "$GETRUN_HOOK"

  run dossier_calls
  [ "$status" -eq 0 ]
  [[ "$output" == *"artifact_link --project mcp-workstation --task tsk_01KS6R3A51BE3CR6YS8DJ4DBDS --kind run"* ]]
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
