#!/usr/bin/env bash

set -euo pipefail

ROOT=$(git -C "${BASH_SOURCE[0]%/*}/.." rev-parse --show-toplevel)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hooks-mode-hygiene.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

tree_modes="$TMP/tree-modes"
index_modes="$TMP/index-modes"
worktree_modes="$TMP/worktree-modes"
scratch_index="$TMP/index"

git -C "$ROOT" ls-tree -r HEAD \
  | sed -E $'s/^([0-9]{6}) [^ ]+ [0-9a-f]+\t/\\1\t/' \
  >"$tree_modes"
git -C "$ROOT" ls-files -s \
  | sed -E $'s/^([0-9]{6}) [0-9a-f]+ [0-9]+\t/\\1\t/' \
  >"$index_modes"

if ! diff -u "$tree_modes" "$index_modes"; then
  echo "tracked modes in the index differ from HEAD" >&2
  exit 1
fi

GIT_INDEX_FILE="$scratch_index" git -C "$ROOT" read-tree HEAD
GIT_INDEX_FILE="$scratch_index" git -C "$ROOT" add -u -- .
GIT_INDEX_FILE="$scratch_index" git -C "$ROOT" ls-files -s \
  | sed -E $'s/^([0-9]{6}) [0-9a-f]+ [0-9]+\t/\\1\t/' \
  >"$worktree_modes"

if ! diff -u "$tree_modes" "$worktree_modes"; then
  echo "tracked modes in the working tree differ from HEAD" >&2
  exit 1
fi
