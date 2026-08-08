#!/usr/bin/env bash
# adapter-claude.sh — Claude agent module. Covers claude_usage_rows (directly,
# and end-to-end through tmux-ctdl.sh agentbar), claude_refresh_costs (with the two cost
# commands stubbed) and claude_live_cwds (session probe).
DIR="$(cd "$(dirname "$0")" && pwd)" || exit 1
. "$DIR/../helpers.sh"
ADAPTER="$DIR/../../adapter"
# TMUX_CTDL_HOME points the boot module at the repo; TMUX_CTDL_CONF at a scratch
# conf naming the agent and nothing else — the palette defaults at the module
# that reads it, so a test never restates it. No HOME manipulation needed.
export TMUX_CTDL_HOME="$(cd "$DIR/../.." && pwd)"

# End-to-end: claude_format_usage renders Session/Weekly from the shared file.
test_display_renders_session_weekly() {
  local th; th=$(mktemp -d)
  echo "CODING_AGENT='claude'" > "$th/tmux-ctdl.conf"
  local tmp; tmp=$(mktemp -d)
  printf 'session\t45.5\nweekly\t22.7\nfive_reset\t9999999999\nweek_reset\t9999999999\nmodel\tSonnet\neffort\tnormal\n' \
    > "$tmp/agent-shared-claude-test-session-@1"
  local out
  out=$(TMUX_CTDL_CONF="$th/tmux-ctdl.conf" AGENT_TMP_DIR="$tmp" \
         bash "$TMUX_CTDL_HOME/tmux-ctdl.sh" agentbar test-session @1)
  rm -rf "$th" "$tmp"
  assert_contains "$out" "Claude: Sonnet" &&
  assert_contains "$out" "Session: 45.5%" &&
  assert_contains "$out" "Weekly: 22.7%"
}

# claude_parse_session: pure jq extraction, testable without real processes.
test_parse_session_extracts_pid_cwd() {
  . "$ADAPTER/adapter-claude.sh"
  local tmp; tmp=$(mktemp)
  printf '{"pid":12345,"cwd":"/home/user/project"}' > "$tmp"
  IFS=$'\t' read -r pid cwd <<< "$(claude_parse_session "$tmp")"
  rm -f "$tmp"
  [ "$pid" = "12345" ] && [ "$cwd" = "/home/user/project" ]
}

# claude_live_cwds: reads sessions_dir/*.json (injectable), prints cwd for live pids.
# Inject sessions_dir directly — no HOME manipulation needed.
test_live_cwds_prints_live_session_cwd() {
  . "$ADAPTER/adapter-claude.sh"
  local dir; dir=$(mktemp -d)
  printf '{"pid":%d,"cwd":"/home/user/project"}' "$$" > "$dir/s1.json"
  local out; out=$(claude_live_cwds "$dir")
  rm -rf "$dir"
  assert_contains "$out" "/home/user/project" "prints cwd of live session"
}

# A dead pid must be skipped (no output).
test_live_cwds_skips_dead_pid() {
  . "$ADAPTER/adapter-claude.sh"
  local dir; dir=$(mktemp -d)
  # pid 2^31-1: guaranteed not running.
  printf '{"pid":2147483647,"cwd":"/home/user/dead"}' > "$dir/s1.json"
  local out; out=$(claude_live_cwds "$dir")
  rm -rf "$dir"
  assert_empty "$out" "dead pid produces no cwd"
}

# claude_usage_rows: data only — no tmux style syntax may escape the module.
test_usage_rows_are_plain_data() {
  . "$ADAPTER/adapter-claude.sh"
  local tmp; tmp=$(mktemp -d)
  printf 'session\t45.5\nweekly\t22.7\nfive_reset\t9999999999\nweek_reset\t9999999999\n' \
    > "$tmp/agent-shared-claude-test-session-@1"
  local out; out=$(AGENT_TMP_DIR="$tmp" claude_usage_rows claude 0 test-session @1)
  rm -rf "$tmp"
  assert_contains "$out" "$(printf 'Session\t45.5\t⟳?:??')" "session row" &&
  assert_contains "$out" "$(printf 'Weekly\t22.7\t⟳?@?:??')" "weekly row" &&
  ! printf '%s' "$out" | grep -qF '#['
}

# A real five_reset renders the block clock and countdown into the suffix.
test_usage_rows_render_block_countdown() {
  . "$ADAPTER/adapter-claude.sh"
  local tmp; tmp=$(mktemp -d)
  local now=1700000000
  printf 'session\t10\nweekly\t5\nfive_reset\t%d\nweek_reset\t9999999999\n' "$(( now + 1800 ))" \
    > "$tmp/agent-shared-claude-test-session-@1"
  local out; out=$(AGENT_TMP_DIR="$tmp" claude_usage_rows claude "$now" test-session @1)
  rm -rf "$tmp"
  assert_contains "$out" "(in 30m)" "countdown under an hour is minutes"
}

