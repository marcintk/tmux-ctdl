#!/usr/bin/env bash
# ctdl installer — idempotent. Deploys this repo to ~/.config/tmux/tmux-ctdl
# and appends integration snippets to zshrc / tmux.conf / Claude settings.json.
# Safe to re-run: each step checks for its own marker before touching a file.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${TMUX_CTDL_HOME:-$HOME/.config/tmux/tmux-ctdl}"
ZSHRC="${ZSHRC:-$HOME/.config/zsh/.zshrc}"
TMUX_CONF="${TMUX_CONF:-$HOME/.config/tmux/tmux.conf}"
CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

MARK_START="# >>> ctdl >>>"
MARK_END="# <<< ctdl <<<"

log() { echo "ctdl-install: $*"; }

deploy_workspace() {
  mkdir -p "$(dirname "$TARGET")"
  ln -sfn "$REPO_DIR" "$TARGET"
  log "linked $TARGET -> $REPO_DIR"
}

append_marked() {
  local file=$1 snippet=$2
  [[ -f "$file" ]] || {
    log "skip $file (not found)"
    return 0
  }
  if grep -qF "$MARK_START" "$file" 2>/dev/null; then
    local current
    current=$(sed -n "/^${MARK_START}\$/,/^${MARK_END}\$/p" "$file")
    local fresh
    fresh=$(
      echo "$MARK_START"
      cat "$snippet"
      echo "$MARK_END"
    )
    if [[ "$current" == "$fresh" ]]; then
      log "$file ctdl block already up to date, skipping"
    else
      sed -i "/^${MARK_START}\$/,/^${MARK_END}\$/d" "$file"
      # sed -i on macOS/BSD leaves a stray blank line differently than GNU; trim trailing blanks either way
      printf '%s\n' "$fresh" >>"$file"
      log "refreshed stale ctdl block in $file"
    fi
    return 0
  fi
  {
    echo ""
    echo "$MARK_START"
    cat "$snippet"
    echo "$MARK_END"
  } >>"$file"
  log "appended ctdl block to $file"
}

merge_claude_settings() {
  [[ -f "$CLAUDE_SETTINGS" ]] || {
    log "skip $CLAUDE_SETTINGS (not found)"
    return 0
  }
  command -v jq >/dev/null || {
    log "jq not found, skipping $CLAUDE_SETTINGS merge — see integrations/claude-settings.json"
    return 0
  }
  if jq -e '.statusLine.command? // "" | contains("tmux-ctdl.sh")' "$CLAUDE_SETTINGS" >/dev/null 2>&1; then
    log "$CLAUDE_SETTINGS already wired, skipping"
    return 0
  fi
  local tmp
  tmp=$(mktemp)
  jq -s '.[0] * .[1]' "$CLAUDE_SETTINGS" "$REPO_DIR/integrations/claude-settings.json" >"$tmp"
  cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.bak"
  mv "$tmp" "$CLAUDE_SETTINGS"
  log "merged ctdl hooks into $CLAUDE_SETTINGS (backup: $CLAUDE_SETTINGS.bak)"
}

deploy_workspace
append_marked "$ZSHRC" "$REPO_DIR/integrations/zshrc.sh"
append_marked "$TMUX_CONF" "$REPO_DIR/integrations/tmux.conf"
merge_claude_settings

log "done. reload: source $ZSHRC ; tmux source-file $TMUX_CONF"
