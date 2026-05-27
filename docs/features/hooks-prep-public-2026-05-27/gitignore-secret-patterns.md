**Status**: draft
**Owner**: @claude-code:michael
**Date**: 2026-05-27
**Related**: dossier task `gitignore-missing-secret-patterns` (id: `tsk_01KSKX6P7424GNHG1K3652FS42`)

# .gitignore secret-pattern entries — design spec

## Scope

| Bucket | Files | Est. LOC | Weighted |
|---|---|---|---|
| Config | `.gitignore` | 6 added | 0× |
| **Total** | | | **0 weighted (config only)** |

Band: **amazing**.

## Goal

Add universal secret-pattern entries to `.gitignore` so future accidental commits of `.env` / `*.pem` / `*.key` / `credentials*` / `secrets/` files get caught by git before they hit history. Hooks repo currently has no such patterns; `gitleaks` shows 0 historical findings, so this is preventative for the next mistake.

## Behavior / fix

Append to `.gitignore`:

```
# Secret patterns — universal hygiene
.env
.env.*
*.pem
*.key
credentials*
secrets/
```

Append at the end. Don't reorder existing entries.

## Acceptance

- `git check-ignore .env` returns 0 (ignored) after the change.
- `git check-ignore secrets/whatever` returns 0.
- Existing tracked files are unaffected (none of the patterns match anything currently in the index).

## Test plan

Manual verification:

```bash
git check-ignore .env .env.local foo.pem bar.key credentials credentials.json secrets/anything
# All should print the matching pattern; exit 0
```

No bats tests — pure config change.

## Non-goals

- Stack-specific entries (no Cargo.toml / package.json / etc. → none apply per `/prep-public` Step 3e).
- Tightening `.claude/` (already listed; correct).
- Setting up gitleaks pre-commit hook (separate concern; not in this phase).
