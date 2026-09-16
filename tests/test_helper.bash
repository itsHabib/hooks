#!/usr/bin/env bash

setup() {
  TEST_TMP="${BATS_TEST_TMPDIR}/ship-hooks"
  mkdir -p "$TEST_TMP/docs/integration-layer"
  cp "$BATS_TEST_DIRNAME/fixtures/spec-with-related.md" \
    "$TEST_TMP/docs/integration-layer/ship-ship-done-hook.md"

  export DOSSIER_LOG="$TEST_TMP/dossier.log"
  : >"$DOSSIER_LOG"
  export HOOKS_ROOT="$BATS_TEST_DIRNAME/.."

  # Tests exercise scripts through the same explicit Bash boundary used by the
  # harness, without changing tracked executable bits in the checkout.
  bash_wrapper "$BATS_TEST_DIRNAME/fixtures/mock-dossier.sh" \
    "$TEST_TMP/mock-dossier"
  bash_wrapper "$HOOKS_ROOT/scripts/posttool-ship-ship-dispatch.sh" \
    "$TEST_TMP/posttool-ship-ship-dispatch"
  bash_wrapper "$HOOKS_ROOT/scripts/posttool-ship-getrun.sh" \
    "$TEST_TMP/posttool-ship-getrun"

  export DOSSIER="$TEST_TMP/mock-dossier"
  # Override DOSSIER_BIN explicitly so the lib/dossier-cli.sh wrapper
  # uses the mock even when the operator's environment has DOSSIER_BIN
  # set (e.g. via ~/.claude/settings.json env block). Without this, tests
  # silently shell out to the operator's real dossier binary against the
  # real corpus — works on a clean machine, breaks on configured ones.
  export DOSSIER_BIN="$DOSSIER"
  # Same hygiene: hooks pass --corpus when DOSSIER_CORPUS is set, which
  # the mock accepts (see mock-dossier.sh) — but unsetting keeps the test
  # invocation symmetric with how cursor originally wrote it.
  unset DOSSIER_CORPUS
  export DOSSIER_MOCK_LOG="$DOSSIER_LOG"

  export DISPATCH_HOOK="$TEST_TMP/posttool-ship-ship-dispatch"
  export GETRUN_HOOK="$TEST_TMP/posttool-ship-getrun"

  # Scope dossier-wrapper failure logging to the test tmp dir so
  # `~/.cache/hooks-errors.log` doesn't get polluted by test runs.
  export HOOKS_ERROR_LOG="$TEST_TMP/hooks-errors.log"

}

bash_wrapper() {
  local source="$1"
  local wrapper="$2"

  printf '#!/usr/bin/env bash\nexec bash %q "$@"\n' "$source" >"$wrapper"
  chmod +x "$wrapper"
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
