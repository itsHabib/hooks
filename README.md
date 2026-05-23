# hooks

LLM-side git hooks for the personal workbench — deterministic harness-level scripts that race the agent to mechanical metadata-ferrying between dossier / ship / gh.

## What this is

The **hooks** layer sits between Claude Code's hook system and your local tooling. Each script in `scripts/` handles one lifecycle event (`SessionStart`, `PostToolUse`, etc.), reads event JSON from stdin, and optionally emits short context blocks to stdout for the model.

Hooks integrate with the workbench MCPs (dossier, ship) and the GitHub CLI to ferry metadata between them on deterministic triggers — closing the gap between "agent did the thing" and "the thing got recorded."

This PR ships the scaffold only. Each hook lands in its own follow-up PR with its own bats tests and `examples/` snippet.

## Wiring hooks

Each hook ships its own snippet under `examples/`. Copy the relevant block into `~/.claude/settings.json` under the top-level `hooks` key. Merge with any existing hook entries — do not replace the whole file.

After editing settings, restart Claude Code (or reload settings) so hooks take effect.

## Conventions

| Rule | Rationale |
|---|---|
| **Stdout = context** | Hook output is injected into the model's context. Keep it short and actionable. |
| **Speed budget ≤ 3s** | Wrap commands with `timeout 3` in settings or inside the script. Slow hooks degrade every session. |
| **Fail silent on edge cases** | Missing git repo, malformed JSON, missing tools → exit 0 with no output. Never block the agent. |
| **Idempotent verbs** | When a hook ferries metadata to a tool, the tool's verb must tolerate the hook + the prompt both firing (no double-writes). |
| **Pure bash + git + jq** | No extra runtime dependencies beyond what's already on the operator's machine. |
| **Forward slashes** | Scripts avoid Windows-specific bash idioms; use paths like `~/pers/hooks/...`. |

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
