#!/usr/bin/env bash

# PostToolUse reminder for edits to CLAUDE.md / AGENTS.md. It catches missing
# counterparts, forwarding-only Codex shims, and drift in shared managed blocks.
# It never blocks; stdout is short corrective context for the agent.

command -v jq >/dev/null 2>&1 || exit 0
payload=$(cat) || exit 0

tool_name=$(jq -r '.tool_name // ""' <<<"$payload" 2>/dev/null) || exit 0
cwd=$(jq -r '.cwd // ""' <<<"$payload" 2>/dev/null) || exit 0
[ -n "$cwd" ] || cwd=$PWD

paths=()
if [[ $tool_name == apply_patch ]]; then
  patch=$(jq -r '.tool_input.command // ""' <<<"$payload" 2>/dev/null) || exit 0
  while IFS= read -r line || [[ -n $line ]]; do
    case "$line" in
      '*** Add File: '* | '*** Update File: '* | '*** Delete File: '* | '*** Move to: '*)
        paths+=("${line#*: }")
        ;;
    esac
  done <<<"$patch"
else
  file_path=$(jq -r '.tool_input.file_path // ""' <<<"$payload" 2>/dev/null) || exit 0
  [ -n "$file_path" ] && paths+=("$file_path")
fi

[ "${#paths[@]}" -gt 0 ] || exit 0

guide_rows=""
for path in "${paths[@]}"; do
  path=${path//\\//}
  [[ $path == /* ]] || path="$cwd/$path"
  parent=${path%/*}
  base=${path##*/}
  [[ $base == CLAUDE.md || $base == AGENTS.md ]] || continue
  if [ -d "$parent" ]; then
    parent=$(cd "$parent" && pwd -P) || continue
  fi
  guide_rows+="$parent"$'\t'"$base"$'\n'
done
[ -n "$guide_rows" ] || exit 0

extract_block() {
  local marker="$1" file="$2"
  awk -v marker="$marker" '
    index($0, "<!-- BEGIN " marker) { capture = 1 }
    capture { print }
    index($0, "<!-- END " marker) { found = 1; exit }
    END { if (!found) exit 1 }
  ' "$file"
}

while IFS= read -r parent; do
  [ -n "$parent" ] || continue
  claude="$parent/CLAUDE.md"
  agents="$parent/AGENTS.md"
  label=${parent#"$cwd"/}
  [ "$label" = "$parent" ] && label=$parent
  [ -n "$label" ] || label=.

  touched_claude=0
  touched_agents=0
  grep -Fqx "$parent"$'\tCLAUDE.md' <<<"$guide_rows" && touched_claude=1
  grep -Fqx "$parent"$'\tAGENTS.md' <<<"$guide_rows" && touched_agents=1

  if [ ! -f "$claude" ] || [ ! -f "$agents" ]; then
    missing=CLAUDE.md
    [ -f "$claude" ] && missing=AGENTS.md
    printf 'agent-guide parity: %s is missing %s; keep Claude and Codex entrypoints paired.\n' "$label" "$missing"
    continue
  fi

  if [ "$(wc -l <"$agents" | tr -d ' ')" -le 8 ] && grep -q 'CLAUDE\.md' "$agents"; then
    printf 'agent-guide parity: %s/AGENTS.md is only a CLAUDE.md forwarding shim; give Codex scoped guidance.\n' "$label"
    continue
  fi

  structural_issue=0
  for marker in dev-workbench eng-philo; do
    claude_has=0
    agents_has=0
    claude_block=""
    agents_block=""
    if claude_block=$(extract_block "$marker" "$claude"); then claude_has=1; fi
    if agents_block=$(extract_block "$marker" "$agents"); then agents_has=1; fi
    if [ "$claude_has" -ne "$agents_has" ]; then
      printf 'agent-guide parity: %s %s block exists in only one entrypoint.\n' "$label" "$marker"
      structural_issue=1
    elif [ "$claude_has" -eq 1 ] && [ "$claude_block" != "$agents_block" ]; then
      printf 'agent-guide parity: %s %s block differs between CLAUDE.md and AGENTS.md.\n' "$label" "$marker"
      structural_issue=1
    fi
  done

  if [ "$structural_issue" -eq 0 ] && { [ "$touched_claude" -eq 0 ] || [ "$touched_agents" -eq 0 ]; }; then
    changed=AGENTS.md
    [ "$touched_claude" -eq 1 ] && changed=CLAUDE.md
    printf 'agent-guide parity: %s/%s changed alone; review its sibling for the corresponding agent-neutral update.\n' "$label" "$changed"
  fi
done < <(cut -f1 <<<"$guide_rows" | sort -u)

exit 0
