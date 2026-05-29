#!/usr/bin/env bash

load test_helper

# `run --separate-stderr` (used by run_hook_split) needs bats >= 1.5.0.
bats_require_minimum_version 1.5.0

setup() {
  export PATH="$BATS_TEST_DIRNAME/fixtures/bin:$PATH"
  export DOSSIER_BIN=dossier
  export DOSSIER_CORPUS="$BATS_TEST_DIRNAME/fixtures/corpus"
  export DOSSIER_PROJECT=mcp-workstation
  export HOOK_TEST_TMP="$BATS_TEST_DIRNAME/tmp"
  rm -rf "$HOOK_TEST_TMP"
  mkdir -p "$HOOK_TEST_TMP"
  # Scope dossier-wrapper failure logging to the test tmp dir so
  # `~/.cache/hooks-errors.log` doesn't get polluted by test runs.
  export HOOKS_ERROR_LOG="$HOOK_TEST_TMP/hooks-errors.log"
}

run_hook() {
  local fixture="$1"
  run "$BATS_TEST_DIRNAME/../scripts/posttool-gh-pr-create.sh" --no-timeout \
    <"$BATS_TEST_DIRNAME/fixtures/posttool-gh-pr-create/$fixture"
}

# Like run_hook but splits the streams: $output = stdout, $stderr = stderr.
# Needed to prove a message lands on STDOUT specifically — plain `run`
# merges both into $output, so a stdout-only assertion would pass even if
# the text were on stderr.
run_hook_split() {
  local fixture="$1"
  run --separate-stderr "$BATS_TEST_DIRNAME/../scripts/posttool-gh-pr-create.sh" --no-timeout \
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
  # Regression lock: artifact_link must be called with the project SLUG,
  # never an ID. Catches any future drift back to reading `.project` instead
  # of `.project_slug` from task_list output.
  ! grep -q -- "--project prj_" "$HOOK_TEST_TMP/dossier.log"
  grep -q -- "--project mcp-workstation" "$HOOK_TEST_TMP/dossier.log"
  # Regression lock: pr_lookup_task must not cap task_list with --limit.
  # The previous hardcoded `--limit 100` silently truncated the corpus once
  # it grew past 100 tasks. lib/pr-lookup.sh is shared between merge and
  # create hooks, so this lock lives in both bats files.
  ! grep -qE 'task_list[[:space:]].*--limit' "$HOOK_TEST_TMP/dossier.log"
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

@test "successful create without linked task surfaces a stdout reminder" {
  run_hook_split "success-without-task.json"

  [ "$status" -eq 0 ]
  # The reminder must land on STDOUT (the channel injected into the model's
  # context); the old _warn path went to stderr, which the PostToolUse
  # dispatcher swallows. With --separate-stderr, $output is stdout-only and
  # $stderr is stderr-only — so these assertions actually prove the routing.
  [[ "$output" == *"Reminder:"* ]]
  [[ "$output" == *"no dossier task linkage"* ]]
  [[ "$stderr" != *"Reminder:"* ]]
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

@test "malformed task reference in PR body surfaces a stdout reminder" {
  run_hook_split "malformed-body.json"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Reminder:"* ]]
  [[ "$output" == *"no dossier task linkage"* ]]
  [[ "$stderr" != *"Reminder:"* ]]
  [[ "$output" != *"Auto-linked"* ]]
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
