**Status**: draft
**Owner**: @claude-code:michael
**Date**: 2026-05-27
**Related**: dossier task `no-security-md` (id: `tsk_01KSKX8WJV61HYR60YJDGBSNYS`)

# SECURITY.md — design spec

## Scope

| Bucket | Files | Est. LOC | Weighted |
|---|---|---|---|
| Docs | `SECURITY.md` | ~25 new | 0× |
| **Total** | | | **0 weighted (docs only)** |

Band: **amazing**.

## Goal

Short SECURITY.md at repo root so vuln reporters (or honest first-time researchers) have a private channel rather than filing public issues. Scope the security-relevant surface so reporters know what counts.

## Behavior / fix

Create `SECURITY.md` with this content:

```markdown
# Security policy

## Reporting a vulnerability

For security concerns, **don't file a public issue**. Email the maintainer privately or use [GitHub's private vulnerability reporting](https://github.com/itsHabib/hooks/security/advisories/new) if enabled on this repo.

Expect acknowledgment within 7 days. Coordinated disclosure timing depends on severity — for in-process bash-parsing bugs the window is typically short (days, not months) because the blast radius is limited to the operator's own machine.

## Scope

These hooks run as `bash` subprocesses spawned by Claude Code's hook system on the operator's local machine. They:

- Read event JSON from stdin (fed by Claude Code).
- Shell out to `dossier`, `gh`, and `jq`.
- Write structured failure lines to `~/.cache/hooks-errors.log` on dossier-call failure.

**Security-relevant surfaces:**

- `lib/pr-lookup.sh` — parses PR body text fetched via `gh pr view --json body`. A malicious PR body could in theory trigger unintended dossier writes if the parser is too lenient.
- `lib/ship-task-lookup.sh` — parses `**Related**` headers in spec docs.
- `lib/dossier-cli.sh` — invokes the operator's local `dossier` binary with `--corpus <path>`.
- `scripts/posttool-*.sh` — jq pipelines reading PostToolUse event JSON.

**Out of scope:**

- The operator's `dossier` binary itself (separate repo; report there).
- Claude Code's hook execution model (Anthropic).
- `gh` / `jq` / `bash` upstream.

## Threat model

These hooks are not network-facing. They run only on the operator's machine, triggered by their own Claude Code session, against their own dossier corpus. The realistic threats are:

1. **Malicious PR body causing unintended dossier writes** when the operator merges someone else's PR. Currently mitigated by dossier's verb-level validation; we still want to catch parser bugs.
2. **Path-traversal / injection via crafted event JSON** when Claude Code passes through tool input the agent constructed. Same mitigation — every shell-out should go through proper quoting.

Internet-facing attacks (RCE via external network, supply-chain on the bash itself) aren't in scope — this code doesn't bind to ports or download executables at runtime.
```

Update the email link / contact mechanism to the operator's preferred public channel if GitHub private advisory isn't suitable.

## Acceptance

- `SECURITY.md` exists at repo root.
- GitHub's Community Standards checklist (Settings → Code security → Community standards) shows SECURITY.md as present after merge.
- Scope section honestly enumerates the bash parsing surfaces — no aspirational "we run a bug bounty" claim.

## Test plan

- Render markdown locally; confirm links resolve.
- No bats — docs only.

## Non-goals

- `security.txt` (RFC 9116) — that's for internet-facing services; these are local hooks.
- A bug bounty program (single maintainer, no budget for it).
- Threat model formality beyond the inline paragraph above. This is the right grain for a hobby repo.
