#!/usr/bin/env bash
# Unit tests for the PreToolUse(Bash) broad-`git add` guard. Pipes synthesized
# tool-call payloads into the hook and asserts the deny decision is emitted for
# broad-add forms and withheld for explicit-path adds.

HOOK="$BATS_TEST_DIRNAME/../scripts/pretool-block-broad-git-add.sh"

run_cmd() {
  local payload
  payload="$(jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}')"
  run bash -c 'printf "%s" "$1" | bash "$2"' _ "$payload" "$HOOK"
}

assert_blocked() {
  run_cmd "$1"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision":"deny"'* ]]
}

assert_allowed() {
  run_cmd "$1"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- broad forms: must block ---

@test "blocks: git add -A" { assert_blocked "git add -A"; }
@test "blocks: git add ." { assert_blocked "git add ."; }
@test "blocks: git add --all" { assert_blocked "git add --all"; }
@test "blocks: git add -A . (combined)" { assert_blocked "git add -A ."; }
@test "blocks: bare dot after explicit file" { assert_blocked "git add foo ."; }
@test "blocks: compound cd && git add -A" { assert_blocked "cd repo && git add -A"; }
@test "blocks: git add . && git push" { assert_blocked "git add . && git push"; }
@test "blocks: env-prefixed git add ." { assert_blocked "GIT_PAGER=cat git add ."; }

# --- explicit / narrow forms: must pass through ---

@test "allows: explicit file path" { assert_allowed "git add src/foo.ts"; }
@test "allows: file literally named .gitignore" { assert_allowed "git add .gitignore"; }
@test "allows: .gitignore in a compound command" { assert_allowed "git add .gitignore && git push"; }
@test "allows: relative ./src path" { assert_allowed "git add ./src"; }
@test "allows: interactive -p" { assert_allowed "git add -p"; }
@test "allows: multiple explicit paths" { assert_allowed "git add docs/a.md docs/b.md"; }
@test "allows: non-add git command" { assert_allowed "git status"; }
@test "allows: unrelated command" { assert_allowed "npm install"; }

# --- robustness ---

@test "soft-passes on malformed stdin (no decision)" {
  run bash -c 'printf "%s" "not json" | bash "$1"' _ "$HOOK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
