#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")" && pwd)" || exit 1
. "$DIR/../helpers.sh"
. "$DIR/../../libs/state-lib.sh"
SCRIPTS="$DIR/../.."

# TMUX_CTDL_HOME points the boot module at the repo; TMUX_CTDL_CONF pins
# CODING_AGENT=claude regardless of the live tmux-ctdl.conf's setting.
export TMUX_CTDL_HOME="$(cd "$DIR/../.." && pwd)"
CONF_DIR=$(mktemp -d)
cat > "$CONF_DIR/tmux-ctdl.conf" << CONF
CODING_AGENT="claude"
CONF
export TMUX_CTDL_CONF="$CONF_DIR/tmux-ctdl.conf"

# Scratch state dir so a test run never clobbers the live /tmp status files.
export AGENT_TMP_DIR
AGENT_TMP_DIR=$(mktemp -d)
trap 'rm -rf "$AGENT_TMP_DIR" "$CONF_DIR"' EXIT

RATE_FILE="$AGENT_TMP_DIR/agent-rate-claude"
SHARED_FILE="$AGENT_TMP_DIR/agent-shared-claude-test-session-@1"

setup() {
  rm -f "$RATE_FILE" "$SHARED_FILE" "$AGENT_TMP_DIR"/agent-ctx-claude-* /tmp/mock-tmux-calls
  export TMUX_PANE=mock-pane
  export PATH="$FIXTURES:$PATH"
  export MOCK_SESSION=test-session MOCK_WIN=@1
}

test_parses_safe_fixture() {
  setup
  cat "$FIXTURES/claude-status-safe.json" | bash "$SCRIPTS/tmux-ctdl.sh" agent-push-usage
  assert_file_exists "$RATE_FILE" &&
  local -A F; kv_fill F < "$RATE_FILE"
  assert_contains "${F[session]}" "30" "parses session %" &&
  local -A S; kv_fill S < "$SHARED_FILE"
  assert_contains "${S[model]}" "Sonnet" "parses model" &&
  assert_contains "${S[effort]}" "normal" "parses effort" &&
  assert_file_exists "$AGENT_TMP_DIR/agent-ctx-claude-test-session-@1" &&
  local -A C; kv_fill C < "$AGENT_TMP_DIR/agent-ctx-claude-test-session-@1"
  assert_contains "${C[ctx]}" "25" "parses context %"
}

test_parses_crit_fixture() {
  setup
  cat "$FIXTURES/claude-status-crit.json" | bash "$SCRIPTS/tmux-ctdl.sh" agent-push-usage
  assert_file_exists "$RATE_FILE" &&
  local -A F; kv_fill F < "$RATE_FILE"
  assert_contains "${F[session]}" "95" "parses crit session %" &&
  local -A S; kv_fill S < "$SHARED_FILE"
  assert_contains "${S[model]}" "Opus" "parses Opus model" &&
  assert_file_exists "$AGENT_TMP_DIR/agent-ctx-claude-test-session-@1" &&
  local -A C; kv_fill C < "$AGENT_TMP_DIR/agent-ctx-claude-test-session-@1"
  assert_contains "${C[ctx]}" "85" "parses crit context %"
}

test_writes_rate_file() {
  setup
  cat "$FIXTURES/claude-status-safe.json" | bash "$SCRIPTS/tmux-ctdl.sh" agent-push-usage
  assert_file_exists "$RATE_FILE" &&
  local -A F; kv_fill F < "$RATE_FILE"
  assert_contains "${F[session]}" "30" "rate file has session %"
}

test_writes_ctx_file() {
  setup
  cat "$FIXTURES/claude-status-safe.json" | bash "$SCRIPTS/tmux-ctdl.sh" agent-push-usage
  assert_file_exists "$AGENT_TMP_DIR/agent-ctx-claude-test-session-@1" &&
  local -A C; kv_fill C < "$AGENT_TMP_DIR/agent-ctx-claude-test-session-@1"
  assert_contains "${C[ctx]}" "25" "ctx file has context %"
}

# model/effort land under those keys, in the per-window shared file — not the
# per-agent rate file — findable regardless of line order.
test_model_effort_are_keyed() {
  setup
  cat "$FIXTURES/claude-status-safe.json" | bash "$SCRIPTS/tmux-ctdl.sh" agent-push-usage
  local -A S; kv_fill S < "$SHARED_FILE"
  assert_contains "${S[model]}" "Sonnet" "model keyed" &&
  assert_contains "${S[effort]}" "normal" "effort keyed"
}

# Real caller (Claude Code's statusLine hook) redirects stdin from a regular
# file, not a pipe — `<` here reproduces that, unlike every `cat | tmux-ctdl.sh`
# case above which is a true FIFO and would miss a stdin-detection regression.
test_reads_input_from_redirected_file() {
  setup
  bash "$SCRIPTS/tmux-ctdl.sh" agent-push-usage < "$FIXTURES/claude-status-safe.json"
  assert_file_exists "$RATE_FILE" &&
  local -A F; kv_fill F < "$RATE_FILE"
  assert_contains "${F[session]}" "30" "redirected-file stdin still parses session %"
}

test_silent_on_empty_input() {
  setup
  echo '{}' | bash "$SCRIPTS/tmux-ctdl.sh" agent-push-usage
  [ ! -f "$RATE_FILE" ] && [ ! -f "$SHARED_FILE" ]
}

test_null_resets_at_writes_sentinel() {
  setup
  cat "$FIXTURES/claude-status-null-resets.json" | bash "$SCRIPTS/tmux-ctdl.sh" agent-push-usage
  assert_file_exists "$RATE_FILE"
  local -A F; kv_fill F < "$RATE_FILE"
  assert_contains "${F[five_reset]}" "9999999999" "null resets_at becomes sentinel"
}

test_real_resets_overwrite_sentinel() {
  setup
  # pre-seed with sentinel so the incoming_stale guard is exercised
  printf 'session\t30.5\nweekly\t20.1\nfive_reset\t9999999999\nweek_reset\t9999999999\n' \
    > "$RATE_FILE"
  cat "$FIXTURES/claude-status-real-resets.json" | bash "$SCRIPTS/tmux-ctdl.sh" agent-push-usage
  local -A F; kv_fill F < "$RATE_FILE"
  assert_contains "${F[five_reset]}" "1737100000" "real resets_at overwrites sentinel"
}

# Older incoming data (five_reset in the past vs on disk) must NOT overwrite.
test_stale_incoming_does_not_overwrite() {
  setup
  printf 'session\t30.5\nweekly\t20.1\nfive_reset\t1737100000\nweek_reset\t1737200000\n' \
    > "$RATE_FILE"
  local older; older='{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":1737000000},"seven_day":{"used_percentage":5,"resets_at":1737200000}},"model":{"display_name":"Sonnet"},"effort":{"level":"normal"}}'
  printf '%s' "$older" | bash "$SCRIPTS/tmux-ctdl.sh" agent-push-usage
  local -A F; kv_fill F < "$RATE_FILE"
  assert_contains "${F[five_reset]}" "1737100000" "stale incoming (older five_reset) kept old"
}

run_tests \
  test_parses_safe_fixture \
  test_parses_crit_fixture \
  test_writes_rate_file \
  test_writes_ctx_file \
  test_model_effort_are_keyed \
  test_reads_input_from_redirected_file \
  test_silent_on_empty_input \
  test_null_resets_at_writes_sentinel \
  test_real_resets_overwrite_sentinel \
  test_stale_incoming_does_not_overwrite
