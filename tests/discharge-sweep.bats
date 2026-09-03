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
  mkdir -p "$DISCHARGE_TRANSCRIPT_ROOT/-Users-mh-dev"

  # The sweep asks dossier for every task and reads their notes. Tests build
  # that response here rather than laying out corpus files.
  export DOSSIER_TEST_TASKS="$HOOK_TEST_TMP/tasks.json"
  printf '[]\n' >"$DOSSIER_TEST_TASKS"

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

# task appends a task to the dossier response. Extra arguments become note
# bodies, which is how a test asserts an already-recorded discharge is skipped.
#
# A task with no notes gets NO `notes` key, matching real dossier: the field is
# `skip_serializing_if = "Vec::is_empty"`. Reproducing that here is deliberate —
# a mock that always emitted the key would have hidden the bug this fixture
# exists to prevent.
task() {
  local id="$1"; shift
  local notes="[]" body
  for body in "$@"; do
    notes="$(jq -c --arg b "$body" '. + [{actor:"hook:stop-discharge",body:$b,posted_at:"2026-08-23T00:00:00Z"}]' <<<"$notes")"
  done

  local task_json
  task_json="$(jq -cn --arg id "$id" --argjson notes "$notes" '
    {id:$id, project:"prj_DEMO", project_slug:"demo", slug:"demo-task",
     title:"demo", status:"in_progress", body:""}
    + (if ($notes|length) > 0 then {notes:$notes} else {} end)
  ')"

  jq -c --argjson t "$task_json" '. + [$t]' "$DOSSIER_TEST_TASKS" >"$DOSSIER_TEST_TASKS.tmp"
  mv "$DOSSIER_TEST_TASKS.tmp" "$DOSSIER_TEST_TASKS"
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
  task tsk_aaa "[session 11111111] Session ended after 4 assistant turns."

  run "$SWEEP" --write

  [ "$status" -eq 0 ]
  [[ "$output" == *"discharged"* ]]
  [[ "$output" == *"1 recorded (100%)."* ]]
  [[ "$(dossier_log)" != *task_update* ]]
}

@test "another session's discharge on the same task is not this session's" {
  session 11111111-aaaa-bbbb-cccc-000000000001 tsk_aaa >/dev/null
  task tsk_aaa "[session 99999999] Session ended after 4 assistant turns."

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
  task tsk_aaa "[session 11111111] done"
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

  # Reads fine, writes fail. A stub that failed everything would die at the
  # index read instead, and this test would silently stop covering the write
  # path it is named for.
  local stub="$HOOK_TEST_TMP/write-failing-dossier"
  cat >"$stub" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *task_list*) printf '[]\n'; exit 0 ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$stub"

  DOSSIER_BIN="$stub" run "$SWEEP" --write

  [ "$status" -eq 1 ]
  [[ "$output" == *"dossier-update-failed"* ]]
}

@test "a dossier that cannot be read is an infrastructure error" {
  session 11111111-aaaa-bbbb-cccc-000000000001 tsk_aaa >/dev/null
  task tsk_aaa

  local stub="$HOOK_TEST_TMP/failing-dossier"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$stub"
  chmod +x "$stub"

  # Reading zero recorded discharges because dossier is down would report every
  # session as a gap and, under --write, rewrite the whole backlog.
  DOSSIER_BIN="$stub" run "$SWEEP"

  [ "$status" -eq 1 ]
  [[ "$output" == *"recorded discharges"* ]]
}

@test "an absent transcript root is a quiet no-op, not a failure" {
  DISCHARGE_TRANSCRIPT_ROOT="$HOOK_TEST_TMP/nope" run "$SWEEP"

  [ "$status" -eq 0 ]
  [[ "$output" == *"no session in the last"* ]]
}

# A non-numeric window makes `find` fail with its stderr discarded, which
# would report as "no sessions found" and exit green: a typo as a false
# coverage number. Refuse it up front instead.
@test "a non-numeric scan window is refused, not read as an empty scan" {
  session 11111111-aaaa-bbbb-cccc-000000000001 tsk_aaa >/dev/null
  task tsk_aaa

  run "$SWEEP" --since-days banana
  [ "$status" -eq 1 ]
  [[ "$output" == *"--since-days needs a non-negative integer"* ]]

  run "$SWEEP" --quiet-minutes nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"--quiet-minutes needs a non-negative integer"* ]]

  run "$SWEEP" --since-days
  [ "$status" -eq 1 ]
  [[ "$output" == *"--since-days needs a non-negative integer"* ]]
}

@test "an unknown argument is refused rather than ignored" {
  run "$SWEEP" --backfill-everything

  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown argument"* ]]
}
