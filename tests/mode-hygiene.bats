#!/usr/bin/env bats

setup() {
  repo="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$repo/scripts" "$repo/tests"
  cp "$BATS_TEST_DIRNAME/mode-hygiene.sh" "$repo/tests/mode-hygiene.sh"
  printf '#!/usr/bin/env bash\n' >"$repo/scripts/hook.sh"
  printf '#!/usr/bin/env bash\n' >"$repo/scripts/renamed.sh"
  printf '# fixture\n' >"$repo/removed.txt"

  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name "Mode Hygiene Test"
  git -C "$repo" add .
  git -C "$repo" commit -qm fixture
}

@test "staged path additions, deletions, and renames do not look like mode drift" {
  printf '# added\n' >"$repo/added.txt"
  git -C "$repo" add added.txt
  git -C "$repo" rm -q removed.txt
  git -C "$repo" mv scripts/renamed.sh scripts/moved.sh

  run bash "$repo/tests/mode-hygiene.sh"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a staged mode change is rejected" {
  chmod +x "$repo/scripts/hook.sh"
  git -C "$repo" add scripts/hook.sh

  run bash "$repo/tests/mode-hygiene.sh"

  [ "$status" -ne 0 ]
  [[ "$output" == *"tracked modes in the index differ from HEAD"* ]]
}

@test "an unstaged working-tree mode change is rejected" {
  chmod +x "$repo/scripts/hook.sh"

  run bash "$repo/tests/mode-hygiene.sh"

  [ "$status" -ne 0 ]
  [[ "$output" == *"tracked modes in the working tree differ from HEAD"* ]]
}
