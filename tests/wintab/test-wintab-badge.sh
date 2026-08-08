#!/usr/bin/env bash
# ctdl.sh wintab-badge — the event entry point, end to end through the state machine,
# state-lib and the fixtures/tmux adapter.
DIR="$(cd "$(dirname "$0")" && pwd)" || exit 1
. "$DIR/../helpers.sh"
SCRIPTS="$DIR/../.."
. "$DIR/../../libs/state-lib.sh"

# WORKSPACE_HOME points the boot module at the repo; WORKSPACE_CONF pins
# CODING_AGENT=claude regardless of the live workspace.conf's setting — badge
# reads the active agent from conf, it no longer takes one as an arg.
export WORKSPACE_HOME="$(cd "$DIR/../.." && pwd)"
CONF_DIR=$(mktemp -d)
cat > "$CONF_DIR/workspace.conf" << CONF
CODING_AGENT="claude"
CONF
export WORKSPACE_CONF="$CONF_DIR/workspace.conf"

# Scratch state dir so a test run never clobbers the live /tmp status files.
export AGENT_TMP_DIR
AGENT_TMP_DIR=$(mktemp -d)
trap 'rm -rf "$AGENT_TMP_DIR" "$CONF_DIR"' EXIT

setup() {
  rm -f /tmp/mock-tmux-calls "$AGENT_TMP_DIR"/agent-*
  export TMUX_PANE=mock-pane
  export PATH="$FIXTURES:$PATH"
  export MOCK_SESSION=test-session MOCK_WIN=@1
}

_hook() { echo '' | bash "$SCRIPTS/ctdl.sh" wintab-badge "$@"; }
_calls() { cat /tmp/mock-tmux-calls; }
_phase() { cat "$AGENT_TMP_DIR/agent-phase-claude-test-session-@1" 2>/dev/null; }

test_running_state() {
  setup; _hook RUNNING
  assert_contains "$(_calls)" '4488ff' "running: blue color" &&
  assert_contains "$(_calls)" '○' "running: circle icon"
}

test_permission_state() {
  setup; _hook PERMISSION
  assert_contains "$(_calls)" 'ff5555' "permission: red color" &&
  assert_contains "$(_calls)" '◉' "permission: filled circle icon"
}

test_done_state() {
  setup; _hook DONE
  assert_contains "$(_calls)" '77dd77' "done: green color" &&
  assert_contains "$(_calls)" '●' "done: filled dot icon"
}

test_clear_state() {
  setup; _hook CLEAR
  assert_contains "$(_calls)" '666666' "clear: grey color" &&
  assert_contains "$(_calls)" '◌' "clear: empty circle icon"
}

# /clear while running, then done → grey, not green. The flag survives the gap
# between the two hook invocations because it is stored state.
test_done_after_clear_shows_grey() {
  setup
  _hook RUNNING
  _hook CLEAR
  rm -f /tmp/mock-tmux-calls
  _hook DONE
  assert_contains "$(_calls)" '666666' "done after clear: grey color"
}

# …and the flag is consumed: a second done goes back to green.
test_second_done_shows_green() {
  setup
  _hook RUNNING; _hook CLEAR; _hook DONE
  rm -f /tmp/mock-tmux-calls
  _hook DONE
  assert_contains "$(_calls)" '77dd77' "flag consumed: green again"
}

test_agent_option_name() {
  setup; _hook PERMISSION
  assert_contains "$(_calls)" '@agent_badges' "correct window option name"
}

# The event path stores the phase, so the poll path can hold it instead of
# guessing from whatever is in the tmux option.
test_event_records_phase() {
  setup; _hook PERMISSION
  [ "$(_phase)" = BLOCKED ]
}

test_unknown_code_is_noop() {
  setup; _hook ZZ
  assert_empty "$(_calls | grep set-window-option)" "unknown event paints nothing" &&
  ! state_exists phase claude test-session @1
}

run_tests \
  test_running_state \
  test_permission_state \
  test_done_state \
  test_clear_state \
  test_done_after_clear_shows_grey \
  test_second_done_shows_green \
  test_agent_option_name \
  test_event_records_phase \
  test_unknown_code_is_noop
