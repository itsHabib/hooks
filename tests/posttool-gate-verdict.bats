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
  export HOOKS_ERROR_LOG="$HOOK_TEST_TMP/hooks-errors.log"
}

run_hook() {
  local fixture="$1"
  run "$BATS_TEST_DIRNAME/../scripts/posttool-gate-verdict.sh" --no-timeout \
    <"$BATS_TEST_DIRNAME/fixtures/posttool-gate-verdict/$fixture"
}

run_codex_hook() {
  local fixture="$1"
  run bash -c "jq '.tool_response = {output:.tool_response.stdout, exit_code:.tool_response.exitCode}' '$BATS_TEST_DIRNAME/fixtures/posttool-gate-verdict/$fixture' | '$BATS_TEST_DIRNAME/../scripts/posttool-gate-verdict.sh' --no-timeout"
}

@test "gate pass with linked task records a verdict artifact" {
  run_hook "pass-with-task.json"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Recorded gate verdict for PR #42"* ]]
  # kind=verdict, canonical gate:// ref (short repo + run id), full meta set.
  grep -q -- "--kind verdict" "$HOOK_TEST_TMP/dossier.log"
  grep -q -- "--ref gate://mcp-workstation/pr/42/run_testverdict01" "$HOOK_TEST_TMP/dossier.log"
  grep -q -- "--meta source=gate" "$HOOK_TEST_TMP/dossier.log"
  grep -q -- "--meta outcome=pass" "$HOOK_TEST_TMP/dossier.log"
  grep -q -- "--meta head_sha=cafebabecafebabecafebabecafebabecafebabe" "$HOOK_TEST_TMP/dossier.log"
  grep -q -- "--meta grant=grt_x" "$HOOK_TEST_TMP/dossier.log"
  grep -q -- "--meta tier=T1" "$HOOK_TEST_TMP/dossier.log"
  # Project slug, never an id.
  grep -q -- "--project mcp-workstation" "$HOOK_TEST_TMP/dossier.log"
  ! grep -q -- "--project prj_" "$HOOK_TEST_TMP/dossier.log"
}

@test "Codex Bash response shape records the same verdict artifact" {
  run_codex_hook "pass-with-task.json"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Recorded gate verdict for PR #42"* ]]
  grep -q -- "--kind verdict" "$HOOK_TEST_TMP/dossier.log"
}

@test "gate escalate (park) records no verdict" {
  run_hook "escalate.json"

  [ "$status" -eq 0 ]
  [[ "$output" != *"Recorded gate verdict"* ]]
  [ ! -f "$HOOK_TEST_TMP/dossier.log" ]
}

@test "non-gate-gate command (gate judge) is ignored" {
  run_hook "gate-judge.json"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$HOOK_TEST_TMP/dossier.log" ]
}

@test "gate pass without task linkage records no verdict" {
  run_hook "pass-without-task.json"

  [ "$status" -eq 0 ]
  [[ "$output$stderr" == *"no task linkage for PR #99"* ]]
  [[ "$output" != *"Recorded gate verdict"* ]]
}

@test "malformed envelope JSON exits silent" {
  err="$BATS_TEST_TMPDIR/err.log"
  run bash -c "printf '%s' 'not-json{' | '$BATS_TEST_DIRNAME/../scripts/posttool-gate-verdict.sh' --no-timeout 2>'$err'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  ! grep -q 'jq:' "$err"
}

@test "re-firing the same gate pass stays idempotent at the dossier layer" {
  run_hook "pass-with-task.json"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'artifact_link NEW' "$HOOK_TEST_TMP/dossier.log")" -eq 1 ]

  run_hook "pass-with-task.json"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'artifact_link NEW' "$HOOK_TEST_TMP/dossier.log")" -eq 1 ]
  [ "$(grep -c 'artifact_link NOOP' "$HOOK_TEST_TMP/dossier.log")" -eq 1 ]
}
