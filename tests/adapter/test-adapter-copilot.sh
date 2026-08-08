#!/usr/bin/env bash
# adapter-copilot.sh — consumer-side module. Covers copilot_format_usage (via the
# tmux-ctdl.sh agentbar end-to-end render) and copilot_live_cwds (process probe).
DIR="$(cd "$(dirname "$0")" && pwd)" || exit 1
. "$DIR/../helpers.sh"
ADAPTER="$DIR/../../adapter"
# WORKSPACE_HOME points the boot module at the repo; WORKSPACE_CONF at a scratch
# conf naming the agent and nothing else — the palette defaults at the module
# that reads it, so a test never restates it. No HOME manipulation needed.
export WORKSPACE_HOME="$(cd "$DIR/../.." && pwd)"

# End-to-end: enable copilot in AGENTS and confirm the display renders it —
# model shown, usage segment gracefully omitted (copilot_format_usage returns
# early when today/week/month are empty).
test_display_renders_copilot_model_only() {
  local th; th=$(mktemp -d)
  echo "CODING_AGENT='copilot'" > "$th/workspace.conf"
  local tmp; tmp=$(mktemp -d)
  printf 'model\tGPT-5\neffort\thigh\n' > "$tmp/agent-shared-copilot-test-session-@1"
  local out
  out=$(WORKSPACE_CONF="$th/workspace.conf" AGENT_TMP_DIR="$tmp" \
         bash "$WORKSPACE_HOME/tmux-ctdl.sh" agentbar test-session @1)
  rm -rf "$th" "$tmp"
  assert_contains "$out" "Copilot: GPT-5" "copilot model line rendered" &&
  ! printf '%s' "$out" | grep -qF "Today:"  # no usage segment without data
}

# When usage data IS present, copilot_format_usage renders Today/Week/Month.
test_display_renders_copilot_usage() {
  local th; th=$(mktemp -d)
  echo "CODING_AGENT='copilot'" > "$th/workspace.conf"
  local tmp; tmp=$(mktemp -d)
  printf 'today\t12.5\nweek\t40\nmonth\t63.2\nmodel\tGPT-5\neffort\thigh\n' > "$tmp/agent-shared-copilot-test-session-@1"
  local out
  out=$(WORKSPACE_CONF="$th/workspace.conf" AGENT_TMP_DIR="$tmp" \
         bash "$WORKSPACE_HOME/tmux-ctdl.sh" agentbar test-session @1)
  rm -rf "$th" "$tmp"
  assert_contains "$out" "Today: 12.5%"  &&
  assert_contains "$out" "Week: 40.0%"   &&
  assert_contains "$out" "Month: 63.2%"
}

test_collect_no_db_is_empty_object() {
  . "$ADAPTER/adapter-copilot.sh"
  [ "$(COPILOT_DB=/no/such/db.sqlite copilot_collect)" = "{}" ]
}

test_parse_context_is_always_empty() {
  . "$ADAPTER/adapter-copilot.sh"
  assert_empty "$(copilot_parse_context)" "no context telemetry in the db"
}

# copilot_parse_shared called directly on a synthetic collect payload — the
# pull-usage suite drives it too, but only downstream of copilot_collect's
# real sqlite3 call. Standalone here, no foreign binary involved.
test_parse_shared_direct() {
  . "$ADAPTER/adapter-copilot.sh"
  local out; out=$(printf '{"model":"GPT-5","reasoning_effort":"high"}' | copilot_parse_shared)
  assert_contains "$out" "$(printf 'model\tGPT-5')" "model parsed directly" &&
  assert_contains "$out" "$(printf 'effort\thigh')" "effort parsed directly"
}


# copilot_live_cwds: pgrep -x copilot → readlink /proc/<pid>/cwd, one cwd/line.
# Mock pgrep with our own live shell pid so /proc/<pid>/cwd resolves for real.
test_live_cwds_resolves_pid_cwd() {
  . "$ADAPTER/adapter-copilot.sh"
  pgrep() { echo $$; }
  local out; out=$(copilot_live_cwds)
  unset -f pgrep
  assert_contains "$out" "$(readlink /proc/$$/cwd)" "resolves live pid cwd"
}

run_tests \
  test_display_renders_copilot_model_only \
  test_display_renders_copilot_usage \
  test_collect_no_db_is_empty_object \
  test_parse_context_is_always_empty \
  test_parse_shared_direct \
  test_live_cwds_resolves_pid_cwd
