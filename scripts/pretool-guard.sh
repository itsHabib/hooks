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
# gate). Match `merge` as the actual gh-pr subcommand: gh, then pr, then
# merge, each a real token, with only flags (e.g. -R o/r, --repo o/r)
# tolerated in between — never spanning into a bare word, a quoted string,
# or a path segment. Anchoring gh to a non-[alnum._-] boundary keeps a
# filename like posttool-gh-pr-merge.bats from tripping it (the `-` before
# `gh` is not a match), and requiring `merge` right after the pr subcommand
# (modulo flags) keeps `gh pr create --body "...merge..."` clean.
flag='([[:space:]]+-[^[:space:]]*([[:space:]]+[^-[:space:]][^[:space:]]*)?)*'
if printf '%s' "$cmd" | grep -qE "(^|[^[:alnum:]._-])gh${flag}[[:space:]]+pr${flag}[[:space:]]+merge\b" && ! printf '%s' "$cmd" | grep -q -- '--match-head-commit'; then
  deny "bare gh pr merge bypasses gate (no grant, verdict, or artifact)" \
       "run: gate gate -repo <owner/repo> -pr <n> -grant <grt_...>, then use its emitted merge command"
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

# gate state (audit chain) + signing keys — only the gate binary writes here.
# Anchored on the `gate/` parent, not on a specific home (the state dir has
# lived at ~/pers/gate and now ~/dev/gate; pinning either one silently stops
# protecting the other — which is exactly what happened). Matching the parent
# is safe: no source tree in the portfolio has a `gate/state` or `gate/keys`
# path, and `gate/internal/state` does not match (the segments aren't
# adjacent). \b on BOTH sides of gate: the trailing one keeps sibling names
# like state_backup out, and the leading one keeps any word merely ending in
# "gate" — aggregate/state, delegate/keys — from tripping the rule. A miss on
# either is a false negative, never a false positive.
if printf '%s' "$cmd" | grep -qE '(rm|mv|cp|Remove-Item|Move-Item)[^|;&]*\bgate[/\\](state|keys)\b'; then
  deny "gate state/keys are append-only and owned by the gate binary" \
       "use gate subcommands; never edit state files directly"
fi

# The custody rules match against a normalized copy of the command: quotes
# stripped (so "custody.exe", gr""ant, '.custody\..' collapse) and matching
# done case-insensitively (Windows exe/path lookup is case-insensitive; .KEYS
# is .keys). This covers ordinary spellings — quoting, casing, Join-Path — not
# arbitrary obfuscation. Env indirection (verb=grant; custody "$verb") and
# `bash -c script.sh` are out of reach of a text regex and stay so: under
# "discipline plus audit" those are deliberate, not routine (see docs).
norm=$(printf '%s' "$cmd" | sed "s/['\"]//g")

# custody mint authority + secret entry are operator verbs (authority is
# minted, not inferred). Governed sessions call the proxy with a grant they
# were handed; they never mint grants or write secrets. Read verbs
# (custody log, custody explain) pass. Match custody only in command
# position — start of command, or right after a pipe / && / ; / subshell —
# so prose that merely names the verb (git commit -m "document custody
# grant", rg "custody keys" docs) doesn't trip it. Wrapper indirection
# (sudo/env, bash -c) is out of a text regex's reach, same as env-indirection.
if printf '%s' "$norm" | grep -qiE '(^|[|&;`(])[[:space:]]*([^[:space:];|&`]*[/\\])?custody(\.exe)?[[:space:]]+(grant|keys)\b'; then
  deny "custody grant/keys are operator-only (mint authority + secret entry)" \
       "surface the need; the operator runs: custody grant -key <k> -actions <a> -ttl <t>"
fi

# custody state (mint key, grant records, audit log) — only the custody
# binary touches it. Match the path token wherever it appears (path-joined,
# space-separated, or quoted), not only after a separator.
if printf '%s' "$norm" | grep -qiE '(^|[^[:alnum:]_.])\.custody([/\\]|\b)'; then
  deny "custody state is owned by the custody binary" \
       "use custody log / custody explain; never touch state files directly"
fi

# plaintext keys-file reads — OFF by default until the custody-drain phase
# deletes the file (flip GUARD_KEYS_DENY=1 in settings env then). Until
# drain, skills still legitimately read it, and denying early would train
# bypass habits. Scoped to raw-file readers (mirrors the ssh-key rule) so
# prose that merely names the file — git commit -m "remove .keys",
# gh pr create --body "deleted .keys" — isn't denied. \b after keys keeps
# .keystore from matching.
if [ "${GUARD_KEYS_DENY:-0}" = "1" ] && printf '%s' "$norm" | grep -qiE '\b(cat|cp|type|less|more|head|tail|nl|jq|rg|grep|awk|sed|cut|xxd|od|Get-Content|Copy-Item)\b[^|;&]*[ /\\]\.keys\b'; then
  deny "plaintext keys files are drained into custody" \
       "call the vendor through the proxy: curl http://127.0.0.1:8127/<key>/<path> with X-Custody-Grant"
fi

exit 0
