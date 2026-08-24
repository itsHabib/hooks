#!/usr/bin/env bash

load test_helper

setup() {
  export PATH="$BATS_TEST_DIRNAME/fixtures/bin:$PATH"
  export DOSSIER_BIN=dossier
  export HOOK_TEST_TMP="$BATS_TEST_DIRNAME/tmp/discharge-sweep"
  rm -rf "$HOOK_TEST_TMP"
  mkdir -p "$HOOK_TEST_TMP"
  export HOOKS_ERROR_LOG="$HOOK_TEST_TMP/hooks-errors.log"

  export DISCHARGE_TRANSCRIPT_ROOT="$HOOK_TEST_TMP/transcripts"
  export DOSSIER_CORPUS="$HOOK_TEST_TMP/corpus"
  mkdir -p "$DISCHARGE_TRANSCRIPT_ROOT/-Users-mh-dev" \
           "$DOSSIER_CORPUS/projects/demo/tasks"

  SWEEP="$BATS_TEST_DIRNAME/../scripts/discharge-sweep.sh"
  chmod +x "$SWEEP"
}

# stamp_old backdates a file past any sane quiet window while keeping it inside
# the --since-days window. BSD `date -v` first, GNU `date -d` second: the same
# fallback order the scripts use, for the same reason.
stamp_old() {
  local when
  when="$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M)"
  touch -t "$when" "$1"
}

# session writes a transcript naming each task id, backdates it, prints its path.
session() {
  local id="$1"; shift
  local path="$DISCHARGE_TRANSCRIPT_ROOT/-Users-mh-dev/$id.jsonl" task
  : >"$path"
  for task in "$@"; do
    jq -cn --arg id "$task" \
      '{type:"assistant",message:{content:[{type:"tool_use",name:"mcp__dossier__task_update",input:{id:$id}}]}}' \
      >>"$path"
  done
  stamp_old "$path"
  printf '%s' "$path"
}

# task writes a corpus task file. Any extra arguments become note lines, which
# is how a test asserts that an already-recorded discharge is left alone.
task() {
  local id="$1"; shift
  local path="$DOSSIER_CORPUS/projects/demo/tasks/$id-demo-task.md"
  {
    printf -- '---\nid: %s\nstatus: in_progress\n---\n\n## Notes\n\n' "$id"
    printf -- '- %s\n' "$@"
  } >"$path"
}

dossier_log() {
  cat "$HOOK_TEST_TMP/dossier.log" 2>/dev/null || true
}

@test "a quiet session that owes a discharge is reported as a gap" {
  session 11111111-aaaa-bbbb-cccc-000000000001 tsk_aaa >/dev/null
  task tsk_aaa

  run "$SWEEP"

  [ "$status" -eq 0 ]
  [[ "$output" == *"11111111 | tsk_aaa"* ]]
  [[ "$output" == *"gap"* ]]
  [[ "$output" == *"1 sessions owed a discharge on 1 task(s); 0 recorded (0%)."* ]]
}

@test "reporting is the default: a gap run performs zero dossier writes" {
  session 11111111-aaaa-bbbb-cccc-000000000001 tsk_aaa >/dev/null
  task tsk_aaa

  run "$SWEEP"

  [ "$status" -eq 0 ]
  [[ "$(dossier_log)" != *task_update* ]]
}

@test "--write backfills the gap and says the sweep did it" {
  session 11111111-aaaa-bbbb-cccc-000000000001 tsk_aaa >/dev/null
  task tsk_aaa

  run "$SWEEP" --write

  [ "$status" -eq 0 ]
  [[ "$output" == *"backfilled"* ]]
  [[ "$(dossier_log)" == *task_update* ]]
  [[ "$(dossier_log)" == *"[session 11111111] (backfilled by sweep)"* ]]
  [[ "$(dossier_log)" == *"hook:discharge-sweep"* ]]
}

@test "a task that already carries this session's discharge is left alone" {
  session 11111111-aaaa-bbbb-cccc-000000000001 tsk_aaa >/dev/null
  task tsk_aaa "2026-08-23T00:00:00Z — hook:stop-discharge: [session 11111111] Session ended after 4 assistant turns."

  run "$SWEEP" --write

  [ "$status" -eq 0 ]
  [[ "$output" == *"discharged"* ]]
  [[ "$output" == *"1 recorded (100%)."* ]]
  [[ "$(dossier_log)" != *task_update* ]]
}

