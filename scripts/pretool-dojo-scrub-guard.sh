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

canonical_lessons_root=$(canonicalize_path "$HOME/.claude/dojo/lessons")
lessons_root=${canonical_lessons_root,,}
tool_name=$(jq -r '.tool_name // ""' <<<"$payload" 2>/dev/null) || exit 0
cwd=$(jq -r '.cwd // ""' <<<"$payload" 2>/dev/null) || exit 0
content=""
paths=()

resolve_path() {
  local path="$1"
  [[ $path == /* || $path =~ ^[A-Za-z]:[\\/] ]] || path="${cwd:-$PWD}/$path"
  canonicalize_path "$path"
}

is_lessons_path() {
  local normalized_path=${1,,}
  [[ $normalized_path == "$lessons_root" || $normalized_path == "$lessons_root/"* ]]
}

if [[ $tool_name == "apply_patch" ]]; then
  patch=$(jq -r '.tool_input.command // ""' <<<"$payload" 2>/dev/null) || exit 0
  current_path=""
  current_kind=""
  move_source=""
  move_removed=""
  move_added=""
  unreadable_move=""

  flush_path() {
    if [[ -n $current_path && $current_kind != delete ]] && is_lessons_path "$current_path"; then
      paths+=("$current_path")
      if [[ $current_kind == move ]]; then
        if [[ -r $move_source ]]; then
          content+="$(awk '
            NR == FNR { if (FNR > 1) removed[$0]++; next }
            removed[$0] > 0 { removed[$0]--; next }
            { print }
          ' <(printf '__dojo_removed_lines__\n%s' "$move_removed") "$move_source")"$'\n'
          content+="$move_added"
        else
          unreadable_move=$move_source
        fi
      fi
    fi
    move_source=""
    move_removed=""
    move_added=""
  }

  while IFS= read -r line || [[ -n $line ]]; do
    case "$line" in
      '*** Add File: '* | '*** Update File: '*)
        flush_path
        current_path=$(resolve_path "${line#*: }")
        current_kind=${line#'*** '}
        current_kind=${current_kind%% File:*}
        current_kind=${current_kind,,}
        ;;
      '*** Delete File: '*)
        flush_path
        current_path=$(resolve_path "${line#*: }")
        current_kind=delete
        ;;
      '*** Move to: '*)
        move_source=$current_path
        current_path=$(resolve_path "${line#*: }")
        current_kind=move
        ;;
      +*)
        if [[ -n $current_path && $current_kind != delete ]] && is_lessons_path "$current_path"; then
          if [[ $current_kind == move ]]; then
            move_added+="${line#+}"$'\n'
          else
            content+="${line#+}"$'\n'
          fi
        fi
        ;;
      -*)
        if [[ -n $current_path && $current_kind == move ]] && is_lessons_path "$current_path"; then
          move_removed+="${line#-}"$'\n'
        fi
        ;;
    esac
  done <<<"$patch"
  flush_path
else
  file_path=$(jq -r '.tool_input.file_path // ""' <<<"$payload" 2>/dev/null) || exit 0
  [[ -n $file_path ]] || exit 0
  canonical_path=$(resolve_path "$file_path")
  is_lessons_path "$canonical_path" || exit 0
  paths+=("$canonical_path")
  content=$(jq -r '[.tool_input.content, .tool_input.new_string] | map(select(type == "string")) | join("\n")' \
    <<<"$payload" 2>/dev/null) || exit 0
fi

relative_paths=""
for canonical_path in "${paths[@]}"; do
  relative_paths+="${canonical_path:${#canonical_lessons_root}}"$'\n'
done
[[ -n $relative_paths ]] || exit 0

if [[ -n $unreadable_move ]]; then
  jq -nc --arg reason \
    "dojo scrub-guard: cannot read the source file being moved into shared lessons; refusing the move." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
  exit 0
fi

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
