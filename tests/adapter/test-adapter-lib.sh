#!/usr/bin/env bash
# adapter-lib.sh — the shared, agent-agnostic machinery. Sourced directly and
# driven with stub `faketest_*` hooks (no real adapter): every verb takes the
# agent as an argument and the payload on stdin, so nothing here has to stage a
# global first. Covers _agent_tmp, write_shared (incl the incoming_stale hook),
# write_ctx (incl no-pane), adapter_main (incl the optional refresh_costs hook)
# and usage_refresh_secs.
DIR="$(cd "$(dirname "$0")" && pwd)" || exit 1
. "$DIR/../helpers.sh"
export TMUX_CTDL_HOME="$(cd "$DIR/../.." && pwd)"
LIB="$DIR/../../adapter/adapter-lib.sh"

export AGENT_TMP_DIR
AGENT_TMP_DIR=$(mktemp -d)
trap 'rm -rf "$AGENT_TMP_DIR"' EXIT

. "$LIB"

setup() {
  rm -f "$AGENT_TMP_DIR"/agent-shared-* "$AGENT_TMP_DIR"/agent-ctx-* "$AGENT_TMP_DIR"/agent-cost-* "$AGENT_TMP_DIR"/agent-rate-*
  rm -f "$AGENT_TMP_DIR"/collected
  unset -f faketest_incoming_stale faketest_collect 2>/dev/null
  export PATH="$FIXTURES:$PATH"
  export MOCK_SESSION=test-session MOCK_WIN=@1
}

test_agent_tmp_respects_env() {
  setup
  [ "$(_agent_tmp)" = "$AGENT_TMP_DIR" ]
}

# write_shared stores exactly the kv content it's handed — no reordering.
test_write_shared_layout() {
  setup
  export TMUX_PANE=mock-pane
  write_shared faketest "$(printf 'session\t12.5\nmodel\tSonnet\neffort\thigh')"
  assert_file_exists "$AGENT_TMP_DIR/agent-shared-faketest-test-session-@1" &&
    local -A F
  kv_fill F <"$AGENT_TMP_DIR/agent-shared-faketest-test-session-@1"
  assert_contains "${F[session]}" "12.5" "session field" &&
    assert_contains "${F[model]}" "Sonnet" "model field" &&
    assert_contains "${F[effort]}" "high" "effort field"
}

# write_rate is the one with the incoming_stale hook (account-wide, no
# window) — a hook returning true (stale) must skip the overwrite.
test_write_rate_stale_hook_skips() {
  setup
  faketest_incoming_stale() { return 0; }
  printf 'session\tOLD\n' >"$AGENT_TMP_DIR/agent-rate-faketest"
  write_rate faketest "$(printf 'session\tNEW\n')"
  local -A F
  kv_fill F <"$AGENT_TMP_DIR/agent-rate-faketest"
  unset -f faketest_incoming_stale
  assert_contains "${F[session]}" "OLD" "stale hook prevented overwrite"
}

# No hook declared → write_rate falls through to the plain overwrite.
test_write_rate_no_hook_writes_normally() {
  setup
  write_rate faketest "$(printf 'session\tNEW\n')"
  local -A F
  kv_fill F <"$AGENT_TMP_DIR/agent-rate-faketest"
  assert_contains "${F[session]}" "NEW" "no hook → state written"
}

# write_shared needs a resolvable pane too — same "nowhere" rule as write_ctx.
test_write_shared_no_pane_skips() {
  setup
  unset TMUX_PANE
  write_shared faketest "$(printf 'session\t12.5\n')"
  [ -z "$(ls "$AGENT_TMP_DIR"/agent-shared-* 2>/dev/null)" ]
}

test_write_ctx_no_pane_skips() {
  setup
  unset TMUX_PANE
  write_ctx faketest "$(printf 'ctx\t25\n')" Sonnet normal
  [ -z "$(ls "$AGENT_TMP_DIR"/agent-ctx-* 2>/dev/null)" ]
}