@test "another session's discharge on the same task is not this session's" {
  session 11111111-aaaa-bbbb-cccc-000000000001 tsk_aaa >/dev/null
  task tsk_aaa "2026-08-23T00:00:00Z — hook:stop-discharge: [session 99999999] Session ended after 4 assistant turns."

  run "$SWEEP"

  [ "$status" -eq 0 ]
  [[ "$output" == *"gap"* ]]
}

@test "a session that named no task owes nothing and is not counted" {
  local path="$DISCHARGE_TRANSCRIPT_ROOT/-Users-mh-dev/22222222-aaaa-bbbb-cccc-000000000002.jsonl"
  jq -cn '{type:"assistant",message:{content:[{type:"text",text:"just thinking"}]}}' >"$path"
  stamp_old "$path"

  run "$SWEEP"

  [ "$status" -eq 0 ]
  [[ "$output" == *"no session in the last"* ]]
}

@test "a transcript still being appended to belongs to a live session and is skipped" {
  local path="$DISCHARGE_TRANSCRIPT_ROOT/-Users-mh-dev/33333333-aaaa-bbbb-cccc-000000000003.jsonl"
  jq -cn '{type:"assistant",message:{content:[{type:"tool_use",name:"mcp__dossier__task_update",input:{id:"tsk_aaa"}}]}}' >"$path"
  task tsk_aaa

  run "$SWEEP"

  [ "$status" -eq 0 ]
  [[ "$output" == *"no session in the last"* ]]
}

@test "subagent and workflow journals are not sessions" {
  mkdir -p "$DISCHARGE_TRANSCRIPT_ROOT/-Users-mh-dev/abc/subagents/workflows/wf_x"
  local path="$DISCHARGE_TRANSCRIPT_ROOT/-Users-mh-dev/abc/subagents/workflows/wf_x/journal.jsonl"
  jq -cn '{type:"assistant",message:{content:[{type:"tool_use",name:"mcp__dossier__task_update",input:{id:"tsk_aaa"}}]}}' >"$path"
  stamp_old "$path"
  task tsk_aaa

  run "$SWEEP"

  [ "$status" -eq 0 ]
  [[ "$output" == *"no session in the last"* ]]
}

@test "coverage counts session-task pairs, not sessions" {
  session 11111111-aaaa-bbbb-cccc-000000000001 tsk_aaa tsk_bbb >/dev/null
  task tsk_aaa "2026-08-23T00:00:00Z — hook:stop-discharge: [session 11111111] done"
  task tsk_bbb

  run "$SWEEP"

  [ "$status" -eq 0 ]
  [[ "$output" == *"1 sessions owed a discharge on 2 task(s); 1 recorded (50%)."* ]]
}

@test "the per-session task cap is the hook's cap" {
  session 11111111-aaaa-bbbb-cccc-000000000001 tsk_aaa tsk_bbb tsk_ccc tsk_ddd >/dev/null
  task tsk_aaa; task tsk_bbb; task tsk_ccc; task tsk_ddd

  DISCHARGE_MAX_TASKS=2 run "$SWEEP"

  [ "$status" -eq 0 ]
  [[ "$output" == *"on 2 task(s)"* ]]
}

@test "a dossier write failure is an infrastructure error, not a green sweep" {
  session 11111111-aaaa-bbbb-cccc-000000000001 tsk_aaa >/dev/null
  task tsk_aaa

  local stub="$HOOK_TEST_TMP/failing-dossier"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$stub"
  chmod +x "$stub"

  DOSSIER_BIN="$stub" run "$SWEEP" --write

  [ "$status" -eq 1 ]
  [[ "$output" == *"dossier-update-failed"* ]]
}

@test "a missing corpus is an infrastructure error" {
  DOSSIER_CORPUS="$HOOK_TEST_TMP/nope" run "$SWEEP"

  [ "$status" -eq 1 ]
  [[ "$output" == *"no dossier corpus"* ]]
}

@test "an absent transcript root is a quiet no-op, not a failure" {
  DISCHARGE_TRANSCRIPT_ROOT="$HOOK_TEST_TMP/nope" run "$SWEEP"

  [ "$status" -eq 0 ]
  [[ "$output" == *"no session in the last"* ]]
}

@test "an unknown argument is refused rather than ignored" {
  run "$SWEEP" --backfill-everything

  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown argument"* ]]
}
