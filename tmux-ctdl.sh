#!/usr/bin/env bash
# ctdl — Coding Tmux Dev Layout. The one external entry point into the
# workspace runtime — every hook/keybind/status-format below calls THIS file,
# never a subdirectory path directly.
#
# Sourced from a shell rc:
#   source ~/.config/tmux/workspace/tmux-ctdl.sh
# defines two functions:
#   ctdl   — build the 3-pane layout (agent / change-tracker / terminal)
#   ctdlm  — one ctdl window per git workspace under the current dir
#
# Executed directly, by tmux.conf / claude/.claude/settings.json — dispatch on
# a verb:
#   tmux-ctdl.sh tracker-editor-toggle <pane_id>  tmux Space      — tracker <-> editor
#   tmux-ctdl.sh agent-respawn <pane_id>          tmux prefix-C   — restart agent pane
#   tmux-ctdl.sh wintab-tick <session>            status-format[0]— poll wintab badges
#   tmux-ctdl.sh agentbar <sess> <win>        status-format[1]   — render outer bar
#   tmux-ctdl.sh wintab-badge <RUNNING|CLEAR|DONE|PERMISSION>
#                                        Claude Code hooks  — set window badge
#   tmux-ctdl.sh agent-push-usage             Claude statusLine  — write usage state
#                                        (agent pushes a JSON payload on stdin)
#   tmux-ctdl.sh agent-footer                 Claude Stop hook   — end-of-turn usage
#                                        line (stdin JSON, answers on stdout)
#   tmux-ctdl.sh agent-pull-usage             wintab-tick        — write usage state
#                                        (agent has no hook; adapter-lib polls
#                                        <agent>_collect, rate-limited by
#                                        USAGE_REFRESH)
#
# badge/push/pull act on CODING_AGENT (tmux-ctdl.conf) — they don't take an
# agent argument. Whichever tool's hooks are configured is assumed to be the
# active one; there's no support yet for two agents' hooks feeding this at once.

_ctdl_boot() {
  . "${TMUX_CTDL_HOME:-$HOME/.config/tmux/workspace}/tmux-ctdl-boot.sh"
  tmux_ctdl_boot "$@"
}

# Coding Tmux Dev Layout — the ctdl pane layout in the current window
ctdl() {
  [[ -z $TMUX ]] && { echo "You must be inside tmux to use ctdl."; return 1; }

  _ctdl_boot layout agent
  layout_build "$TMUX_PANE" "$PWD" "$AGENT_CMD" "$CHANGE_TRACKER_CMD"
}

# Coding Tmux Dev Layout Multi — one ctdl window per git workspace under the current
# dir. Works inside and outside tmux, handles symlinks.
ctdlm() {
  # Outside tmux: start tmux and immediately run ctdlm inside it. The only raw
  # tmux call left in this file — there is no session to talk to yet.
  if [[ -z $TMUX ]]; then
    tmux new-session "zsh -ic ctdlm"
    return 0
  fi

  _ctdl_boot layout

  local base_dir
  if find "$PWD" -maxdepth 2 -name ".git" -type d -print -quit 2>/dev/null | grep -q .; then
    base_dir="$PWD"
  else
    cd ~/Development || { echo "Cannot cd to ~/Development"; return 1; }
    base_dir="$PWD"
  fi

  layout_open_workspaces "$base_dir" "$TMUX_PANE" ctdl
}

# ── Verb dispatch (executed, not sourced) ────────────────────────────────────
# Each arm is boot + one lib verb — the lib owns the behaviour, this owns
# nothing but routing. See tmux-ctdl-boot.sh for lib names.
_ctdl_main() {
  local verb=$1; shift

  case "$verb" in
    tracker-editor-toggle)
      _ctdl_boot layout
      layout_toggle "$1" "$EDITOR_CMD" "$CHANGE_TRACKER_CMD"
      ;;

    agent-respawn)
      _ctdl_boot layout agent
      layout_respawn_agent "$1" "$AGENT_CMD" "$1"
      ;;

    wintab-tick)
      _ctdl_boot wintab adapter agent state
      wintab_status_tick "$CODING_AGENT" "$1"
      ;;

    wintab-badge)
      # Claude Code hooks always pipe a JSON payload this verb never reads —
      # drain it so the caller doesn't block on an unread pipe.
      cat > /dev/null
      _ctdl_boot wintab
      wintab_hook "$CODING_AGENT" "$1"
      ;;

    agentbar)
      _ctdl_boot agentbar adapter agent
      agentbar_render "$CODING_AGENT" "${1:-_}" "${2:-0}" "$(date +%s)" || return 0
      ;;

    agent-push-usage) _ctdl_boot adapter agent; adapter_push_usage "$CODING_AGENT" ;;

    agent-footer) _ctdl_boot adapter agent; adapter_footer "$CODING_AGENT" ;;

    agent-pull-usage) _ctdl_boot adapter agent; adapter_pull_usage "$CODING_AGENT" "$(date +%s)" ;;

    *)
      echo "ctdl: unknown verb '$verb'" >&2
      return 1
      ;;
  esac
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] && _ctdl_main "$@"
