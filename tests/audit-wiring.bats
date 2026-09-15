#!/usr/bin/env bats

setup() {
  AUDIT="$BATS_TEST_DIRNAME/../scripts/audit-wiring.sh"
  SETTINGS="$BATS_TEST_TMPDIR/settings.json"
  printf '{"hooks":{}}' > "$SETTINGS"
}

@test "empty settings report absent references without changing files" {
  before=$(cat "$SETTINGS")
  run bash "$AUDIT" --claude "$SETTINGS" --codex "$SETTINGS"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'claude\tpretool-guard.sh\tnot-referenced'* ]]
  [ "$(cat "$SETTINGS")" = "$before" ]
}

@test "reports quoted paths, actual event and matcher without executing commands" {
  jq -n --arg marker "$BATS_TEST_TMPDIR/executed" '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:("bash \"/a path/pretool-guard.sh\"; touch " + $marker)}]}]}}' > "$SETTINGS"
  run bash "$AUDIT" --claude "$SETTINGS" --codex "$SETTINGS"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'pretool-guard.sh\treferenced\tPreToolUse:Bash'* ]]
  [ ! -e "$BATS_TEST_TMPDIR/executed" ]
}

@test "similarly named scripts do not count and fleet stays external" {
  cat > "$SETTINGS" <<'JSON'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash /tmp/pretool-guard.sh.backup"},{"type":"command","command":"/somewhere/fleet hook codex"}]}]}}
JSON
  run bash "$AUDIT" --claude "$SETTINGS" --codex "$SETTINGS"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'pretool-guard.sh\tnot-referenced'* ]]
  [[ "$output" == *$'codex\texternal:fleet-hook\t1'* ]]
}

@test "missing config is unavailable rather than empty" {
  run bash "$AUDIT" --claude "$SETTINGS.missing" --codex "$SETTINGS"
  [ "$status" -eq 1 ]
  [[ "$output" == *$'claude\tconfig-missing'* ]]
  [[ "$output" != *$'claude\tpretool-guard.sh\tnot-referenced'* ]]
}

@test "malformed JSON and invalid event schema are errors" {
  printf '{' > "$SETTINGS"
  run bash "$AUDIT" --claude "$SETTINGS" --codex "$SETTINGS"
  [ "$status" -eq 1 ]
  for invalid in '{"hooks":{"Stop":{}}}' '{"hooks":false}' '{"hooks":null}'; do
    printf '%s' "$invalid" > "$SETTINGS"
    run bash "$AUDIT" --claude "$SETTINGS" --codex "$SETTINGS"
    [ "$status" -eq 1 ]
    [[ "$output" == *'config-invalid'* ]]
  done
}

@test "disabled configuration is visible and secret settings are not dumped" {
  printf '{"disableAllHooks":true,"env":{"TOKEN":"do-not-print-me"},"hooks":{}}' > "$SETTINGS"
  run bash "$AUDIT" --claude "$SETTINGS" --codex "$SETTINGS"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'disableAllHooks\ttrue'* ]]
  [[ "$output" != *'do-not-print-me'* ]]
}
