#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")" && pwd)" || exit 1
. "$DIR/../helpers.sh"
SCRIPTS="$DIR/../.."
export TMUX_CTDL_HOME="$SCRIPTS"
CONF_DIR=$(mktemp -d)
cat >"$CONF_DIR/tmux-ctdl.conf" <<CONF
CODING_AGENT="claude"
CONF
export TMUX_CTDL_CONF="$CONF_DIR/tmux-ctdl.conf"

export AGENT_TMP_DIR
AGENT_TMP_DIR=$(mktemp -d)
trap 'rm -rf "$AGENT_TMP_DIR" "$CONF_DIR"' EXIT

setup() {
  rm -f "${AGENT_TMP_DIR}/agent-shared-claude-"* "${AGENT_TMP_DIR}/agent-ctx-claude-"*
}

seed_shared() {
  printf 'session\t%s\nweekly\t%s\nfive_reset\t9999999999\nweek_reset\t9999999999\nmodel\t%s\neffort\t%s\n' \
    "${1:-30.5}" "${2:-20.1}" "Sonnet" "normal" \
    >"${AGENT_TMP_DIR}/agent-shared-claude-test-session-@1"
}

# render_ctx is pure now (no state read) — build the array by hand instead of
# seeding a file.
ctx_out() {
  local pct=$1 used=${2:-0} max=${3:-0}
  (
    . "$SCRIPTS/agentbar/agentbar-lib.sh"
    local -A C=([ctx]="$pct" [ctx_used]="$used" [ctx_max]="$max")
    render_ctx C 0
  )
}

test_silent_without_shared_file() {
  setup
  local out
  out=$(bash "$SCRIPTS/tmux-ctdl.sh" agentbar test-session @1)
  assert_empty "$out"
}

test_shows_session_pct() {
  setup
  seed_shared 45.5
  local out
  out=$(bash "$SCRIPTS/tmux-ctdl.sh" agentbar test-session @1)
  assert_contains "$out" "Session: 45.5%"
}

test_shows_weekly_pct() {
  setup
  seed_shared 30 22.7
  local out
  out=$(bash "$SCRIPTS/tmux-ctdl.sh" agentbar test-session @1)
  assert_contains "$out" "Weekly: 22.7%"
}

test_shows_agent_label() {
  setup
  seed_shared
  local out
  out=$(bash "$SCRIPTS/tmux-ctdl.sh" agentbar test-session @1)
  assert_contains "$out" "Claude:"
}

# The verb hands tmux exactly what agentbar-lib painted — the router neither
# adds nor strips style codes. (There used to be a --plain flag here that
# stripped them, used by nothing but these tests; the assertions below match
# substrings, so the styled string serves them directly.)
test_render_carries_style_codes() {
  setup
  seed_shared
  local out
  out=$(bash "$SCRIPTS/tmux-ctdl.sh" agentbar test-session @1)
  assert_contains "$out" '#[' "style codes reach tmux unmangled"
}

test_reset_times_unknown_sentinel() {
  setup
  seed_shared
  local out
  out=$(bash "$SCRIPTS/tmux-ctdl.sh" agentbar test-session @1)
  assert_contains "$out" '⟳?:??'
  assert_contains "$out" '?@?:??'
}

test_weekly_cost_unknown_shows_nothing() {
  setup
  seed_shared
  # non-numeric content → show nothing, not $?.??
  echo ";unknown" >${AGENT_TMP_DIR}/agent-cost-weekly-claude
  local out
  out=$(bash "$SCRIPTS/tmux-ctdl.sh" agentbar test-session @1)
  rm -f ${AGENT_TMP_DIR}/agent-cost-weekly-claude
  ! printf '%s' "$out" | grep -qF '$?'
}

test_weekly_cost_numeric_shows_value() {
  setup
  seed_shared
  echo "3.14" >${AGENT_TMP_DIR}/agent-cost-weekly-claude
  local out
  out=$(bash "$SCRIPTS/tmux-ctdl.sh" agentbar test-session @1)
  rm -f ${AGENT_TMP_DIR}/agent-cost-weekly-claude
  assert_contains "$out" '$3.14'
}

