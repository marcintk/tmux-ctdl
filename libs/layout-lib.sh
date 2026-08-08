#!/usr/bin/env bash
# The ctdl pane layout: agent / change-tracker / terminal, wired to tmux
# window options so later commands (toggle, respawn) can find their panes
# again. Pane-role option names (@coding_agent_pane_id,
# @change_tracker_pane_id, @change_tracker_state) live HERE and nowhere
# else — callers use the verbs below, never the option names directly.
# Every tmux call goes through tmux-lib.sh.
#
# Config-agnostic: callers (tmux-ctdl.sh's toggle/respawn verbs, tmux.conf's bind C)
# source tmux-ctdl.conf + the agent module themselves and pass the resulting
# commands in as arguments.

. "${TMUX_CTDL_HOME:-$HOME/.config/tmux/tmux-ctdl}/libs/boot-lib.sh"
tmux_ctdl_boot tmux

# ── Role accessors ───────────────────────────────────────────────────────
# All take the calling pane as their first argument, so options resolve
# against that pane's window explicitly rather than tmux's ambient "current
# window" (see tmux_window_option_get/set).

layout_agent_pane() { tmux_window_option_get "$1" "@coding_agent_pane_id"; }
layout_tracker_pane() { tmux_window_option_get "$1" "@change_tracker_pane_id"; }
layout_tracker_state_get() { tmux_window_option_get "$1" "@change_tracker_state"; }
layout_tracker_state_set() { tmux_window_option_set "$1" "@change_tracker_state" "$2"; }

# ── Verbs ─────────────────────────────────────────────────────────────────

# layout_build <agent_pane> <cwd> <agent_cmd> <tracker_cmd> — lay out the
# 3-pane ctdl structure in <agent_pane>'s window, launch the agent and
# tracker, and record pane roles for layout_toggle/layout_respawn_agent.
# Leaves the agent pane selected.
layout_build() {
  local agent_pane=$1 cwd=$2 agent_cmd=$3 tracker_cmd=$4
  local tracker_pane terminal_pane

  tmux_rename_window "$agent_pane" "$(basename "$cwd")"

  tracker_pane=$(tmux_split_window "$agent_pane" "$cwd" -h 55)
  terminal_pane=$(tmux_split_window "$tracker_pane" "$cwd" -v 25)

  tmux_send_keys "$agent_pane" "$agent_cmd"
  tmux_send_keys "$tracker_pane" "$tracker_cmd"
  tmux_send_keys "$terminal_pane" "clear"

  tmux_window_option_set "$agent_pane" "@coding_agent_pane_id" "$agent_pane"
  tmux_window_option_set "$agent_pane" "@change_tracker_pane_id" "$tracker_pane"
  layout_tracker_state_set "$agent_pane" "$tracker_cmd"

  tmux_select_pane "$agent_pane"
}

# layout_toggle <calling_pane> <editor_cmd> <tracker_cmd> — flip the
# change-tracker pane between the tracker and the editor. <calling_pane>
# identifies which window's role options to read: a run-shell binding has no
# window of its own, so this must be passed explicitly rather than resolved
# via tmux's ambient "current window" — otherwise the lookup can drift to
# whatever window a different client last touched and respawn a pane the
# user isn't even looking at. No-ops when that window has no recorded
# tracker pane (no ctdl layout built here) — an empty target handed to
# tmux_respawn would otherwise fall back to tmux's own default, the CURRENT
# active pane, silently respawning whatever the user is looking at instead of
# doing nothing.
layout_toggle() {
  local calling_pane=$1 editor_cmd=$2 tracker_cmd=$3
  local target state cwd
  target=$(layout_tracker_pane "$calling_pane")
  [ -z "$target" ] && return 0
  state=$(layout_tracker_state_get "$calling_pane")
  cwd=$(tmux_pane_path "$target")

  if [ "$state" = "$tracker_cmd" ] || [ -z "$state" ]; then
    tmux_respawn "$target" "$cwd" "$editor_cmd ."
    layout_tracker_state_set "$calling_pane" "$editor_cmd"
  else
    tmux_respawn "$target" "$cwd" "$tracker_cmd"
    layout_tracker_state_set "$calling_pane" "$tracker_cmd"
  fi
}

# layout_respawn_agent <calling_pane> <agent_cmd> <fallback_pane> — kill
# whatever is in the agent pane and start a clean new agent session there.
# Falls back to <fallback_pane> when no role has been recorded yet (fresh
# window, no ctdl layout built).
layout_respawn_agent() {
  local calling_pane=$1 agent_cmd=$2 fallback_pane=$3 target cwd
  target=$(layout_agent_pane "$calling_pane")
  target=${target:-$fallback_pane}
  cwd=$(tmux_pane_path "$target")
  tmux_respawn "$target" "$cwd" "$agent_cmd"
}

# layout_workspace_dirs <base> — the git workspaces directly under <base>, one
# per line. No tmux: a directory listing and a test for .git, so it is
# assertable against a scratch tree.
layout_workspace_dirs() {
  local d
  for d in "$1"/*; do
    [ -d "$d/.git" ] && printf '%s\n' "$d"
  done
  return 0
}

# layout_open_workspaces <base> <installer_pane> <cmd> — one window per git
# workspace under <base>, each running <cmd>, then close the window <cmd> was
# launched from so no dead space is left. Names the session after <base>.
layout_open_workspaces() {
  local base=$1 installer=$2 cmd=$3 dir pane
  tmux_rename_session "$(basename "$base" | tr '.:' '--')"
  # One physical line (loop body included): kcov's bash line tracer doesn't
  # credit a bare `done < <(...)` on its own line even though it runs.
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    pane=$(tmux_new_window "$dir")
    tmux_send_keys "$pane" "$cmd"
  done < <(layout_workspace_dirs "$base")
  tmux_kill_window "$installer"
}

# layout_open_workspaces_new_session <base> <cmd> — same as
# layout_open_workspaces, but for a SECOND (or third, ...) base dir passed to
# ctdlm: rather than take over the calling session, it opens a brand-new
# detached one (named after <base>, same as layout_open_workspaces names the
# current one) and populates it. Lets one ctdlm call fan out across multiple
# workspace roots, one tmux session per root.
layout_open_workspaces_new_session() {
  local base=$1 cmd=$2 name installer dir pane
  name="$(basename "$base" | tr '.:' '--')"
  installer=$(tmux_new_session "$name" "$base")
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    pane=$(tmux_new_window "$dir" "$name")
    tmux_send_keys "$pane" "$cmd"
  done < <(layout_workspace_dirs "$base")
  tmux_kill_window "$installer"
}