test_write_ctx_writes_file() {
  setup
  export TMUX_PANE=mock-pane
  write_ctx faketest "$(printf 'ctx\t25\n')" Sonnet normal
  assert_file_exists "$AGENT_TMP_DIR/agent-ctx-faketest-test-session-@1" &&
    local -A C
  kv_fill C <"$AGENT_TMP_DIR/agent-ctx-faketest-test-session-@1"
  assert_contains "${C[ctx]}" "25" "ctx% written" &&
    assert_contains "${C[model]}" "Sonnet" "model appended" &&
    assert_contains "${C[effort]}" "normal" "effort appended"
}

# A pane that tmux can't resolve is "nowhere" too — write nothing rather than a
# file keyed on the empty session and window (_state_path's :- defaults would
# name it agent-ctx-faketest-_-0, which no reader ever asks for).
test_write_ctx_unresolvable_pane_skips() {
  setup
  export TMUX_PANE=mock-pane
  PATH=/nonexistent-for-adapter-lib-test write_ctx faketest "$(printf 'ctx\t25\n')" Sonnet normal
  [ -z "$(ls "$AGENT_TMP_DIR"/agent-ctx-* 2>/dev/null)" ]
}

# adapter_main drives <agent>_parse_shared/parse_context → splits rate keys
# (session, account-wide) from model/effort (per-window) into their own files.
test_adapter_main_writes_from_parsers() {
  setup
  export TMUX_PANE=mock-pane
  faketest_parse_shared() { printf 'session\t33.3\nmodel\tOpus\neffort\thigh\n'; }
  faketest_parse_context() { :; }
  adapter_main faketest </dev/null
  unset -f faketest_parse_shared faketest_parse_context
  assert_file_exists "$AGENT_TMP_DIR/agent-rate-faketest" &&
    local -A F
  kv_fill F <"$AGENT_TMP_DIR/agent-rate-faketest"
  assert_contains "${F[session]}" "33.3" "adapter_main wrote usage" &&
    local -A S
  kv_fill S <"$AGENT_TMP_DIR/agent-shared-faketest-test-session-@1"
  assert_contains "${S[model]}" "Opus" "adapter_main wrote model per-window"
}

# kv_fill round-trips write_shared: any key/value stored comes back out.
test_kv_fill_roundtrip() {
  setup
  export TMUX_PANE=mock-pane
  write_shared faketest "$(printf 'session\t12.5\nweekly\t20.1\nmodel\tSonnet\neffort\thigh\n')"
  local -A F
  kv_fill F <"$AGENT_TMP_DIR/agent-shared-faketest-test-session-@1"
  [ "${F[session]}" = "12.5" ] && [ "${F[weekly]}" = "20.1" ] &&
    [ "${F[model]}" = "Sonnet" ] && [ "${F[effort]}" = "high" ]
}

# adapter_main calls <agent>_refresh_costs when the agent defines it.
test_adapter_main_calls_refresh_hook() {
  setup
  unset TMUX_PANE
  faketest_parse_shared() { printf 'session\t1\n'; }
  faketest_parse_context() { :; }
  faketest_refresh_costs() { : >"$AGENT_TMP_DIR/refreshed"; }
  adapter_main faketest </dev/null
  unset -f faketest_parse_shared faketest_parse_context faketest_refresh_costs
  assert_file_exists "$AGENT_TMP_DIR/refreshed"
}

# An agent with no cost hook (copilot's case) still succeeds, silently.
test_adapter_main_without_refresh_hook_is_silent() {
  setup
  unset TMUX_PANE
  faketest_parse_shared() { printf 'session\t1\n'; }
  faketest_parse_context() { :; }
  local out
  out=$(adapter_main faketest </dev/null 2>&1)
  local rc=$?
  unset -f faketest_parse_shared faketest_parse_context
  assert_empty "$out" "no cost hook → nothing said" && [ "$rc" -eq 0 ]
}

# interval_secs (USAGE_REFRESH's parser) accepts seconds, minutes, hours —
# with or without an explicit unit.
test_usage_refresh_secs_units() {
  [ "$(USAGE_REFRESH=90 usage_refresh_secs)" = 90 ] &&
    [ "$(USAGE_REFRESH=30s usage_refresh_secs)" = 30 ] &&
    [ "$(USAGE_REFRESH=1m usage_refresh_secs)" = 60 ] &&
    [ "$(USAGE_REFRESH=2h usage_refresh_secs)" = 7200 ]
}

