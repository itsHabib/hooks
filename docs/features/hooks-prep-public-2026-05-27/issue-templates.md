**Status**: draft
**Owner**: @claude-code:michael
**Date**: 2026-05-27
**Related**: dossier task `no-issue-template` (id: `tsk_01KSKX92FD8PXTGT2VVVEE20PS`)

# GitHub issue templates — design spec

## Scope

| Bucket | Files | Est. LOC | Weighted |
|---|---|---|---|
| Docs / config | `.github/ISSUE_TEMPLATE/bug_report.yml`, `.github/ISSUE_TEMPLATE/feature_request.yml` | ~30 each | 0× |
| **Total** | | | **0 weighted (config only)** |

Band: **amazing**.

## Goal

Guided issue templates for the public repo. Two forms: bug report and feature request. YAML form templates (modern GitHub format), not Markdown. The hooks' specific surface — settings.json wiring, dossier env vars, hooks-errors.log — needs to be in the bug-report form so reporters don't have to guess what to include.

## Behavior / fix

Create two files under `.github/ISSUE_TEMPLATE/`.

**`.github/ISSUE_TEMPLATE/bug_report.yml`**:

```yaml
name: Bug report
description: Something a hook does (or doesn't do) that contradicts the README / CLAUDE.md / dossier task body
labels: [bug]
body:
  - type: textarea
    id: what-happened
    attributes:
      label: What happened
      description: What did you observe? What should have happened instead?
    validations:
      required: true

  - type: textarea
    id: reproduce
    attributes:
      label: Steps to reproduce
      description: |
        Ideally a minimal sequence: settings.json hook block, the tool call that should have triggered the hook, and what you saw (or didn't see) in the dossier corpus / hooks-errors.log.
      placeholder: |
        1. settings.json hook block: ...
        2. Ran `gh pr merge ...` against PR with body `Closes task \`foo\``.
        3. Expected: kind:commit artifact under projects/<slug>/artifacts.jsonl
        4. Observed: no new artifact; no entry in ~/.cache/hooks-errors.log either.
    validations:
      required: true

  - type: textarea
    id: hooks-errors-log
    attributes:
      label: Lines from ~/.cache/hooks-errors.log
      description: |
        If the hook attempted and failed, the wrapper logs a line here. Paste the relevant lines, scrubbing any sensitive content.
      render: text

  - type: input
    id: hooks-version
    attributes:
      label: hooks commit / tag
      description: Output of `git -C ~/pers/hooks rev-parse --short HEAD` or the tag you cloned.
    validations:
      required: true

  - type: input
    id: dossier-version
    attributes:
      label: dossier binary version
      description: Output of `$DOSSIER_BIN --version`.

  - type: dropdown
    id: shell
    attributes:
      label: Shell
      options:
        - bash (Git Bash on Windows)
        - bash (macOS default / Homebrew)
        - bash (Linux distro default)
        - WSL bash
        - other
    validations:
      required: true
```

**`.github/ISSUE_TEMPLATE/feature_request.yml`**:

```yaml
name: Feature request
description: A new hook or a change to an existing hook's contract
labels: [enhancement]
body:
  - type: textarea
    id: use-case
    attributes:
      label: Use case
      description: What workflow does this enable? What metadata gap does it close between dossier / ship / gh?
    validations:
      required: true

  - type: dropdown
    id: hook-type
    attributes:
      label: Proposed hook type
      options:
        - New hook (new PostToolUse matcher)
        - Extend existing hook (new artifact kind / lookup form / etc.)
        - Library helper (lib/ change only)
        - Other
    validations:
      required: true

  - type: textarea
    id: matcher
    attributes:
      label: Tool / matcher to listen on
      description: |
        For new hooks: which Claude Code tool would fire it? (e.g. `Bash` for gh commands, `mcp__ship__ship`, `mcp__dossier__task_create`, etc.) Settings.json `matcher` field shape.
      placeholder: |
        Matcher: mcp__ship__cancel_workflow_run
        Triggers when: agent cancels a still-running ship workflow

  - type: textarea
    id: dossier-write
    attributes:
      label: Dossier write
      description: |
        What artifact_link / task_update / task_complete call should the hook make? Reference the dossier verb signatures from PROTOCOL.md.

  - type: textarea
    id: alternatives
    attributes:
      label: Alternatives considered
      description: Why not solve this with an MCP verb / a different hook / a manual ferry?
```

YAML form is the modern GitHub format. Templates appear when a user clicks "New issue" → they get a choice between the two forms.

## Acceptance

- `.github/ISSUE_TEMPLATE/bug_report.yml` and `.github/ISSUE_TEMPLATE/feature_request.yml` both exist.
- Open https://github.com/itsHabib/hooks/issues/new/choose (after merge) — both forms show.
- GitHub validates the YAML on push (any malformed template is rejected).
- Renders correctly: required fields are required; the dropdown options appear.

## Test plan

- Local YAML parse check: `python -c "import yaml; yaml.safe_load(open('.github/ISSUE_TEMPLATE/bug_report.yml'))"` (or any yaml linter).
- After merge: open the issue chooser on github.com and confirm both forms appear + render.
- No bats — config files.

## Non-goals

- Config-driven `config.yml` to disable blank issues entirely. Single-maintainer repo; default GitHub behavior is fine.
- More than two templates. Two covers the realistic spread.
- Auto-labelers / triage bots.
