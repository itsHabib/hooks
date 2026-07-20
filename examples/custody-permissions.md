# custody — settings.json permission staging

The pattern: **deny the raw thing, allow the brokered thing.** Same shape as
gate (gate's read verbs are allowlisted while `pers/gate/state` and bare
merges are guarded). An allow rule is safe in proportion to the gates behind
it — vendor calls become allowlistable *because* they go through the proxy.

Rules land in two stages, matching the custody rollout
(workbench `docs/features/custody/spec.md` §9).

## Stage 1 — with custody v0 (first key wired)

```jsonc
{
  "permissions": {
    "allow": [
      // the brokered path: reach is bounded by the grant, not the rule
      "Bash(curl http://127.0.0.1:8127/*)",
      "PowerShell(curl http://127.0.0.1:8127/*)",
      // custody read verbs (mint/secret verbs are guard-blocked, not allowlisted)
      "Bash(custody log:*)",
      "Bash(custody explain:*)"
    ],
    "deny": [
      // the mint key and state dir, for the Read tool (the shell path is
      // covered by pretool-guard.sh, which holds in every permission mode)
      "Read(//<home>/.custody/**)"
    ]
  }
}
```

Dual-shell rule: every Bash allow gets a PowerShell twin, or a wildcard in one
shell silently undoes curation in the other.

## Stage 2 — at custody-drain (plaintext keys file deleted)

```jsonc
{
  "permissions": {
    "deny": [
      // the raw secret source; by drain the file is gone, this catches stragglers
      "Read(//<path-to-plaintext-keys-file>)"
    ]
  },
  "env": {
    // flips the pretool-guard keys-file rule on (shell-side reads)
    "GUARD_KEYS_DENY": "1"
  }
}
```

The deny is deliberately NOT enabled at stage 1: skills still legitimately
read the plaintext file until drain, and a deny that breaks daily work trains
bypass habits — fail closed, but make closed cheap.

## MCP servers

An MCP server repointed at the proxy (base URL `http://127.0.0.1:8127/<key>`,
auth header = the grant token) can have its tools allowlisted the same way —
the server's reach is whatever the grant allows, so the per-tool allow rule is
no longer load-bearing.
