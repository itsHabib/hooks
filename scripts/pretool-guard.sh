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

# force push (--force-with-lease is allowed). Subcommands may be separated
# from the binary by global options (git -C /repo push ...), and a +refspec
# (git push origin +HEAD:main) forces without any flag — match both.
if printf '%s' "$cmd" | grep -qE '\bgit\b[^|;&]*\bpush\b[^|;&]*( --force([^-]|$)|( |=)-f( |$)| \+[^ ]+)'; then
  deny "force push rewrites shared history" \
       "use --force-with-lease, or ask the operator to run it manually"
fi

# bare merge (gate emits --match-head-commit; a merge without it skipped
# gate). Inherited flags may sit between subcommands: gh pr -R o/r merge.
if printf '%s' "$cmd" | grep -qE '\bgh\b[^|;&]*\bpr\b[^|;&]*\bmerge\b' && ! printf '%s' "$cmd" | grep -q -- '--match-head-commit'; then
  deny "bare gh pr merge bypasses gate (no grant, verdict, or artifact)" \
       "run: gate gate -repo <owner/repo> -pr <n> -grant <grt_...> -state ~/pers/gate/state, then use its emitted merge command"
fi

# repo deletion / visibility change (same intervening-flag tolerance)
if printf '%s' "$cmd" | grep -qE '\bgh\b[^|;&]*\brepo\b[^|;&]*\bdelete\b'; then
  deny "repo deletion is irreversible" "operator runs this by hand if truly intended"
fi
if printf '%s' "$cmd" | grep -qE '\bgh\b[^|;&]*\brepo\b[^|;&]*\bedit\b[^|;&]*--visibility'; then
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

# custody mint authority + secret entry are operator verbs (authority is
# minted, not inferred). Governed sessions call the proxy with a grant they
# were handed; they never mint grants or write secrets. Read verbs
# (custody log, custody explain) pass. Subcommand-position match so paths
# that merely contain "custody" don't trip it.
if printf '%s' "$cmd" | grep -qE '\bcustody(\.exe)?\s+(grant|keys)\b'; then
  deny "custody grant/keys are operator-only (mint authority + secret entry)" \
       "surface the need; the operator runs: custody grant -key <k> -actions <a> -ttl <t>"
fi

# custody state (mint key, grant records, audit log) — only the custody
# binary touches it
if printf '%s' "$cmd" | grep -qE '[/\\~]\.custody([/\\]|\b)'; then
  deny "custody state is owned by the custody binary" \
       "use custody log / custody explain; never touch state files directly"
fi

# plaintext keys-file reads — OFF by default until the custody-drain phase
# deletes the file (flip GUARD_KEYS_DENY=1 in settings env then). Until
# drain, skills still legitimately read it, and denying early would train
# bypass habits.
if [ "${GUARD_KEYS_DENY:-0}" = "1" ] && printf '%s' "$cmd" | grep -qE '(^|[^[:alnum:]_])\.keys\b'; then
  deny "plaintext keys files are drained into custody" \
       "call the vendor through the proxy: curl http://127.0.0.1:8127/<key>/<path> with X-Custody-Grant"
fi

exit 0
