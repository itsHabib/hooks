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

- `posttool-ship-ship-dispatch.sh` — notes ship dispatches into the linked task; on cloud runs also links the Cursor agent watch URL (`cursor.com/agents/<bc-id>`) as a `kind:url` artifact
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
catches mock-reality drift before merge.

<!-- BEGIN dev-workbench (managed by /dev-workbench skill — re-run to refresh; hand-edits inside this block will be overwritten) -->
## Dev workbench

These MCPs, planes, and skills are available in any agent session on this machine; the harness injects each tool's signature, so this is the *map* — how they compose — not the per-verb manual. When the signal matches, call the verb; don't ask permission. Stuck on a *knowledge* question about another portfolio repo → `/consult` its steward; only *authority* questions (direction, spend, irreversible calls) go to the operator. **This is hooks — the PostToolUse dossier bookkeeping**; mechanical metadata-ferrying raced by the harness, not entrusted to agent diligence.

**MCPs (in-session):**
- **dossier** — durable project memory: projects → phases → tasks → artifacts (markdown-on-disk).
- **ship** — the driver engine: dispatch a task to a cloud/local agent and persist the run (dispatch→poll→judgment→land→record); inspect/cancel/replay.
- **huddle** — *optional* multi-seat coordination (Slack-backed); off the normal PR path.
- **playwright** — browser automation when a task needs a real DOM.

**Planes (CLIs, composed via exit codes + JSONL — not MCPs):**
- **gate** — authorization: evaluates the *exact* PR head, emits governed-path merge authorization. Findings ≠ authorization; gate is the merge boundary.
- **flare** — notification: best-effort escalation sink over authoritative receipts → its own Slack app/channel. Pure sink; never gates; not built on huddle.

**Skills:**
- **/work-driver** [+ **/work-driver-prep**] — drive agent-led impl end-to-end; prep builds the specs + conflict-batched plan.
- **/pr-risk** — size how much review a PR needs (deterministic floor + agent advisory); upstream of the reviewers — it decides *how much*, they *do* it.
- **/review-coordinator** [+ **/review-digest**] — consolidate the AI PR reviewers into one verdict (the judge over the finders); digest pre-triages the bot pile locally.
- **/shipped** · **/status** · **/wip** — retrospective recap · in-flight update · cross-store live board.
- **/consult** — summon a sibling repo's steward for a same-turn answer; knowledge → peer, authority → operator.
- **/worktree-*** — add · list · remove · transfer · where, over `git worktree`.

### The loop

```
dossier task → /worktree-add → spec → ship driver (cloud-first: dispatch→poll→judgment→land→record)
   → PR + CI → /pr-risk tiers it → reviewers fire → /review-coordinator → one verdict
   → gate evaluates the exact head → governed-path authorization → merge
   → authoritative receipts → dossier close-out → /worktree-remove
        ↘ any attention/terminal receipt → best-effort flare sweep → Slack   (independent; never gates)
```

`/work-driver` coordinates dispatch→poll→land and runs its own review triage inline. `/pr-risk` and `/review-coordinator` are steps you *invoke* — the driver→pr-risk / driver→coordinator wiring is planned, not built, so nothing here auto-delegates.

### Why this shape

Each layer owns one responsibility and is swappable without rippling: dossier owns *what needs doing*; worktree skills own *where work happens*; ship owns *drive an agent + persist the run*; pr-risk owns *how much review*; review-coordinator owns *consolidate the finders* (the bots are swappable under it); **gate owns *authorization* — is this exact head allowed to merge — which is not the reviewers' findings**; **flare owns *notification* — a best-effort sink on authoritative receipts, its own Slack app, never blocking the driver, never depending on huddle**; consult owns the stuck path; huddle owns optional multi-seat; playwright owns browser. The workbench is a menu, not a checklist — skip what a flow doesn't need.

### The shape underneath

These tools instantiate the redesign's five contract planes — coupled only by typed artifacts (`evidence → verdict → action`), never call stacks:

- **State** (remembers) — dossier + run/verdict/grant/receipt artifacts; the append-only substrate.
- **Execution** (does) — ship's driver; emits evidence, never judges itself.
- **Verification** (judges) — the escalate-only ladder (deterministic floor → local → premium), monotone `worst`/`max`: gate's reducer, review-coordinator, sense/triage/tracelens.
- **Capability** (bounds) — scoped/timed grants; every effectful verb needs a live grant + a supporting verdict.
- **Observability** (explains) — read-only, storeless views from State: flare, /wip, /shipped, /status.

This section is the sixth — **Composition**: the agent + thin policy choosing which planes a task needs. The boundaries above *are* the plane laws, not conventions.
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
`DOSSIER_BIN` at it. Both repos are public, so the workflow's default
`GITHUB_TOKEN` is enough — no extra PAT or repo secret needed.

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

<!-- BEGIN eng-philo (managed by /eng-philo — re-run to refresh; hand-edits inside this block will be overwritten) -->
## Engineering principles

