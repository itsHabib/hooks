#!/usr/bin/env bash
# PreToolUse guard — deterministic tier-3 floor for Bash/PowerShell tool calls.
# Blocks never-sanctioned actions regardless of permission mode; every denial
# prints the remedy. Exit 2 = block (stderr shown to the model), exit 0 = pass.
#
# gh pr merge: shape-checked, not policy-checked. Merge policy lives in gate;
# while gate is advisory, bare merges are a bypass with no grant/verdict/artifact,
# so only gate-emitted-shape merges (--match-head-commit) pass. Raises the bar,
# doesn't close the hole — that takes branch protection or a credential broker.
#
# One fork by design. This hook runs on EVERY Bash tool call, and on an
# EDR-managed box each child process costs ~1.6s of scanner overhead, so the
# old shape (a `grep` per rule, plus `cat` and `sed`) cost 12 forks / ~19s to
# usually decide nothing. Every rule below now uses bash's own [[ =~ ]] — ERE,
# the same syntax grep -E accepts, so the patterns are unchanged — and
# parameter expansion. Keep it that way: no pipelines, no $(...), below here.
#
# The single remaining fork is jq, and it stays. Extracting a JSON string in
# pure bash means truncating at the first `"`, which an escaped quote inside
# the command turns into a bypass: `echo "x\" && custody grant` would present
# as `echo "x` and sail past every rule. A security floor does not get to be
# clever about its own input parsing.

set -uo pipefail

# Read the whole event without forking `cat`. -d '' reads to EOF rather than
# newline; it returns non-zero at EOF, which is the normal case here.
IFS= read -r -d '' input || true
[ -n "$input" ] || exit 0

cmd=$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

deny() {
  echo "BLOCKED by pretool-guard: $1" >&2
  echo "Remedy: $2" >&2
  exit 2
}

# force push (--force-with-lease is allowed). Subcommands may be separated
# from the binary by global options (git -C /repo push ...), and a +refspec
# (git push origin +HEAD:main) forces without any flag — match both.
re='(^|[^[:alnum:]_])git[^[:alnum:]_]([^|;&]*[^[:alnum:]_])?push([^[:alnum:]_][^|;&]*)?( --force([^-]|$)|( |=)-f( |$)| \+[^ ]+)'
if [[ $cmd =~ $re ]]; then
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
re="(^|[^[:alnum:]._-])gh${flag}[[:space:]]+pr${flag}[[:space:]]+merge([^[:alnum:]_]|$)"
if [[ $cmd =~ $re ]] && [[ $cmd != *--match-head-commit* ]]; then
  deny "bare gh pr merge bypasses gate (no grant, verdict, or artifact)" \
       "run: gate gate -repo <owner/repo> -pr <n> -grant <grt_...>, then use its emitted merge command"
fi

# repo deletion / visibility change (same intervening-flag tolerance)
re='(^|[^[:alnum:]_])gh[^[:alnum:]_]([^|;&]*[^[:alnum:]_])?repo[^[:alnum:]_]([^|;&]*[^[:alnum:]_])?delete([^[:alnum:]_]|$)'
if [[ $cmd =~ $re ]]; then
  deny "repo deletion is irreversible" "operator runs this by hand if truly intended"
fi
re='(^|[^[:alnum:]_])gh[^[:alnum:]_]([^|;&]*[^[:alnum:]_])?repo[^[:alnum:]_]([^|;&]*[^[:alnum:]_])?edit([^[:alnum:]_][^|;&]*)?--visibility'
if [[ $cmd =~ $re ]]; then
  deny "repo visibility changes are an operator decision" \
       "surface the request; operator flips visibility manually"
fi

# credential material
if [[ $cmd == *.credentials.json* ]]; then
  deny "commands may not touch .credentials.json" \
       "credential handling is manual; ask the operator"
fi

# Case-insensitive for the rest: Windows exe/path lookup is case-insensitive,
# and .KEYS is .keys. Scoped with shopt so it applies only to these rules.
shopt -s nocasematch

re='(^|[^[:alnum:]_])(cat|cp|type|less|head|tail|Get-Content|Copy-Item)([^[:alnum:]_][^|;&]*)?[ /\]\.ssh[/\]id_[a-z0-9_]+([^.]|$)'
if [[ $cmd =~ $re ]]; then
  shopt -u nocasematch
  deny "private ssh keys are off limits (using ssh itself is fine)" \
       "reference keys via ssh -i; never read or copy key files"
fi

shopt -u nocasematch

