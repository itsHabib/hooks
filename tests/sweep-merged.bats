#!/usr/bin/env bash

bats_require_minimum_version 1.5.0

load test_helper

setup() {
  export PATH="$BATS_TEST_DIRNAME/fixtures/sweep-merged/bin:$PATH"
  export DOSSIER_BIN=dossier
  export DOSSIER_CORPUS="$BATS_TEST_DIRNAME/fixtures/sweep-merged/corpus"
  export HOOK_TEST_TMP="$BATS_TEST_DIRNAME/tmp/sweep-merged"
  rm -rf "$HOOK_TEST_TMP"
  mkdir -p "$HOOK_TEST_TMP"
  export HOOKS_ERROR_LOG="$HOOK_TEST_TMP/hooks-errors.log"
  chmod +x \
    "$BATS_TEST_DIRNAME/fixtures/sweep-merged/bin/dossier" \
    "$BATS_TEST_DIRNAME/fixtures/sweep-merged/bin/gh" \
    "$BATS_TEST_DIRNAME/../scripts/sweep-merged.sh"
}

run_sweep() {
  run "$BATS_TEST_DIRNAME/../scripts/sweep-merged.sh" "$@"
}

@test "merged PRs are swept: todo gets the full chain, in_progress skips claim" {
  run_sweep

  [ "$status" -eq 0 ]
  [[ "$output" == *"task_slug | PR | state | action-taken"* ]]
  [[ "$output" == *"sweep-merged-task | #101 | MERGED | swept"* ]]
  [[ "$output" == *"todo-merged-task | #104 | MERGED | swept"* ]]
  [[ "$output" == *"open-pr-task | #102 | OPEN | untouched"* ]]
  [[ "$output" == *"closed-pr-task | #103 | CLOSED | untouched"* ]]

  # todo task: full chain — claim, update, complete (+ link)
  grep -qE 'task_claim.*tsk_SWEEP04' "$HOOK_TEST_TMP/dossier.log"
  grep -qE 'task_update.*tsk_SWEEP04' "$HOOK_TEST_TMP/dossier.log"
  grep -qE 'task_complete.*tsk_SWEEP04' "$HOOK_TEST_TMP/dossier.log"
  # in_progress task: never claimed or status-bumped — straight to complete
  ! grep -qE 'task_claim.*tsk_SWEEP01' "$HOOK_TEST_TMP/dossier.log"
  ! grep -qE 'task_update.*tsk_SWEEP01' "$HOOK_TEST_TMP/dossier.log"
  grep -qE 'task_complete.*tsk_SWEEP01' "$HOOK_TEST_TMP/dossier.log"
  grep -q "artifact_link" "$HOOK_TEST_TMP/dossier.log"
  grep -q "abc123def4567890abcdef1234567890abcdef12" "$HOOK_TEST_TMP/dossier.log"
  grep -q "PR #101 merge commit (swept)" "$HOOK_TEST_TMP/dossier.log"
  grep -q "pr view 101" "$HOOK_TEST_TMP/gh.log"
  ! grep -qE 'task_list[[:space:]].*--limit' "$HOOK_TEST_TMP/dossier.log"
}

@test "second sweep is a no-op at the dossier write layer" {
  run_sweep
  [ "$status" -eq 0 ]

  first_claim="$(grep -c 'task_claim NEW' "$HOOK_TEST_TMP/dossier.log")"
  first_update="$(grep -c 'task_update NEW' "$HOOK_TEST_TMP/dossier.log")"
  first_complete="$(grep -c 'task_complete NEW' "$HOOK_TEST_TMP/dossier.log")"
  first_link="$(grep -c 'artifact_link NEW' "$HOOK_TEST_TMP/dossier.log")"
  [ "$first_claim" -eq 1 ]
  [ "$first_update" -eq 1 ]
  [ "$first_complete" -eq 2 ]
  [ "$first_link" -eq 2 ]

  run_sweep
  [ "$status" -eq 0 ]
  [[ "$output" != *"swept"* ]]

  [ "$(grep -c 'task_claim NEW' "$HOOK_TEST_TMP/dossier.log")" -eq 1 ]
  [ "$(grep -c 'task_update NEW' "$HOOK_TEST_TMP/dossier.log")" -eq 1 ]
  [ "$(grep -c 'task_complete NEW' "$HOOK_TEST_TMP/dossier.log")" -eq 2 ]
  [ "$(grep -c 'artifact_link NEW' "$HOOK_TEST_TMP/dossier.log")" -eq 2 ]
  [ "$(grep -c 'task_list' "$HOOK_TEST_TMP/dossier.log")" -eq 2 ]
}

