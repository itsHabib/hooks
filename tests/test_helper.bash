#!/usr/bin/env bash

setup() {
  TEST_TMP="${BATS_TEST_TMPDIR}/ship-hooks"
  mkdir -p "$TEST_TMP/docs/integration-layer"
  cp "$BATS_TEST_DIRNAME/fixtures/spec-with-related.md" \
    "$TEST_TMP/docs/integration-layer/ship-ship-done-hook.md"

  export DOSSIER_LOG="$TEST_TMP/dossier.log"
  : >"$DOSSIER_LOG"
  export DOSSIER="$BATS_TEST_DIRNAME/fixtures/mock-dossier.sh"
  export DOSSIER_MOCK_LOG="$DOSSIER_LOG"

  export HOOKS_ROOT="$BATS_TEST_DIRNAME/.."
  export DISPATCH_HOOK="$HOOKS_ROOT/scripts/posttool-ship-ship-dispatch.sh"
  export GETRUN_HOOK="$HOOKS_ROOT/scripts/posttool-ship-getrun.sh"

  chmod +x "$DOSSIER" "$DISPATCH_HOOK" "$GETRUN_HOOK"
}

substitute_workdir() {
  local fixture="$1"
  sed "s|TEST_WORKDIR|$TEST_TMP|g" "$fixture"
}

dossier_calls() {
  if [[ -f "$DOSSIER_LOG" ]]; then
    cat "$DOSSIER_LOG"
  fi
}