How code is written here — Dave Cheney lineage ([Practical Go](https://dave.cheney.net/practical-go)): simplicity, clarity, line-of-sight. Apply on every change; the lint below catches the slips.

1. **No `else` — line-of-sight.** Handle errors / edge cases with early returns and guard clauses; keep the happy path un-indented, flowing down the left margin. Reaching for `else` → return early instead.
2. **Shallow nesting — ≤2 levels *per scope*.** A `for` + an `if` is the ceiling in one scope. The budget is per-scope, not per-function — a closure / anon fn is its own scope, so a `for`+`if` inside a closure is fine. Deeper in one scope → extract a function.
3. **Policy vs mechanism.** Separate the decisions (policy: validation, state machines, business rules) from the plumbing (mechanism: persistence, transport, I/O). Mechanism is dumb and swappable; policy lives in a layer above it. Never let policy leak into a mechanism layer.
4. **Composition of single-responsibility layers.** Each layer / package owns ~one responsibility; the app is a *composition* of them; any piece is swappable without rippling into the others. Dependencies flow one direction.
5. **Small, sharp APIs.** Export the least callers need. Intention-revealing names. Accept the narrowest input, return concrete types. Make the zero value useful.
6. **Errors are values; simplicity over cleverness.** Handle or propagate errors explicitly — never swallow. Readable > clever > short. A little copying beats a premature abstraction or dependency.

_No code manifest detected — universals only; re-run `/eng-philo` once the repo has a stack manifest to add the idioms + enforcement block._
<!-- END eng-philo -->

## Common gotchas

- **Mock-reality drift.** `tests/fixtures/bin/dossier` and `tests/fixtures/mock-dossier.sh` mirror real dossier wire shape (`project` = id, `project_slug` = slug). When the dossier wire format changes, update the mocks here OR `make smoke` will catch it in CI. Don't author hook logic against a hand-crafted mock that's drifted from reality — that's how the 2026-05-23 silent-fail outage happened.
- **Silent failure was the original design flaw.** Until 2026-05-27, every dossier wrapper call ended in `|| true` at the caller — failures left no trace and the only operator signal was "no artifacts ever appear in the corpus." `_dossier_run` in `lib/dossier-cli.sh` now captures stderr and logs every non-zero exit to `HOOKS_ERROR_LOG`. Don't undo this in the name of "cleaner code."
- **PR body forms.** `lib/pr-lookup.sh` accepts four task-linkage forms: `Closes task/<slug>` (slash), `Closes task tsk_…` (space-id), `task: tsk_…` (yaml), and `` Closes task `<slug>` `` (backtick — the operator's standing convention). All four are exercised in bats; smoke uses the backtick form.
- **Ship hooks (`posttool-ship-*.sh`) firing in real Claude Code sessions is unverified.** The 2026-05-27 "PostToolUse hooks not firing" gotcha was traced to two bugs in `lib/pr-lookup.sh` + `_infer_project_slug` that affect `posttool-gh-pr-{create,merge}.sh`; those are fixed in this commit. The ship hooks read from `tool_response.worktree.path` + `tool_response.docPath` and parse the spec's `**Related**` header — that path hasn't been re-verified end-to-end since the gh-side fix landed. If you fire a `mcp__ship__ship` or `mcp__ship__get_workflow_run` and don't see a `hook:ship-*`-actor artifact in the corpus, add a `date >> /tmp/hooks-fired.log` probe to confirm whether the hook is firing at all.
- **`gh pr merge` from the GitHub web UI does NOT fire `posttool-gh-pr-merge.sh`.** Use `gh pr merge` from the agent session, or call `artifact_link` + `task_complete` manually.
- **Windows binary lock.** When `DOSSIER_BIN` points at a debug-build dossier in a worktree, rebuilding requires a Claude Code restart to release the file lock. Switching to `cargo install --path ~/pers/dossier --force` (which writes to `~/.cargo/bin/dossier.exe`) sidesteps this — the installed binary isn't held by the running session.

## Shipping changes

- Each new hook (or major change) ships one PR. Include bats coverage in `tests/<hook>.bats`; if the change touches the wire contract with dossier, extend `tests/smoke.sh` too.
- PR body must close a dossier task with the backtick form: `` Closes task `<slug>` ``.
- Request Copilot, `@codex review`, and `@claude review`. (`@claude review` on this repo needs `CLAUDE_CODE_OAUTH_TOKEN` set in repo secrets; on `itsHabib/hooks` specifically that secret is already in place — but worth confirming if reviews don't fire.)
- `make check` must pass before merge — CI gates on both bats and smoke.
- Address review comments in cycles (~3 cap before merging anyway). Opinionated is fine; don't take comments blindly.

<!-- local-offload:start -->
## Local-first offload

Before spending cloud tokens on a mechanical sub-step, check for a free local path (needs the `local` CLI / Ollama on this machine):

- Narrowing a big file list, extracting structure from noisy tool output, shallow classification -> `/offload`
- "Have we solved/decided this before?" questions about the operator's own work -> `/ask-portfolio`
- Triaging a PR's bot-comment pile -> `/review-digest <PR#>`

Deep judgment (code review, risk calls, dense-diff reasoning) stays with the primary model. If `local` is not on PATH, skip silently -- never block on this.
<!-- local-offload:end -->
