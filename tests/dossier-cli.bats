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
  # Unique HOOK_NAME marker — a regression that flips suppression off would
  # cause this exact string to appear in the operator's real log file,
  # which we then assert is absent. Without the marker the grep would be
  # vacuous (looking for a string nothing writes).
  local marker="suppressed-marker-$$-$RANDOM"
  export DOSSIER_BIN="$BATS_TEST_DIRNAME/fixtures/bin-fail/dossier"
  export HOOKS_ERROR_LOG=""
  export HOOK_NAME="$marker"
  source "$HOOKS_ROOT/lib/dossier-cli.sh"

  run dossier_artifact_link "alpha" "tsk_X" "pr" "ref"
  [ "$status" -ne 0 ]
  # Default log location depends on env (XDG_CACHE_HOME or HOME). Don't
  # assert the file is absent (might pre-exist from prior real hook runs);
  # just assert no line with our unique marker appears in any plausible
  # default location.
  for candidate in \
    "${XDG_CACHE_HOME:-}/hooks-errors.log" \
    "${HOME:-}/.cache/hooks-errors.log" \
    "/tmp/.cache/hooks-errors.log"; do
    if [[ -n "$candidate" && -f "$candidate" ]]; then
      ! grep -q "$marker" "$candidate"
    fi
  done
}
