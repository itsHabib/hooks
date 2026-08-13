#!/usr/bin/env bash

# Normalize the small portion of Claude Code and Codex hook envelopes used by
# this repository. Hooks consume this contract instead of branching on the
# harness that emitted the event.

hook_event_tool_command() {
  local event="$1"
  jq -r '
    if (.tool_input.command? // "") != "" then .tool_input.command
    elif (.tool_input | type) == "string" then .tool_input
    else empty end
  ' <<<"$event"
}

hook_event_tool_output() {
  local event="$1"
  jq -r '
    if ((.tool_output? | type) == "string") and (.tool_output != "") then
      .tool_output
    elif (.tool_response | type) == "string" then
      .tool_response
    elif (.tool_response | type) == "object" then
      if ((.tool_response.output? | type) == "string") then
        .tool_response.output
      else
        [
          (.tool_response.stdout? | select(type == "string") // ""),
          (.tool_response.stderr? | select(type == "string") // "")
        ] | join("")
      end
    else
      ""
    end
  ' <<<"$event"
}

hook_event_tool_stdout() {
  local event="$1"
  jq -r '
    if ((.tool_output? | type) == "string") and (.tool_output != "") then
      .tool_output
    elif (.tool_response | type) == "string" then
      .tool_response
    elif (.tool_response | type) == "object" then
      if ((.tool_response.output? | type) == "string") then
        .tool_response.output
      else
        (.tool_response.stdout? | select(type == "string") // "")
      end
    else
      ""
    end
  ' <<<"$event"
}

hook_event_tool_exit_code() {
  local event="$1"
  jq -r '
    if (.tool_response | type) != "object" then 0
    elif (.tool_response.exitCode? // null) != null then .tool_response.exitCode
    elif (.tool_response.exit_code? // null) != null then .tool_response.exit_code
    else 0 end
  ' <<<"$event"
}

hook_event_tool_output_json() {
  local event="$1"
  jq -c '
    def decoded:
      if type == "string" then (try fromjson catch {}) else . end;
    (.tool_response // .tool_output // {}) as $raw
    | if ($raw | type) == "object" and ($raw.structuredContent? != null) then
        ($raw.structuredContent | decoded)
      elif ($raw | type) == "object" and ($raw.structured_content? != null) then
        ($raw.structured_content | decoded)
      elif ($raw | type) == "object" and ($raw.output? != null) then
        ($raw.output | decoded)
      elif ($raw | type) == "object" and (($raw.content? | type) == "array") then
        ([$raw.content[]? | select(.type == "text") | .text] | join("\n") | decoded)
      else
        ($raw | decoded)
      end
  ' <<<"$event"
}
