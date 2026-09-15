# hooks

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/itsHabib/hooks/actions/workflows/ci.yml/badge.svg)](https://github.com/itsHabib/hooks/actions/workflows/ci.yml)

Small Claude Code and Codex hook scripts for guards, task bookkeeping and agent-guide
reminders. Each reads one event from stdin. Shared helpers normalize supported
harness envelopes; tests cover their differences.

## What's here

| Hook | Event | Job |
|---|---|---|
| [pretool-guard](scripts/pretool-guard.sh) | PreToolUse | Shape-check sensitive shell commands; deny matches with a remedy. |
| [dojo-scrub-guard](scripts/pretool-dojo-scrub-guard.sh) | PreToolUse | Check lesson writes for work-data identifiers, including supported `apply_patch` edits. |
| [gh-pr-create](scripts/posttool-gh-pr-create.sh) | PostToolUse | Link a new PR to its Dossier task. |
| [gh-pr-merge](scripts/posttool-gh-pr-merge.sh) | PostToolUse | Complete the linked task and record merge evidence. |
| [gate-verdict](scripts/posttool-gate-verdict.sh) | PostToolUse | Record a passing `gate gate` result against the linked task and head. |
| [ship-dispatch](scripts/posttool-ship-ship-dispatch.sh) | PostToolUse | Record a Ship dispatch against the task. |
| [ship-getrun](scripts/posttool-ship-getrun.sh) | PostToolUse | Record terminal Ship run artifacts. |
| [agent-guide-parity](scripts/posttool-agent-guide-parity.sh) | PostToolUse | Advise when paired `AGENTS.md` / `CLAUDE.md` guidance drifts. |

[sweep-merged.sh](scripts/sweep-merged.sh) reconciles missed merge bookkeeping.
[audit-wiring.sh](scripts/audit-wiring.sh) reports local configuration references.
Neither is a lifecycle hook.

**Fleet's current lifecycle hooks live in Workbench.** Use `fleet hook claude` or
`fleet hook codex` through its own installation workflow. See the
[ownership map](docs/hook-ownership.md) for Fleet, codexguard and older adapters.

## Check your wiring

```sh
bash scripts/audit-wiring.sh
# Or inspect saved configurations:
bash scripts/audit-wiring.sh --claude /path/settings.json --codex /path/hooks.json
```

The audit reads configuration without executing commands or changing settings. It
reports textual references, their event/matcher and Fleet command counts. Missing or
malformed files return a nonzero exit. `not-referenced` means absent from the inspected
file, which can be intentional. It doesn't inspect project/plugin settings, prove a
matcher fires, or establish trust, enablement or successful execution.

## Wire the pieces you need

1. Choose a hook from the table and its [example](examples/).
2. Merge its event entries into Claude's `~/.claude/settings.json` or Codex's
   `~/.codex/hooks.json`. Preserve existing hooks, especially Fleet's lifecycle entries.
3. Replace the clone path and set `DOSSIER_BIN` / `DOSSIER_CORPUS` for bookkeeping
   hooks. Use a temporary corpus for validation.
4. Reload the harness, complete its command-hook trust flow where required, and
   exercise the event. Check the resulting artifact or diagnostic.

Examples are opt-in fragments, not full settings files. The event-envelope tests
cover the supported shapes; configuration on one harness doesn't install it on the
other. [The reconciliation notes](docs/hook-ownership.md#observed-installation-gaps)
show a concrete case where that distinction matters.

## Dependencies and behavior

- Bash, Git and jq. **The Dojo scrub guard requires Bash 4+**; macOS's system Bash
  3.2 lacks its lowercase expansion. Use a current Bash explicitly in that hook.
- Local Dojo scrub patterns at `~/.claude/dojo/scrub-markers.txt` for the lesson
  guard. Missing patterns deny writes to the shared lesson directory; keep patterns
  private and out of settings examples.
- Dossier for task bookkeeping; set `DOSSIER_BIN` and `DOSSIER_CORPUS`.
- Authenticated `gh` for PR lookups. Ship hooks apply to the named MCP tool events,
  not every possible Ship invocation.

Bookkeeping and reminder hooks return success on recoverable errors. Dossier failures
are logged to `HOOKS_ERROR_LOG` (default `~/.cache/hooks-errors.log`). Guards can return
exit 2 to deny a matched operation. **The “never block” convention applies to
bookkeeping, not guards.** Keep context output short and hooks fast.

The shell guard checks command text and merge shape. It doesn't establish a grant,
verify the Gate verdict, or prevent every alternative execution path. Authority and
credential boundaries remain with their owning tools.

## Development

```sh
make test     # Bats fixtures, including Claude/Codex event envelopes
make smoke    # temporary corpus against a real Dossier binary
make check    # both
```

`make smoke` requires `DOSSIER_BIN` or a built sibling Dossier checkout. CI builds
Dossier before running both checks. Tests must preserve tracked executable modes;
[PR #44](https://github.com/itsHabib/hooks/pull/44) addresses the existing validation
mode churn. See [CONTRIBUTING.md](CONTRIBUTING.md) and [CLAUDE.md](CLAUDE.md).

MIT. See [LICENSE](LICENSE).
