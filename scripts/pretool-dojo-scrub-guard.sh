#!/usr/bin/env bash

# PreToolUse guard for the shared ~/.claude/dojo/lessons directory. Denylist
# patterns stay local in ~/.claude/dojo/scrub-markers.txt and are never echoed
# back into the agent transcript.

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat) || exit 0

canonicalize_path() {
  local path=${1//\\//} segment last
  local -a parts normalized
  if [[ $path =~ ^([A-Za-z]):(/.*)$ ]]; then
    path="/${BASH_REMATCH[1],,}${BASH_REMATCH[2]}"
  fi
  IFS='/' read -r -a parts <<<"$path"
  for segment in "${parts[@]}"; do
    case "$segment" in
      '' | '.') ;;
      '..')
        if ((${#normalized[@]} > 0)); then
          last=$((${#normalized[@]} - 1))
          unset "normalized[$last]"
        fi
        ;;
      *) normalized+=("$segment") ;;
    esac
  done
  printf '/%s' "$(IFS=/; printf '%s' "${normalized[*]}")"
}

tool_name=$(jq -r '.tool_name // ""' <<<"$payload" 2>/dev/null) || exit 0
cwd=$(jq -r '.cwd // ""' <<<"$payload" 2>/dev/null) || exit 0
content=""
paths=()

if [[ $tool_name == "apply_patch" ]]; then
  content=$(jq -r '.tool_input.command // ""' <<<"$payload" 2>/dev/null) || exit 0
  while IFS= read -r line || [[ -n $line ]]; do
    case "$line" in
      '*** Add File: '* | '*** Update File: '* | '*** Delete File: '* | '*** Move to: '*)
        file_path=${line#*: }
        [[ $file_path == /* || $file_path =~ ^[A-Za-z]:[\\/] ]] || file_path="${cwd:-$PWD}/$file_path"
        paths+=("$file_path")
        ;;
    esac
  done <<<"$content"
else
  file_path=$(jq -r '.tool_input.file_path // ""' <<<"$payload" 2>/dev/null) || exit 0
  [[ -n $file_path ]] || exit 0
  [[ $file_path == /* || $file_path =~ ^[A-Za-z]:[\\/] ]] || file_path="${cwd:-$PWD}/$file_path"
  paths+=("$file_path")
  content=$(jq -r '[.tool_input.content, .tool_input.new_string] | map(select(type == "string")) | join("\n")' \
    <<<"$payload" 2>/dev/null) || exit 0
fi

canonical_lessons_root=$(canonicalize_path "$HOME/.claude/dojo/lessons")
lessons_root=${canonical_lessons_root,,}
relative_paths=""
for file_path in "${paths[@]}"; do
  canonical_path=$(canonicalize_path "$file_path")
  normalized_path=${canonical_path,,}
  if [[ $normalized_path == "$lessons_root" || $normalized_path == "$lessons_root/"* ]]; then
    relative_paths+="${canonical_path:${#canonical_lessons_root}}"$'\n'
  fi
done
[[ -n $relative_paths ]] || exit 0

markers_path="$HOME/.claude/dojo/scrub-markers.txt"
if [[ ! -r $markers_path ]]; then
  jq -nc --arg reason \
    "dojo scrub-guard: cannot read the local marker list; refusing writes to the shared lessons directory until it exists." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
  exit 0
fi

scan_text="$relative_paths$content"

while IFS= read -r line || [[ -n $line ]]; do
  line=${line%$'\r'}
  [[ -z $line || $line == \#* || $line != /*/* ]] && continue
  body=${line#/}
  pattern=${body%/*}
  flags=${line##*/}
  [[ -n $pattern && $flags =~ ^i?$ ]] || continue

  if [[ $flags == i ]]; then
    shopt -s nocasematch
  fi
  matched=1
  if ( [[ $scan_text =~ $pattern ]] ) 2>/dev/null; then
    matched=0
  fi
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