# gate state (audit chain) + signing keys — only the gate binary writes here.
# Anchored on the `gate/` parent, not on a specific home (the state dir has
# lived at ~/pers/gate and now ~/dev/gate; pinning either one silently stops
# protecting the other — which is exactly what happened). Matching the parent
# is safe: no source tree in the portfolio has a `gate/state` or `gate/keys`
# path, and `gate/internal/state` does not match (the segments aren't
# adjacent). Boundaries on BOTH sides of gate: the trailing one keeps sibling names
# like state_backup out, and the leading one keeps any word merely ending in
# "gate" — aggregate/state, delegate/keys — from tripping the rule. The verb
# needs its own leading boundary too: without one, "rm" inside an interior
# substring — "normalization" in a `gate judge -why "..."` argument — matches,
# and any legitimate `-state ~/dev/gate/state` flag later in the command turns
# the whole call into a denial (this blocked a real gate judge on 2026-08-12).
#
# Anchoring the verb costs the coverage the unanchored form got by accident:
# `cp` used to match inside `scp`, so remote copies of the signing key were
# blocked as a side effect of the bug. Every remote-copy verb is therefore
# listed in its own right — dropping one is a silent exfiltration path, not a
# stray denial. rsync was never covered even before the anchor.
#
# Bias, since the two boundaries pull opposite ways: a leading boundary that
# matches too little only ever costs a block (false negative), while the verb
# list that matches too little costs a KEY. Widen the verb list on sight;
# loosen the boundaries only with a test that proves the denial was spurious.
re='(^|[^[:alnum:]_])(rm|mv|cp|scp|rsync|Remove-Item|Move-Item|Copy-Item)[^|;&]*[^[:alnum:]_]gate[/\](state|keys)([^[:alnum:]_]|$)'
if [[ $cmd =~ $re ]]; then
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
norm="${cmd//\'/}"
norm="${norm//\"/}"

shopt -s nocasematch

# custody mint authority + secret entry are operator verbs (authority is
# minted, not inferred). Governed sessions call the proxy with a grant they
# were handed; they never mint grants or write secrets. Read verbs
# (custody log, custody explain) pass. Match custody only in command
# position — start of command, or right after a pipe / && / ; / subshell —
# so prose that merely names the verb (git commit -m "document custody
# grant", rg "custody keys" docs) doesn't trip it. Wrapper indirection
# (sudo/env, bash -c) is out of a text regex's reach, same as env-indirection.
# Newline is a command boundary too: `=~` anchors ^ to the start of the WHOLE
# string (the grep this replaced evaluated each line separately), so without
# it in the class, `cd /repo<newline>custody grant ...` would sit in command
# position and pass.
nl=$'\n'
re="(^|[|&;\`(${nl}])[[:space:]]*([^[:space:];|&\`]*[/\\])?custody(\.exe)?[[:space:]]+(grant|keys)([^[:alnum:]_]|$)"
if [[ $norm =~ $re ]]; then
  shopt -u nocasematch
  deny "custody grant/keys are operator-only (mint authority + secret entry)" \
       "surface the need; the operator runs: custody grant -key <k> -actions <a> -ttl <t>"
fi

# custody state (mint key, grant records, audit log) — only the custody
# binary touches it. Match the path token wherever it appears (path-joined,
# space-separated, or quoted), not only after a separator.
re='(^|[^[:alnum:]_.])\.custody([/\]|[^[:alnum:]_]|$)'
if [[ $norm =~ $re ]]; then
  shopt -u nocasematch
  deny "custody state is owned by the custody binary" \
       "use custody log / custody explain; never touch state files directly"
fi

# plaintext keys-file reads — OFF by default until the custody-drain phase
# deletes the file (flip GUARD_KEYS_DENY=1 in settings env then). Until
# drain, skills still legitimately read it, and denying early would train
# bypass habits. Scoped to raw-file readers (mirrors the ssh-key rule) so
# prose that merely names the file — git commit -m "remove .keys",
# gh pr create --body "deleted .keys" — isn't denied. The trailing boundary keeps
# .keystore from matching.
re='(^|[^[:alnum:]_])(cat|cp|type|less|more|head|tail|nl|jq|rg|grep|awk|sed|cut|xxd|od|Get-Content|Copy-Item)([^[:alnum:]_][^|;&]*)?[ /\]\.keys([^[:alnum:]_]|$)'
if [ "${GUARD_KEYS_DENY:-0}" = "1" ] && [[ $norm =~ $re ]]; then
  shopt -u nocasematch
  deny "plaintext keys files are drained into custody" \
       "call the vendor through the proxy: curl http://127.0.0.1:8127/<key>/<path> with X-Custody-Grant"
fi

shopt -u nocasematch

exit 0