# since/until_at — one ladder, two directions. Asserted directly rather than
# through a rendered row: the clock is an argument, so both the countdown and
# the already-reached case are reachable without waiting for one.
test_since_seconds_rung() { [ "$(since 42)" = "42s ago" ]; }
test_since_minutes_rung() { [ "$(since 2520)" = "42m ago" ]; }
test_since_hours_keep_decimal() { [ "$(since 11520)" = "3.2h ago" ]; }

test_until_at_minutes_rung() { [ "$(until_at 1700002520 1700000000)" = "in 42m" ]; }
test_until_at_hours_keep_decimal() { [ "$(until_at 1700005400 1700000000)" = "in 1.5h" ]; }

# Under a minute the countdown counts seconds — it used to floor to "in 0m",
# which is the last thing shown before a block resets.
test_until_at_final_minute_counts_seconds() {
  [ "$(until_at 1700000042 1700000000)" = "in 42s" ]
}

# A target already reached reads "now", not a countdown past zero.
test_until_at_reached_reads_now() { [ "$(until_at 1700000000 1700000000)" = "now" ]; }
test_until_at_overdue_reads_now() { [ "$(until_at 1699999000 1700000000)" = "now" ]; }

test_get_agent_usage_fills_vars() {
  setup
  export TMUX_PANE=mock-pane
  write_shared faketest "$(printf 'session\t12.5\nmodel\tSonnet\neffort\thigh\n')"
  local -A F
  get_agent_usage F faketest test-session @1
  [ "${F[session]}" = "12.5" ] && [ "${F[model]}" = "Sonnet" ] && [ "${F[effort]}" = "high" ]
}

# get_agent_usage also merges the account-wide rate store (not just shared).
test_get_agent_usage_fills_from_rate() {
  setup
  write_rate faketest "$(printf 'five_reset\t123\n')"
  local -A F
  get_agent_usage F faketest test-session @1
  [ "${F[five_reset]}" = "123" ]
}

test_get_agent_usage_missing_returns_1() {
  setup
  local -A F
  get_agent_usage F faketest test-session @1
  [ "$?" -eq 1 ]
}

test_get_agent_context_fills_vars() {
  setup
  export TMUX_PANE=mock-pane
  write_ctx faketest "$(printf 'ctx\t25\n')" Sonnet normal
  local -A C
  get_agent_context C faketest test-session @1
  [ "${C[ctx]}" = "25" ] && [ "${C[model]}" = "Sonnet" ]
}

test_get_agent_context_missing_returns_1() {
  setup
  local -A C
  get_agent_context C faketest nosess @0
  [ "$?" -eq 1 ]
}

# ── Usage verbs ──────────────────────────────────────────────────────────────
# <now> is a parameter, so the rate limit is asserted by arithmetic instead of
# by sleeping — the state file's mtime is real, the clock handed in is not.

# push takes whatever arrives on stdin and runs the pipeline. No rate limit.
# session is a rate key (account-wide) — lands in agent-rate-faketest.
test_push_usage_reads_stdin() {
  setup
  export TMUX_PANE=mock-pane
  faketest_parse_shared() { printf 'session\t%s\n' "$(cat)"; }
  faketest_parse_context() { :; }
  adapter_push_usage faketest <<<"77.7"
  unset -f faketest_parse_shared faketest_parse_context
  local -A F
  kv_fill F <"$AGENT_TMP_DIR/agent-rate-faketest"
  assert_contains "${F[session]}" "77.7" "push parsed the stdin payload"
}

# A push-based agent defines no _collect — pull must be a silent no-op for it,
# not an error, because the wintab tick calls it every second regardless.
test_pull_usage_without_collect_is_noop() {
  setup
  export TMUX_PANE=mock-pane
  local out
  out=$(adapter_pull_usage faketest "$(date +%s)" 2>&1)
  assert_empty "$out" "no collect hook → nothing said" &&
    [ ! -f "$AGENT_TMP_DIR/agent-shared-faketest-test-session-@1" ]
}

