#!/usr/bin/env bash

# PreToolUse guard for the shared ~/.claude/dojo/lessons directory. Denylist
# patterns stay local in ~/.claude/dojo/scrub-markers.txt and are never echoed
# back into the agent transcript.

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat) || exit 0
file_path=$(jq -er '.tool_input.file_path // ""' <<<"$payload" 2>/dev/null) || exit 0

normalize_path() {
  local path=${1//\\//}
  if [[ $path =~ ^([A-Za-z]):(/.*)$ ]]; then
    path="/${BASH_REMATCH[1],,}${BASH_REMATCH[2]}"
  fi
  printf '%s' "${path,,}"
}

normalized_path=$(normalize_path "$file_path")
lessons_root=$(normalize_path "$HOME/.claude/dojo/lessons/")
[[ $normalized_path == "$lessons_root"* ]] || exit 0

markers_path="$HOME/.claude/dojo/scrub-markers.txt"
if [[ ! -r $markers_path ]]; then
  jq -nc --arg reason \
    "dojo scrub-guard: cannot read the local marker list; refusing writes to the shared lessons directory until it exists." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
  exit 0
fi

content=$(jq -r '[.tool_input.content, .tool_input.new_string] | map(select(type == "string")) | join("\n")' \
  <<<"$payload" 2>/dev/null) || exit 0

while IFS= read -r line || [[ -n $line ]]; do
  [[ -z $line || $line == \#* || $line != /*/* ]] && continue
  body=${line#/}
  pattern=${body%/*}
  flags=${line##*/}
  [[ $flags =~ ^i?$ ]] || continue

  if [[ $flags == i ]]; then
    shopt -s nocasematch
  fi
  [[ $content =~ $pattern ]]
  matched=$?
  shopt -u nocasematch
  if [[ $matched -ne 0 ]]; then
    continue
  fi

  jq -nc --arg reason \
    "dojo scrub-guard: content matches a sensitive local marker. Scrub it, or keep the repo-specific lesson in that repository's docs/dojo/ directory." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
  exit 0
done <"$markers_path"

exit 0
