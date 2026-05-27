# Contributing

Thanks for your interest. This repo is small + opinionated; the bar for contributions is "fits the conventions in this file."

## Local development

```bash
make deps     # vendors bats-core into .deps/ (first run only)
make test     # bats unit tests — fast, mock-based, no external deps
make smoke    # live-corpus end-to-end smoke; requires DOSSIER_BIN or a sibling pers/dossier checkout
make check    # bats + smoke (the CI gate)
```

Smoke needs a working `dossier` binary. The easiest way: clone https://github.com/itsHabib/dossier as a sibling and `cargo build --release` it, then `DOSSIER_BIN=$(pwd)/../dossier/target/release/dossier make smoke`.

## Pull requests

- Each new hook (or major change) ships one PR. Smaller is fine.
- Include bats coverage in `tests/<hook>.bats`. If the change touches the wire contract with dossier, extend `tests/smoke.sh` too.
- PR body must close a dossier task with the backtick form: `` Closes task `<slug>` ``. The `posttool-gh-pr-merge.sh` hook parses this — without it the dossier ferry doesn't fire on merge.
- `make check` must pass — CI gates on both bats and smoke.

## Review cycle

Expect ~3 cycles of review before merge:
1. Copilot + `@codex review` + `@claude review` fire on PR open.
2. Address feedback; push fixes; re-trigger codex/claude with `@codex review` / `@claude review` comments.
3. Repeat until clean or the operator weighs in.

Opinionated changes are fine; don't take review comments blindly.

## Questions vs issues

- Bug reports and feature requests → GitHub issues.
- Larger design questions → open a draft PR with the design doc inline; easier to comment line-by-line than in an issue thread.
