#!/usr/bin/env bash
# tmux-lib.sh — the only module that knows tmux command syntax. Driven here
# against the fixtures/tmux adapter; in a live session the same interface is
# backed by the real binary.
DIR="$(cd "$(dirname "$0")" && pwd)" || exit 1
. "$DIR/../helpers.sh"
. "$DIR/../../libs/tmux-lib.sh"

setup() {
  rm -f /tmp/mock-tmux-calls
  export PATH="$FIXTURES:$PATH"
  export MOCK_SESSION=test-session MOCK_WIN=@1 MOCK_PPATH=/home/user/project
  unset MOCK_PPATH2 MOCK_BADGE
}

# One round trip for both fields — callers used to make two.
test_where_am_i_returns_session_and_window() {
  setup
  local s w
  IFS=$'\t' read -r s w < <(tmux_where_am_i mock-pane)
  [ "$s" = test-session ] && [ "$w" = @1 ] &&
    [ "$(grep -c display-message /tmp/mock-tmux-calls)" -eq 1 ]
}

# tmux_here — the "where am I" judgment callers used to each make themselves.
test_here_returns_session_and_window() {
  setup
  export TMUX_PANE=mock-pane
  local s w
  IFS=$'\t' read -r s w < <(tmux_here)
  [ "$s" = test-session ] && [ "$w" = @1 ]
}

test_here_fails_without_pane() {
  setup
  unset TMUX_PANE
  local out
  out=$(tmux_here) && return 1
  assert_empty "$out" "no output when there is no current pane"
}

# TMUX_PANE set but tmux unreachable: an empty answer is "nowhere", not a
# half-known window. Callers return 0 on this and store nothing.
test_here_fails_when_tmux_answers_nothing() {
  setup
  export TMUX_PANE=mock-pane
  local out
  out=$(PATH=/nonexistent-for-tmux-lib-test tmux_here) && return 1
  assert_empty "$out" "no output when tmux is missing"
}

test_pane_path() {
  setup
  [ "$(tmux_pane_path mock-pane)" = /home/user/project ]
}

# Every pane, not just the window's active one.
test_session_panes_lists_all_panes() {
  setup
  export MOCK_PPATH2=/elsewhere
  local out
  out=$(tmux_session_panes test-session)
  [ "$(printf '%s\n' "$out" | wc -l)" -eq 2 ] &&
    assert_contains "$out" "/elsewhere" "non-active pane listed"
}

test_badge_set_targets_session_window() {
  setup
  tmux_badge_set test-session @1 ' X'
  local calls
  calls=$(cat /tmp/mock-tmux-calls)
  assert_contains "$calls" 'test-session:@1' "target is session:window" &&
    assert_contains "$calls" '@agent_badges' "correct window option name"
}

test_window_option_roundtrip() {
  setup
  export MOCK_BADGE=lazygit
  tmux_window_option_set mock-pane @change_tracker_state nvim
  assert_contains "$(cat /tmp/mock-tmux-calls)" 'set-window-option -t mock-pane @change_tracker_state nvim' "set issued" &&
    [ "$(tmux_window_option_get mock-pane @change_tracker_state)" = lazygit ]
}

test_respawn_kills_and_sets_cwd() {
  setup
  tmux_respawn %3 /tmp/proj "nvim ."
  assert_contains "$(cat /tmp/mock-tmux-calls)" 'respawn-pane -k -c /tmp/proj -t %3 nvim .' "respawn args"
}

test_rename_window() {
  setup
  tmux_rename_window mock-pane myproj
  assert_contains "$(cat /tmp/mock-tmux-calls)" 'rename-window -t mock-pane myproj' "rename args"
}

test_split_window_returns_new_pane_id() {
  setup
  export MOCK_SPLIT_PANE=%9
  local out
  out=$(tmux_split_window mock-pane /tmp/proj -h 55)
  [ "$out" = %9 ] &&
    assert_contains "$(cat /tmp/mock-tmux-calls)" 'split-window -h -p 55 -t mock-pane -c /tmp/proj' "split args"
}

test_send_keys_types_and_enters() {
  setup
  tmux_send_keys mock-pane "ls"
  assert_contains "$(cat /tmp/mock-tmux-calls)" 'send-keys -t mock-pane ls C-m' "send-keys args"
}

test_select_pane() {
  setup
  tmux_select_pane mock-pane
  assert_contains "$(cat /tmp/mock-tmux-calls)" 'select-pane -t mock-pane' "select-pane args"
}

test_new_window_without_session_targets_current() {
  setup
  export MOCK_NEW_PANE=%9
  local out
  out=$(tmux_new_window /tmp/proj)
  [ "$out" = %9 ] &&
    assert_contains "$(cat /tmp/mock-tmux-calls)" 'new-window -c /tmp/proj -P -F #{pane_id}' "no -t flag when session omitted"
}

test_new_window_with_session_targets_it() {
  setup
  export MOCK_NEW_PANE=%9
  tmux_new_window /tmp/proj my-session
  assert_contains "$(cat /tmp/mock-tmux-calls)" 'new-window -c /tmp/proj -t my-session:' "session:  window target"
}

test_new_session_returns_first_pane_id() {
  setup
  export MOCK_NEW_SESSION_PANE=%8
  local out
  out=$(tmux_new_session my-session /tmp/proj)
  [ "$out" = %8 ] &&
    assert_contains "$(cat /tmp/mock-tmux-calls)" 'new-session -d -s my-session -c /tmp/proj' "detached session args"
}

# Outside tmux every call must be a silent no-op, not an error on the status bar.
test_silent_without_tmux() {
  rm -f /tmp/mock-tmux-calls
  local out
  out=$(PATH=/nonexistent-for-tmux-lib-test tmux_where_am_i mock-pane 2>&1)
  assert_empty "$out" "no output when tmux is missing"
}

run_tests \
  test_where_am_i_returns_session_and_window \
  test_here_returns_session_and_window \
  test_here_fails_without_pane \
  test_here_fails_when_tmux_answers_nothing \
  test_pane_path \
  test_session_panes_lists_all_panes \
  test_badge_set_targets_session_window \
  test_window_option_roundtrip \
  test_respawn_kills_and_sets_cwd \
  test_rename_window \
  test_split_window_returns_new_pane_id \
  test_send_keys_types_and_enters \
  test_select_pane \
  test_new_window_without_session_targets_current \
  test_new_window_with_session_targets_it \
  test_new_session_returns_first_pane_id \
  test_silent_without_tmux
