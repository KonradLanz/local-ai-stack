#!/usr/bin/env bash
# pull-all.sh — Pull latest from all sibling repos in ~/git/
# Copyright 2026 GrEEV.com KG  |  AGPL-3.0-or-later
#
# Run from anywhere:
#   bash ~/git/local-ai-stack/pull-all.sh
#
# Or symlink for convenience:
#   ln -sf ~/git/local-ai-stack/pull-all.sh ~/bin/pull-all
set -euo pipefail

GIT_ROOT="${GIT_ROOT:-$HOME/git}"
FAILED=0
UPDATED=0
ALREADY=0

# Colour helpers (degrade gracefully if no tty)
_green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
_yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
_red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
_bold()   { printf '\033[1m%s\033[0m\n'   "$*"; }

echo ''
_bold "=== pull-all: $GIT_ROOT ==="
echo ''

for dir in "$GIT_ROOT"/*/; do
  [ -d "$dir/.git" ] || continue
  name=$(basename "$dir")
  printf '  %-30s ' "$name"

  # Fetch + pull, capture output
  out=$(git -C "$dir" pull --ff-only 2>&1) && rc=0 || rc=$?

  if [ $rc -ne 0 ]; then
    _red "FAIL"
    echo "    $out" | head -5
    FAILED=$((FAILED + 1))
  elif echo "$out" | grep -q 'Already up to date'; then
    _green "up to date"
    ALREADY=$((ALREADY + 1))
  else
    _yellow "updated"
    # Show changed files concisely
    echo "$out" | grep -E '^\s+(create|delete|rename| )' | head -8 || true
    UPDATED=$((UPDATED + 1))
  fi
done

echo ''
_bold "=== Summary: $UPDATED updated, $ALREADY already current, $FAILED failed ==="
echo ''

[ $FAILED -eq 0 ] || exit 1