# A window with live context data overrides the shared model/effort with its
# own — this is the per-window fact write_ctx exists to carry.
test_context_model_overrides_shared() {
  setup
  seed_shared
  printf 'model\tOpus\neffort\tultrahigh\nctx\t10\n' \
    >"${AGENT_TMP_DIR}/agent-ctx-claude-test-session-@1"
  local out
  out=$(bash "$SCRIPTS/tmux-ctdl.sh" agentbar test-session @1)
  rm -f "${AGENT_TMP_DIR}/agent-ctx-claude-test-session-@1"
  assert_contains "$out" "Opus"
}

# paint: the three maps over the same ladder. Blink is a parameter here, which is
# what makes both frames assertable. Colours and thresholds are the module's own
# defaults — nothing is sourced from a conf, so these assertions describe the
# code rather than whatever palette the machine running them happens to have.
# paint is the module's only public styling verb, so tier/threshold facts are
# asserted through it, not through the internal classifiers it folds in.
p() { (
  . "$SCRIPTS/agentbar/agentbar-lib.sh"
  paint "$1" "$2" "${3:-0}"
); }

# The conf overrides those defaults, and only where it names one.
test_paint_conf_overrides_default_colour() {
  local out
  out=$(
    . "$SCRIPTS/agentbar/agentbar-lib.sh"
    COLOR_SAFE_BG='#010203' paint PILL 20 0
  )
  [ "$out" = '#[bg=#010203,fg=#77dd77]' ]
}

test_paint_conf_overrides_default_threshold() {
  local out
  out=$(
    . "$SCRIPTS/agentbar/agentbar-lib.sh"
    THRESHOLD_CRITICAL=20 paint PILL 20 1
  )
  [ "$out" = '#[bg=#8b0000,fg=#ffffff,bold]' ]
}

test_paint_pill_safe_paints_background() { [ "$(p PILL 20 0)" = '#[bg=#1a3320,fg=#77dd77]' ]; }
test_paint_pill_dim_paints_background() { [ "$(p PILL 0 0)" = '#[bg=#333333,fg=#aaaaaa]' ]; }
test_paint_pill_notice_is_bold() { [ "$(p PILL 50 0)" = '#[bg=#3d2200,fg=#ffb347,bold]' ]; }
test_paint_pill_alarm_blink_on_fills() { [ "$(p PILL 95 1)" = '#[bg=#8b0000,fg=#ffffff,bold]' ]; }
test_paint_pill_alarm_blink_off_empties() { [ "$(p PILL 95 0)" = '#[bg=default,fg=#ffffff,bold]' ]; }
test_paint_ctx_text_never_paints_bg() { [ "$(p CTX_TEXT 50 0)" = '#[fg=#ffb347,bold]' ]; }
test_paint_ctx_text_alarm_calm_is_dim() { [ "$(p CTX_TEXT 85 0)" = '#[fg=#aaaaaa,bold]' ]; }
test_paint_ctx_bar_alarm_blink_is_white() { [ "$(p CTX_BAR 85 1)" = '#[bg=#8b0000,fg=white]' ]; }
test_paint_ctx_bar_calm_is_fg_only() { [ "$(p CTX_BAR 50 0)" = '#[fg=#ffb347]' ]; }

# Threshold boundaries, at the module's default values (RATE:
# 90/75/50/10, CTX: 80/65/40/1) — what tier_of/ladder_tier used to be tested
# for directly, now asserted through the rendered style so a wrong escape in
# paint's matrix fails these too. Also closes cells no other test hits:
# CTX_TEXT's ALARM_ON/PLAIN, CTX_BAR's WARN alarm and SAFE floor.
test_paint_pill_critical_boundary() { [ "$(p PILL 90 1)" = '#[bg=#8b0000,fg=#ffffff,bold]' ]; }
test_paint_pill_warn_boundary() { [ "$(p PILL 75 1)" = '#[bg=#7a1a1a,fg=#ff8c42,bold]' ]; }
test_paint_pill_safe_floor_boundary() { [ "$(p PILL 10 0)" = '#[bg=#1a3320,fg=#77dd77]' ]; }
test_paint_pill_dim_below_floor() { [ "$(p PILL 9 0)" = '#[bg=#333333,fg=#aaaaaa]' ]; }
test_paint_ctx_text_critical_alarm_on() { [ "$(p CTX_TEXT 80 1)" = '#[fg=#ffffff,bold]' ]; }
test_paint_ctx_text_dim_below_floor() { [ "$(p CTX_TEXT 0 0)" = '#[fg=#aaaaaa]' ]; }
test_paint_ctx_bar_warn_alarm_on() { [ "$(p CTX_BAR 65 1)" = '#[bg=#7a1a1a,fg=white]' ]; }
test_paint_ctx_bar_safe_floor_boundary() { [ "$(p CTX_BAR 1 0)" = '#[fg=#77dd77]' ]; }

