#!/usr/bin/env bash

load test_helper

bats_require_minimum_version 1.5.0

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.claude/dojo"
  guard="$BATS_TEST_DIRNAME/../scripts/pretool-dojo-scrub-guard.sh"
}

run_guard() {
  local file_path="$1"
  local content="$2"
  local payload
  payload=$(jq -n --arg p "$file_path" --arg c "$content" \
    '{tool_input: {file_path: $p, content: $c}}')
  run --separate-stderr bash "$guard" <<<"$payload"
}

run_codex_patch_guard() {
  local patch="$1"
  local payload
  payload=$(jq -n --arg cwd "$HOME/dev/repo" --arg command "$patch" \
    '{tool_name:"apply_patch", cwd:$cwd, tool_input:{command:$command}}')
  run --separate-stderr bash "$guard" <<<"$payload"
}

@test "writes outside shared dojo lessons pass without a marker file" {
  run_guard "$HOME/dev/repo/notes.md" "customer-internal"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "lookalike repo path is not treated as the shared home directory" {
  run_guard "$HOME/dev/repo/notes/.claude/dojo/lessons/example.md" "customer-internal"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "shared dojo lessons fail closed when the marker file is missing" {
  run_guard "$HOME/.claude/dojo/lessons/example.md" "generic lesson"
  [ "$status" -eq 0 ]
  decision=$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")
  reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")
  [ "$decision" = "deny" ]
  [[ "$reason" == *"cannot read the local marker list"* ]]
  [ -z "$stderr" ]
}

@test "matching sensitive content is denied" {
  printf '/customer-internal/i\n' >"$HOME/.claude/dojo/scrub-markers.txt"
  run_guard "$HOME/.claude/dojo/lessons/example.md" "Customer-Internal project"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
  reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")
  [[ "$reason" == *"sensitive local marker"* ]]
  [[ "$reason" != *"customer-internal"* ]]
  [ -z "$stderr" ]
}

@test "Codex apply_patch writes to shared lessons are scanned" {
  printf '/customer-internal/i\n' >"$HOME/.claude/dojo/scrub-markers.txt"
  run_codex_patch_guard "*** Begin Patch
*** Add File: $HOME/.claude/dojo/lessons/example.md
+Customer-Internal project
*** End Patch"

  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
  [ -z "$stderr" ]
}

@test "Codex apply_patch resolves relative paths and dot segments" {
  printf '/customer-internal/i\n' >"$HOME/.claude/dojo/scrub-markers.txt"
  run_codex_patch_guard "*** Begin Patch
*** Add File: ../../.claude/dojo/lessons/example.md
+Customer-Internal project
*** End Patch"

  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
  [ -z "$stderr" ]
}

@test "Codex apply_patch outside shared lessons passes" {
  run_codex_patch_guard "*** Begin Patch
*** Add File: docs/lesson.md
+Customer-Internal project
*** End Patch"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "matching sensitive lesson filenames are denied without scanning the home prefix" {
  export HOME="$BATS_TEST_TMPDIR/customer-internal-home"
  mkdir -p "$HOME/.claude/dojo"
  printf '/customer-internal/i\n' >"$HOME/.claude/dojo/scrub-markers.txt"

  run_guard "$HOME/.claude/dojo/lessons/customer-internal.md" "Generic lesson"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
  [ -z "$stderr" ]

  run_guard "$HOME/.claude/dojo/lessons/generic.md" "Generic lesson"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "clean shared lesson content passes" {
  printf '/customer-internal/i\n' >"$HOME/.claude/dojo/scrub-markers.txt"
  run_guard "$HOME/.claude/dojo/lessons/example.md" "Use an early return to keep line of sight."
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "empty marker patterns are ignored" {
  printf '//i\n' >"$HOME/.claude/dojo/scrub-markers.txt"
  run_guard "$HOME/.claude/dojo/lessons/example.md" "generic lesson"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "invalid marker regexes are ignored without leaking diagnostics" {
  printf '/customer-[internal/i\n' >"$HOME/.claude/dojo/scrub-markers.txt"
  run_guard "$HOME/.claude/dojo/lessons/example.md" "customer-internal"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "CRLF marker files are supported" {
  printf '/customer-internal/i\r\n' >"$HOME/.claude/dojo/scrub-markers.txt"
  run_guard "$HOME/.claude/dojo/lessons/example.md" "Customer-Internal project"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
  [ -z "$stderr" ]
}
