#!/usr/bin/env bash
# PreToolUse guard — deterministic tier-3 floor for Bash/PowerShell tool calls.
# Blocks never-sanctioned actions regardless of permission mode; every denial
# prints the remedy. Exit 2 = block (stderr shown to the model), exit 0 = pass.
#
# gh pr merge: shape-checked, not policy-checked. Merge policy lives in gate;
# while gate is advisory, bare merges are a bypass with no grant/verdict/artifact,
# so only gate-emitted-shape merges (--match-head-commit) pass. Raises the bar,
# doesn't close the hole — that takes branch protection or a credential broker.

set -euo pipefail

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

deny() {
  echo "BLOCKED by pretool-guard: $1" >&2
  echo "Remedy: $2" >&2
  exit 2
}

# force push (--force-with-lease is allowed)
if printf '%s' "$cmd" | grep -qE 'git +push[^|;&]*( --force([^-]|$)|( |=)-f( |$))'; then
  deny "force push rewrites shared history" \
       "use --force-with-lease, or ask the operator to run it manually"
fi

# bare merge (gate emits --match-head-commit; a merge without it skipped gate)
if printf '%s' "$cmd" | grep -qE 'gh +pr +merge' && ! printf '%s' "$cmd" | grep -q -- '--match-head-commit'; then
  deny "bare gh pr merge bypasses gate (no grant, verdict, or artifact)" \
       "run: gate gate -repo <owner/repo> -pr <n> -grant <grt_...> -state ~/pers/gate/state, then use its emitted merge command"
fi

# repo deletion / visibility change
if printf '%s' "$cmd" | grep -qE 'gh +repo +delete'; then
  deny "repo deletion is irreversible" "operator runs this by hand if truly intended"
fi
if printf '%s' "$cmd" | grep -qE 'gh +repo +edit[^|;&]*--visibility'; then
  deny "repo visibility changes are an operator decision" \
       "surface the request; operator flips visibility manually"
fi

# credential material
if printf '%s' "$cmd" | grep -qE '\.credentials\.json'; then
  deny "commands may not touch .credentials.json" \
       "credential handling is manual; ask the operator"
fi
if printf '%s' "$cmd" | grep -qiE '\b(cat|cp|type|less|head|tail|Get-Content|Copy-Item)\b[^|;&]*[ /\\]\.ssh[/\\]id_[a-z0-9_]+([^.]|$)'; then
  deny "private ssh keys are off limits (using ssh itself is fine)" \
       "reference keys via ssh -i; never read or copy key files"
fi

# gate state (audit chain + signing keys) — only the gate binary writes here
if printf '%s' "$cmd" | grep -qE '(rm|mv|cp|Remove-Item|Move-Item)[^|;&]*pers[/\\]gate[/\\]state'; then
  deny "gate state is append-only and owned by the gate binary" \
       "use gate subcommands; never edit state files directly"
fi

exit 0
