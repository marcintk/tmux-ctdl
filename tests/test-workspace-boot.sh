#!/usr/bin/env bash
# workspace-boot.sh — the `agent:<id>` lib name (source a specific agent's
# module regardless of CODING_AGENT), which no push/pull entry point uses
# yet but the loader has always supported per its own docstring.
DIR="$(cd "$(dirname "$0")" && pwd)" || exit 1
. "$DIR/helpers.sh"

export WORKSPACE_HOME="$(cd "$DIR/.." && pwd)"
CONF_DIR=$(mktemp -d)
cat > "$CONF_DIR/workspace.conf" << CONF
CODING_AGENT="copilot"
CONF
export WORKSPACE_CONF="$CONF_DIR/workspace.conf"
trap 'rm -rf "$CONF_DIR"' EXIT

test_agent_colon_id_sources_that_specific_module() {
  unset _WB_LOADED 2>/dev/null
  declare -gA _WB_LOADED
  . "$WORKSPACE_HOME/workspace-boot.sh"
  workspace_boot "agent:claude"
  declare -f claude_parse_shared >/dev/null 2>&1
}

run_tests \
  test_agent_colon_id_sources_that_specific_module
