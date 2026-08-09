#!/usr/bin/env bash
# The wintab badge state machine. ONE machine, two entry verbs: tmux-ctdl.sh wintab-badge
# feeds it agent events, tmux-ctdl.sh agent-refresh feeds it liveness on the status tick.
# Both go through wintab_apply, so neither decides the badge behind the other's
# back — the phase is stored state, not "whatever is currently in the tmux option".
#
# Phases: RUNNING · IDLE · DONE · BLOCKED · NONE (no badge).
#
# The decision functions (wintab_next_phase, wintab_next_poll, wintab_badge) are
# pure: no filesystem, no tmux, no clock. They are the test surface. State goes
# through state-lib, tmux through tmux-lib.
#
# The caller must have CODING_AGENT and the BADGE_* palette in scope (both entry
# points source tmux-ctdl.conf before calling in).

. "${TMUX_CTDL_HOME:-$HOME/.config/tmux/tmux-ctdl}/libs/boot-lib.sh"
tmux_ctdl_boot state tmux

# badge <color> <glyph> — render one window badge: a blinking coloured glyph
# wrapped so it resets to default after. The single place that knows tmux badge
# style syntax.
badge() { printf '#[fg=%s,blink]%s#[fg=default]' "$1" "$2"; }

# badge_icons <agent> — set ICON_RUNNING/IDLE/DONE/BLOCKED in caller scope from
# the agent's ${AGENT^^}_ICON_* overrides, falling back to ○ ◌ ● ◉.
badge_icons() {
  local pfx="${1^^}" v
  v="${pfx}_ICON_RUNNING"
  ICON_RUNNING="${!v:-○}"
  v="${pfx}_ICON_IDLE"
  ICON_IDLE="${!v:-◌}"
  v="${pfx}_ICON_DONE"
  ICON_DONE="${!v:-●}"
  v="${pfx}_ICON_BLOCKED"
  ICON_BLOCKED="${!v:-◉}"
}

# ── Decisions (pure) ─────────────────────────────────────────────────────────

# wintab_next_phase <phase> <event> <cleared> — the event half of the machine.
# Prints "<phase> <cleared>". The /clear flag survives one transition: a CLEAR
# while running makes the next DONE resolve to IDLE rather than DONE.
wintab_next_phase() {
  local phase=$1 event=$2 cleared=$3
  case "$event" in
    RUNNING) printf 'RUNNING 0' ;;
    CLEAR) printf 'IDLE 1' ;;
    DONE) if [ "$cleared" = 1 ]; then printf 'IDLE 0'; else printf 'DONE 0'; fi ;;
    PERMISSION) printf 'BLOCKED 0' ;;
    *) printf '%s %s' "${phase:-NONE}" "$cleared" ;;
  esac
}

# wintab_next_poll <phase> <is_live> <recently_live> — the liveness half.
# Live and unbadged → IDLE. Live and badged → hold whatever the event path set,
# so a DONE or BLOCKED badge is never downgraded while the agent is still up.
# Gone for longer than the grace window → NONE. A transient miss inside the grace
# window holds the current phase.
wintab_next_poll() {
  local phase=${1:-NONE} live=$2 recent=$3
  if [ "$live" = 1 ]; then
    if [ "$phase" = NONE ]; then printf 'IDLE'; else printf '%s' "$phase"; fi
    return 0
  fi
  if [ "$recent" = 1 ]; then
    printf '%s' "$phase"
    return 0
  fi
  printf 'NONE'
}

