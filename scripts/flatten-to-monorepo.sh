#!/usr/bin/env bash
set -euo pipefail

if [[ "${CONFIRM_MONOREPO_FLATTEN:-}" != "1" ]]; then
  echo "Refusing to flatten nested git repositories without explicit confirmation."
  echo "Run with: CONFIRM_MONOREPO_FLATTEN=1 scripts/flatten-to-monorepo.sh"
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

mkdir -p monorepo-backups

if [[ -d IMApp/.git ]]; then
  git -C IMApp bundle create ../monorepo-backups/IMApp-pre-monorepo.bundle --all
  git -C IMApp diff > monorepo-backups/IMApp-working-tree.patch
  git -C IMApp status --short > monorepo-backups/IMApp-status.txt
  rm -rf monorepo-backups/IMApp.git
  mv IMApp/.git monorepo-backups/IMApp.git
fi

if [[ -d IMServer/.git ]]; then
  git -C IMServer bundle create ../monorepo-backups/IMServer-pre-monorepo.bundle --all
  git -C IMServer diff > monorepo-backups/IMServer-working-tree.patch
  git -C IMServer status --short > monorepo-backups/IMServer-status.txt
  rm -rf monorepo-backups/IMServer.git
  mv IMServer/.git monorepo-backups/IMServer.git
fi

if [[ ! -d .git ]]; then
  git init
fi

git add README.md .gitignore Makefile docs scripts IMApp IMClientKit IMServer

echo "Nested git metadata moved to monorepo-backups/*.git."
echo "Review with: git status --short"
echo "Commit with: git commit -m \"Create IM monorepo\""

