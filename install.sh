#!/usr/bin/env bash
# ctdl installer — idempotent. Deploys this repo to ~/.config/tmux/workspace
# and appends integration snippets to zshrc / tmux.conf / Claude settings.json.
# Safe to re-run: each step checks for its own marker before touching a file.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${WORKSPACE_HOME:-$HOME/.config/tmux/workspace}"
ZSHRC="${ZSHRC:-$HOME/.config/zsh/.zshrc}"
TMUX_CONF="${TMUX_CONF:-$HOME/.config/tmux/tmux.conf}"
CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

MARK_START="# >>> ctdl >>>"
MARK_END="# <<< ctdl <<<"

log() { echo "ctdl-install: $*"; }

deploy_workspace() {
  mkdir -p "$TARGET"
  rsync -a --delete --exclude='.git' --exclude='.coverage' \
    --exclude='workspace.conf' "$REPO_DIR"/ "$TARGET"/
  if [[ ! -f "$TARGET/workspace.conf" ]]; then
    cp "$REPO_DIR/workspace.conf.example" "$TARGET/workspace.conf"
    log "wrote $TARGET/workspace.conf from example — edit CODING_AGENT if needed"
  fi
  log "deployed to $TARGET"
}

append_marked() {
  local file=$1 snippet=$2
  [[ -f "$file" ]] || { log "skip $file (not found)"; return 0; }
  if grep -qF "$MARK_START" "$file" 2>/dev/null; then
    log "$file already has ctdl block, skipping"
    return 0
  fi
  {
    echo ""
    echo "$MARK_START"
    cat "$snippet"
    echo "$MARK_END"
  } >> "$file"
  log "appended ctdl block to $file"
}

merge_claude_settings() {
  [[ -f "$CLAUDE_SETTINGS" ]] || { log "skip $CLAUDE_SETTINGS (not found)"; return 0; }
  command -v jq >/dev/null || { log "jq not found, skipping $CLAUDE_SETTINGS merge — see integrations/claude-settings.json"; return 0; }
  if jq -e '.statusLine.command? // "" | contains("tmux-ctdl.sh")' "$CLAUDE_SETTINGS" >/dev/null 2>&1; then
    log "$CLAUDE_SETTINGS already wired, skipping"
    return 0
  fi
  local tmp
  tmp=$(mktemp)
  jq -s '.[0] * .[1]' "$CLAUDE_SETTINGS" "$REPO_DIR/integrations/claude-settings.json" > "$tmp"
  cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.bak"
  mv "$tmp" "$CLAUDE_SETTINGS"
  log "merged ctdl hooks into $CLAUDE_SETTINGS (backup: $CLAUDE_SETTINGS.bak)"
}

deploy_workspace
append_marked "$ZSHRC" "$REPO_DIR/integrations/zshrc.sh"
append_marked "$TMUX_CONF" "$REPO_DIR/integrations/tmux.conf"
merge_claude_settings

log "done. reload: source $ZSHRC ; tmux source-file $TMUX_CONF"
