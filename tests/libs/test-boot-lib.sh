#!/usr/bin/env bash
# libs/boot-lib.sh — the `agent:<id>` lib name (source a specific agent's
# module regardless of CODING_AGENT), which no push/pull entry point uses
# yet but the loader has always supported per its own docstring.
DIR="$(cd "$(dirname "$0")" && pwd)" || exit 1
. "$DIR/../helpers.sh"

export TMUX_CTDL_HOME="$(cd "$DIR/../.." && pwd)"
CONF_DIR=$(mktemp -d)
cat > "$CONF_DIR/tmux-ctdl.conf" << CONF
CODING_AGENT="copilot"
CONF
export TMUX_CTDL_CONF="$CONF_DIR/tmux-ctdl.conf"
trap 'rm -rf "$CONF_DIR"' EXIT

test_agent_colon_id_sources_that_specific_module() {
  unset _WB_LOADED 2>/dev/null
  declare -gA _WB_LOADED
  . "$TMUX_CTDL_HOME/libs/boot-lib.sh"
  tmux_ctdl_boot "agent:claude"
  declare -f claude_parse_shared >/dev/null 2>&1
}

run_tests \
  test_agent_colon_id_sources_that_specific_module
