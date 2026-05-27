**Status**: draft
**Owner**: @claude-code:michael
**Date**: 2026-05-27
**Related**:
  - dossier task `readme-no-inline-settings-snippet` (id: `tsk_01KSKX615G980SST6GZZ9WKMWC`)
  - dossier task `readme-no-prerequisites-section` (id: `tsk_01KSKX6FQS9MYAJRYYKR1M6HTZ`)
  - dossier task `readme-no-license-badge` (id: `tsk_01KSKX83DNCJC2ZMF8CDBMKX2Y`)
  - dossier task `readme-no-ci-badge` (id: `tsk_01KSKX88ZFZY7SMT7T8FNG966C`)

# README polish for public launch — design spec

## Scope

| Bucket | Files | Est. LOC | Weighted |
|---|---|---|---|
| Docs (README) | `README.md` | ~30 added | 0× |
| **Total** | | | **0 weighted (docs only)** |

Band: **amazing** (docs-only changes).

## Goal

Bring `README.md` to public-launch readiness. Four prep-public findings all touch the same file with small additive edits, so they ship as one PR rather than serializing across four tiny PRs that would each rebase on the previous. The dossier tasks remain individually trackable; this PR closes all four.

## Behavior / fix

Four edits to `README.md`:

1. **Badges row** (`readme-no-license-badge` + `readme-no-ci-badge`). Add directly under the `# hooks` title:

   ```markdown
   [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
   [![CI](https://github.com/itsHabib/hooks/actions/workflows/ci.yml/badge.svg)](https://github.com/itsHabib/hooks/actions/workflows/ci.yml)
   ```

   The CI badge depends on `.github/workflows/ci.yml` existing — that workflow lands in PR #10. If #10 hasn't merged yet when this PR opens, the badge will show "no status" until #10 lands; not a launch blocker.

2. **Prerequisites section** (`readme-no-prerequisites-section`). Insert a new `## Prerequisites` section between `## What this is` and `## Wiring hooks`:

   ```markdown
   ## Prerequisites

   - **dossier** — https://github.com/itsHabib/dossier. Install the binary (`cargo install --git https://github.com/itsHabib/dossier`) and create a corpus dir with `<corpus>/.dossier/` as the marker. Hooks find it via `DOSSIER_BIN` + `DOSSIER_CORPUS` env vars set in your settings.json.
   - **jq** — modern coreutils version (`brew install jq` / `scoop install jq` / `apt install jq`).
   - **gh** — GitHub CLI authenticated (`gh auth status` must succeed) for the `posttool-gh-*` hooks.
   - **bash** — Git Bash on Windows, default shell on macOS / Linux.

   Optionally:
   - **ship** MCP if you want the `posttool-ship-*` hooks to fire (those listen on `mcp__ship__ship` / `mcp__ship__get_workflow_run` PostToolUse events).
   ```

3. **Inline settings.json snippet** (`readme-no-inline-settings-snippet`). In the existing `## Wiring hooks` section, before the paragraph that points at `examples/`, add a copy-pasteable code block:

   ```markdown
   Minimal `~/.claude/settings.json` shape for the `gh pr merge` hook:

   ```json
   {
     "hooks": {
       "PostToolUse": [
         {
           "matcher": "Bash",
           "hooks": [
             { "type": "command", "command": "bash ~/pers/hooks/scripts/posttool-gh-pr-merge.sh", "timeout": 5 }
           ]
         }
       ]
     },
     "env": {
       "DOSSIER_BIN": "/path/to/dossier",
       "DOSSIER_CORPUS": "/path/to/dossier-corpus"
     }
   }
   ```

   Per-hook snippets for the other three hooks (gh-pr-create, ship-ship-dispatch, ship-getrun) live in `examples/`. Merge them into the same `hooks` block by combining their `PostToolUse` entries.
   ```

   Note: the dossier URL placeholders assume `itsHabib/dossier` is the public destination. If dossier ends up at a different URL, update the Prerequisites + this snippet together.

## Acceptance

- Two badges visible at the top of `README.md` when rendered on github.com.
- `## Prerequisites` section exists with dossier / jq / gh / bash listed; ship is called out as optional.
- A copy-pasteable JSON code block exists inside `## Wiring hooks` showing the minimal settings.json shape.
- `markdown` lint (if any) passes; no broken anchors.

## Test plan

- Render `README.md` locally (any markdown viewer) and confirm the badges row + Prerequisites + settings.json block are visible.
- Click both badges — they should resolve to `LICENSE` (in-repo) and the CI workflow page (404 acceptable until #10 lands).
- No new bats tests — docs-only change.

## Non-goals

- Reworking the `## Conventions` table or the `## Common gotchas` section.
- Adding screenshots / GIFs / diagrams.
- Cross-linking to dossier or ship READMEs (those are external repos; one-way link via Prerequisites is enough).
- Replacing the existing `examples/` workflow — the README still points at it for per-hook snippets; this just adds the inline shape for the "first 60 seconds" experience.
