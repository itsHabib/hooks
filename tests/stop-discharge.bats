#!/usr/bin/env bash

load test_helper

setup() {
  export PATH="$BATS_TEST_DIRNAME/fixtures/bin:$PATH"
  export DOSSIER_BIN=dossier
  export DOSSIER_CORPUS="$BATS_TEST_DIRNAME/fixtures/corpus"
  export HOOK_TEST_TMP="$BATS_TEST_DIRNAME/tmp"
  rm -rf "$HOOK_TEST_TMP"
  mkdir -p "$HOOK_TEST_TMP"
  export HOOKS_ERROR_LOG="$HOOK_TEST_TMP/hooks-errors.log"
}

# transcript writes a JSONL transcript containing one tool_use per task id, plus
# the assistant turns those calls belong to, and prints its path.
transcript() {
  local path="$HOOK_TEST_TMP/transcript.jsonl" id
  : >"$path"
  for id in "$@"; do
    jq -cn --arg id "$id" \
      '{type:"assistant",message:{content:[{type:"tool_use",name:"mcp__dossier__task_update",input:{id:$id}}]}}' \
      >>"$path"
  done
  printf '%s' "$path"
}

event() {
  jq -cn --arg t "${1:-}" --argjson reentrant "${2:-false}" \
    '{hook_event_name:"Stop", session_id:"sess1234abcd", transcript_path:$t,
      cwd:"/tmp", stop_hook_active:$reentrant}'
}

# event_camel is the Codex-shaped envelope: same fields, camelCase keys. Every
# hook that consumes an event needs both shapes covered (cross-harness parity
# is part of the wire contract).
event_camel() {
  jq -cn --arg t "${1:-}" --argjson reentrant "${2:-false}" \
    '{hookEventName:"Stop", sessionId:"sess1234abcd", transcriptPath:$t,
      cwd:"/tmp", stopHookActive:$reentrant}'
}

run_hook() {
  run bash -c "'$BATS_TEST_DIRNAME/../scripts/stop-discharge.sh' --no-timeout <<<'$1'"
}

@test "a session that touched tasks gets a discharge on each" {
  local t; t="$(transcript tsk_aaa tsk_bbb)"
  run_hook "$(event "$t")"

  [ "$status" -eq 0 ]
  [[ "$output" == *"2 dossier task(s)"* ]]
}

@test "the number of tasks written is capped" {
  local t; t="$(transcript tsk_aaa tsk_bbb tsk_ccc tsk_ddd tsk_eee)"
  DISCHARGE_MAX_TASKS=2 run bash -c \
    "DISCHARGE_MAX_TASKS=2 '$BATS_TEST_DIRNAME/../scripts/stop-discharge.sh' --no-timeout <<<'$(event "$t")'"

  [ "$status" -eq 0 ]
  [[ "$output" == *"2 dossier task(s)"* ]]
}

@test "the same task touched repeatedly is discharged once" {
  local t; t="$(transcript tsk_aaa tsk_aaa tsk_aaa)"
  run_hook "$(event "$t")"

  [ "$status" -eq 0 ]
  [[ "$output" == *"1 dossier task(s)"* ]]
}

# A hook that comments on every exit is a hook people turn off, so a session
# that touched no task must say nothing at all.
@test "a session that touched no task is silent" {
  local t; t="$(transcript)"
  run_hook "$(event "$t")"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# A Stop hook acting on its own continuation drives an unbounded loop.
@test "a re-entrant Stop is a no-op" {
  local t; t="$(transcript tsk_aaa)"
  run_hook "$(event "$t" true)"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a Codex-shaped event gets the same discharge" {
  local t; t="$(transcript tsk_aaa tsk_bbb)"
  run_hook "$(event_camel "$t")"

  [ "$status" -eq 0 ]
  [[ "$output" == *"2 dossier task(s)"* ]]
}

# The camelCase re-entrancy guard matters twice: the jq check must catch it,
# and the fast-path literal must too (a fall-through here is a silent perf
# regression on every Codex session end, not a correctness bug).
@test "a re-entrant Codex-shaped Stop is a no-op" {
  local t; t="$(transcript tsk_aaa)"
  run_hook "$(event_camel "$t" true)"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a missing transcript is a no-op, not a failure" {
  run_hook "$(event "$HOOK_TEST_TMP/does-not-exist.jsonl")"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an event with no transcript path is a no-op" {
  run_hook "$(event "")"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "empty stdin is a no-op" {
  run bash -c "'$BATS_TEST_DIRNAME/../scripts/stop-discharge.sh' --no-timeout </dev/null"

  [ "$status" -eq 0 ]
}

# The whole point of the hook is that it never becomes the reason a person waits
# or a session fails, so no input may produce a non-zero exit.
@test "malformed event json still exits zero" {
  run bash -c "'$BATS_TEST_DIRNAME/../scripts/stop-discharge.sh' --no-timeout <<<'not json at all'"

  [ "$status" -eq 0 ]
}
