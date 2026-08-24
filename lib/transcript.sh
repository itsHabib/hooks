#!/usr/bin/env bash

# Read the mechanical facts out of a Claude Code transcript.
#
# Everything here is observable without the model's cooperation: which dossier
# tasks a session touched, which pull requests it opened, which files it wrote.
# That is deliberate. A session's own account of what it did is the least
# reliable thing it produces at the moment it is least attentive — the exit —
# and asking for one is how `/claim` ended up with two records. These facts are
# already in the transcript whether anyone remembers to write them or not.
#
# Distillation — turning a transcript into prose about what was CONCLUDED — is a
# separate, fallible step and is not done here.

set -euo pipefail

# transcript_task_ids prints the dossier task ids a session addressed, one per
# line, in first-seen order.
#
# This is the resolution signal that needs no mapping table and no guessing: a
# session that called task_update or task_complete named the task in the call.
transcript_task_ids() {
  local path="$1"
  [[ -r "$path" ]] || return 0
  jq -r '
    (.message?.content? // [])
    | if type == "array" then .[] else empty end
    | select(type == "object" and .type == "tool_use")
    | select((.name // "") | startswith("mcp__dossier__task_"))
    | (.input?.id // empty)
  ' "$path" 2>/dev/null | awk 'NF && !seen[$0]++'
}

# transcript_pr_urls prints the pull-request URLs the session opened or acted
# on, one per line. The harness records these itself as `pr-link` entries; the
# tool-output scan catches the rest.
transcript_pr_urls() {
  local path="$1"
  [[ -r "$path" ]] || return 0
  {
    jq -r 'select(.type == "pr-link") | (.url // .prUrl // empty)' "$path" 2>/dev/null
    grep -Eo 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' "$path" 2>/dev/null
  } | awk 'NF && !seen[$0]++'
}

# transcript_files_written prints the paths the session created or edited.
transcript_files_written() {
  local path="$1"
  [[ -r "$path" ]] || return 0
  jq -r '
    (.message?.content? // [])
    | if type == "array" then .[] else empty end
    | select(type == "object" and .type == "tool_use")
    | select((.name // "") == "Write" or (.name // "") == "Edit" or (.name // "") == "NotebookEdit")
    | (.input?.file_path // .input?.notebook_path // empty)
  ' "$path" 2>/dev/null | awk 'NF && !seen[$0]++'
}

# transcript_turn_count prints how many assistant turns the session produced —
# the cheapest available proxy for "was this a real working session or a glance".
transcript_turn_count() {
  local path="$1"
  [[ -r "$path" ]] || { printf '0'; return 0; }
  jq -r 'select(.type == "assistant") | 1' "$path" 2>/dev/null | wc -l | tr -d ' '
}
