#!/usr/bin/env bash
# tmux-ctdl.sh wintab-tick — the poll entry point, end to end. Phase is seeded through
# state-lib rather than by touching files, and badges are read back from the
# fixtures/tmux call log.
DIR="$(cd "$(dirname "$0")" && pwd)" || exit 1
. "$DIR/../helpers.sh"
SCRIPTS="$DIR/../.."
. "$DIR/../../libs/state-lib.sh"

# WORKSPACE_HOME points the boot module at the repo (real wintab-lib), while
# WORKSPACE_CONF points at a scratch conf naming a stub agent module.
export WORKSPACE_HOME="$(cd "$DIR/../.." && pwd)"
TEST_HOME=$(mktemp -d)
# Scratch state dir so a test run never clobbers the live /tmp status files.
export AGENT_TMP_DIR
AGENT_TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_HOME" "$AGENT_TMP_DIR"' EXIT

_make_workspace() {
  # Stub agent module with injectable live_cwds (MOCK_LIVE_PPATH is env-injectable)
  cat > "$TEST_HOME/adapter-claude.sh" << 'AGENT'
claude_live_cwds() { printf '%s\n' "${MOCK_LIVE_PPATH:-}"; }
AGENT
  cat > "$TEST_HOME/workspace.conf" << CONF
CODING_AGENT="claude"
CODING_AGENT_MODULE="$TEST_HOME/adapter-claude.sh"
WINTAB_LIVE_GRACE=5
CONF
}

# Last set-window-option call targeting @agent_badges, empty (cleared).
_last_badge_cleared() {
  printf '%s' "$1" | grep 'set-window-option' | tail -1 | grep -qE '@agent_badges[[:space:]]*$'
}

setup() {
  _make_workspace
  rm -f /tmp/mock-tmux-calls "$AGENT_TMP_DIR"/agent-*
  export WORKSPACE_CONF="$TEST_HOME/workspace.conf"
  export PATH="$FIXTURES:$PATH"
  export MOCK_SESSION=test-session MOCK_WIN=@1 MOCK_PPATH=/home/user/project
  unset MOCK_LIVE_PPATH MOCK_PPATH2 MOCK_BADGE
}

_seed()  { state_put "$1" phase claude test-session @1; }
_tick()  { bash "$SCRIPTS/tmux-ctdl.sh" wintab-tick test-session; }
_calls() { cat /tmp/mock-tmux-calls; }
_phase() { state_get phase claude test-session @1; }

test_no_session_exits_silently() {
  setup
  assert_empty "$(bash "$SCRIPTS/tmux-ctdl.sh" wintab-tick 2>&1)" "no output without session arg"
}

test_live_process_sets_pulse() {
  setup
  export MOCK_LIVE_PPATH=/home/user/project
  _seed RUNNING; _tick
  assert_contains "$(_calls)" '@agent_badges' "sets agent_badges option" &&
  assert_contains "$(_calls)" '4488ff' "pulse is blue"
}

test_dead_process_clears_badge() {
  setup
  # Not live and no recent liveness stamp (agent truly gone) → run badge cleared.
  _seed RUNNING; _tick
  _last_badge_cleared "$(_calls)" && ! state_exists phase claude test-session @1
}

# A running window + a transient live miss (fresh liveness stamp) must NOT clear
# the badge — guards the icon against a one-tick detection miss under load.
test_transient_miss_keeps_run_badge() {
  setup
  _seed RUNNING
  state_mark live claude test-session @1   # seen live this grace window
  _tick
  ! _last_badge_cleared "$(_calls)"
}

# A done window + a transient live miss must NOT reset to idle.
test_transient_miss_keeps_done_badge() {
  setup
  _seed DONE
  state_mark live claude test-session @1
  _tick
  [ "$(_phase)" = DONE ]
}

test_live_no_phase_sets_grey() {
  setup
  export MOCK_LIVE_PPATH=/home/user/project
  _tick
  assert_contains "$(_calls)" '666666' "idle live agent shows grey"
}

test_dead_stale_badge_cleared() {
  setup
  _seed DONE; _tick
  _last_badge_cleared "$(_calls)"
}

# A live agent waiting on permission keeps its red badge — the poll path used to
# decide from the tmux option alone and could reset it.
test_live_blocked_badge_survives_poll() {
  setup
  export MOCK_LIVE_PPATH=/home/user/project
  _seed BLOCKED; _tick
  [ "$(_phase)" = BLOCKED ] && ! _last_badge_cleared "$(_calls)"
}

# The pane-path bug: the agent runs in its own pane while the ACTIVE pane of the
# same window has been cd'd elsewhere. The window is still live.
test_agent_pane_matches_when_active_pane_wandered() {
  setup
  export MOCK_PPATH=/home/user/somewhere-else   # active pane, cd'd away
  export MOCK_PPATH2=/home/user/project         # agent's pane
  export MOCK_LIVE_PPATH=/home/user/project
  _seed RUNNING; _tick
  [ "$(_phase)" = RUNNING ] && ! _last_badge_cleared "$(_calls)"
}

# An idle window with nothing to show must not touch tmux every second.
test_idle_window_makes_no_tmux_writes() {
  setup
  _tick
  assert_empty "$(_calls | grep set-window-option)" "no badge writes when nothing changes"
}

run_tests \
  test_no_session_exits_silently \
  test_live_process_sets_pulse \
  test_dead_process_clears_badge \
  test_transient_miss_keeps_run_badge \
  test_transient_miss_keeps_done_badge \
  test_live_no_phase_sets_grey \
  test_dead_stale_badge_cleared \
  test_live_blocked_badge_survives_poll \
  test_agent_pane_matches_when_active_pane_wandered \
  test_idle_window_makes_no_tmux_writes
