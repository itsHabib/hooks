#!/usr/bin/env bash

set -euo pipefail

ROOT=$(git -C "${BASH_SOURCE[0]%/*}/.." rev-parse --show-toplevel)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hooks-mode-hygiene.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

tree_modes="$TMP/tree-modes"
index_modes="$TMP/index-modes"
worktree_modes="$TMP/worktree-modes"
scratch_index="$TMP/index"

mode_mismatches() {
  local expected="$1"
  local actual="$2"

  awk '
    NR == FNR {
      expected[substr($0, 8)] = substr($0, 1, 6)
      next
    }

    {
      path = substr($0, 8)
      mode = substr($0, 1, 6)
    }

    path in expected && expected[path] != mode {
      print expected[path] " => " mode "\t" path
    }
  ' "$expected" "$actual"
}

git -C "$ROOT" ls-tree -r HEAD \
  | sed -E $'s/^([0-9]{6}) [^ ]+ [0-9a-f]+\t/\\1\t/' \
  >"$tree_modes"
git -C "$ROOT" ls-files -s \
  | sed -E $'s/^([0-9]{6}) [0-9a-f]+ [0-9]+\t/\\1\t/' \
  >"$index_modes"

mode_mismatches "$tree_modes" "$index_modes" >"$TMP/index-mismatches"
if [[ -s "$TMP/index-mismatches" ]]; then
  cat "$TMP/index-mismatches" >&2
  echo "tracked modes in the index differ from HEAD" >&2
  exit 1
fi

GIT_INDEX_FILE="$scratch_index" git -C "$ROOT" read-tree HEAD
GIT_INDEX_FILE="$scratch_index" git -C "$ROOT" add -u -- .
GIT_INDEX_FILE="$scratch_index" git -C "$ROOT" ls-files -s \
  | sed -E $'s/^([0-9]{6}) [0-9a-f]+ [0-9]+\t/\\1\t/' \
  >"$worktree_modes"

mode_mismatches "$tree_modes" "$worktree_modes" >"$TMP/worktree-mismatches"
if [[ -s "$TMP/worktree-mismatches" ]]; then
  cat "$TMP/worktree-mismatches" >&2
  echo "tracked modes in the working tree differ from HEAD" >&2
  exit 1
fi