# tokens is each row's OWN cached total — Session and Weekly differ, not one
# figure copied onto both.
test_usage_rows_show_distinct_tokens_per_row() {
  . "$ADAPTER/adapter-claude.sh"
  local tmp; tmp=$(mktemp -d)
  printf 'session\t45.5\nweekly\t22.7\nfive_reset\t9999999999\nweek_reset\t9999999999\n' \
    > "$tmp/agent-shared-claude-test-session-@1"
  printf '6488061\n' > "$tmp/agent-tokens-session-claude"
  printf '357025\n'  > "$tmp/agent-tokens-weekly-claude"
  local out; out=$(AGENT_TMP_DIR="$tmp" claude_usage_rows claude 0 test-session @1)
  rm -rf "$tmp"
  assert_contains "$out" "$(printf 'Session\t45.5\t⟳?:??\t-\tΣ6488k')" "session shows its own total" &&
  assert_contains "$out" "$(printf 'Weekly\t22.7\t⟳?@?:??\t-\tΣ357k')" "weekly shows its own, different total"
}

# No cached tokens yet → tokens field is empty, no crash, no "Σ0".
test_usage_rows_tokens_empty_without_cache() {
  . "$ADAPTER/adapter-claude.sh"
  local tmp; tmp=$(mktemp -d)
  printf 'session\t45.5\nweekly\t22.7\nfive_reset\t9999999999\nweek_reset\t9999999999\n' \
    > "$tmp/agent-shared-claude-test-session-@1"
  local out; out=$(AGENT_TMP_DIR="$tmp" claude_usage_rows claude 0 test-session @1)
  rm -rf "$tmp"
  ! printf '%s' "$out" | grep -qE 'Σ[0-9]'
}

# Never reported → no rows, non-zero, so the bar omits the segment entirely.
test_usage_rows_absent_returns_1() {
  . "$ADAPTER/adapter-claude.sh"
  local tmp; tmp=$(mktemp -d)
  local out; out=$(AGENT_TMP_DIR="$tmp" claude_usage_rows claude 0 test-session @1)
  local rc=$?
  rm -rf "$tmp"
  assert_empty "$out" && [ "$rc" -eq 1 ]
}

# claude_incoming_stale: a same-block session% that drops by a LOT (Claude
# Code's rare spike-correction bug: an erroneous ~100% self-corrected down to
# the real figure) must still be written. Regression for the bug where a bad
# early spike (e.g. 100%) permanently locked the display until the block
# reset, because used_percentage was wrongly treated as monotonic within a
# block.
test_incoming_stale_accepts_lower_session_same_block() {
  . "$ADAPTER/adapter-claude.sh"
  local tmp; tmp=$(mktemp -d)
  printf 'session\t100\nweekly\t37\nfive_reset\t1785726000\nweek_reset\t9999999999\n' \
    > "$tmp/agent-rate-claude"
  local incoming; incoming=$(printf 'session\t13\nweekly\t38\nfive_reset\t1785726000\nweek_reset\t9999999999\n')
  AGENT_TMP_DIR="$tmp" claude_incoming_stale claude "$incoming"
  local rc=$?
  rm -rf "$tmp"
  [ "$rc" -eq 1 ]
}

# A small same-block DROP is an idle window re-echoing its own stale cached
# reading, not a spike correction — must be rejected. Regression for the
# flicker bug: `rate` is account-wide now (one file, every window pushes into
# it), so a busy window's fresh 15% and an idle window's stale 8% otherwise
# fight over the same file every 5s tick, forever alternating the display.
test_incoming_stale_rejects_small_drop_same_block() {
  . "$ADAPTER/adapter-claude.sh"
  local tmp; tmp=$(mktemp -d)
  printf 'session\t15\nweekly\t37\nfive_reset\t1785726000\nweek_reset\t9999999999\n' \
    > "$tmp/agent-rate-claude"
  local incoming; incoming=$(printf 'session\t8\nweekly\t37\nfive_reset\t1785726000\nweek_reset\t9999999999\n')
  AGENT_TMP_DIR="$tmp" claude_incoming_stale claude "$incoming"
  local rc=$?
  rm -rf "$tmp"
  [ "$rc" -eq 0 ]
}

# An incoming event naming an OLDER rate-limit block (five_reset in the past
# relative to what's stored) is still correctly rejected as out-of-order.
# claude_parse_shared/claude_parse_context called directly in-process (the
# push-usage suite drives them too, but only through many rapid `bash
# tmux-ctdl.sh` subprocesses — belt and suspenders against losing a real path to
# that indirection).
test_parse_shared_direct() {
  . "$ADAPTER/adapter-claude.sh"
  local out; out=$(cat "$FIXTURES/claude-status-safe.json" | claude_parse_shared)
  assert_contains "$out" "$(printf 'session\t30')" "session parsed directly"
}

