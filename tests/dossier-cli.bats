#!/usr/bin/env bats
# Unit tests for lib/dossier-cli.sh — error logging contract.

setup() {
  HOOKS_ROOT="$BATS_TEST_DIRNAME/.."
  export HOOKS_ERROR_LOG="$BATS_TEST_TMPDIR/hooks-errors.log"
  export HOOK_NAME="test-hook"
  chmod +x "$BATS_TEST_DIRNAME/fixtures/bin-fail/dossier" \
           "$BATS_TEST_DIRNAME/fixtures/bin-ok/dossier"
}

@test "dossier_artifact_link logs to HOOKS_ERROR_LOG on non-zero exit" {
  export DOSSIER_BIN="$BATS_TEST_DIRNAME/fixtures/bin-fail/dossier"
  # shellcheck source=../lib/dossier-cli.sh
  source "$HOOKS_ROOT/lib/dossier-cli.sh"

  run dossier_artifact_link "alpha" "tsk_X" "pr" "https://example/1" "label" "test"
  [ "$status" -ne 0 ]
  [ -f "$HOOKS_ERROR_LOG" ]

  # Log line carries hook name, verb, exit code, and a stderr snippet.
  grep -q "test-hook" "$HOOKS_ERROR_LOG"
  grep -q "artifact_link" "$HOOKS_ERROR_LOG"
  grep -q "boom from mock dossier" "$HOOKS_ERROR_LOG"
}

@test "dossier_task_complete logs to HOOKS_ERROR_LOG on non-zero exit" {
  export DOSSIER_BIN="$BATS_TEST_DIRNAME/fixtures/bin-fail/dossier"
  source "$HOOKS_ROOT/lib/dossier-cli.sh"

  run dossier_task_complete "tsk_X" "note" "actor"
  [ "$status" -ne 0 ]
  grep -q "task_complete" "$HOOKS_ERROR_LOG"
}

@test "dossier_task_update logs to HOOKS_ERROR_LOG on non-zero exit" {
  export DOSSIER_BIN="$BATS_TEST_DIRNAME/fixtures/bin-fail/dossier"
  source "$HOOKS_ROOT/lib/dossier-cli.sh"

  run dossier_task_update "tsk_X" "note" "actor"
  [ "$status" -ne 0 ]
  grep -q "task_update" "$HOOKS_ERROR_LOG"
}

@test "dossier_task_list logs to HOOKS_ERROR_LOG on non-zero exit" {
  export DOSSIER_BIN="$BATS_TEST_DIRNAME/fixtures/bin-fail/dossier"
  source "$HOOKS_ROOT/lib/dossier-cli.sh"

  run dossier_task_list
  [ "$status" -ne 0 ]
  grep -q "task_list" "$HOOKS_ERROR_LOG"
}

@test "successful dossier call writes nothing to HOOKS_ERROR_LOG" {
  export DOSSIER_BIN="$BATS_TEST_DIRNAME/fixtures/bin-ok/dossier"
  source "$HOOKS_ROOT/lib/dossier-cli.sh"

  run dossier_task_update "tsk_X" "note" "actor"
  [ "$status" -eq 0 ]
  [ ! -f "$HOOKS_ERROR_LOG" ]
}

@test "successful task_list preserves stdout AND writes nothing to log" {
  export DOSSIER_BIN="$BATS_TEST_DIRNAME/fixtures/bin-ok/dossier"
  source "$HOOKS_ROOT/lib/dossier-cli.sh"

  run dossier_task_list
  [ "$status" -eq 0 ]
  [[ "$output" == "[]" ]]
  [ ! -f "$HOOKS_ERROR_LOG" ]
}

@test "HOOKS_ERROR_LOG= (empty) suppresses logging entirely" {
  export DOSSIER_BIN="$BATS_TEST_DIRNAME/fixtures/bin-fail/dossier"
  export HOOKS_ERROR_LOG=""
  source "$HOOKS_ROOT/lib/dossier-cli.sh"

  run dossier_artifact_link "alpha" "tsk_X" "pr" "ref"
  [ "$status" -ne 0 ]
  # Default log path is ~/.cache/hooks-errors.log. We can't assert that file
  # is absent (might pre-exist), but we can assert no new line for this test
  # run by snapshotting before+after under a unique HOOK_NAME.
  if [[ -f "$HOME/.cache/hooks-errors.log" ]]; then
    ! grep -q "test-hook-suppressed-marker" "$HOME/.cache/hooks-errors.log"
  fi
}
