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
  run "$BATS_TEST_DIRNAME/../scripts/posttool-gh-pr-create.sh" --no-timeout \
    <"$BATS_TEST_DIRNAME/fixtures/posttool-gh-pr-create/$fixture"
}

@test "successful create with linked task auto-links PR artifact" {
  run_hook "success-with-task.json"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Auto-linked PR #7 to dossier task gh-pr-create-hook"* ]]

  grep -q "artifact_link" "$HOOK_TEST_TMP/dossier.log"
  # Hook now resolves PR metadata via the URL form to be cross-repo safe.
  grep -qE "pr view (7 |.*pull/7)" "$HOOK_TEST_TMP/gh.log"
  grep -q "https://github.com/pers/hooks/pull/7" "$HOOK_TEST_TMP/dossier.log"
}

@test "successful create with backtick task linkage also auto-links" {
  run_hook "success-with-task-backtick.json"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Auto-linked PR #11 to dossier task gh-pr-create-hook"* ]]

  grep -q "artifact_link" "$HOOK_TEST_TMP/dossier.log"
  grep -q "https://github.com/pers/hooks/pull/11" "$HOOK_TEST_TMP/dossier.log"
}

@test "backtick form with task id (tsk_…) routes through id branch" {
  run_hook "success-with-task-id-backtick.json"

  [ "$status" -eq 0 ]
  # `tsk_CREATE01` resolves to slug `gh-pr-create-hook` via the dossier mock.
  [[ "$output" == *"Auto-linked PR #12 to dossier task gh-pr-create-hook"* ]]
  grep -q "artifact_link" "$HOOK_TEST_TMP/dossier.log"
  grep -q "tsk_CREATE01" "$HOOK_TEST_TMP/dossier.log"
}

@test "successful create without linked task surfaces soft warning" {
  run_hook "success-without-task.json"

  [ "$status" -eq 0 ]
  [[ "$output$stderr" == *"no task linkage in PR body"* ]]
  [[ "$output" != *"Auto-linked"* ]]
  [ ! -f "$HOOK_TEST_TMP/dossier.log" ]
}

@test "failed create command exits silent" {
  run_hook "failed-create.json"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$HOOK_TEST_TMP/dossier.log" ]
  [ ! -f "$HOOK_TEST_TMP/gh.log" ]
}

@test "malformed envelope JSON exits silent without jq parse-error noise" {
  err="$BATS_TEST_TMPDIR/err.log"
  run bash -c "printf '%s' 'not-valid-json{' | '$BATS_TEST_DIRNAME/../scripts/posttool-gh-pr-create.sh' --no-timeout 2>'$err'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  ! grep -q 'jq:' "$err"
  ! grep -q 'parse error' "$err"
}

@test "malformed task reference in PR body surfaces soft warning" {
  run_hook "malformed-body.json"

  [ "$status" -eq 0 ]
  [[ "$output$stderr" == *"no task linkage in PR body"* ]]
  [ ! -f "$HOOK_TEST_TMP/dossier.log" ]
}

@test "re-firing the same create event stays idempotent at the dossier layer" {
  run_hook "success-with-task.json"
  [ "$status" -eq 0 ]

  first_link="$(grep -c 'artifact_link NEW' "$HOOK_TEST_TMP/dossier.log")"
  [ "$first_link" -eq 1 ]

  run_hook "success-with-task.json"
  [ "$status" -eq 0 ]

  [ "$(grep -c 'artifact_link NEW' "$HOOK_TEST_TMP/dossier.log")" -eq 1 ]
  [ "$(grep -c 'artifact_link NOOP' "$HOOK_TEST_TMP/dossier.log")" -eq 1 ]
}
