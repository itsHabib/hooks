#!/usr/bin/env bash

load test_helper

setup() {
  export PATH="$BATS_TEST_DIRNAME/fixtures/bin:$PATH"
  export DOSSIER_BIN=dossier
  export DOSSIER_CORPUS="$BATS_TEST_DIRNAME/fixtures/corpus"
  export DOSSIER_PROJECT=mcp-workstation
  export HOOK_TEST_TMP="$BATS_TEST_DIRNAME/tmp"
  rm -rf "$HOOK_TEST_TMP"
  mkdir -p "$HOOK_TEST_TMP"
}

run_hook() {
  local fixture="$1"
  run "$BATS_TEST_DIRNAME/../scripts/posttool-gh-pr-merge.sh" --no-timeout \
    <"$BATS_TEST_DIRNAME/fixtures/posttool-gh-pr-merge/$fixture"
}

@test "successful merge with linked task auto-completes and links commit" {
  run_hook "success-with-task.json"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Auto-closed dossier task gh-pr-merge-hook on PR #42 merge"* ]]
  [[ "$output" == *"Commit linked."* ]]

  grep -q "task_complete" "$HOOK_TEST_TMP/dossier.log"
  grep -q "artifact_link" "$HOOK_TEST_TMP/dossier.log"
  grep -q "pr view 42" "$HOOK_TEST_TMP/gh.log"
}

@test "successful merge without linked task surfaces soft warning" {
  run_hook "success-without-task.json"

  [ "$status" -eq 0 ]
  [[ "$output$stderr" == *"no task linkage found for PR #99"* ]]
  [[ "$output" != *"Auto-closed"* ]]
  [ ! -f "$HOOK_TEST_TMP/dossier.log" ]
}

@test "failed merge command exits silent" {
  run_hook "failed-merge.json"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$HOOK_TEST_TMP/dossier.log" ]
  [ ! -f "$HOOK_TEST_TMP/gh.log" ]
}

@test "re-firing the same merge event stays idempotent at the dossier layer" {
  run_hook "success-with-task.json"
  [ "$status" -eq 0 ]

  first_complete="$(grep -c 'task_complete NEW' "$HOOK_TEST_TMP/dossier.log")"
  first_link="$(grep -c 'artifact_link NEW' "$HOOK_TEST_TMP/dossier.log")"
  [ "$first_complete" -eq 1 ]
  [ "$first_link" -eq 1 ]

  run_hook "success-with-task.json"
  [ "$status" -eq 0 ]

  [ "$(grep -c 'task_complete NEW' "$HOOK_TEST_TMP/dossier.log")" -eq 1 ]
  [ "$(grep -c 'artifact_link NEW' "$HOOK_TEST_TMP/dossier.log")" -eq 1 ]
  [ "$(grep -c 'task_complete NOOP' "$HOOK_TEST_TMP/dossier.log")" -eq 1 ]
  [ "$(grep -c 'artifact_link NOOP' "$HOOK_TEST_TMP/dossier.log")" -eq 1 ]
}