test_pull_usage_collects_and_writes() {
  setup
  export TMUX_PANE=mock-pane
  faketest_collect() { printf '41.5'; }
  faketest_parse_shared() { printf 'session\t%s\n' "$(cat)"; }
  faketest_parse_context() { :; }
  USAGE_REFRESH=0 adapter_pull_usage faketest "$(date +%s)"
  unset -f faketest_collect faketest_parse_shared faketest_parse_context
  local -A F
  kv_fill F <"$AGENT_TMP_DIR/agent-rate-faketest"
  assert_contains "${F[session]}" "41.5" "pull wrote what collect printed"
}

# A stored read younger than USAGE_REFRESH blocks the collect entirely — the
# expensive query is the thing being rate-limited, not just the write. Gated
# on `rate` (account-wide), not the per-window shared file.
test_pull_usage_rate_limit_skips_collect() {
  setup
  export TMUX_PANE=mock-pane
  printf 'session\tOLD\n' >"$AGENT_TMP_DIR/agent-rate-faketest"
  faketest_collect() {
    : >"$AGENT_TMP_DIR/collected"
    printf 'NEW'
  }
  faketest_parse_shared() { printf 'session\t%s\n' "$(cat)"; }
  faketest_parse_context() { :; }
  USAGE_REFRESH=1h adapter_pull_usage faketest "$(date +%s)"
  unset -f faketest_collect faketest_parse_shared faketest_parse_context
  local -A F
  kv_fill F <"$AGENT_TMP_DIR/agent-rate-faketest"
  assert_contains "${F[session]}" "OLD" "fresh state held" &&
    [ ! -f "$AGENT_TMP_DIR/collected" ]
}

# Same state, a <now> an hour in the future: the interval has elapsed, so the
# collect runs. Pins that the limit is age-vs-interval, not "never re-query".
test_pull_usage_refreshes_once_interval_elapsed() {
  setup
  export TMUX_PANE=mock-pane
  printf 'session\tOLD\n' >"$AGENT_TMP_DIR/agent-rate-faketest"
  faketest_collect() { printf 'NEW'; }
  faketest_parse_shared() { printf 'session\t%s\n' "$(cat)"; }
  faketest_parse_context() { :; }
  USAGE_REFRESH=1m adapter_pull_usage faketest "$(($(date +%s) + 3600))"
  unset -f faketest_collect faketest_parse_shared faketest_parse_context
  local -A F
  kv_fill F <"$AGENT_TMP_DIR/agent-rate-faketest"
  assert_contains "${F[session]}" "NEW" "stale state re-collected"
}

run_tests \
  test_agent_tmp_respects_env \
  test_write_shared_layout \
  test_write_rate_stale_hook_skips \
  test_write_rate_no_hook_writes_normally \
  test_write_ctx_no_pane_skips \
  test_write_ctx_writes_file \
  test_write_ctx_unresolvable_pane_skips \
  test_kv_fill_roundtrip \
  test_adapter_main_writes_from_parsers \
  test_adapter_main_calls_refresh_hook \
  test_adapter_main_without_refresh_hook_is_silent \
  test_usage_refresh_secs_units \
  test_since_seconds_rung \
  test_since_minutes_rung \
  test_since_hours_keep_decimal \
  test_until_at_minutes_rung \
  test_until_at_hours_keep_decimal \
  test_until_at_final_minute_counts_seconds \
  test_until_at_reached_reads_now \
  test_until_at_overdue_reads_now \
  test_get_agent_usage_fills_vars \
  test_get_agent_usage_fills_from_rate \
  test_get_agent_usage_missing_returns_1 \
  test_get_agent_context_fills_vars \
  test_get_agent_context_missing_returns_1 \
  test_push_usage_reads_stdin \
  test_pull_usage_without_collect_is_noop \
  test_pull_usage_collects_and_writes \
  test_pull_usage_rate_limit_skips_collect \
  test_pull_usage_refreshes_once_interval_elapsed