# paint_usage turns the agent module's rows into the segment. Stub the rows so
# the painter is tested without any agent. Rows are label⇥pct⇥suffix⇥cost⇥tokens.
usage_seg() {
  STUB_ROWS=$1
  (
    . "$SCRIPTS/agentbar/agentbar-lib.sh"
    stub_usage_rows() { printf '%s\n' "$STUB_ROWS"; }
    paint_usage stub 0 0
  )
}

test_usage_seg_formats_pct_and_cost() {
  local out
  out=$(usage_seg "$(printf 'Session\t45.5\t⟳12:00\t3.1')")
  assert_contains "$out" "Session: 45.5%" "pct to one decimal" &&
    assert_contains "$out" '$3.10' "cost to two decimals" &&
    assert_contains "$out" "⟳12:00" "suffix carried through"
}

test_usage_seg_drops_non_numeric_cost() {
  local out
  out=$(usage_seg "$(printf 'Session\t10\t⟳12:00\t;unknown')")
  ! printf '%s' "$out" | grep -qF '$'
}

test_usage_seg_omits_empty_cost() {
  local out
  out=$(usage_seg "$(printf 'Today\t10\t⟳12:00\t')")
  assert_contains "$out" "Today: 10.0%" &&
    ! printf '%s' "$out" | grep -qF '$'
}

test_usage_seg_empty_without_rows_fn() {
  local out
  out=$(
    . "$SCRIPTS/agentbar/agentbar-lib.sh"
    paint_usage nosuchagent 0
  )
  assert_empty "$out" "agent with no usage_rows renders no segment"
}

# tokens is each row's own field — paint_usage never computes it, just paints
# whatever the row hands it, and two rows can carry two different totals.
test_usage_seg_shows_each_rows_own_tokens() {
  local out
  out=$(usage_seg "$(printf 'Session\t45.5\t⟳12:00\t3.1\tT12k\nWeekly\t20\t⟳Mon\t9.4\tT99k')")
  assert_contains "$out" "T12k" "session row shows its own total" &&
    assert_contains "$out" "T99k" "weekly row shows its own, different total"
}

test_usage_seg_puts_tokens_before_cost() {
  local out
  out=$(usage_seg "$(printf 'Session\t45.5\t⟳12:00\t3.1\tT12k')")
  printf '%s' "$out" | grep -q 'T12k.*\$3\.10'
}

test_usage_seg_omits_tokens_when_absent() {
  local out
  out=$(usage_seg "$(printf 'Session\t45.5\t⟳12:00\t3.1')")
  ! printf '%s' "$out" | grep -qE 'T[0-9]'
}

# Lifetime-style row: "-" pct sentinel — no "N%" in the label, still tokens+cost.
test_usage_seg_empty_pct_omits_percent() {
  local out
  out=$(usage_seg "$(printf 'Since May25\t-\t-\t12.34\tΣ8B')")
  assert_contains "$out" "Since May25 " &&
    assert_contains "$out" "\$12.34" &&
    assert_contains "$out" "Σ8B" &&
    ! printf '%s' "$out" | grep -qE '%'
}

# render_ctx: pure now — no state read, no tmux. Fed an already-filled array.
test_ctx_renders_percent() {
  assert_contains "$(ctx_out 25 50000 200000)" "Context: 25%"
}

test_ctx_gauge_zero_is_empty() {
  assert_contains "$(ctx_out 0)" "░░░░░░░░░░░░░░░░░░░░"
}

test_ctx_gauge_full_is_filled() {
  assert_contains "$(ctx_out 100)" "▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓"
}

test_ctx_gauge_quarter_fill() {
  assert_contains "$(ctx_out 25)" "▓▓▓▓▓░░░░░░░░░░░░░░░"
}

test_ctx_used_max_suffix_falls_back_when_zero() {
  assert_contains "$(ctx_out 0 0 0)" "0k/100k" "fresh session shows the empty gauge"
}

