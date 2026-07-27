#!/usr/bin/env bash
# PostToolUse hook: record a dossier `verdict` artifact when `gate gate`
# authorizes a PR (decision=pass). This is the driver-agnostic verdict emitter
# of the substrate-autowiring initiative — it fires whenever an agent runs
# `gate gate` and gate passes, so the authorizing verdict lands in the substrate
# at decision time (the only moment tier/grant/outcome are in hand). The
# matching `receipt` is emitted by posttool-gh-pr-merge.sh at merge time and
# joins back to this verdict on head_sha.
set -uo pipefail

HOOK_NAME="posttool-gate-verdict"
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HOOK_DIR/.." && pwd)"

# shellcheck source=lib/dossier-cli.sh
source "$ROOT_DIR/lib/dossier-cli.sh"
# shellcheck source=lib/pr-lookup.sh
source "$ROOT_DIR/lib/pr-lookup.sh"

_warn() {
  printf '%s: %s\n' "$HOOK_NAME" "$*" >&2
}

_soft_fail() {
  _warn "$*"
  exit 0
}

_read_event() {
  local event=""
  event="$(cat)"
  if [[ -z "$event" ]]; then
    exit 0
  fi
  jq -e '.' <<<"$event" >/dev/null 2>&1 || exit 0
  printf '%s' "$event"
}

_tool_command() {
  local event="$1"
  jq -r '
    if (.tool_input.command? // "") != "" then .tool_input.command
    elif (.tool_input | type) == "string" then .tool_input
    else empty end
  ' <<<"$event"
}

# gate prints its decision as a JSON object on stdout; read that specifically
# (not stderr, which may carry unrelated noise that would break the parse).
_tool_stdout() {
  local event="$1"
  jq -r '.tool_response.stdout // .tool_output // ""' <<<"$event"
}

# Match only `gate gate …` as the actual command — not `gate judge` / `gate
# grant` / `gate backtest`, and not the word embedded in a quoted arg.
_is_gate_gate_command() {
  local command="$1"
  [[ "$command" =~ ^[[:space:]]*gate[[:space:]]+gate([[:space:]]|$) ]]
}

_main() {
  local event tool_name command stdout
  local decision run outcome tier head_sha grant pr_field
  local owner_repo repo_short pr_num pr_body lookup project_slug task_id task_slug ref

  if ! command -v jq >/dev/null 2>&1; then
    _soft_fail "jq not found"
  fi

  event="$(_read_event)"
  tool_name="$(jq -r '.tool_name // ""' <<<"$event")"
  if [[ "$tool_name" != "Bash" ]]; then
    exit 0
  fi

  command="$(_tool_command "$event")"
  if [[ -z "$command" ]] || ! _is_gate_gate_command "$command"; then
    exit 0
  fi

  stdout="$(_tool_stdout "$event")"
  decision="$(jq -r '.decision // ""' <<<"$stdout" 2>/dev/null || true)"
  # Only a pass authorizes a merge. escalate/block/refuse are real gate
  # outcomes but not merge authorizations — recording those is a later concern
  # (tied to the `escalation` kind question), so skip them here.
  if [[ "$decision" != "pass" ]]; then
    exit 0
  fi

  run="$(jq -r '.run // ""' <<<"$stdout" 2>/dev/null || true)"
  outcome="$(jq -r '.outcome // ""' <<<"$stdout" 2>/dev/null || true)"
  tier="$(jq -r '.tier // ""' <<<"$stdout" 2>/dev/null || true)"
  head_sha="$(jq -r '.head_sha // ""' <<<"$stdout" 2>/dev/null || true)"
  grant="$(jq -r '.grant // ""' <<<"$stdout" 2>/dev/null || true)"
  pr_field="$(jq -r '.pr // ""' <<<"$stdout" 2>/dev/null || true)"

  if [[ -z "$run" || -z "$head_sha" || -z "$pr_field" ]]; then
    _soft_fail "gate pass output missing run/head_sha/pr"
  fi

  # pr_field is "owner/repo#N".
  owner_repo="${pr_field%#*}"
  pr_num="${pr_field##*#}"
  repo_short="${owner_repo##*/}"
  if [[ -z "$pr_num" || -z "$repo_short" || "$pr_num" == "$pr_field" ]]; then
    _soft_fail "could not parse gate pr field: $pr_field"
  fi

  if ! command -v gh >/dev/null 2>&1; then
    _soft_fail "gh not found"
  fi
  if ! pr_body="$(gh pr view "$pr_num" -R "$owner_repo" --json body -q '.body' 2>/dev/null)"; then
    _soft_fail "could not fetch PR body for #$pr_num"
  fi

  # Anchor the verdict to the same task the receipt will use, so the two join
  # via the shared task + meta.pr even if the FK id is absent. No task link →
  # skip (v1 records the governed, task-linked path; project-wide is a later
  # enhancement, and mirrors the receipt hook's task requirement).
  if ! lookup="$(pr_lookup_task "$pr_body" "$repo_short")"; then
    _warn "no task linkage for PR #$pr_num — verdict not recorded"
    exit 0
  fi
  IFS=$'\t' read -r project_slug task_id task_slug <<<"$lookup"

  ref="gate://$repo_short/pr/$pr_num/$run"
  local -a meta=( "source=gate" "outcome=$decision" "pr=$pr_num" "head_sha=$head_sha" )
  [[ -n "$grant" ]] && meta+=( "grant=$grant" )
  [[ -n "$tier" ]] && meta+=( "tier=$tier" )

  if ! dossier_artifact_link "$project_slug" "$task_id" "verdict" "$ref" \
      "gate pass PR #$pr_num" "hook:gate-verdict" "${meta[@]}"; then
    _soft_fail "verdict link failed for PR #$pr_num"
  fi

  printf 'Recorded gate verdict for PR #%s (%s, %s) → %s.\n' \
    "$pr_num" "$decision" "${tier:-?}" "$ref"
}

if [[ "${1:-}" == "--no-timeout" ]]; then
  shift
  _main "$@" || exit 0
  exit 0
fi

if command -v timeout >/dev/null 2>&1; then
  # Invoke via `bash "$0"`, not `"$0"` directly, so the timed leg does not
  # depend on the file's executable bit (a 100644 checkout would otherwise die
  # on "Permission denied" and record nothing). The file is also committed
  # 100755 for good measure.
  timeout 5 bash "$0" --no-timeout "$@" || exit 0
else
  _main "$@" || exit 0
fi
