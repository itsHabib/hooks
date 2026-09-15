# Text references are deliberately weaker than installed/enabled/live claims.
def entries:
  if type != "object" then error("settings must be an object") else . end
  | (.hooks // {})
  | if type != "object" then error("hooks must be an object") else . end
  | to_entries[]
  | .key as $event
  | .value
  | if type != "array" then error("event entries must be arrays") else . end
  | .[]
  | (.matcher // "*") as $matcher
  | .hooks
  | if type != "array" then error("entry hooks must be arrays") else . end
  | .[]
  | select(.type == "command")
  | if (.command | type) != "string" then error("command must be a string") else . end
  | {event: $event, matcher: $matcher, command: .command};
def mentions($name):
  # Tokenize for inventory only. Quoted prose can still mention a script.
  .command | split("/") | join(" ") | split("\\") | join(" ")
  | gsub("[\"';&|()]"; " ") | [scan("[^[:space:]]+")] | index($name) != null;
. as $config
| [entries] as $entries
| ([$harness, "config-read", "command-entries", ($entries | length),
    "disableAllHooks", ($config.disableAllHooks // false)] | @tsv),
  ($names[] as $name
    | [$entries[] | select(mentions($name)) | "\(.event):\(.matcher)"] as $refs
    | [$harness, $name, (if ($refs | length) == 0 then "not-referenced" else "referenced" end),
       ($refs | unique | join(", "))] | @tsv),
  ([$entries[] | select(.command | test("fleet(\\.exe)?[[:space:]]+hook[[:space:]]"))] | length) as $fleet
    | [$harness, "external:fleet-hook", $fleet] | @tsv