test_parse_context_direct() {
  . "$ADAPTER/adapter-claude.sh"
  local out; out=$(cat "$FIXTURES/claude-status-safe.json" | claude_parse_context)
  assert_contains "$out" "$(printf 'ctx\t25')" "context parsed directly"
}

# claude_cost_weekly/claude_cost_session shell out to `npm exec ccusage`.
# Real command, fake binary (tests/fixtures/npm) — exercises the actual
# invocation and jq parse rather than stubbing the functions away.
test_cost_weekly_parses_npm_ccusage() {
  . "$ADAPTER/adapter-claude.sh"
  local out; out=$(PATH="$DIR/../fixtures:$PATH" claude_cost_weekly)
  assert_contains "$out" "$(printf '2\t1500')" "sums daily cost and tokens from ccusage json"
}

test_cost_session_parses_npm_ccusage() {
  . "$ADAPTER/adapter-claude.sh"
  local out; out=$(PATH="$DIR/../fixtures:$PATH" claude_cost_session)
  assert_contains "$out" "$(printf '0.25\t200')" "reads the last block's cost and tokens"
}

test_incoming_stale_rejects_older_block() {
  . "$ADAPTER/adapter-claude.sh"
  local tmp; tmp=$(mktemp -d)
  printf 'session\t50\nweekly\t37\nfive_reset\t1785726000\nweek_reset\t9999999999\n' \
    > "$tmp/agent-rate-claude"
  local incoming; incoming=$(printf 'session\t90\nweekly\t37\nfive_reset\t1785700000\nweek_reset\t9999999999\n')
  AGENT_TMP_DIR="$tmp" claude_incoming_stale claude "$incoming"
  local rc=$?
  rm -rf "$tmp"
  [ "$rc" -eq 0 ]
}

# claude_refresh_costs: both slots cache cost AND tokens, keyed by slot name.
# The two cost commands are stubbed (cost<TAB>tokens) — the real ones shell
# out to ccusage.
test_refresh_costs_caches_both_slots() {
  . "$ADAPTER/adapter-claude.sh"
  local tmp; tmp=$(mktemp -d)
  claude_cost_weekly()  { printf '4.20\t357025\n'; }
  claude_cost_session() { printf '0.70\t6488061\n'; }
  AGENT_TMP_DIR="$tmp" USAGE_REFRESH=0 claude_refresh_costs claude
  wait
  local weekly session weekly_tok session_tok
  read -r weekly      < "$tmp/agent-cost-weekly-claude"
  read -r session     < "$tmp/agent-cost-session-claude"
  read -r weekly_tok  < "$tmp/agent-tokens-weekly-claude"
  read -r session_tok < "$tmp/agent-tokens-session-claude"
  rm -rf "$tmp"
  assert_contains "$weekly" "4.20" "weekly cost cached" &&
  assert_contains "$session" "0.70" "session cost cached" &&
  assert_contains "$weekly_tok" "357025" "weekly tokens cached" &&
  assert_contains "$session_tok" "6488061" "session tokens cached"
}

# A cache fresher than USAGE_REFRESH is left alone — no command runs.
test_refresh_costs_skips_fresh_cache() {
  . "$ADAPTER/adapter-claude.sh"
  local tmp; tmp=$(mktemp -d)
  echo "STALE" > "$tmp/agent-cost-weekly-claude"
  echo "STALE" > "$tmp/agent-tokens-weekly-claude"
  echo "STALE" > "$tmp/agent-cost-session-claude"
  claude_cost_weekly()  { printf 'NEW\t1\n'; }
  claude_cost_session() { printf 'NEW\t1\n'; }
  AGENT_TMP_DIR="$tmp" USAGE_REFRESH=1h claude_refresh_costs claude
  wait
  local weekly weekly_tok
  read -r weekly     < "$tmp/agent-cost-weekly-claude"
  read -r weekly_tok < "$tmp/agent-tokens-weekly-claude"
  rm -rf "$tmp"
  assert_contains "$weekly" "STALE" "fresh cost not refreshed" &&
  assert_contains "$weekly_tok" "STALE" "fresh tokens not refreshed"
}

run_tests \
  test_display_renders_session_weekly \
  test_incoming_stale_accepts_lower_session_same_block \
  test_incoming_stale_rejects_small_drop_same_block \
  test_incoming_stale_rejects_older_block \
  test_parse_shared_direct \
  test_parse_context_direct \
  test_cost_weekly_parses_npm_ccusage \
  test_cost_session_parses_npm_ccusage \
  test_usage_rows_are_plain_data \
  test_usage_rows_render_block_countdown \
  test_usage_rows_show_distinct_tokens_per_row \
  test_usage_rows_tokens_empty_without_cache \
  test_usage_rows_absent_returns_1 \
  test_refresh_costs_caches_both_slots \
  test_refresh_costs_skips_fresh_cache \
  test_parse_session_extracts_pid_cwd \
  test_live_cwds_prints_live_session_cwd \
  test_live_cwds_skips_dead_pid
