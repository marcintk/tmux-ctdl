#!/usr/bin/env bash
# The one way into the workspace runtime. Load order — conf, then libs, then the
# active agent module — lives HERE and nowhere else. Entry points AND libs name
# libs, not paths:
#
#   . "${TMUX_CTDL_HOME:-$HOME/.config/tmux/tmux-ctdl}/libs/boot-lib.sh"
#   tmux_ctdl_boot layout agent
#
# Lib names: tmux · state · layout · adapter · wintab · agentbar. `agent`
# sources CODING_AGENT_MODULE if the conf set one, else
# $TMUX_CTDL_HOME/adapter/adapter-<CODING_AGENT>.sh — the same formula
# `agent:<id>` below always uses; `agent:<id>` sources that
# specific agent's module by id instead — e.g. `tmux_ctdl_boot adapter
# agent:claude` in a push entry point, so a Claude hook still writes
# Claude state while agentbar displays Copilot. A lib that needs another lib
# calls tmux_ctdl_boot
# itself (e.g. `tmux_ctdl_boot state tmux` at the top of wintab-lib.sh)
# instead of sourcing a relative path — tmux_ctdl_boot is idempotent (tracked
# in _WB_LOADED), so that costs nothing when the caller already loaded it.
# The conf load is under the same guard: it is read once per process, not once
# per tmux_ctdl_boot call.
#
# TMUX_CTDL_HOME is where the libs live (the stowed copy by default);
# TMUX_CTDL_CONF is the conf to read. Tests point TMUX_CTDL_HOME at the repo and
# TMUX_CTDL_CONF at a scratch file, so a test run drives the real code with a
# throwaway palette.

: "${TMUX_CTDL_HOME:=$HOME/.config/tmux/tmux-ctdl}"
: "${TMUX_CTDL_CONF:=$TMUX_CTDL_HOME/tmux-ctdl.conf}"

declare -gA _WB_LOADED

tmux_ctdl_boot() {
  if [ -z "${_WB_LOADED[conf]:-}" ]; then
    . "$TMUX_CTDL_CONF"
    _WB_LOADED[conf]=1
  fi
  local lib path
  for lib; do
    [ "$lib" = conf ] && continue
    [ -n "${_WB_LOADED[$lib]:-}" ] && continue
    case "$lib" in
      agent) path="${CODING_AGENT_MODULE:-$TMUX_CTDL_HOME/adapter/adapter-${CODING_AGENT}.sh}" ;;
      agent:*) path="$TMUX_CTDL_HOME/adapter/adapter-${lib#agent:}.sh" ;;
      adapter) path="$TMUX_CTDL_HOME/adapter/adapter-lib.sh" ;;
      wintab) path="$TMUX_CTDL_HOME/wintab/wintab-lib.sh" ;;
      agentbar) path="$TMUX_CTDL_HOME/agentbar/agentbar-lib.sh" ;;
      *) path="$TMUX_CTDL_HOME/libs/${lib}-lib.sh" ;;
    esac
    . "$path"
    _WB_LOADED[$lib]=1
  done
}
