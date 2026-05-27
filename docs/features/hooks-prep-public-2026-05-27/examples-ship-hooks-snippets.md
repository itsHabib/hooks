**Status**: draft
**Owner**: @claude-code:michael
**Date**: 2026-05-27
**Related**: dossier task `examples-missing-for-ship-hooks` (id: `tsk_01KSKX788ZJD24C2Y21F9VX8R2`)

# examples/ snippets for ship hooks — design spec

## Scope

| Bucket | Files | Est. LOC | Weighted |
|---|---|---|---|
| Docs / config | `examples/posttool-ship-ship-dispatch.json.snippet`, `examples/posttool-ship-getrun.json.snippet` | ~10 each | 0× |
| **Total** | | | **0 weighted (config only)** |

Band: **amazing**.

## Goal

`README.md` claims *"Each hook ships its own snippet under `examples/`"*. Today only the gh hooks have snippets (`posttool-gh-pr-create.json.snippet`, `posttool-gh-pr-merge.json.snippet`); the two ship hooks lack them. This PR delivers what the README promises.

## Behavior / fix

Add two files under `examples/`, matching the **full settings.json shape** of the existing `posttool-gh-pr-create.json.snippet` / `posttool-gh-pr-merge.json.snippet`. Each snippet must be a self-contained `{ "hooks": { "PostToolUse": [...] } }` document so a user can paste it directly into `~/.claude/settings.json` (or `cp` it as their starter settings file).

**`examples/posttool-ship-ship-dispatch.json.snippet`**:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "mcp__ship__ship",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/pers/hooks/scripts/posttool-ship-ship-dispatch.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

**`examples/posttool-ship-getrun.json.snippet`**:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "mcp__ship__get_workflow_run",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/pers/hooks/scripts/posttool-ship-getrun.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

Both go directly under `examples/`, no subdirs. Same file naming convention as the existing two (`<hook-script-name-minus-.sh>.json.snippet`).

## Acceptance

- `ls examples/*.snippet` returns four entries (the two new ones plus the existing pair).
- Each new snippet is valid JSON (`jq . < examples/posttool-ship-ship-dispatch.json.snippet` succeeds).
- The matcher field matches the actual tool name the hook script listens for (cross-check against `scripts/posttool-ship-*.sh` which gates on `tool_name`).

## Test plan

```bash
for f in examples/posttool-ship-ship-dispatch.json.snippet examples/posttool-ship-getrun.json.snippet; do
  jq . <"$f" >/dev/null && echo "$f: valid JSON"
done
```

No bats tests — config files only.

## Non-goals

- A combined "all four hooks" snippet — keep each hook in its own file so operators can mix and match.
- A top-level `examples/README.md` explaining how to merge the snippets — the main `README.md` covers this (or will after `readme-polish.md` lands).
- Migrating to YAML / another format. JSON matches settings.json natively.
