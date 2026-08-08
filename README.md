# hooks

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/itsHabib/hooks/actions/workflows/ci.yml/badge.svg)](https://github.com/itsHabib/hooks/actions/workflows/ci.yml)

LLM-side git hooks for the personal workbench — deterministic harness-level scripts that race the agent to mechanical metadata-ferrying between dossier / ship / gh.

## What this is

The **hooks** layer sits between Claude Code or Codex lifecycle hooks and your local tooling. Each script in `scripts/` handles one lifecycle event (`PreToolUse`, `PostToolUse`, etc.), reads event JSON from stdin, and optionally emits short context blocks to stdout for the model. `lib/hook-event.sh` normalizes the envelope differences so hook policy stays harness-neutral.

Hooks integrate with the workbench MCPs (dossier, ship) and the GitHub CLI to ferry metadata between them on deterministic triggers — closing the gap between "agent did the thing" and "the thing got recorded."

Hooks land one per PR with bats tests and an `examples/` settings snippet.

### `posttool-gh-pr-merge.sh`

Runs on `PostToolUse` when the agent executes `gh pr merge`. If the merged PR body contains `Closes task/<slug>` (or `Closes task tsk_…`), the hook auto-completes the dossier task, links the merge commit, and records a State-substrate `receipt` artifact (`meta`: `event=merge`, `pr`, `merge_sha`, `head_sha`, and the authorizing `verdict` art id when one is found). Include that `Closes task` line in PR bodies opened from worktrees.

**Limitation:** merges done in the GitHub web UI do not fire this hook — use `gh pr merge` from the agent session (or complete/link manually).

### `posttool-gate-verdict.sh`

Runs on `PostToolUse` when the agent executes `gate gate` and gate returns `decision: pass`. Records a State-substrate `verdict` artifact at decision time (`ref`: `gate://<repo>/pr/<n>/<run>`, `meta`: `source=gate`, `outcome`, `pr`, `head_sha`, `grant`, `tier`), anchored to the PR's `Closes task` linkage. This is the verdict half of the substrate-autowiring pair; the merge hook's `receipt` joins back to it on `head_sha`. escalate/block/refuse decisions are skipped.

**Limitation:** only agent-run `gate gate` calls fire this — a `gate gate` run in a raw shell won't. The universal anchor for the verdict fact is gate itself; this hook is the local convenience path.

## Prerequisites

- **dossier** — https://github.com/itsHabib/dossier. Install the binary (`cargo install --git https://github.com/itsHabib/dossier`) and create a corpus dir with `<corpus>/.dossier/` as the marker. Hooks find it via `DOSSIER_BIN` + `DOSSIER_CORPUS` env vars set in your settings.json.
- **jq** — `jq >= 1.6` recommended (`brew install jq` / `scoop install jq` / `apt install jq`).
- **gh** — GitHub CLI authenticated (`gh auth status` must succeed) for the `posttool-gh-*` hooks.
- **bash** — Git Bash on Windows; available on Linux out of the box; macOS ships bash 3.2 by default (`brew install bash` for a current build if needed).

Optionally:
- **ship** MCP if you want the `posttool-ship-*` hooks to fire (those listen on `mcp__ship__ship` / `mcp__ship__get_workflow_run` PostToolUse events).

## Wiring hooks

The hook shape is shared. Put it under `hooks` in `~/.claude/settings.json`, or use it as `~/.codex/hooks.json`. Replace `$HOME/dev/hooks` if your clone lives elsewhere:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "bash \"$HOME/dev/hooks/scripts/posttool-gh-pr-merge.sh\"", "timeout": 5 }
        ]
      }
    ]
  }
}
```

Per-hook snippets for the other hooks live in `examples/`. Merge them into the same `hooks` block by combining their `PreToolUse` or `PostToolUse` entries.

Claude Code users merge the relevant blocks into `~/.claude/settings.json`; Codex users put the merged document in `~/.codex/hooks.json`. Do not replace unrelated settings. Set `DOSSIER_BIN` and `DOSSIER_CORPUS` in Claude's top-level `env` block or Codex's `[shell_environment_policy.set]` config table. Codex requires reviewing changed command hooks with `/hooks` before they run.

After editing settings, start a fresh session so the harness reloads hook configuration.

## Conventions

| Rule | Rationale |
|---|---|
| **Stdout = context** | Hook output is injected into the model's context. Keep it short and actionable. |
| **Speed budget ≤ 3s** | Settings.json wraps each hook with `timeout: 5` as a safety margin; hooks should aim well under that. Slow hooks degrade every session. |
| **Fail silent on edge cases** | Missing git repo, malformed JSON, missing tools → exit 0 with no output. Never block the agent. |
| **Idempotent verbs** | When a hook ferries metadata to a tool, the tool's verb must tolerate the hook + the prompt both firing (no double-writes). |
| **Pure bash + git + jq** | No extra runtime dependencies beyond what's already on the operator's machine. |
| **Forward slashes** | Scripts avoid Windows-specific bash idioms; use paths like `~/dev/hooks/...`. |

## Layout

```
scripts/          Hook entrypoints (one per event handler) — populated by follow-up PRs
lib/              Shared helpers (stubs pre-created for parallel wave-2 work)
examples/         Copy-pasteable settings.json snippets — populated by follow-up PRs
tests/            bats unit tests — populated alongside each hook
```

## Development

```bash
make test    # run hook unit tests (vendors bats-core on first run; no-ops if no tests yet)
```

Requires `bash`, `git`, and `jq`. Tests run under bash (Git Bash or WSL on Windows).

## License

MIT — see [LICENSE](LICENSE).
