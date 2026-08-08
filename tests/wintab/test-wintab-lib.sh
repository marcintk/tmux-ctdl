#!/usr/bin/env bash
# wintab-lib.sh — the badge state machine. The decision functions are pure, so
# the transition table is asserted directly here; wintab_on_event / wintab_on_tick
# are driven end-to-end in test-wintab-badge.sh / test-wintab-tick.sh.
DIR="$(cd "$(dirname "$0")" && pwd)" || exit 1
. "$DIR/../helpers.sh"
. "$DIR/../../wintab/wintab-lib.sh"

export AGENT_TMP_DIR
AGENT_TMP_DIR=$(mktemp -d)
trap 'rm -rf "$AGENT_TMP_DIR"' EXIT

setup() { rm -f "$AGENT_TMP_DIR"/agent-*; }

# ── badge rendering ──────────────────────────────────────────────────────────

test_badge_renders_wrapper() {
  [ "$(badge '#4488ff' '○')" = '#[fg=#4488ff,blink]○#[fg=default]' ]
}

test_badge_icons_defaults() {
  local ICON_RUNNING ICON_IDLE ICON_DONE ICON_BLOCKED
  ( unset CLAUDE_ICON_RUNNING CLAUDE_ICON_IDLE CLAUDE_ICON_DONE CLAUDE_ICON_BLOCKED
    badge_icons claude
    [ "$ICON_RUNNING" = '○' ] && [ "$ICON_IDLE" = '◌' ] &&
    [ "$ICON_DONE" = '●' ] && [ "$ICON_BLOCKED" = '◉' ] )
}

test_badge_icons_override() {
  local ICON_RUNNING
  ( export CLAUDE_ICON_RUNNING='▶'
    badge_icons claude
    [ "$ICON_RUNNING" = '▶' ] )
}

# No conf is sourced anywhere in this file: the colours below are the module's
# own defaults, and BADGE_* overrides them where a conf names one.
test_badge_none_is_empty()  { assert_empty "$(wintab_badge claude NONE 0)" "NONE paints nothing"; }
test_badge_idle_is_grey()   { assert_contains "$(wintab_badge claude IDLE 0)" '666666' "idle grey"; }
test_badge_done_is_green()  { assert_contains "$(wintab_badge claude DONE 0)" '77dd77' "done green"; }
test_badge_blocked_is_red() { assert_contains "$(wintab_badge claude BLOCKED 0)" 'ff5555' "blocked red"; }

# The pulse: same colour, alternating glyph, so a running window animates.
test_badge_running_pulses_glyph() {
  local a b
  a=$(wintab_badge claude RUNNING 0); b=$(wintab_badge claude RUNNING 1)
  assert_contains "$a" '○' "tick 0 glyph" &&
  assert_contains "$b" '●' "tick 1 glyph" &&
  assert_contains "$b" '4488ff' "colour held at BADGE_RUNNING"
}

test_badge_conf_overrides_default_colour() {
  assert_contains "$(BADGE_DONE='#010203' wintab_badge claude DONE 0)" '010203' \
    "conf BADGE_DONE wins over the default"
}

# ── event half (pure) ────────────────────────────────────────────────────────

test_event_running()          { [ "$(wintab_next_phase NONE RUNNING 0)"       = "RUNNING 0" ]; }
test_event_permission()       { [ "$(wintab_next_phase RUNNING PERMISSION 0)" = "BLOCKED 0" ]; }
test_event_done()             { [ "$(wintab_next_phase RUNNING DONE 0)"       = "DONE 0" ]; }
test_event_clear_sets_flag()  { [ "$(wintab_next_phase RUNNING CLEAR 0)"      = "IDLE 1" ]; }
# /clear then done → idle, not done. The flag is consumed by the transition.
test_event_done_after_clear() { [ "$(wintab_next_phase IDLE DONE 1)"          = "IDLE 0" ]; }
test_event_unknown_holds()    { [ "$(wintab_next_phase DONE WAT 1)"           = "DONE 1" ]; }

# ── poll half (pure) ─────────────────────────────────────────────────────────

