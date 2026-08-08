# hooks — agent guide

Portfolio-managed context for Codex / AGENTS-aware harnesses. For this repo's own project detail, read **CLAUDE.md**.

<!-- BEGIN dev-workbench (managed by /dev-workbench skill - re-run to refresh; hand-edits inside this block will be overwritten) -->
## Dev workbench

These MCPs, planes, and skills are available in Claude and Codex sessions on this machine; each harness injects tool signatures, so this is the map of how they compose, not a second verb manual. When the signal matches, call the verb. Knowledge questions about another portfolio repo go to `/consult`; authority questions - direction, spend, credentials, irreversible actions - go to the operator.

**MCPs (in-session):**
- **dossier** - durable project memory: projects -> phases -> tasks -> artifacts.
- **ship** - dispatch an agent and persist dispatch -> poll -> judgment -> land -> record.
- **huddle** - optional multi-seat coordination; off the normal PR path.
- **playwright** - browser automation when the task requires a real DOM.

**Planes (workbench CLIs composed through exit codes and JSONL, not MCPs):**
- **gate** - authorization at the exact PR head against an operator-minted grant; findings are not authorization. Exit 0 pass / 1 block / 2 park / 3 refuse / 4 error.
- **flare** - best-effort notification sink over authoritative receipts; never gates.
- **console** - read-only local view of Gate's inbox and grant ledger; explains, never decides.
- **escalate** - agent -> human -> agent resolution channel for a parked Gate run.

**Skills:**
- **/work-driver** + **/work-driver-prep** - drive implementation; prep builds specs and conflict-safe batches.
- **/pr-risk** - decide how much review a change needs; reviewers perform it.
- **/review-coordinator** + **/review-digest** - consolidate reviewer findings; digest is the deterministic pre-pass.
- **/shipped** / **/status** / **/wip** - retrospective / current-session / portfolio-liveness views.
- **/consult** - ask a sibling repo's steward; knowledge to peers, authority to the operator.
- **/worktree-*** - add / list / remove / transfer / locate isolated checkouts.

### The loop

```text
dossier task -> /worktree-add -> spec -> ship driver (dispatch -> poll -> judgment -> land -> record)
  -> PR + CI -> /pr-risk -> reviewer panel -> /review-coordinator -> one findings artifact
  -> gate evaluates the exact head -> 0: emitted head-pinned merge command -> merge
  -> authoritative receipts -> dossier close-out -> /worktree-remove
       \-> 2: park -> console / gate next -> human decision -> escalate -> gate resolve -> gate next
       \-> attention or terminal receipt -> flare -> Slack (best effort; never gates)
```

### Why this shape

Each layer owns one responsibility and can be replaced without rippling: dossier owns what needs doing; worktree skills own where work happens; Ship owns agent execution and durable run state; pr-risk owns review depth; reviewer bots are swappable finders; review-coordinator owns their consolidated artifact; Gate alone owns exact-head merge authorization; Escalate carries a human resolution without deciding it; Console explains Gate state; Flare notifies; Consult handles cross-repo knowledge. The workbench is a menu, not a checklist.

### The shape underneath

The contract planes are **State** (dossier plus run, verdict, grant, and receipt artifacts), **Execution** (Ship), **Verification** (review and Gate's escalate-only verifier ladder), **Capability** (scoped operator-minted grants), and **Observability** (Console, Flare, /wip, /shipped, /status). This section is **Composition**. Planes share typed artifacts - evidence -> verdict -> action - rather than call stacks.
<!-- END dev-workbench -->

## Review-cycle discipline

Per PR, at most **two fix-rounds** against the review panel: fix every
verified finding at P1 or higher and anything touching authorization
invariants, push once, re-trigger the panel once — then one more round
at the same bar. After round two, STOP fixing. Residual P2s and nits go
to the judge with a written why — a judgment can accept
verified-addressed-but-unretracted threads and recorded deferrals (a
FOLLOWUPS.md at the repo root). Reviewers generate second-order findings
on every new diff indefinitely, so "zero open findings" is a
non-terminating exit condition; the judge's residual acceptance is the
terminating one.

Two fix-rounds plus the initial panel run is three review cycles, which
is why review caps default to `max_cycles: 3`; `max_requests` caps total
panel re-triggers across the PR. These caps are the stop signal, not
friction — never respond to a ceiling park by asking for a wider grant.
A blown cap means the process looped; the fix is fewer rounds, not more
budget. Behavioral claims that reviewers keep re-litigating belong in
e2e tests asserted every CI run, not in review rounds.

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
