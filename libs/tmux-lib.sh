#!/usr/bin/env bash
# The only module that knows tmux command syntax. Everything else asks in terms
# of sessions, windows, panes and badges — nobody else writes `-t "${sess}:${win}"`
# or a `#{...}` format string.
#
# Two adapters back this interface: the real tmux binary in a live session, and
# tests/fixtures/tmux on PATH under test. Every function is silent and returns 0
# when tmux is absent, so a script that runs outside tmux degrades to a no-op.

# tmux_where_am_i <pane> — prints "<session>\t<window_id>" for a pane. One round
# trip; callers that need both used to make two.
tmux_where_am_i() {
  tmux display-message -t "$1" -p '#{session_name}	#{window_id}' 2>/dev/null
}

# tmux_here — "<session>\t<window_id>" for the pane THIS process runs in, which
# tmux names in $TMUX_PANE. Returns 1 when there is no such pane (not under
# tmux) or when tmux answers nothing (no server, dead session) — the one place
# that decides what "nowhere" means, so a caller branches on the status instead
# of re-inventing the check. Prints a trailing newline so `read` sees a complete
# line.
tmux_here() {
  [ -n "${TMUX_PANE:-}" ] || return 1
  local sess win
  IFS=$'\t' read -r sess win < <(tmux_where_am_i "$TMUX_PANE")
  [ -n "$sess" ] && [ -n "$win" ] || return 1
  printf '%s\t%s\n' "$sess" "$win"
}

# tmux_pane_path <pane> — cwd of a single pane.
tmux_pane_path() {
  tmux display-message -t "$1" -p '#{pane_current_path}' 2>/dev/null
}

# tmux_window_name <pane> — the tmux window title a pane lives in (e.g. the
# repo name ctdl names the window after). Empty, not an error, when tmux or
# the pane is gone — callers treat a blank name as "omit," never as failure.
tmux_window_name() {
  [ -n "${1:-}" ] || return 0
  tmux display-message -t "$1" -p '#{window_name}' 2>/dev/null
}

# tmux_session_panes <session> — prints "<window_id>\t<pane_current_path>", one
# line per pane. EVERY pane, not just each window's active one: a window hosts an
# agent if ANY of its panes sits in the agent's cwd, and in a ctdl layout the
# active pane is usually the terminal, not the agent.
tmux_session_panes() {
  tmux list-panes -s -t "$1" -F '#{window_id}	#{pane_current_path}' 2>/dev/null
}

# tmux_badge_set <session> <window_id> <badge> — write the @agent_badges window
# option that tmux.conf renders right after #W.
tmux_badge_set() {
  tmux set-window-option -t "${1}:${2}" @agent_badges "$3" 2>/dev/null
}

# tmux_window_option_get/set <pane> <name> [value] — window containing <pane>.
# Explicit, not tmux's ambient "current window": a detached run-shell binding
# has no current window of its own, so an implicit target drifts to whatever
# window a *different* client last touched. The layout tools' pane-role
# bookkeeping (@coding_agent_pane_id and friends) goes through here.
tmux_window_option_get() { tmux show-window-option -t "$1" -v "$2" 2>/dev/null; }
tmux_window_option_set() { tmux set-window-option -t "$1" "$2" "$3" 2>/dev/null; }

# tmux_respawn <target> <cwd> <cmd> — replace whatever is running in a pane.
tmux_respawn() { tmux respawn-pane -k -c "$2" -t "$1" "$3" 2>/dev/null; }

# tmux_rename_window <target> <name>
tmux_rename_window() { tmux rename-window -t "$1" "$2" 2>/dev/null; }

# tmux_split_window <target> <cwd> <direction: -h|-v> <pct> — creates a new
# pane in <target>'s window, split off <target>. Prints the new pane_id.
tmux_split_window() {
  tmux split-window "$3" -p "$4" -t "$1" -c "$2" -P -F '#{pane_id}' 2>/dev/null
}

# tmux_send_keys <target> <cmd> — type <cmd> into a pane followed by Enter.
tmux_send_keys() { tmux send-keys -t "$1" "$2" C-m 2>/dev/null; }

# tmux_select_pane <target>
tmux_select_pane() { tmux select-pane -t "$1" 2>/dev/null; }

# tmux_new_window <cwd> [session] — new window, in <session> if given, else the
# current session. Prints its pane_id.
tmux_new_window() {
  local cwd=$1 session=${2:-}
  if [ -n "$session" ]; then
    tmux new-window -c "$cwd" -t "${session}:" -P -F '#{pane_id}' 2>/dev/null
  else
    tmux new-window -c "$cwd" -P -F '#{pane_id}' 2>/dev/null
  fi
}

# tmux_rename_session <name>
tmux_rename_session() { tmux rename-session "$1" 2>/dev/null; }

# tmux_new_session <name> <cwd> — a fresh DETACHED session (server keeps
# running, no client attaches). Prints its first window's pane_id, same shape
# as tmux_new_window, so both feed layout_open_workspaces callers identically.
tmux_new_session() { tmux new-session -d -s "$1" -c "$2" -P -F '#{pane_id}' 2>/dev/null; }

# tmux_kill_window <target>
tmux_kill_window() { tmux kill-window -t "$1" 2>/dev/null; }
