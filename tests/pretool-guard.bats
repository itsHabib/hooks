#!/usr/bin/env bash

load test_helper

# `run --separate-stderr` needs bats >= 1.5.0.
bats_require_minimum_version 1.5.0

# Feed the guard a PreToolUse payload for a shell command and capture the
# verdict: exit 0 = pass, exit 2 = block (denial + remedy on stderr).
run_guard() {
  local json
  json=$(jq -n --arg c "$1" '{tool_input: {command: $c}}')
  run --separate-stderr bash "$BATS_TEST_DIRNAME/../scripts/pretool-guard.sh" <<<"$json"
}

# --- custody: operator-only verbs ---

@test "custody grant is blocked (mint authority stays with the operator)" {
  run_guard "custody grant -key tracker -actions read -ttl 8h"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"operator-only"* ]]
  [[ "$stderr" == *"Remedy:"* ]]
}

@test "custody keys set is blocked (secret entry stays with the operator)" {
  run_guard "custody keys set -name tracker-pat"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"operator-only"* ]]
}

@test "custody.exe grant is blocked too" {
  run_guard "./custody.exe grant -key tracker -actions read -ttl 8h"
  [ "$status" -eq 2 ]
}

@test "custody read verbs pass" {
  run_guard "custody log -key tracker -since 24h"
  [ "$status" -eq 0 ]
  run_guard "custody explain -req req_abc123"
  [ "$status" -eq 0 ]
}

@test "paths that merely contain custody don't trip the verb rule" {
  run_guard "cat docs/features/custody/grant-notes.md"
  [ "$status" -eq 0 ]
}

# --- custody verbs: normalized spellings (case, quoted exe, split token) ---

@test "quoted exe + capitalized verb is blocked (PowerShell call operator)" {
  run_guard '& "custody.exe" Grant -key tracker -actions read -ttl 8h'
  [ "$status" -eq 2 ]
}

@test "quote-split verb is blocked" {
  run_guard 'custody gr""ant -key tracker -actions read -ttl 8h'
  [ "$status" -eq 2 ]
}

@test "env-indirected verb is NOT caught (accepted obfuscation under discipline)" {
  run_guard 'verb=grant; custody "$verb" -key tracker -actions read -ttl 8h'
  [ "$status" -eq 0 ]
}

# --- custody verbs: command position, not prose (P2 false-positive fix) ---

@test "the verb inside a commit message is NOT blocked" {
  run_guard 'git commit -m "document custody grant in the rulebook"'
  [ "$status" -eq 0 ]
}

@test "the verb inside a search string is NOT blocked" {
  run_guard 'rg "custody keys" docs'
  [ "$status" -eq 0 ]
}

@test "piped custody verb is still blocked (command position after |)" {
  run_guard "echo go | custody grant -key tracker -actions read -ttl 8h"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"operator-only"* ]]
}

@test "chained custody verb is still blocked (command position after &&)" {
  run_guard "cd /repo && custody keys set -name tracker-pat"
  [ "$status" -eq 2 ]
}

# --- custody: state dir ---

@test "touching custody state is blocked" {
  run_guard "cat ~/.custody/mint.key"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"custody state"* ]]
}

@test "windows-style custody state path is blocked" {
  run_guard 'type C:\Users\op\.custody\grants\cst_1.json'
  [ "$status" -eq 2 ]
}

@test "Join-Path-built quoted state path is blocked" {
  run_guard "Get-Content (Join-Path \$env:USERPROFILE '.custody\\mint.key')"
  [ "$status" -eq 2 ]
}

# --- custody: the brokered path stays open ---

@test "calls through the proxy pass" {
  run_guard 'curl -H "X-Custody-Grant: cst_abc" http://127.0.0.1:8127/tracker/rest/api/2/issue/PROJ-1'
  [ "$status" -eq 0 ]
}

# --- plaintext keys file: env-gated until drain ---

@test "keys-file read passes while GUARD_KEYS_DENY is unset" {
  run_guard "jq -r .vendor /c/Users/op/dev/repo/.keys"
  [ "$status" -eq 0 ]
}

@test "keys-file read is blocked when GUARD_KEYS_DENY=1" {
  GUARD_KEYS_DENY=1 run_guard "jq -r .vendor /c/Users/op/dev/repo/.keys"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"custody"* ]]
}

@test "uppercase .KEYS is blocked when enabled (case-insensitive)" {
  GUARD_KEYS_DENY=1 run_guard "Get-Content .KEYS"
  [ "$status" -eq 2 ]
}

@test "quote-split keys path is blocked when enabled" {
  GUARD_KEYS_DENY=1 run_guard 'jq -r .vendor "./.ke""ys"'
  [ "$status" -eq 2 ]
}

@test "keys-file rule doesn't match .keystore when enabled" {
  GUARD_KEYS_DENY=1 run_guard "ls app/.keystore"
  [ "$status" -eq 0 ]
}

# --- plaintext keys file: prose naming the file, not reading it (P2 fix) ---

@test "commit message naming .keys is NOT blocked even when enabled" {
  GUARD_KEYS_DENY=1 run_guard 'git commit -m "remove .keys"'
  [ "$status" -eq 0 ]
}

@test "PR body naming .keys is NOT blocked even when enabled" {
  GUARD_KEYS_DENY=1 run_guard 'gh pr create --title drain --body "deleted .keys"'
  [ "$status" -eq 0 ]
}

# --- bare gh pr merge: block the real subcommand, not the word `merge` ---

@test "bare gh pr merge is blocked" {
  run_guard "gh pr merge 42 --squash --admin --delete-branch"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"bypasses gate"* ]]
  [[ "$stderr" == *"Remedy:"* ]]
}

@test "gh -R o/r pr merge (repo flag before pr) is blocked" {
  run_guard "gh -R itsHabib/hooks pr merge 42 --squash"
  [ "$status" -eq 2 ]
}

@test "gh pr -R o/r merge (repo flag between pr and merge) is blocked" {
  run_guard "gh pr -R itsHabib/hooks merge 42 --squash"
  [ "$status" -eq 2 ]
}

@test "gate-emitted --match-head-commit merge passes" {
  run_guard "gh pr merge 42 --squash --admin --match-head-commit abc123"
  [ "$status" -eq 0 ]
}

@test "false positive: filename with gh-pr-merge segments passes" {
  run_guard "head tests/posttool-gh-pr-merge.bats"
  [ "$status" -eq 0 ]
}

@test "false positive: gh pr create with 'merge' in the body passes" {
  run_guard 'gh pr create --title fix --body "this reverts the bad merge from main"'
  [ "$status" -eq 0 ]
}
