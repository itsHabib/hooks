# Followups

Deferrals recorded with a written why, for the gate judge to accept as
residuals rather than treat as open findings. Each entry says what was
found, why it was not fixed in the PR that found it, and what would
actually terminate it.

## The gate-substrate rule enumerates verb names instead of anchoring on command position

**From:** PR #41 (`guard-verb-word-boundary`). Raised by both the Codex and
Claude reviewers.

**What.** The rule in `scripts/pretool-guard.sh` protecting `gate/state` and
`gate/keys` matches a list of verb names:

```
(rm|mv|cp|scp|rcp|pscp|srm|rsync|Remove-Item|Move-Item|Copy-Item)
```

PR #41 anchored that alternation on a word boundary to stop `rm` inside
`normalization` from matching. The anchor removed coverage the buggy form had
by accident, since a verb substring no longer matches mid-token. That cost
exactly the prefixed spellings — `scp`, `rcp`, `pscp`, `srm` — each of which
had to be added back by name. Three review rounds went into finding them one
at a time.

**Why it was not fixed there.** The list is now empirically complete for the
regression surface: every prefixed spelling that the pre-PR rule blocked is
blocked again, asserted in `tests/guard-equivalence.sh` against the pre-PR ref
and in `tests/pretool-guard.bats`. So the PR ships no loss of coverage. What
remains is a *structural* weakness, not a regression, and rewriting the rule's
matching strategy inside a PR whose purpose was a one-character boundary fix
would have been a much larger change to a security control than the bug
warranted — with the review budget already spent.

**What would terminate it.** Anchor on command position rather than on verb
names, the way the custody rule further down the same file already does:

```
(^|[|&;`(<newline>])[[:space:]]*([^[:space:];|&`]*[/\])?custody(\.exe)?[[:space:]]+...
```

A token in command position is the thing being invoked, whatever it is called.
That makes the rule indifferent to how a copy client is spelled and removes
the enumeration entirely — which is the only version of this rule that stops
producing "you missed verb X" findings. It also removes the reason the
original bug existed, since prose inside a quoted argument is never in command
position.

The same treatment likely belongs on the ssh-key and `.keys` rules, which
carry the same `VERB [^|;&]* PATH` shape.

**Exposure while deferred:** none relative to the pre-PR baseline. The rule
blocks everything today that it blocked before PR #41, plus `rsync` and the
`Copy-Item` casings, which it never did.

## `make test` and `make smoke` mutate tracked file modes

**From:** PR #41. Raised by the Codex reviewer as a P2, after the PR itself
tripped on it twice in consecutive commits.

Both targets run `chmod +x` over `scripts/` and `tests/smoke.sh` in the
working tree. Most of those files are tracked `100644`, so every test run
dirties them, and anyone staging after a test run commits mode churn they did
not intend. The targets then mask the breakage they cause, because they chmod
before executing — so a wrong tracked mode never fails CI.

Tracked in dossier as `hooks/make-targets-mutate-tracked-modes`, which carries
the two candidate fixes. Not fixed in PR #41 because the fix belongs in the
Makefile and the bats helper, not in the security guard that PR changes.

## `lib/transcript.sh` reads Claude Code transcripts only

**From:** PR #42 (`stop-discharge`). Raised by the Codex reviewer as a P1
(task resolution) and a P2 (files written).

**What.** `transcript_task_ids` and `transcript_files_written` match Claude's
`.message.content[] | select(.type == "tool_use")` records. A Codex rollout
(`~/.codex/sessions/**/rollout-*.jsonl`) records the same activity as
`{type: "response_item", payload: {type: "custom_tool_call" | "function_call",
name: ...}}`, so run against a Codex rollout these helpers return nothing.

**Why it was not fixed there.** The Stop hook is not wired into Codex.
`~/.codex/hooks.json` binds `Stop` to the fleet-governance adapter, the
example snippet in `examples/stop-discharge.json.snippet` is the Claude
`settings.json` form, and the sweep in PR #43 walks `~/.claude/projects` only.
No Codex session reaches this code today, so nothing is silently dropped; the
gap is a missing capability, not a broken one. The reviewer's cited evidence
(`/opt/codex/sessions`) does not exist on this machine, so the envelope
shapes above come from a local rollout and a Codex fixture needs to be built
from one before the parser is extended — which is a PR of its own.

**What would terminate it.** Wire `stop-discharge.sh` into Codex's `Stop`,
teach the three `transcript_*` helpers the `response_item` envelope (task ids
from `function_call` to the dossier MCP; files from `custom_tool_call` /
`apply_patch`), add a rollout-shaped fixture beside the Claude one in
`tests/stop-discharge.bats`, and point the sweep at both transcript roots.
