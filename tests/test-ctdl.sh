#!/usr/bin/env bash
# ctdl.sh — the `ctdl`/`ctdlm` shell functions and the dispatch arms not
# exercised by any other suite (tracker-editor-toggle, agent-respawn). Every
# other verb already has its own end-to-end test file next to the lib it
# drives; this one covers ctdl.sh's own routing/wrapper code.
DIR="$(cd "$(dirname "$0")" && pwd)" || exit 1
. "$DIR/helpers.sh"
SCRIPTS="$DIR/.."

export WORKSPACE_HOME="$(cd "$DIR/.." && pwd)"
CONF_DIR=$(mktemp -d)
cat > "$CONF_DIR/workspace.conf" << CONF
CODING_AGENT="claude"
EDITOR_CMD="nvim"
CHANGE_TRACKER_CMD="lazygit"
CONF
export WORKSPACE_CONF="$CONF_DIR/workspace.conf"
trap 'rm -rf "$CONF_DIR"' EXIT

setup() {
  rm -f /tmp/mock-tmux-calls
  export PATH="$FIXTURES:$PATH"
  export MOCK_SESSION=test-session MOCK_WIN=@1 MOCK_PPATH=/home/user/project
  unset MOCK_OPT_coding_agent_pane_id MOCK_OPT_change_tracker_pane_id \
        MOCK_OPT_change_tracker_state
}

test_tracker_editor_toggle_verb() {
  setup
  export MOCK_OPT_change_tracker_pane_id=%3
  bash "$SCRIPTS/ctdl.sh" tracker-editor-toggle mock-agent
  assert_contains "$(cat /tmp/mock-tmux-calls)" 'respawn-pane -k -c /home/user/project -t %3 nvim .' \
    "verb routes to layout_toggle with the configured editor"
}

test_agent_respawn_verb() {
  setup
  export MOCK_OPT_coding_agent_pane_id=%5
  bash "$SCRIPTS/ctdl.sh" agent-respawn mock-agent
  assert_contains "$(cat /tmp/mock-tmux-calls)" 'respawn-pane -k -c /home/user/project -t %5 claude' \
    "verb routes to layout_respawn_agent with AGENT_CMD"
}

# agent-push-usage, called in-process via _ctdl_main directly rather than a
# `bash ctdl.sh` subprocess — the push-usage suite covers the real subprocess
# path many times over already; this exercises ctdl.sh's own dispatch line.
test_agent_push_usage_verb_direct() {
  setup
  local agent_tmp; agent_tmp=$(mktemp -d)
  ( . "$SCRIPTS/ctdl.sh"
    export AGENT_TMP_DIR="$agent_tmp" TMUX_PANE=mock-pane
    cat "$FIXTURES/claude-status-safe.json" | _ctdl_main agent-push-usage )
  local out; out=$(cat "$agent_tmp/agent-rate-claude" 2>/dev/null)
  rm -rf "$agent_tmp"
  assert_contains "$out" "session" "push-usage arm wrote rate state"
}

test_agent_pull_usage_verb_direct() {
  setup
  local agent_tmp; agent_tmp=$(mktemp -d)
  ( . "$SCRIPTS/ctdl.sh"
    export AGENT_TMP_DIR="$agent_tmp" TMUX_PANE=mock-pane
    _ctdl_main agent-pull-usage )
  local rc=$?
  rm -rf "$agent_tmp"
  # Claude has no agent-side collect hook — a no-op, not an error.
  [ "$rc" -eq 0 ]
}

test_unknown_verb_errors() {
  setup
  bash "$SCRIPTS/ctdl.sh" bogus-verb 2>/tmp/ctdl-err
  assert_contains "$(cat /tmp/ctdl-err)" "unknown verb" "unknown verb reported on stderr"
}

# ctdl() — outside tmux it must refuse instead of building a layout nowhere.
test_ctdl_outside_tmux_refuses() {
  setup
  local out
  out=$(. "$SCRIPTS/ctdl.sh"; unset TMUX; ctdl 2>&1)
  assert_contains "$out" "must be inside tmux" "refuses without a live tmux"
}

# ctdl() inside tmux builds the layout in the current pane.
test_ctdl_inside_tmux_builds_layout() {
  setup
  local out
  out=$(. "$SCRIPTS/ctdl.sh"
        export TMUX=/tmp/fake-tmux-socket TMUX_PANE=mock-agent PWD=/home/user/project
        ctdl)
  assert_contains "$(cat /tmp/mock-tmux-calls)" 'send-keys -t mock-agent claude --dangerously-skip-permissions C-m' \
    "ctdl() launches AGENT_CMD in the current pane"
}

# ctdlm() outside tmux starts one and re-enters — the one raw tmux call left
# in ctdl.sh itself.
test_ctdlm_outside_tmux_starts_session() {
  setup
  ( . "$SCRIPTS/ctdl.sh"; unset TMUX; ctdlm )
  assert_contains "$(cat /tmp/mock-tmux-calls)" 'new-session zsh -ic ctdlm' \
    "starts a fresh tmux session and re-enters ctdlm"
}

# ctdlm() inside tmux, run from a dir with git workspaces one level down —
# one window per workspace via layout_open_workspaces.
test_ctdlm_inside_tmux_opens_workspaces() {
  setup
  export MOCK_NEW_PANE=%7
  local base; base=$(mktemp -d)
  mkdir -p "$base/repo-a/.git"
  local out
  out=$(. "$SCRIPTS/ctdl.sh"
        export TMUX=/tmp/fake-tmux-socket TMUX_PANE=mock-installer
        cd "$base" && ctdlm)
  local calls; calls=$(cat /tmp/mock-tmux-calls)
  rm -rf "$base"
  assert_contains "$calls" "new-window -c $base/repo-a" "one window opened for the git workspace"
}

# ctdlm() with no git workspace within 2 levels of $PWD falls back to
# ~/Development (the one hardcoded path in ctdl.sh, per its own comment).
test_ctdlm_falls_back_to_development_dir() {
  [ -d ~/Development ] || { echo "skip: ~/Development doesn't exist here"; return 0; }
  setup
  export MOCK_NEW_PANE=%7
  local nogit; nogit=$(mktemp -d)
  local out
  out=$(. "$SCRIPTS/ctdl.sh"
        export TMUX=/tmp/fake-tmux-socket TMUX_PANE=mock-installer
        cd "$nogit" && ctdlm
        pwd)
  rm -rf "$nogit"
  assert_contains "$out" "$HOME/Development" "cwd fell back to ~/Development"
}

run_tests \
  test_tracker_editor_toggle_verb \
  test_agent_respawn_verb \
  test_agent_push_usage_verb_direct \
  test_agent_pull_usage_verb_direct \
  test_unknown_verb_errors \
  test_ctdl_outside_tmux_refuses \
  test_ctdl_inside_tmux_builds_layout \
  test_ctdlm_outside_tmux_starts_session \
  test_ctdlm_inside_tmux_opens_workspaces \
  test_ctdlm_falls_back_to_development_dir