test_ctx_used_max_suffix_shown_when_positive() {
  assert_contains "$(ctx_out 25 50000 200000)" "50k/200k"
}

# kfmt now lives in adapter-lib.sh (agentbar-lib sources it via `tmux_ctdl_boot
# state adapter`) — every ${AGENT}_usage_rows uses it to build a tokens field;
# see test-adapter-claude.sh's test_usage_rows_show_distinct_tokens_per_row.
test_kfmt_below_1000_shows_raw() {
  local out
  out=$(
    . "$SCRIPTS/agentbar/agentbar-lib.sh"
    kfmt_out=
    kfmt 999 kfmt_out
    printf '%s' "$kfmt_out"
  )
  [ "$out" = "999" ]
}

test_kfmt_at_1000_shows_k() {
  local out
  out=$(
    . "$SCRIPTS/agentbar/agentbar-lib.sh"
    kfmt_out=
    kfmt 1000 kfmt_out
    printf '%s' "$kfmt_out"
  )
  [ "$out" = "1k" ]
}

test_kfmt_at_1000000_shows_m() {
  local out
  out=$(
    . "$SCRIPTS/agentbar/agentbar-lib.sh"
    kfmt_out=
    kfmt 6488061 kfmt_out
    printf '%s' "$kfmt_out"
  )
  [ "$out" = "6M" ]
}

test_kfmt_at_1000000000_shows_b() {
  local out
  out=$(
    . "$SCRIPTS/agentbar/agentbar-lib.sh"
    kfmt_out=
    kfmt 8200000000 kfmt_out
    printf '%s' "$kfmt_out"
  )
  [ "$out" = "8B" ]
}

test_ctx_label_shown_when_requested() {
  local out
  out=$(
    . "$SCRIPTS/agentbar/agentbar-lib.sh"
    local -A C=([ctx]=10)
    render_ctx C 0 true Claude
  )
  assert_contains "$out" "Claude"
}

run_tests \
  test_silent_without_shared_file \
  test_shows_session_pct \
  test_shows_weekly_pct \
  test_shows_agent_label \
  test_render_carries_style_codes \
  test_reset_times_unknown_sentinel \
  test_weekly_cost_unknown_shows_nothing \
  test_weekly_cost_numeric_shows_value \
  test_context_model_overrides_shared \
  test_paint_pill_safe_paints_background \
  test_paint_pill_dim_paints_background \
  test_paint_pill_notice_is_bold \
  test_paint_pill_alarm_blink_on_fills \
  test_paint_pill_alarm_blink_off_empties \
  test_paint_ctx_text_never_paints_bg \
  test_paint_ctx_text_alarm_calm_is_dim \
  test_paint_ctx_bar_alarm_blink_is_white \
  test_paint_ctx_bar_calm_is_fg_only \
  test_paint_pill_critical_boundary \
  test_paint_pill_warn_boundary \
  test_paint_pill_safe_floor_boundary \
  test_paint_pill_dim_below_floor \
  test_paint_ctx_text_critical_alarm_on \
  test_paint_ctx_text_dim_below_floor \
  test_paint_ctx_bar_warn_alarm_on \
  test_paint_ctx_bar_safe_floor_boundary \
  test_paint_conf_overrides_default_colour \
  test_paint_conf_overrides_default_threshold \
  test_usage_seg_formats_pct_and_cost \
  test_usage_seg_drops_non_numeric_cost \
  test_usage_seg_omits_empty_cost \
  test_usage_seg_empty_without_rows_fn \
  test_usage_seg_shows_each_rows_own_tokens \
  test_usage_seg_puts_tokens_before_cost \
  test_usage_seg_omits_tokens_when_absent \
  test_usage_seg_empty_pct_omits_percent \
  test_ctx_renders_percent \
  test_ctx_gauge_zero_is_empty \
  test_ctx_gauge_full_is_filled \
  test_ctx_gauge_quarter_fill \
  test_ctx_used_max_suffix_falls_back_when_zero \
  test_ctx_used_max_suffix_shown_when_positive \
  test_kfmt_below_1000_shows_raw \
  test_kfmt_at_1000_shows_k \
  test_kfmt_at_1000000_shows_m \
  test_kfmt_at_1000000000_shows_b \
  test_ctx_label_shown_when_requested
