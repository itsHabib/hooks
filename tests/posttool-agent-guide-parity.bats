#!/usr/bin/env bash

load test_helper

bats_require_minimum_version 1.5.0

setup() {
  repo="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$repo"
  hook="$BATS_TEST_DIRNAME/../scripts/posttool-agent-guide-parity.sh"
}

write_pair() {
  printf '# Guide\n' >"$repo/CLAUDE.md"
  printf '# Guide\n' >"$repo/AGENTS.md"
}

run_edit() {
  local path="$1"
  payload=$(jq -n --arg cwd "$repo" --arg path "$path" \
    '{tool_name:"Edit",cwd:$cwd,tool_input:{file_path:$path}}')
  run --separate-stderr bash "$hook" <<<"$payload"
}

run_patch() {
  local patch="$1"
  payload=$(jq -n --arg cwd "$repo" --arg command "$patch" \
    '{tool_name:"apply_patch",cwd:$cwd,tool_input:{command:$command}}')
  run --separate-stderr bash "$hook" <<<"$payload"
}

@test "non-guide edits are silent" {
  write_pair
  run_edit "$repo/README.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "a one-sided Claude edit prompts a sibling review" {
  write_pair
  run_edit "$repo/CLAUDE.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLAUDE.md changed alone"* ]]
  [ -z "$stderr" ]
}

@test "a missing Codex counterpart is named" {
  printf '# Guide\n' >"$repo/CLAUDE.md"
  run_edit "$repo/CLAUDE.md"
  [[ "$output" == *"missing AGENTS.md"* ]]
}

@test "a forwarding-only Codex shim is rejected" {
  printf '# Detailed guide\n' >"$repo/CLAUDE.md"
  printf '# Codex\n\nRead CLAUDE.md.\n' >"$repo/AGENTS.md"
  run_edit "$repo/CLAUDE.md"
  [[ "$output" == *"forwarding shim"* ]]
}

@test "managed block drift is named" {
  printf '<!-- BEGIN dev-workbench -->\nClaude\n<!-- END dev-workbench -->\n' >"$repo/CLAUDE.md"
  printf '<!-- BEGIN dev-workbench -->\nCodex\n<!-- END dev-workbench -->\n' >"$repo/AGENTS.md"
  run_edit "$repo/AGENTS.md"
  [[ "$output" == *"dev-workbench block differs"* ]]
}

@test "a paired apply_patch with equal final guides is silent" {
  write_pair
  run_patch '*** Begin Patch
*** Update File: CLAUDE.md
*** Update File: AGENTS.md
*** End Patch'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "a paired guide deletion is silent" {
  write_pair
  unlink "$repo/CLAUDE.md"
  unlink "$repo/AGENTS.md"
  run_patch '*** Begin Patch
*** Delete File: CLAUDE.md
*** Delete File: AGENTS.md
*** End Patch'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "Codex apply_patch resolves nested relative guide paths" {
  mkdir -p "$repo/cmd/gate"
  printf '# Guide\n' >"$repo/cmd/gate/CLAUDE.md"
  run_patch '*** Begin Patch
*** Update File: cmd/gate/CLAUDE.md
*** End Patch'
  [[ "$output" == *"cmd/gate is missing AGENTS.md"* ]]
}

@test "Codex edits recognize Windows drive paths as absolute" {
  mkdir -p "$repo/C:/nested"
  printf '# Guide\n' >"$repo/C:/nested/CLAUDE.md"
  printf '# Guide\n' >"$repo/C:/nested/AGENTS.md"
  payload=$(jq -n --arg cwd "$repo" --arg path 'C:\nested\CLAUDE.md' \
    '{tool_name:"Edit",cwd:$cwd,tool_input:{file_path:$path}}')

  run --separate-stderr bash -c 'cd "$1" && bash "$2"' _ "$repo" "$hook" <<<"$payload"

  [ "$status" -eq 0 ]
  [[ "$output" == *"CLAUDE.md changed alone"* ]]
  [ -z "$stderr" ]
}

@test "malformed input fails silent" {
  run --separate-stderr bash "$hook" <<<'not-json'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}
