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
  export HOOKS_STATE_DIR="$HOOK_TEST_TMP/state"
}

# record appends one raw JSONL record to the transcript at $1.
record() {
  printf '%s\n' "$2" >>"$1"
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

# Stop fires after every response, and each one sees the cumulative transcript.
# The second Stop of a session owes nothing on a task the first already paid.
@test "a second Stop in the same session does not discharge the same task twice" {
  local t; t="$(transcript tsk_aaa)"
  run_hook "$(event "$t")"
  [[ "$output" == *"1 dossier task(s)"* ]]

  run_hook "$(event "$t")"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a task first touched after an earlier discharge still gets its own" {
  local t; t="$(transcript tsk_aaa)"
  run_hook "$(event "$t")"

  t="$(transcript tsk_aaa tsk_bbb)"
  run_hook "$(event "$t")"

  [ "$status" -eq 0 ]
  [[ "$output" == *"1 dossier task(s)"* ]]
}

# The fold's deadline must sit inside the hook's, or the fold takes the mark
# down with it when the outer timeout fires first.
@test "a fold that outlives its clamped budget still leaves the mark" {
  command -v timeout >/dev/null 2>&1 || skip "needs GNU timeout"
  local t; t="$(transcript tsk_aaa)"
  local started; started="$(date +%s)"

  run bash -c "DISCHARGE_FOLD_CMD='sleep 30' DISCHARGE_FOLD_TIMEOUT=30 \
    '$BATS_TEST_DIRNAME/../scripts/stop-discharge.sh' --no-timeout <<<'$(event "$t")'"

  [ "$status" -eq 0 ]
  [[ "$output" == *"1 dossier task(s)"* ]]
  [ "$(( $(date +%s) - started ))" -lt 10 ]
}

@test "a PR URL in prose is not a PR touched; one in a tool call is" {
  local t="$HOOK_TEST_TMP/prs.jsonl"
  : >"$t"
  record "$t" '{"type":"user","message":{"content":"look at https://github.com/o/r/pull/1 please"}}'
  record "$t" '{"type":"assistant","message":{"content":[{"type":"text","text":"see https://github.com/o/r/pull/2"}]}}'
  record "$t" '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"gh pr view https://github.com/o/r/pull/3"}}]}}'
  record "$t" '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"x","content":"https://github.com/o/r/pull/4"}]}}'
  source "$BATS_TEST_DIRNAME/../lib/transcript.sh"

  run transcript_pr_urls "$t"

  [ "$output" == $'https://github.com/o/r/pull/3\nhttps://github.com/o/r/pull/4' ]
}

@test "an edit whose result errored is not a file written" {
  local t="$HOOK_TEST_TMP/edits.jsonl"
  : >"$t"
  record "$t" '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/w/stale.sh"}}]}}'
  record "$t" '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"old_string not found"}]}}'
  record "$t" '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Write","input":{"file_path":"/w/ok.sh"}}]}}'
  record "$t" '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"ok"}]}}'
  source "$BATS_TEST_DIRNAME/../lib/transcript.sh"

  run transcript_files_written "$t"

  [ "$output" == "/w/ok.sh" ]
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
