# hooks

Notes for agents working on this repo. Read before touching code.

hooks is the operator's **LLM-side git hook layer** — deterministic
harness-level scripts that race the agent to mechanical
metadata-ferrying between dossier, ship, and gh. Each script in
`scripts/` handles one `PostToolUse` event, reads event JSON from
stdin, resolves the linked dossier task, and writes back via the
dossier CLI. Hooks must never block the agent: they soft-fail silent
on every error path; failures land in `~/.cache/hooks-errors.log` for
triage rather than the agent's transcript.

## State

Wave-1 (integration-layer) shipped 2026-05-22 → 27. Four hooks live:

- `posttool-ship-ship-dispatch.sh` — notes ship dispatches into the linked task
- `posttool-ship-getrun.sh` — links terminal ship runs as `kind:run` artifacts (also appends a terminal note on `failed` / `cancelled`)
- `posttool-gh-pr-create.sh` — auto-links new PRs as `kind:pr` artifacts
- `posttool-gh-pr-merge.sh` — auto-completes the linked task + links the merge commit as `kind:commit`

All four are wired in `~/.claude/settings.json` under PostToolUse with
matchers `Bash`, `mcp__ship__ship`, and `mcp__ship__get_workflow_run`.
The session env sets `DOSSIER_BIN` and `DOSSIER_CORPUS` so the hook
subprocess hits the real dossier corpus.

