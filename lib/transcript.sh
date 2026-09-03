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
# scan over tool calls and tool results catches the rest.
#
# Only tool traffic is scanned. A URL in a prompt, pasted document, or the
# model's prose proves nothing about what the session DID, and a fact recorded
# here is durable — so the scan is scoped to where an action would have left it.
transcript_pr_urls() {
  local path="$1"
  [[ -r "$path" ]] || return 0
  {
    jq -r 'select(.type == "pr-link") | (.url // .prUrl // empty)' "$path" 2>/dev/null
    jq -r '
      (.message?.content? // [])
      | if type == "array" then .[] else empty end
      | select(type == "object" and (.type == "tool_use" or .type == "tool_result"))
      | (.input? // .content? // empty) | tostring
    ' "$path" 2>/dev/null \
      | grep -Eo 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+'
  } | awk 'NF && !seen[$0]++'
}

# transcript_files_written prints the paths the session created or edited.
#
# A Write or Edit whose tool_result came back `is_error` left the filesystem
# untouched (stale old_string, denied permission), so its call is dropped by
# pairing each call's id against the errored result ids. A path both failed and
# later written still lists, because the filter is per call, not per path.
transcript_files_written() {
  local path="$1" failed
  [[ -r "$path" ]] || return 0
  failed="$(jq -r '
    (.message?.content? // [])
    | if type == "array" then .[] else empty end
    | select(type == "object" and .type == "tool_result" and .is_error == true)
    | (.tool_use_id // empty)
  ' "$path" 2>/dev/null)"
  jq -r '
    (.message?.content? // [])
    | if type == "array" then .[] else empty end
    | select(type == "object" and .type == "tool_use")
    | select((.name // "") == "Write" or (.name // "") == "Edit" or (.name // "") == "NotebookEdit")
    | "\(.id // "")\t\(.input?.file_path // .input?.notebook_path // "")"
  ' "$path" 2>/dev/null \
    | awk -F'\t' -v failed="$failed" '
        BEGIN { n = split(failed, ids, "\n"); for (i = 1; i <= n; i++) if (ids[i] != "") bad[ids[i]] = 1 }
        $2 != "" && !($1 != "" && ($1 in bad)) && !seen[$2]++ { print $2 }
      '
}

# transcript_turn_count prints how many assistant turns the session produced —
# the cheapest available proxy for "was this a real working session or a glance".
transcript_turn_count() {
  local path="$1"
  [[ -r "$path" ]] || { printf '0'; return 0; }
  jq -r 'select(.type == "assistant") | 1' "$path" 2>/dev/null | wc -l | tr -d ' '
}
