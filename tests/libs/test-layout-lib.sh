#!/usr/bin/env bash
# layout-lib.sh — pane-role bookkeeping and the ctdl build/toggle/respawn
# verbs. Driven against the fixtures/tmux adapter, like tmux-lib itself.
DIR="$(cd "$(dirname "$0")" && pwd)" || exit 1
. "$DIR/../helpers.sh"
. "$DIR/../../libs/layout-lib.sh"

setup() {
  rm -f /tmp/mock-tmux-calls
  export PATH="$FIXTURES:$PATH"
  export MOCK_SESSION=test-session MOCK_WIN=@1 MOCK_PPATH=/home/user/project
  export MOCK_SPLIT_PANE=%2
  unset MOCK_PPATH2 MOCK_BADGE MOCK_OPT_coding_agent_pane_id \
        MOCK_OPT_change_tracker_pane_id MOCK_OPT_change_tracker_state
}

test_build_renames_and_splits() {
  setup
  layout_build mock-agent /home/user/project claude lazygit
  local calls; calls=$(cat /tmp/mock-tmux-calls)
  assert_contains "$calls" 'rename-window -t mock-agent project' "window renamed from cwd basename" &&
  assert_contains "$calls" 'split-window -h -p 55 -t mock-agent -c /home/user/project' "tracker split off agent" &&
  assert_contains "$calls" 'split-window -v -p 25 -t %2 -c /home/user/project' "terminal split off tracker"
}

test_build_launches_agent_and_tracker() {
  setup
  layout_build mock-agent /home/user/project claude lazygit
  local calls; calls=$(cat /tmp/mock-tmux-calls)
  assert_contains "$calls" 'send-keys -t mock-agent claude C-m' "agent launched" &&
  assert_contains "$calls" 'send-keys -t %2 lazygit C-m' "tracker launched" &&
  assert_contains "$calls" 'send-keys -t %2 clear C-m' "terminal cleared"
}

test_build_records_pane_roles_and_selects_agent() {
  setup
  layout_build mock-agent /home/user/project claude lazygit
  local calls; calls=$(cat /tmp/mock-tmux-calls)
  assert_contains "$calls" '@coding_agent_pane_id mock-agent' "agent pane role stored" &&
  assert_contains "$calls" '@change_tracker_pane_id %2' "tracker pane role stored" &&
  assert_contains "$calls" '@change_tracker_state lazygit' "tracker state stored" &&
  assert_contains "$calls" 'select-pane -t mock-agent' "leaves user on agent pane"
}

test_toggle_switches_tracker_to_editor() {
  setup
  export MOCK_OPT_change_tracker_pane_id=%3
  export MOCK_OPT_change_tracker_state=lazygit
  layout_toggle mock-agent nvim lazygit
  local calls; calls=$(cat /tmp/mock-tmux-calls)
  assert_contains "$calls" 'respawn-pane -k -c /home/user/project -t %3 nvim .' "editor respawned in tracker pane" &&
  assert_contains "$calls" '@change_tracker_state nvim' "state flipped to editor"
}

test_toggle_switches_editor_back_to_tracker() {
  setup
  export MOCK_OPT_change_tracker_pane_id=%3
  export MOCK_OPT_change_tracker_state=nvim
  layout_toggle mock-agent nvim lazygit
  local calls; calls=$(cat /tmp/mock-tmux-calls)
  assert_contains "$calls" 'respawn-pane -k -c /home/user/project -t %3 lazygit' "tracker respawned" &&
  assert_contains "$calls" '@change_tracker_state lazygit' "state flipped to tracker"
}

test_toggle_defaults_to_editor_when_state_unset() {
  setup
  export MOCK_OPT_change_tracker_pane_id=%3
  layout_toggle mock-agent nvim lazygit
  assert_contains "$(cat /tmp/mock-tmux-calls)" 'nvim .' "no recorded state starts the editor"
}

# The bug this guards: no @change_tracker_pane_id for the current window (Space
# hit in a window ctdl never built) must NOT fall through to tmux's own
# default target (the current active pane) — that silently respawns whatever
# the user is looking at instead of doing nothing.
test_toggle_noop_when_no_tracker_pane_recorded() {
  setup
  layout_toggle mock-agent nvim lazygit
  ! grep -q respawn-pane /tmp/mock-tmux-calls
}

test_respawn_agent_uses_recorded_pane() {
  setup
  export MOCK_OPT_coding_agent_pane_id=%5
  layout_respawn_agent mock-agent claude mock-fallback
  assert_contains "$(cat /tmp/mock-tmux-calls)" 'respawn-pane -k -c /home/user/project -t %5 claude' "respawns recorded agent pane"
}

test_respawn_agent_falls_back_when_no_role_recorded() {
  setup
  layout_respawn_agent mock-agent claude mock-fallback
  assert_contains "$(cat /tmp/mock-tmux-calls)" 'respawn-pane -k -c /home/user/project -t mock-fallback claude' "falls back to given pane"
}

test_workspace_dirs_lists_only_git_repos() {
  local base; base=$(mktemp -d)
  mkdir -p "$base/repo-a/.git" "$base/repo-b/.git" "$base/not-a-repo" "$base/repo-c"
  touch "$base/loose-file"
  local out; out=$(layout_workspace_dirs "$base")
  rm -rf "$base"
  assert_contains "$out" "repo-a" "git repo listed" &&
  assert_contains "$out" "repo-b" "git repo listed" &&
  ! printf '%s' "$out" | grep -qF "not-a-repo" &&
  ! printf '%s' "$out" | grep -qF "loose-file"
}

test_workspace_dirs_empty_base_is_silent() {
  local base; base=$(mktemp -d)
  local out; out=$(layout_workspace_dirs "$base")
  rm -rf "$base"
  assert_empty "$out" "no repos → no output"
}

test_open_workspaces_one_window_per_repo() {
  setup
  export MOCK_NEW_PANE=%7
  local base; base=$(mktemp -d)/my.workspace
  mkdir -p "$base/repo-a/.git" "$base/repo-b/.git" "$base/plain"
  layout_open_workspaces "$base" mock-installer ctdl
  local calls; calls=$(cat /tmp/mock-tmux-calls)
  rm -rf "$(dirname "$base")"
  assert_contains "$calls" 'rename-session my-workspace' "session named from base, dots swapped" &&
  assert_contains "$calls" "new-window -c $base/repo-a" "window per git repo" &&
  assert_contains "$calls" "new-window -c $base/repo-b" "window per git repo" &&
  assert_contains "$calls" 'send-keys -t %7 ctdl C-m' "ctdl launched in the new pane" &&
  assert_contains "$calls" 'kill-window -t mock-installer' "installer window closed" &&
  ! printf '%s' "$calls" | grep -qF "$base/plain"
}

run_tests \
  test_build_renames_and_splits \
  test_workspace_dirs_lists_only_git_repos \
  test_workspace_dirs_empty_base_is_silent \
  test_open_workspaces_one_window_per_repo \
  test_build_launches_agent_and_tracker \
  test_build_records_pane_roles_and_selects_agent \
  test_toggle_switches_tracker_to_editor \
  test_toggle_switches_editor_back_to_tracker \
  test_toggle_defaults_to_editor_when_state_unset \
  test_toggle_noop_when_no_tracker_pane_recorded \
  test_respawn_agent_uses_recorded_pane \
  test_respawn_agent_falls_back_when_no_role_recorded
