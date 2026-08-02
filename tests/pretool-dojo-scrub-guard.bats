#!/usr/bin/env bash

load test_helper

bats_require_minimum_version 1.5.0

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claude/dojo"
  guard="$BATS_TEST_DIRNAME/../scripts/pretool_dojo_scrub_guard.py"
}

run_guard() {
  local file_path="$1"
  local content="$2"
  local payload
  payload=$(jq -n --arg p "$file_path" --arg c "$content" \
    '{tool_input: {file_path: $p, content: $c}}')
  run --separate-stderr python3 "$guard" <<<"$payload"
}

@test "writes outside shared dojo lessons pass without a marker file" {
  run_guard "$HOME/dev/repo/notes.md" "customer-internal"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "shared dojo lessons fail closed when the marker file is missing" {
  run_guard "$HOME/.claude/dojo/lessons/example.md" "generic lesson"
  [ "$status" -eq 0 ]
  decision=$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")
  reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")
  [ "$decision" = "deny" ]
  [[ "$reason" == *"cannot read marker list"* ]]
}

@test "matching sensitive content is denied" {
  printf '/customer-internal/i\n' >"$HOME/.claude/dojo/scrub-markers.txt"
  run_guard "$HOME/.claude/dojo/lessons/example.md" "Customer-Internal project"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
  [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")" == *"sensitive marker"* ]]
}

@test "clean shared lesson content passes" {
  printf '/customer-internal/i\n' >"$HOME/.claude/dojo/scrub-markers.txt"
  run_guard "$HOME/.claude/dojo/lessons/example.md" "Use an early return to keep line of sight."
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
