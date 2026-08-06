#!/usr/bin/env bash

load test_helper

# Cross-hook contract tests for how hooks are INVOKED and how much they cost,
# as opposed to what they decide (covered per-hook elsewhere).
#
# Both properties here regressed during the fork-reduction work and neither was
# catchable by the existing suites, which always invoke hooks by absolute path
# and never count processes.

setup() {
  export PATH="$BATS_TEST_DIRNAME/fixtures/bin:$PATH"
  export DOSSIER_BIN=dossier
  export DOSSIER_CORPUS="$BATS_TEST_DIRNAME/fixtures/corpus"
  export DOSSIER_PROJECT=mcp-workstation
  export HOOK_TEST_TMP="$BATS_TEST_DIRNAME/tmp/invocation"
  rm -rf "$HOOK_TEST_TMP"
  mkdir -p "$HOOK_TEST_TMP"
  export HOOKS_ERROR_LOG="$HOOK_TEST_TMP/hooks-errors.log"
  ROOT="$BATS_TEST_DIRNAME/.."
}

# A Bash event none of the hooks act on — the ~99% case.
INERT='{"tool_name":"Bash","tool_input":{"command":"echo hello"},"tool_response":{"stdout":"hello","exitCode":0}}'

# --- path derivation ---
#
# Hooks derive ROOT_DIR from BASH_SOURCE with parameter expansion rather than
# `dirname`+`cd`+`pwd` (3 forks). The strip-twice form (${d%/*} applied to
# ${BASH_SOURCE%/*}) is WRONG for a one-segment relative path: `scripts/h.sh`
# strips to `scripts`, and stripping again yields `scripts` — not the parent —
# so lib sourcing silently resolves against the wrong directory.

@test "hooks source their libs when invoked by relative path" {
  cd "$ROOT" || return 1
  for hook in posttool-gate-verdict posttool-gh-pr-create posttool-gh-pr-merge; do
    run bash "scripts/$hook.sh" --no-timeout <"$BATS_TEST_DIRNAME/fixtures/posttool-gate-verdict/pass-with-task.json"
    [[ "$output" != *"No such file or directory"* ]] || {
      echo "$hook broke on relative invocation: $output"
      return 1
    }
  done
}

@test "hooks source their libs when invoked as a bare name from scripts/" {
  cd "$ROOT/scripts" || return 1
  run bash posttool-gate-verdict.sh --no-timeout <"$BATS_TEST_DIRNAME/fixtures/posttool-gate-verdict/pass-with-task.json"
  [ "$status" -eq 0 ]
  [[ "$output" != *"No such file or directory"* ]]
}

@test "hooks still work when invoked by absolute path" {
  run bash "$ROOT/scripts/posttool-gate-verdict.sh" --no-timeout \
    <"$BATS_TEST_DIRNAME/fixtures/posttool-gate-verdict/pass-with-task.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Recorded gate verdict"* ]]
}

# --- fork budget ---
#
# Every hook runs on every matching tool call, and on an EDR-managed box each
# CreateProcess costs ~1.6s of scanner overhead. The no-op path is therefore a
# latency contract, not just a style preference: 45 forks per Bash call
# measured 68s of pure overhead before this was fixed.

count_forks() {
  local hook="$1" trace n
  trace="$HOOK_TEST_TMP/trace-$hook.txt"
  # Trace the outer leg: it must bail before any re-exec. Bash prefixes PS4
  # with one '+' per subshell depth, so strip the whole run.
  PS4='+CMD+ ' bash -x "$ROOT/scripts/$hook.sh" <<<"$INERT" >/dev/null 2>"$trace"
  n=$(sed -n 's/^+*CMD+ //p' "$trace" \
      | grep -vE '^command -v' \
      | awk '{print $1}' \
      | grep -cE '^(jq|gh|git|sed|grep|awk|cut|basename|dirname|cat|timeout|bash|date|tr|head|tail|wc|sort|realpath|pwd)$' || true)
  printf '%s' "$n"
}

@test "pretool-guard forks at most once on the common path" {
  # The one permitted fork is jq, for JSON-correct extraction of the command:
  # truncating a JSON string in pure bash makes an escaped quote a bypass.
  n=$(count_forks pretool-guard)
  [ "$n" -le 1 ] || {
    echo "pretool-guard forked $n times on an inert event (budget: 1)"
    cat "$HOOK_TEST_TMP/trace-pretool-guard.txt"
    return 1
  }
}

@test "posttool hooks fork zero times on a non-matching event" {
  for hook in posttool-gh-pr-merge posttool-gh-pr-create posttool-gate-verdict; do
    n=$(count_forks "$hook")
    [ "$n" -eq 0 ] || {
      echo "$hook forked $n times on an inert event (budget: 0)"
      cat "$HOOK_TEST_TMP/trace-$hook.txt"
      return 1
    }
  done
}

@test "posttool hooks do not re-exec under timeout on a non-matching event" {
  # The `timeout` re-exec doubles bash startup. It must sit behind the
  # fast-path bail-out so only real events pay it.
  for hook in posttool-gh-pr-merge posttool-gh-pr-create posttool-gate-verdict; do
    PS4='+CMD+ ' bash -x "$ROOT/scripts/$hook.sh" <<<"$INERT" \
      >/dev/null 2>"$HOOK_TEST_TMP/outer-$hook.txt"
    run grep -c '^+*CMD+ timeout' "$HOOK_TEST_TMP/outer-$hook.txt"
    [ "$output" -eq 0 ] || {
      echo "$hook re-exec'd under timeout for an inert event"
      return 1
    }
  done
}