# wintab_badge <agent> <phase> <tick> — phase to badge string ("" for NONE).
# RUNNING pulses: the glyph alternates with the tick, colour held at
# BADGE_RUNNING — an animated blink beyond tmux's own. The leading space matches
# what tmux.conf expects right after #W.
#
# The BADGE_* colours default here, like the icons above: tmux-ctdl.conf names
# only what a user wants different, so a caller that sources no conf at all
# still paints the real badge instead of `#[fg=,blink]`.
wintab_badge() {
  local agent=$1 phase=$2 tick=${3:-0}
  local ICON_RUNNING ICON_IDLE ICON_DONE ICON_BLOCKED
  badge_icons "$agent"
  local running="${BADGE_RUNNING:-#4488ff}" idle="${BADGE_IDLE:-#666666}"
  local done_c="${BADGE_DONE:-#77dd77}" blocked="${BADGE_BLOCKED:-#ff5555}"
  case "$phase" in
    RUNNING) if [ "$tick" -eq 0 ]; then
      printf ' %s' "$(badge "$running" "$ICON_RUNNING")"
    else printf ' %s' "$(badge "$running" "$ICON_DONE")"; fi ;;
    IDLE) printf ' %s' "$(badge "$idle" "$ICON_IDLE")" ;;
    DONE) printf ' %s' "$(badge "$done_c" "$ICON_DONE")" ;;
    BLOCKED) printf ' %s' "$(badge "$blocked" "$ICON_BLOCKED")" ;;
  esac
}

# ── Effects ──────────────────────────────────────────────────────────────────

# wintab_live_windows <panes> <live_cwds> — prints "<window_id>\t0|1", one line
# per distinct window in <panes>. <panes> is EVERY pane in the session
# ("window_id\tpath" per line, as tmux_session_panes prints it); a window is
# live if ANY of its panes sits in a live cwd. Matching only the window's
# active pane meant cd-ing the terminal pane of a ctdl layout blanked the badge
# of an agent that was still running — this owns that rule in one place, in
# one pass over the panes, instead of leaving each caller to filter and grep.
wintab_live_windows() {
  local panes=$1 live=$2 win path
  local -A seen winset
  while IFS=$'\t' read -r win path; do
    [ -n "$win" ] || continue
    winset[$win]=1
    if [ -n "$path" ] && printf '%s\n' "$live" | grep -qxF "$path"; then
      seen[$win]=1
    fi
  done <<<"$panes"
  for win in "${!winset[@]}"; do
    printf '%s\t%s\n' "$win" "${seen[$win]:-0}"
  done | sort
}

# wintab_liveness <is_live> <agent> <tsess> <win> <now>
# Sets IS_LIVE and RECENTLY_LIVE in caller scope; stamps the live marker when
# live. <is_live> comes from wintab_live_windows — this function owns only the
# grace-window judgment, not the pane matching.
# Caller declares: local IS_LIVE RECENTLY_LIVE.
wintab_liveness() {
  local is_live=$1 agent=$2 tsess=$3 win=$4 now=${5:-0}
  IS_LIVE=$is_live

  if [ "$IS_LIVE" -eq 1 ]; then
    state_mark live "$agent" "$tsess" "$win"
    RECENTLY_LIVE=1
    return 0
  fi

  RECENTLY_LIVE=0
  [ "$(state_age "$now" live "$agent" "$tsess" "$win")" -le "${WINTAB_LIVE_GRACE:-5}" ] && RECENTLY_LIVE=1
  return 0
}

# wintab_apply <agent> <tsess> <win> <phase> <tick> — persist the phase and paint
# the badge. The single writer of @agent_badges.
wintab_apply() {
  local agent=$1 tsess=$2 win=$3 phase=$4 tick=${5:-0}
  if [ "$phase" = NONE ]; then
    state_clear phase "$agent" "$tsess" "$win"
    state_clear live "$agent" "$tsess" "$win"
  else
    state_put "$phase" phase "$agent" "$tsess" "$win"
  fi
  tmux_badge_set "$tsess" "$win" "$(wintab_badge "$agent" "$phase" "$tick")"
}

# wintab_on_event <agent> <tsess> <win> <event> — event entry point.
wintab_on_event() {
  local agent=$1 tsess=$2 win=$3 event=$4
  local phase cleared
  phase=$(state_get phase "$agent" "$tsess" "$win")
  state_exists cleared "$agent" "$tsess" "$win" && cleared=1 || cleared=0
  read -r phase cleared <<<"$(wintab_next_phase "${phase:-NONE}" "$event" "$cleared")"
  if [ "$cleared" = 1 ]; then
    state_mark cleared "$agent" "$tsess" "$win"
  else state_clear cleared "$agent" "$tsess" "$win"; fi
  wintab_apply "$agent" "$tsess" "$win" "$phase" 0
}

