#!/usr/bin/env bash
# Count how many child processes each hook spawns on the COMMON path — a Bash
# tool call that is not gh pr create / gh pr merge / gate gate, i.e. ~99% of
# calls, where every hook is expected to early-exit doing nothing.
#
# Why count instead of time: on an EDR-managed box each CreateProcess costs
# ~1.6s, so spawn count is the thing that predicts hook latency. Counting is
# also stable across machines, unlike wall-clock.
#
# Method: run the hook under `set -x` with PS4 marking every simple command,
# then count the external-binary invocations. Shell builtins and function calls
# cost nothing; only forks do.
#
# Usage:  tests/spawn-count.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# A payload that every hook should reject immediately: it IS a Bash event, but
# the command is not one any hook acts on.
PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"echo hello"},"tool_response":{"stdout":"hello","exitCode":0}}'

# Binaries that cost a fork when invoked. `timeout` and `bash` matter most: a
# hook that re-execs itself under timeout pays bash startup twice.
FORKING='jq|gh|git|sed|grep|awk|cut|basename|dirname|cat|timeout|bash|date|tr|head|tail|wc|sort|realpath|pwd|command'

printf '\n%-34s %s\n' "hook" "forking commands on common path"
printf '%-34s %s\n' "----" "-------------------------------"

total=0
for hook in pretool-guard.sh posttool-gh-pr-merge.sh posttool-gh-pr-create.sh posttool-gate-verdict.sh; do
  path="$ROOT/scripts/$hook"
  [ -f "$path" ] || continue

  trace="$(mktemp)"
  # Trace the inner leg directly (--no-timeout): the outer leg re-execs itself
  # under `timeout`, and that child is a separate process xtrace cannot see, so
  # tracing the outer leg alone reports only the re-exec and hides everything.
  # Counting the inner leg and adding the re-exec back is the honest total.
  PS4='+CMD+ ' bash -x "$path" --no-timeout <<<"$PAYLOAD" >/dev/null 2>"$trace"

  # Bash prefixes PS4 with one extra marker char per subshell depth, so nested
  # commands appear as `++CMD+` / `+++CMD+`. Strip any leading '+' run before
  # matching or every nested fork is missed (they are the majority).
  cmds=$(sed -n 's/^+*CMD+ //p' "$trace" 2>/dev/null \
      | grep -vE '^command -v' \
      | awk '{print $1}')

  n=$(printf '%s\n' "$cmds" | grep -cE "^($FORKING)$" || true)

  # Show the breakdown so the fix is obvious, not just the number.
  detail=$(printf '%s\n' "$cmds" \
      | grep -E "^($FORKING)$" \
      | sort | uniq -c | sort -rn \
      | awk '{printf "%s x%s  ", $2, $1}')

  # The `timeout` re-exec is a second bash startup the traced inner leg cannot
  # show. Count it only when the common path actually REACHES it: a hook that
  # bails out before the re-exec never pays it. Detect that by checking whether
  # the untraced outer leg produces the re-exec at all.
  if grep -q 'timeout 5' "$path"; then
    outer="$(mktemp)"
    PS4='+CMD+ ' bash -x "$path" <<<"$PAYLOAD" >/dev/null 2>"$outer"
    if sed -n 's/^+*CMD+ //p' "$outer" | grep -q '^timeout'; then
      n=$((n + 2))
      detail="$detail(+timeout re-exec x2)"
    else
      detail="${detail:-(none)} [bails before timeout re-exec]"
    fi
    rm -f "$outer"
  fi

  printf '%-34s %-4s %s\n' "$hook" "$n" "$detail"
  total=$((total + n))
  rm -f "$trace"
done

printf '\n  total forks per Bash tool call: %s\n' "$total"
printf '  at ~1.6s per spawn on an EDR box: ~%ss of pure overhead\n\n' "$((total * 16 / 10))"
