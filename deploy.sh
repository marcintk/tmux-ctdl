#!/usr/bin/env bash
# rsync-only deploy — syncs repo to workspace, skips zshrc/tmux/claude integration steps.
# Use install.sh for first-time setup.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${TMUX_CTDL_HOME:-$HOME/.config/tmux/tmux-ctdl}"

mkdir -p "$TARGET"
rsync -av --delete --exclude='.git' --exclude='.coverage' \
  --exclude='tmux-ctdl.conf' "$REPO_DIR"/ "$TARGET"/

echo "deploy: synced to $TARGET"
