# Contributing

Thanks for your interest. This repo is small + opinionated; the bar for contributions is "fits the conventions in this file."

## Local development

Requires `bash`, `git`, and `jq` on PATH. bats-core is vendored on first run.

```bash
make deps     # vendors bats-core into .deps/ (optional — make test self-bootstraps if absent)
make test     # bats unit tests — fast, mock-based, hits stub binaries
make smoke    # live-corpus end-to-end smoke; requires DOSSIER_BIN or a sibling ../dossier build
make check    # bats + smoke (the CI gate)
```

Smoke needs a working `dossier` binary. The easiest path: clone https://github.com/itsHabib/dossier as a sibling (`../dossier` relative to this repo) and `cargo build --release`; smoke auto-discovers `../dossier/target/{release,debug}/dossier[.exe]`. Or set `DOSSIER_BIN=/explicit/path/to/dossier` directly.

## Pull requests

- Each new hook (or major change) ships one PR. Smaller is fine.
- Include bats coverage in `tests/<hook>.bats` (the convention; ship-* hooks share `tests/posttool-ship.bats`). If the change touches the wire contract with dossier, extend `tests/smoke.sh` too.
- PR body must close a dossier task with the backtick form, with a real slug inside the backticks (no angle brackets, only `[a-zA-Z0-9_-]`):

  ```
  Closes task `my-task-slug`
  ```

  The `posttool-gh-pr-merge.sh` hook parses this — without it the dossier ferry doesn't fire on merge.
- `make check` must pass — CI gates on both bats and smoke.

## Review cycle

Expect ~3 cycles of review before merge. Only Copilot is auto-requested via `requested_reviewers`; the other bots need an explicit @-mention comment to fire (the only auto-firing workflow in this repo is `.github/workflows/claude.yml`, which responds to `@claude` mentions):

1. Open the PR — Copilot reviews automatically. Comment `@codex review @claude review @cursor review` in the same PR to trigger the other three.
2. Address feedback; push fixes; re-trigger the bots that need a fresh pass (same `@codex review` / `@claude review` / `@cursor review` form).
3. Repeat until clean or the operator weighs in.

Opinionated changes are fine; don't take review comments blindly.

## Questions vs issues

- Bug reports and feature requests → GitHub issues.
- Larger design questions → open a draft PR with the design doc inline; easier to comment line-by-line than in an issue thread.
