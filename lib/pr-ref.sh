#!/usr/bin/env bash
# Parse GitHub pull-request URLs into owner/repo + PR number.

set -euo pipefail

# shellcheck disable=SC2317
_pr_ref_stub() {
  :
}

# Usage: parse_github_pr_ref <pr_url>
# On success prints: owner/repo<TAB>pr_number
parse_github_pr_ref() {
  local url="$1"
  local owner repo pr

  if [[ "$url" =~ ^https?://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)/?$ ]]; then
    owner="${BASH_REMATCH[1]}"
    repo="${BASH_REMATCH[2]}"
    pr="${BASH_REMATCH[3]}"
    printf '%s/%s\t%s\n' "$owner" "$repo" "$pr"
    return 0
  fi

  return 1
}
