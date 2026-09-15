# Hook ownership and missing wiring

The useful split: keep each implementation with its owner and make installation gaps
visible here. Copying newer hooks between repos creates another stale version.

## Where implementations live

| Layer | Owner | Use it for |
|---|---|---|
| Shell / Dojo guards, PR / Gate / Ship bookkeeping, guide reminders | [this repo](../scripts/) | Event-specific checks and metadata updates. |
| Fleet lifecycle | [Workbench `cmd/fleet`](https://github.com/itsHabib/workbench/tree/main/cmd/fleet) | Runtime observations, mail, handoffs and admission checks through `fleet hook <harness>`. |
| Codex policy adapter | [Workbench `cmd/codexguard`](https://github.com/itsHabib/workbench/tree/main/cmd/codexguard) | Its supported command-policy and hook adapters; installing Fleet doesn't install this. |
| Historical Python adapters | [cc-skills reference](https://github.com/itsHabib/cc-skills/tree/main/docs/features/agent-fleet-rules/ref) | Historical context; inspect the current Fleet owner before using these. |

## Observed installation gaps

Personal Mac snapshot, September 14, 2026. Read only the global Claude settings and
Codex hooks file. This is configuration evidence, not proof that a hook fires.

| Hook group | Claude global file | Codex global file |
|---|---|---|
| Shell and Dojo guards | Referenced | Not referenced |
| PR create / merge and Gate bookkeeping | Referenced | Not referenced |
| Ship dispatch / run bookkeeping | Referenced | Not referenced |
| Agent-guide parity reminder | Not referenced | Not referenced |
| Fleet lifecycle | Six command entries | Six command entries |

Fleet appears at SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop and
SessionEnd in both files. The old “wired in both” statement confused fixture support
with installation. Other configuration layers may add hooks; this audit doesn't read
them. No global settings were changed by this refresh.

**Next move:** decide which absent hooks are useful, merge their snippets with existing
entries, then verify one event against a temporary corpus. Avoid enabling old hooks
solely to make the table full. For example, the Ship hooks only help callers still
using their named MCP operations.

## Existing work that hasn't landed

Open PRs observed during this reconciliation; check their current state before acting.

| PR | Contribution | Why it matters |
|---|---|---|
| [#42](https://github.com/itsHabib/hooks/pull/42) | Stop discharge | End-of-session reporting currently outside main. |
| [#43](https://github.com/itsHabib/hooks/pull/43) | Discharge sweep | Backfill for what Stop missed. |
| [#44](https://github.com/itsHabib/hooks/pull/44) | Validation mode hygiene | Tests currently chmod tracked files. |
| [#45](https://github.com/itsHabib/hooks/pull/45) | Remove review-cycle cap | Removes obsolete procedural limits. |

These are existing contributions to review and reconcile, not missing code to rebuild.
This refresh doesn't merge them or claim their runtime behavior is verified.

## Lessons for the next update

- **Source, configuration and execution are separate.** Check all three before saying “installed.”
- **Keep one owner.** Link Fleet's current implementation rather than copying its old adapter.
- **Bookkeeping can soft-fail; guards can deny.** Document each script's actual contract.
- **Measure the installed path.** A source fix won't help a configuration pointing elsewhere.
- **Use fixtures plus one real event.** Envelope compatibility and successful artifact delivery answer different questions.