# wintab_on_tick <agent> <tsess> <win> <is_live> <tick> <now>
# Poll entry point, once per status-interval per window. <is_live> comes from
# wintab_live_windows (one call per session, not per window).
wintab_on_tick() {
  local agent=$1 tsess=$2 win=$3 is_live=$4 tick=$5 now=$6
  local IS_LIVE RECENTLY_LIVE
  wintab_liveness "$is_live" "$agent" "$tsess" "$win" "$now"

  local phase next
  phase=$(state_get phase "$agent" "$tsess" "$win")
  phase="${phase:-NONE}"
  next=$(wintab_next_poll "$phase" "$IS_LIVE" "$RECENTLY_LIVE")

  # Repaint every tick only while RUNNING (that's the pulse); otherwise touch tmux
  # only when the phase actually moves.
  if [ "$next" != "$phase" ] || [ "$next" = RUNNING ]; then
    wintab_apply "$agent" "$tsess" "$win" "$next" "$tick"
  fi
}

# ── Entry verbs ──────────────────────────────────────────────────────────────
# The two things tmux-ctdl.sh calls into this module for: badge (event, from a
# Claude Code hook) and tick (poll, once per status-interval). Both route
# through wintab_apply above, so neither clobbers the other's state.

# wintab_hook <agent> <RUNNING|CLEAR|DONE|PERMISSION> — badge verb. Validates
# the event and hands off to wintab_on_event.
#   RUNNING [blue ○]      CLEAR [grey ◌]
#   DONE    [green ●]     PERMISSION [red ◉]
# Stop and Notification hooks both fire DONE — they render identically, no
# reason to tell them apart downstream.
wintab_hook() {
  local agent=$1 event=$2
  local here tsess win
  here=$(tmux_here) || return 0
  IFS=$'\t' read -r tsess win <<<"$here"

  case "$event" in
    RUNNING | CLEAR | DONE | PERMISSION) : ;;
    *) return 0 ;;
  esac

  wintab_on_event "$agent" "$tsess" "$win" "$event"
}

# wintab_tick <agent> <tsess> — tick verb. Gathers this session's pane paths
# and the agent's live cwds, then hands one window at a time to wintab_on_tick.
wintab_tick() {
  local agent=$1 tsess=$2
  [ -z "$tsess" ] && return 0

  local now tick live panes win is_live
  now=$(date +%s)
  tick=$((now % 2))
  live=$("${agent}_live_cwds" 2>/dev/null)
  panes=$(tmux_session_panes "$tsess")

  # wintab_live_windows does the per-window "any pane live?" judgment in one
  # pass; this loop just feeds each window's verdict to the state machine.
  while IFS=$'\t' read -r win is_live; do
    [ -n "$win" ] || continue
    wintab_on_tick "$agent" "$tsess" "$win" "$is_live" "$tick" "$now"
  done < <(wintab_live_windows "$panes" "$live") # KCOV_TRACER_LOST
}

# wintab_agent_refresh <agent> <tsess> — the whole once-a-second status-format
# cycle: badge poll, then the usage pull a pull-based agent has no hook for,
# then the state reaper. tmux-ctdl.sh's agent-refresh verb calls this and nothing
# else, keeping the "one arm, one lib verb" rule the router documents for
# itself — this function, not the router, owns the order and why it's safe.
wintab_agent_refresh() {
  local agent=$1 tsess=$2 now
  now=$(date +%s)
  wintab_tick "$agent" "$tsess"
  # adapter_pull_usage owns its own rate limit, so calling it every second is
  # free for push agents (no-op) and for pull agents inside USAGE_REFRESH.
  adapter_pull_usage "$agent" "$now"
  # Own rate limit (STATE_REAP_INTERVAL) makes this free on the other 599
  # ticks out of every 600.
  state_reap_stale "$now"
}
