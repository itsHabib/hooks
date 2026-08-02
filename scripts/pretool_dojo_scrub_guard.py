# PreToolUse guard: blocks Write/Edit into ~/.claude/dojo/lessons/ when the
# content matches a sensitive-marker denylist. The lessons dir is shared by
# agents on every account, so entries there must stay generic; anything
# context-specific belongs in the originating repo's docs/dojo/ instead.
#
# The denylist itself is sensitive and therefore NOT in this file: it lives
# at ~/.claude/dojo/scrub-markers.txt (one /pattern/flags regex per line,
# # comments), local-only and never committed anywhere.

import json
import re
import sys
from pathlib import Path

MARKERS_PATH = Path.home() / ".claude" / "dojo" / "scrub-markers.txt"

FLAG_MAP = {"i": re.IGNORECASE, "m": re.MULTILINE, "s": re.DOTALL}


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, UnicodeDecodeError):
        # unparseable payload: never block unrelated writes
        return

    tool_input = payload.get("tool_input") or {}
    file_path = str(tool_input.get("file_path") or "")

    # only guard the shared home-dir lessons directory
    normalized = file_path.replace("\\", "/").lower()
    if ".claude/dojo/lessons/" not in normalized:
        return

    markers = load_markers()
    # a guarded dir with no readable denylist fails CLOSED, loudly
    if markers is None:
        deny(
            f"dojo scrub-guard: cannot read marker list at {MARKERS_PATH} - "
            "refusing writes to the shared lessons dir until it exists."
        )
        return

    parts = [tool_input.get("content"), tool_input.get("new_string"), file_path]
    content = "\n".join(p for p in parts if p)

    hit = next((m for m in markers if m.search(content)), None)
    if hit is None:
        return

    deny(
        f"dojo scrub-guard: content matches sensitive marker /{hit.pattern}/ - "
        "the shared home-dir scrolls must stay generic. Scrub the content, or "
        "write the repo-specific half to the repo's docs/dojo/ instead."
    )


def load_markers() -> list[re.Pattern] | None:
    """Parses the denylist file into compiled regexes, or None when unreadable."""
    try:
        raw = MARKERS_PATH.read_text(encoding="utf-8")
    except OSError:
        return None

    markers = []
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        # expected shape: /pattern/flags
        m = re.fullmatch(r"/(.+)/([a-z]*)", line)
        if m is None:
            continue
        flags = 0
        for ch in m.group(2):
            flags |= FLAG_MAP.get(ch, 0)
        try:
            markers.append(re.compile(m.group(1), flags))
        except re.error:
            # a malformed pattern skips, it must not disable the rest of the list
            continue
    return markers


def deny(reason: str) -> None:
    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            }
        },
        sys.stdout,
    )
    sys.stdout.write("\n")


main()
