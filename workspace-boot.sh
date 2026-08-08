#!/usr/bin/env bash
# The one way into the workspace runtime. Load order — conf, then libs, then the
# active agent module — lives HERE and nowhere else. Entry points AND libs name
# libs, not paths:
#
#   . "${WORKSPACE_HOME:-$HOME/.config/tmux/workspace}/workspace-boot.sh"
#   workspace_boot layout agent
#
# Lib names: tmux · state · layout · adapter · wintab · agentbar. `agent`
# sources CODING_AGENT_MODULE if the conf set one, else
# $WORKSPACE_HOME/adapter/adapter-<CODING_AGENT>.sh — the same formula
# `agent:<id>` below always uses; `agent:<id>` sources that
# specific agent's module by id instead — e.g. `workspace_boot adapter
# agent:claude` in a push entry point, so a Claude hook still writes
# Claude state while agentbar displays Copilot. A lib that needs another lib
# calls workspace_boot
# itself (e.g. `workspace_boot state tmux` at the top of wintab-lib.sh)
# instead of sourcing a relative path — workspace_boot is idempotent (tracked
# in _WB_LOADED), so that costs nothing when the caller already loaded it.
# The conf load is under the same guard: it is read once per process, not once
# per workspace_boot call.
#
# WORKSPACE_HOME is where the libs live (the stowed copy by default);
# WORKSPACE_CONF is the conf to read. Tests point WORKSPACE_HOME at the repo and
# WORKSPACE_CONF at a scratch file, so a test run drives the real code with a
# throwaway palette.

: "${WORKSPACE_HOME:=$HOME/.config/tmux/workspace}"
: "${WORKSPACE_CONF:=$WORKSPACE_HOME/workspace.conf}"

declare -gA _WB_LOADED

workspace_boot() {
  if [ -z "${_WB_LOADED[conf]:-}" ]; then
    . "$WORKSPACE_CONF"
    _WB_LOADED[conf]=1
  fi
  local lib path
  for lib; do
    [ "$lib" = conf ] && continue
    [ -n "${_WB_LOADED[$lib]:-}" ] && continue
    case "$lib" in
      agent)    path="${CODING_AGENT_MODULE:-$WORKSPACE_HOME/adapter/adapter-${CODING_AGENT}.sh}" ;;
      agent:*)  path="$WORKSPACE_HOME/adapter/adapter-${lib#agent:}.sh" ;;
      adapter)  path="$WORKSPACE_HOME/adapter/adapter-lib.sh" ;;
      wintab)   path="$WORKSPACE_HOME/wintab/wintab-lib.sh" ;;
      agentbar) path="$WORKSPACE_HOME/agentbar/agentbar-lib.sh" ;;
      *)        path="$WORKSPACE_HOME/libs/${lib}-lib.sh" ;;
    esac
    . "$path"
    _WB_LOADED[$lib]=1
  done
}