@test "pre-linked commit artifact resumes the close-out without re-linking" {
  local corpus_copy="$HOOK_TEST_TMP/corpus"
  cp -r "$BATS_TEST_DIRNAME/fixtures/sweep-merged/corpus" "$corpus_copy"
  printf '%s\n' '{"id":"art_RESUME","project":"mcp-workstation","task":"tsk_SWEEP04","kind":"commit","ref":"beef104beef104beef104beef104beef104beef1","label":"PR #104 merge commit (swept)","linked_at":"2026-01-01T00:00:00Z","actor":"hook:sweep-merged"}' \
    >>"$corpus_copy/projects/mcp-workstation/artifacts.jsonl"

  run env DOSSIER_CORPUS="$corpus_copy" "$BATS_TEST_DIRNAME/../scripts/sweep-merged.sh"

  [ "$status" -eq 0 ]
  [[ "$output" == *"todo-merged-task | #104 | MERGED | swept-resumed"* ]]
  ! grep -qE 'artifact_link.*beef104' "$HOOK_TEST_TMP/dossier.log"
  grep -qE 'task_complete.*tsk_SWEEP04' "$HOOK_TEST_TMP/dossier.log"
}

@test "gh pr view failure is an infrastructure error (non-zero exit)" {
  local failing_bin="$HOOK_TEST_TMP/failing-bin"
  mkdir -p "$failing_bin"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$failing_bin/gh"
  chmod +x "$failing_bin/gh"

  run --separate-stderr env PATH="$failing_bin:$PATH" "$BATS_TEST_DIRNAME/../scripts/sweep-merged.sh"

  [ "$status" -ne 0 ]
  [[ "$output" == *"gh-view-failed"* ]]
  [[ "$stderr" == *"infrastructure failure"* ]]
  ! grep -qE 'task_claim|task_update|task_complete|artifact_link' "$HOOK_TEST_TMP/dossier.log"
}

@test "--dry-run performs zero dossier mutations" {
  run_sweep --dry-run

  [ "$status" -eq 0 ]
  [[ "$output" == *"sweep-merged-task | #101 | MERGED | would-sweep"* ]]
  if [[ -f "$HOOK_TEST_TMP/dossier.log" ]]; then
    ! grep -qE 'task_claim|task_update|task_complete|artifact_link' "$HOOK_TEST_TMP/dossier.log"
  fi
  grep -q "pr view 101" "$HOOK_TEST_TMP/gh.log"
}

@test "missing gh is an infrastructure error" {
  local minimal_bin="$HOOK_TEST_TMP/minimal-bin"
  local cmd
  mkdir -p "$minimal_bin"
  cp "$BATS_TEST_DIRNAME/fixtures/sweep-merged/bin/dossier" "$minimal_bin/dossier"
  chmod +x "$minimal_bin/dossier"
  for cmd in bash jq dirname cat printf mkdir rm mktemp awk sed grep head tr date; do
    ln -sf "$(command -v "$cmd")" "$minimal_bin/$cmd"
  done

  run --separate-stderr env PATH="$minimal_bin" "$BATS_TEST_DIRNAME/../scripts/sweep-merged.sh"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"gh not found"* ]]
  [ ! -f "$HOOK_TEST_TMP/dossier.log" ]
}
