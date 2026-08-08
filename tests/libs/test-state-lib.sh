#!/usr/bin/env bash
# state-lib.sh — the agent state store. The interface is verbs, so these tests
# assert stored state, not filenames; the layout tests below exist only to pin
# the on-disk names the live /tmp files already use.
DIR="$(cd "$(dirname "$0")" && pwd)" || exit 1
. "$DIR/../helpers.sh"
. "$DIR/../../libs/state-lib.sh"

export AGENT_TMP_DIR
AGENT_TMP_DIR=$(mktemp -d)
trap 'rm -rf "$AGENT_TMP_DIR"' EXIT

setup() { rm -f "$AGENT_TMP_DIR"/agent-*; }

test_put_get_roundtrip() {
  setup
  state_put RUNNING phase claude sess @1
  [ "$(state_get phase claude sess @1)" = RUNNING ]
}

test_get_missing_returns_1() {
  setup
  state_get phase claude sess @1 >/dev/null
  [ "$?" -eq 1 ]
}

test_put_multiline_roundtrip() {
  setup
  state_put "$(printf 'a\nb\nc')" shared claude
  [ "$(state_get shared claude)" = "$(printf 'a\nb\nc')" ]
}

# state_mark carries no value: exists is true, get prints nothing.
test_marker_exists_without_value() {
  setup
  state_mark cleared claude sess @1
  state_exists cleared claude sess @1 && assert_empty "$(state_get cleared claude sess @1)"
}

test_exists_false_when_absent() {
  setup
  ! state_exists cleared claude sess @1
}

test_clear_removes_entry() {
  setup
  state_put DONE phase claude sess @1
  state_clear phase claude sess @1
  ! state_exists phase claude sess @1
}

# A missing entry reads as "long ago", so callers can compare against a grace
# window without a separate existence check.
test_age_missing_is_huge() {
  setup
  [ "$(state_age 100 live claude sess @1)" -gt 100000 ]
}

test_age_counts_from_mtime() {
  setup
  state_mark live claude sess @1
  local now
  now=$(date +%s)
  [ "$(state_age "$now" live claude sess @1)" -le 1 ]
}

# Overwriting must be atomic — no window where a reader sees a partial value.
test_put_overwrites() {
  setup
  state_put RUNNING phase claude sess @1
  state_put IDLE phase claude sess @1
  [ "$(state_get phase claude sess @1)" = IDLE ] &&
    [ -z "$(ls "$AGENT_TMP_DIR"/*.tmp.* 2>/dev/null)" ]
}

test_agent_tmp_respects_env() { [ "$(_agent_tmp)" = "$AGENT_TMP_DIR" ]; }

# Every verb takes exactly the keys its kind has — a per-slot kind passes one
# key, a per-agent kind passes none, and neither pads a slot to reach the value
# or the clock behind it. The two shapes that used to need "" padding:
test_per_slot_kind_needs_no_padding() {
  setup
  state_put 4.20 cost claude weekly
  [ "$(state_get cost claude weekly)" = "4.20" ] &&
    [ "$(state_age "$(date +%s)" cost claude weekly)" -le 1 ]
}

test_per_agent_kind_needs_no_padding() {
  setup
  state_put LINE shared claude
  [ "$(state_get shared claude)" = "LINE" ] &&
    [ "$(state_age "$(date +%s)" shared claude)" -le 1 ]
}

test_kv_fill_reads_pairs() {
  local -A F
  kv_fill F <<<"$(printf 'session\t12.5\nmodel\tSonnet\n')"
  [ "${F[session]}" = "12.5" ] && [ "${F[model]}" = "Sonnet" ]
}

test_state_get_kv_roundtrip() {
  setup
  state_put "$(printf 'session\t12.5\nmodel\tSonnet\n')" shared claude
  local -A F
  state_get_kv F shared claude
  [ "${F[session]}" = "12.5" ] && [ "${F[model]}" = "Sonnet" ]
}

test_state_get_kv_missing_returns_1() {
  setup
  local -A F
  state_get_kv F shared claude
  [ "$?" -eq 1 ] && [ "${#F[@]}" -eq 0 ]
}

# ── Layout: the names the live status files already use ──────────────────────
test_layout_shared() { [ "$(_state_path shared faketest session-1 @42)" = "$AGENT_TMP_DIR/agent-shared-faketest-session-1-@42" ]; }
test_layout_ctx() { [ "$(_state_path ctx faketest session-1 @42)" = "$AGENT_TMP_DIR/agent-ctx-faketest-session-1-@42" ]; }
test_layout_phase() { [ "$(_state_path phase faketest sess @5)" = "$AGENT_TMP_DIR/agent-phase-faketest-sess-@5" ]; }
test_layout_cost() { [ "$(_state_path cost faketest WEEKLY)" = "$AGENT_TMP_DIR/agent-cost-weekly-faketest" ]; }
test_layout_ctx_defaults() { [ "$(_state_path ctx faketest)" = "$AGENT_TMP_DIR/agent-ctx-faketest-_-0" ]; }

run_tests \
  test_put_get_roundtrip \
  test_get_missing_returns_1 \
  test_put_multiline_roundtrip \
  test_marker_exists_without_value \
  test_exists_false_when_absent \
  test_clear_removes_entry \
  test_age_missing_is_huge \
  test_age_counts_from_mtime \
  test_put_overwrites \
  test_agent_tmp_respects_env \
  test_per_slot_kind_needs_no_padding \
  test_per_agent_kind_needs_no_padding \
  test_kv_fill_reads_pairs \
  test_state_get_kv_roundtrip \
  test_state_get_kv_missing_returns_1 \
  test_layout_shared \
  test_layout_ctx \
  test_layout_phase \
  test_layout_cost \
  test_layout_ctx_defaults