v1-hardening (PRs #9 + #10, in flight): `lib/dossier-cli.sh` wraps
each dossier verb with stderr capture and structured failure logging
to `HOOKS_ERROR_LOG`. A `make smoke` target fires all four hooks
against a real dossier binary + tmp corpus in CI on every PR —
catches mock-reality drift before merge. The CI workflow needs a
`DOSSIER_CHECKOUT_TOKEN` secret (fine-grained PAT, read-only on
`itsHabib/dossier`) for the smoke step.

<!-- BEGIN dev-workbench (managed by /dev-workbench skill — re-run to refresh; hand-edits inside this block will be overwritten) -->
## Dev workbench

Several MCP servers + skills are available in any Claude session on this machine — the dev-workflow infrastructure built across the portfolio. This repo is itself part of that infrastructure: every hook here writes back into dossier and rides on top of ship runs. When the signal matches, **just call the verb**. Don't ask permission.

### dossier — project memory

Long-term home for what's planned, in-flight, and shipped across the portfolio. Projects → phases (design docs) → tasks → artifacts (PRs / commits / files). Markdown-on-disk corpus; the on-disk format IS the source of truth. **The hooks in this repo write to dossier on every ferry** — every change here should think about whether it produces a clean `hook:`-actor artifact in the corpus.

**Use proactively for:**

- *"What's the state of `<project>`?"* → `mcp__dossier__project_get { slug }`, then `mcp__dossier__phase_list` + `mcp__dossier__task_list { project, status: ["in_progress"] }`.
- *"I'm starting `<new chunk of work>`."* → `mcp__dossier__phase_add { project, slug, title, body }`.
- *"I need to do X"* / discrete actionable surface → `mcp__dossier__task_create { project, phase?, slug, title, body }` (status defaults to `todo`).
- Picking up a task → `mcp__dossier__task_claim { id, actor: "human:michael" }`. Re-claim by same actor is a no-op.
- Progress on a task → `mcp__dossier__task_update { id, status?, note?, ... }`. Append notes liberally — the corpus IS the working log.
- Open / merged PR → `mcp__dossier__artifact_link { project, task?, kind: "pr"|"commit", ref, label }` without being asked.
- *"Done with task X."* → `mcp__dossier__task_complete { id, note? }`.

**Don't use for:**

- Code-level work (write the code first; *then* `artifact_link` the PR).
- Anything that only matters within this session's scratch context.

### ship — workflow execution

Hands a task doc to a coding agent (cursor), persists what happened, lets you inspect / cancel / replay the run. Owns nothing about the workspace (the `/worktree-*` skills handle that) or the planning (dossier's job). Ship's `mcp__ship__get_workflow_run` is one of the events `posttool-ship-getrun.sh` listens for.

**Use proactively for:**

- *"Ship `<task doc>` against `<worktree>`."* → `mcp__ship__ship { workdir, docPath, repo, branch }`. V2-async — returns `{ workflowRunId, status: "running" }` immediately.
- *"What ran on `<repo>` recently?"* / *"What's still in flight?"* → `mcp__ship__list_workflow_runs { repo?, status?, limit? }`.
- *"What did `<wf id>` do?"* → `mcp__ship__get_workflow_run { workflowRunId }` (also accessible via the `ship://runs/{id}` resource).
- In-flight run needs to stop → `mcp__ship__cancel_workflow_run { workflowRunId }` (idempotent on terminal rows).
- *"Open the PR for this run."* → `mcp__ship__open_pr { workflowRunId }`.

**Don't use for:**

- Creating the worktree (use `/worktree-add`).
- Writing the task doc (a normal file edit inside the worktree).
- Recording the merged PR back to project state (dossier `artifact_link` — or let `posttool-gh-pr-merge.sh` do it for you).

### huddle — multi-agent / multi-seat coordination

Spins up a Slack channel + per-seat keys so multiple agents (or agent + human) can share a working context without polluting any one session's chat. Each "seat" gets a key it uses to post / read; the orchestrator (huddle creator) has full access via `huddleId`. Not currently exercised by any hook in this repo.

**Use proactively for:**

- *"Set up a coordination channel for `<purpose>` with `<N>` agents."* → `mcp__huddle__huddle_create { purpose, orchestrator: { id, displayName }, seats: [{ id, displayName }, ...], ttlHours? }`. Returns per-seat keys + Slack channel id.
- *"What huddles are open?"* → `mcp__huddle__huddle_list { active: true }`.
- *"Post an update into huddle `<id>`."* → `mcp__huddle__huddle_post { huddleId, body, key?, replyTo? }`. Orchestrator omits `key`; seats include their key.
- *"Catch up on the channel."* → `mcp__huddle__huddle_read { huddleId?, key?, since?, limit? }`.
- Done → `mcp__huddle__huddle_close { huddleId }` (archives the Slack channel + marks done).

**Don't use for:**

- One-off agent runs that don't need cross-agent coordination — just ship the task and read the events log.
- Long-term project memory (dossier owns that).

### playwright — browser automation

Headless / headed browser control via Playwright. Use when an agent task genuinely needs to interact with a web UI (login flow, scraping rendered DOM, screenshotting a page state) rather than hitting an API.

**Use proactively for:**

- *"Open `<url>` and check `<element>`."* → `mcp__plugin_playwright_playwright__browser_navigate { url }` then `..._browser_snapshot` (returns the accessibility tree) or `..._browser_take_screenshot`.
- *"Fill `<form>` and submit."* → `..._browser_fill_form { fields: [...] }` then `..._browser_click { ref }`.
- *"Capture network requests during `<flow>`."* → `..._browser_navigate` + `..._browser_network_requests` after the action.
- *"Run JS against the page."* → `..._browser_evaluate { code }`.

**Don't use for:**

- API testing — use `curl` / `gh` / a real HTTP client.
- Anything where the page is server-rendered and could be fetched via `WebFetch` instead.
- Tasks where the operator's actual Chrome session is needed (use the claude-in-chrome MCP for that — separate tier).

### `/work-driver` — drive agent-led impl end-to-end

Coordinates one or N parallel streams through the full loop: pre-flight worktrees, fan out via `ship.ship`, poll terminal states, verify cursor's auto-commit (or commit manually if absent), open PRs, drive review cycles, merge in dep order, cleanup. Reads a manifest produced by `/work-driver-prep` (the common case) or a list of one-off spec docs (ad-hoc).

**Triggers:** "drive this impl work", "run this through ship", "fire N parallel streams", "ship and merge", explicit `/work-driver`.

**Pair with:** `/work-driver-prep` when you have a batch of dossier tasks and want one spec doc per task + conflict-aware batching before fanning out.

### `/work-driver-prep` — spec docs + batched plan from a backlog of tasks

Takes a list of dossier tasks (or a phase slug) and emits one spec doc per task plus a structured `driver.md` manifest grouping the specs into parallel-safe batches. Removes the manual gap between "I have N todo tasks" and "I can invoke `/work-driver`."

**Triggers:** "ship the open follow-ups", "fan these tasks out", "prep work-driver", "set up the hygiene PRs", explicit `/work-driver-prep`.

**Pair with:** `/work-driver` (consumes the emitted manifest).

### `/shipped` — retrospective recap after a chunk of work lands

Post-batch summary: PRs merged + weighted-LOC, dossier task closures, chips filed, friction-log delta, what's open, next moves. Auto-detects work-driver manifests for ground truth; falls back to git/gh/dossier signals otherwise.

**Triggers:** "what just shipped", "what did we ship", "what merged today", "post-run summary", "what now", explicit `/shipped`.

**Pair with:** `/work-driver` (natural post-fan-out follow-up). Distinct from `/status` — `/shipped` is retrospective on landed work, `/status` is in-flight.

### `/status` — tight in-flight status update

Four sections, 1-3 sentences each: What happened / What's next / What I recommend / What I need from you. Skip any section that's genuinely empty.

**Triggers:** "give me an update", "status", "where are we", "sitrep", "recap", "summarize the situation", explicit `/status`.

**Pair with:** `/shipped` once the work actually lands.

### `/worktree-*` — manage secondary git worktrees

Thin skill family over plain `git worktree`. Use these instead of reaching for an MCP — they cover the verbs that mattered (add, list, remove, transfer, where) without an external state store. Default convention: branch name is user-chosen (no forced prefix); path is `<repo>/.claude/worktrees/<branch>/`.

- **`/worktree-add`** — *"spin up a worktree for <ticket>"* → creates `.claude/worktrees/<branch>/`, copies untracked CLAUDE.md if present
- **`/worktree-list`** — *"what worktrees do I have"* → branch, dirty state, optional PR/CI from `gh`
- **`/worktree-remove`** — *"clean up the worktree"* → dirty-state aware (commit-WIP / stash / discard)
- **`/worktree-transfer`** — *"bring this work over to main"* → removes secondary, checks out branch in root
- **`/worktree-where`** — *"where am I"* → which worktree, branch, and cwd this session is pointing at

### The loop

A typical end-to-end flow when working on any portfolio repo:

```
mcp__dossier__task_create        # plan: discrete shippable unit
       │
       ▼
/worktree-add <branch>           # isolate: own branch + dir under .claude/worktrees/
       │
       ▼
(write the spec doc inside the worktree, commit, push)
       │
       ▼
mcp__ship__ship { workdir, docPath, repo, branch }    # dispatch cursor against the spec
       │     │
       │     └─ /work-driver coordinates the rest if multiple streams:
       │        poll → land → PR → review cycles → merge → cleanup
       ▼
gh pr create + request reviewers (Copilot + @codex + @claude)
       │     │
       │     └─ posttool-gh-pr-create.sh fires → kind:pr artifact lands in dossier
       ▼
gh pr merge --squash --admin --delete-branch     # remote-only delete
       │     │
       │     └─ posttool-gh-pr-merge.sh fires → task_complete + kind:commit artifact
       ▼
/shipped                                          # retrospective recap
       │
       ▼
/worktree-remove                                  # local cleanup (or /worktree-transfer to drain into root)
```

The four hooks in this repo automate the dossier-side bookkeeping in steps 5-6 — without them, the operator (or model) has to remember to call `artifact_link` and `task_complete` manually every time.

### Why this shape

Each layer is independently swappable. Dossier could be Linear or GitHub Projects — it owns "what needs doing." The `/worktree-*` skills could be hand-rolled `git worktree` calls or a Codespace driver — they own "where work happens." Ship could be a different agent runner (Claude Code SDK, a local cursor subprocess, etc.) — it owns "drive an agent against a workdir + persist what happened." Huddle owns multi-seat coordination; playwright owns browser. The hooks in *this* repo are the seam that wires "agent did the thing in ship/gh" to "the thing got recorded in dossier" — substitute any one layer and only the relevant hook needs to change.

Not every flow uses every tool. A one-off CLI fix can skip dossier; an existing-checkout edit can skip the worktree skills; a non-agent change skips ship. The workbench is a menu, not a checklist — but when the signals above match, default to calling the verb without checking in first.
<!-- END dev-workbench -->

## Architecture

```
scripts/<hook>.sh    PostToolUse entrypoint — one file per matcher
lib/                 Shared helpers sourced by hooks
  dossier-cli.sh       wrappers around the dossier CLI verbs hooks use
  pr-lookup.sh         parse PR body → task slug/id
  ship-task-lookup.sh  resolve spec doc → task id + project slug
tests/               bats suite (mock-based) + smoke.sh (live-corpus)
  fixtures/            event JSON, gh mock, dossier mock, corpus stubs
.github/workflows/   ci.yml (bats + smoke) and claude.yml (review bot)
examples/            copy-pasteable settings.json hook snippets
```

Hooks are pure bash + jq. No language runtime, no daemons, no external
state — the operator's dossier corpus IS the state, and every hook
write is idempotent on the dossier side.

## Develop

```sh
make test     # bats unit tests (vendors bats-core on first run)
make smoke    # live-corpus smoke — requires DOSSIER_BIN or sibling pers/dossier
make check    # bats + smoke (the CI gate)
```

CI runs both in `.github/workflows/ci.yml`. The smoke step checks out
`itsHabib/dossier` as a sibling, builds release, and points
`DOSSIER_BIN` at it. Because dossier is private, the workflow needs a
`DOSSIER_CHECKOUT_TOKEN` secret on this repo — a fine-grained PAT
with read access to `itsHabib/dossier`.

Requires `bash`, `git`, and `jq`. Tests run under bash (Git Bash or
WSL on Windows).

## Conventions

| Rule | Rationale |
|---|---|
| **Stdout = context** | Hook output is injected into the model's context. Keep it short and actionable; emit only on auto-link / soft-warn paths. |
| **Speed budget ≤ 3s** | Settings.json wraps each hook with `timeout: 5`. Slow hooks degrade every session. |
| **Soft-fail silent** | Missing git repo, malformed JSON, missing tools → `exit 0`. Never block the agent. Failures land in `~/.cache/hooks-errors.log` for triage rather than the agent transcript. |
| **Idempotent verbs** | Dossier write verbs (`artifact_link`, `task_complete`) tolerate the hook + the prompt both firing — no double-writes. |
| **Pure bash + git + jq** | No extra runtime deps beyond what's already on the operator's machine. |
| **Forward slashes** | Scripts avoid Windows-specific bash idioms; use paths like `~/pers/hooks/...`. |
| **HOOK_NAME at top of every hook** | `lib/dossier-cli.sh`'s failure log uses it as the hook-name column; without it, failures log as `unknown-hook`. |

## Common gotchas

- **Mock-reality drift.** `tests/fixtures/bin/dossier` and `tests/fixtures/mock-dossier.sh` mirror real dossier wire shape (`project` = id, `project_slug` = slug). When the dossier wire format changes, update the mocks here OR `make smoke` will catch it in CI. Don't author hook logic against a hand-crafted mock that's drifted from reality — that's how the 2026-05-23 silent-fail outage happened.
- **Silent failure was the original design flaw.** Until 2026-05-27, every dossier wrapper call ended in `|| true` at the caller — failures left no trace and the only operator signal was "no artifacts ever appear in the corpus." `_dossier_run` in `lib/dossier-cli.sh` now captures stderr and logs every non-zero exit to `HOOKS_ERROR_LOG`. Don't undo this in the name of "cleaner code."
- **PR body forms.** `lib/pr-lookup.sh` accepts four task-linkage forms: `Closes task/<slug>` (slash), `Closes task tsk_…` (space-id), `task: tsk_…` (yaml), and `` Closes task `<slug>` `` (backtick — the operator's standing convention). All four are exercised in bats; smoke uses the backtick form.
- **PostToolUse hooks may not fire reliably for the model's own tool calls.** Observed 2026-05-27: hooks correctly wired in settings.json, binary fresh, env block correct — yet `mcp__ship__get_workflow_run` and `gh pr merge` calls in the same session produced zero hook artifacts. Manual `bash scripts/<hook>.sh --no-timeout < event.json` fires worked fine. If you make tool calls and don't see expected artifacts, manually fire to bisect; root cause for the session-level firing gap is still open.
- **`gh pr merge` from the GitHub web UI does NOT fire `posttool-gh-pr-merge.sh`.** Use `gh pr merge` from the agent session, or call `artifact_link` + `task_complete` manually.
- **Windows binary lock.** When `DOSSIER_BIN` points at a debug-build dossier in a worktree, rebuilding requires a Claude Code restart to release the file lock. Switching to `cargo install --path ~/pers/dossier --force` (which writes to `~/.cargo/bin/dossier.exe`) sidesteps this — the installed binary isn't held by the running session.

## Shipping changes

- Each new hook (or major change) ships one PR. Include bats coverage in `tests/<hook>.bats`; if the change touches the wire contract with dossier, extend `tests/smoke.sh` too.
- PR body must close a dossier task with the backtick form: `` Closes task `<slug>` ``.
- Request Copilot, `@codex review`, and `@claude review`. (`@claude review` on this repo needs `CLAUDE_CODE_OAUTH_TOKEN` set in repo secrets; on `itsHabib/hooks` specifically that secret is already in place — but worth confirming if reviews don't fire.)
- `make check` must pass before merge — CI gates on both bats and smoke.
- Address review comments in cycles (~3 cap before merging anyway). Opinionated is fine; don't take comments blindly.