test_poll_live_unbadged_is_idle() { [ "$(wintab_next_poll NONE 1 1)" = IDLE ]; }
test_poll_live_holds_running()    { [ "$(wintab_next_poll RUNNING 1 1)" = RUNNING ]; }
# The clobber this collapse removes: a live agent awaiting permission keeps its
# red badge instead of being reset by the poll path.
test_poll_live_holds_blocked()    { [ "$(wintab_next_poll BLOCKED 1 1)" = BLOCKED ]; }
test_poll_live_holds_done()       { [ "$(wintab_next_poll DONE 1 1)" = DONE ]; }
test_poll_gone_clears()           { [ "$(wintab_next_poll RUNNING 0 0)" = NONE ]; }
# A one-tick detection miss inside the grace window must not blank the badge.
test_poll_transient_miss_holds()  { [ "$(wintab_next_poll RUNNING 0 1)" = RUNNING ]; }

# ── live windows (pure, one pass over every pane) ───────────────────────────

test_live_windows_marks_matching_pane() {
  [ "$(wintab_live_windows $'@1\t/proj' '/proj')" = $'@1\t1' ]
}

test_live_windows_marks_non_matching_pane_dead() {
  [ "$(wintab_live_windows $'@1\t/other' '/proj')" = $'@1\t0' ]
}

# The pane-path fix: the agent's cwd sits on a pane that is NOT the active one.
# Feeding only the active pane's path is what blanked a running agent's badge.
test_live_windows_matches_any_pane_in_window() {
  [ "$(wintab_live_windows $'@1\t/somewhere/else\n@1\t/proj' '/proj')" = $'@1\t1' ]
}

test_live_windows_distinguishes_windows() {
  local out; out=$(wintab_live_windows $'@1\t/proj\n@2\t/other' '/proj')
  [ "$out" = $'@1\t1\n@2\t0' ]
}

# ── liveness (grace-window judgment only — matching lives in wintab_live_windows) ──

test_liveness_live_marks_recently() {
  setup
  local IS_LIVE RECENTLY_LIVE
  wintab_liveness 1 claude sess @1 100
  [ "$IS_LIVE" -eq 1 ] && [ "$RECENTLY_LIVE" -eq 1 ]
}

test_liveness_stale_outside_grace() {
  setup
  local IS_LIVE RECENTLY_LIVE
  state_mark live claude sess @1
  # now far in the future → age >> WINTAB_LIVE_GRACE regardless of timezone
  wintab_liveness 0 claude sess @1 9999999999
  [ "$IS_LIVE" -eq 0 ] && [ "$RECENTLY_LIVE" -eq 0 ]
}

test_liveness_grace_within_window() {
  setup
  local IS_LIVE RECENTLY_LIVE now
  state_mark live claude sess @1
  now=$(date +%s)
  wintab_liveness 0 claude sess @1 "$now"
  [ "$IS_LIVE" -eq 0 ] && [ "$RECENTLY_LIVE" -eq 1 ]
}

test_liveness_no_stamp_is_stale() {
  setup
  local IS_LIVE RECENTLY_LIVE
  wintab_liveness 0 claude sess @1 100
  [ "$IS_LIVE" -eq 0 ] && [ "$RECENTLY_LIVE" -eq 0 ]
}

run_tests \
  test_badge_renders_wrapper \
  test_badge_icons_defaults \
  test_badge_icons_override \
  test_badge_none_is_empty \
  test_badge_idle_is_grey \
  test_badge_done_is_green \
  test_badge_blocked_is_red \
  test_badge_running_pulses_glyph \
  test_badge_conf_overrides_default_colour \
  test_event_running \
  test_event_permission \
  test_event_done \
  test_event_clear_sets_flag \
  test_event_done_after_clear \
  test_event_unknown_holds \
  test_poll_live_unbadged_is_idle \
  test_poll_live_holds_running \
  test_poll_live_holds_blocked \
  test_poll_live_holds_done \
  test_poll_gone_clears \
  test_poll_transient_miss_holds \
  test_live_windows_marks_matching_pane \
  test_live_windows_marks_non_matching_pane_dead \
  test_live_windows_matches_any_pane_in_window \
  test_live_windows_distinguishes_windows \
  test_liveness_live_marks_recently \
  test_liveness_stale_outside_grace \
  test_liveness_grace_within_window \
  test_liveness_no_stamp_is_stale
