#!/usr/bin/env bash
# The outer status bar's render lib. Every function here is a verb over
# explicit arguments — session, window, blink frame, clock — never a script
# global, so a test calls straight into render_agent/agentbar_render without
# reconstructing an entry point's environment. tmux-ctdl.sh's `agentbar` verb is
# the only caller and does nothing but parse args and call agentbar_render.

. "${TMUX_CTDL_HOME:-$HOME/.config/tmux/tmux-ctdl}/tmux-ctdl-boot.sh"
tmux_ctdl_boot state adapter

SEP='#[fg=brightblack] | #[default]'
AGENT_SEP='#[fg=brightblack] ‖ #[default]'

# ── Painting ─────────────────────────────────────────────────────────────────
# paint is the module's only public styling verb. Everything below it —
# tier, colour, emphasis — is internal (leading underscore): each has exactly
# one caller (paint itself), so splitting them out bought interface hops, not
# reuse. Folding them in means a wrong escape in the matrix below is exactly
# as easy to hit from a test as it is from tmux.

# _tier_of: classify a pct into a severity rung against caller-supplied
# thresholds. Pure (no globals, no clock).
_tier_of() {
  local pct=$1 critical=$2 warn=$3 notice=$4 floor=$5
  if   [ "$pct" -ge "$critical" ]; then printf 'CRITICAL'
  elif [ "$pct" -ge "$warn"     ]; then printf 'WARN'
  elif [ "$pct" -ge "$notice"   ]; then printf 'NOTICE'
  elif [ "$pct" -ge "$floor"    ]; then printf 'SAFE'
  else                                  printf 'DIM'
  fi
}

# _ladder_tier <RATE|CTX> <pct> — the two threshold sets in use. The numbers
# ARE the default palette: tmux-ctdl.conf only names the ones a user wants
# different, so a caller (or a test) that sets nothing still renders the real
# thing. The SAFE floors differ on purpose: a rate limit at 5% isn't worth
# colouring, a context window at 5% is.
_ladder_tier() {
  case "$1" in
    RATE) _tier_of "$2" "${THRESHOLD_CRITICAL:-90}"     "${THRESHOLD_WARN:-75}"     "${THRESHOLD_NOTICE:-50}"     "${THRESHOLD_FLOOR:-10}" ;;
    CTX)  _tier_of "$2" "${THRESHOLD_CTX_CRITICAL:-80}" "${THRESHOLD_CTX_WARN:-65}" "${THRESHOLD_CTX_NOTICE:-40}" "${THRESHOLD_CTX_FLOOR:-1}" ;;
  esac
}

# _tier_colors <tier> — the palette pair for one rung: "<bg>\t<fg>". The only
# place a COLOR_* name is read, and the only place its default lives.
_tier_colors() {
  case "$1" in
    CRITICAL) printf '%s\t%s' "${COLOR_CRITICAL_BG:-#8b0000}" "${COLOR_CRITICAL_FG:-#ffffff}" ;;
    WARN)     printf '%s\t%s' "${COLOR_WARN_BG:-#7a1a1a}"     "${COLOR_WARN_FG:-#ff8c42}" ;;
    NOTICE)   printf '%s\t%s' "${COLOR_NOTICE_BG:-#3d2200}"   "${COLOR_NOTICE_FG:-#ffb347}" ;;
    SAFE)     printf '%s\t%s' "${COLOR_SAFE_BG:-#1a3320}"     "${COLOR_SAFE_FG:-#77dd77}" ;;
    *)        printf '%s\t%s' "${COLOR_DIM_BG:-#333333}"      "${COLOR_DIM_FG:-#aaaaaa}" ;;
  esac
}

# _emphasis_of <tier> <blink> — the ladder shared by every style map: alarm
# tiers (CRITICAL/WARN) pulse between ALARM_ON and ALARM_OFF on the blink
# frame; NOTICE is always BOLD; everything else is PLAIN.
_emphasis_of() {
  local tier=$1 blink=${2:-0}
  case "$tier" in
    CRITICAL|WARN)
      [ "$blink" -eq 1 ] && printf 'ALARM_ON' || printf 'ALARM_OFF' ;;
    NOTICE) printf 'BOLD' ;;
    *)      printf 'PLAIN' ;;
  esac
}

# paint <map> <pct> <blink> — the style string for one rung of one map.
#   PILL     — the rate pill: paints a background at every rung.
#   CTX_TEXT — context text: foreground only, drops to DIM on the calm frame.
#   CTX_BAR  — context bar: foreground only, goes white-on-alarm.
# Same ladder, three presentations. Blink is a parameter, not a global, so a
# test can assert either frame.
paint() {
  local map=$1 pct=$2 blink=${3:-0} tier bg fg emph
  case "$map" in
    PILL) tier=$(_ladder_tier RATE "$pct") ;;
    *)    tier=$(_ladder_tier CTX  "$pct") ;;
  esac
  IFS=$'\t' read -r bg fg <<< "$(_tier_colors "$tier")"
  emph=$(_emphasis_of "$tier" "$blink")

  # Each outer arm keeps its inner case's opener and closer on the arm's own
  # line (rather than splitting label/esac onto bare lines of their own) so
  # kcov's line-based bash tracer can credit them — see coverage/README notes.
  case "$map" in
    PILL) case "$emph" in
        ALARM_ON)  printf '#[bg=%s,fg=%s,bold]' "$bg" "$fg" ;;
        ALARM_OFF) printf '#[bg=default,fg=%s,bold]' "$fg" ;;
        BOLD)      printf '#[bg=%s,fg=%s,bold]' "$bg" "$fg" ;;
        PLAIN)     printf '#[bg=%s,fg=%s]'      "$bg" "$fg" ;; esac ;;
    CTX_TEXT) case "$emph" in
        ALARM_ON)  printf '#[fg=%s,bold]' "$fg" ;;
        ALARM_OFF) printf '#[fg=%s,bold]' "${COLOR_DIM_FG:-#aaaaaa}" ;;
        BOLD)      printf '#[fg=%s,bold]' "$fg" ;;
        PLAIN)     printf '#[fg=%s]'      "$fg" ;; esac ;;
    CTX_BAR) case "$emph" in
        ALARM_ON)  printf '#[bg=%s,fg=white]' "$bg" ;;
        ALARM_OFF) printf '#[bg=default,fg=%s]' "$fg" ;;
        *)         printf '#[fg=%s]' "$fg" ;; esac ;;
  esac
}

# paint_usage <agent> <now> <blink> <tsess> <win> — the usage segment, from
# the agent module's rows (label⇥pct⇥suffix⇥cost⇥tokens). Every colour and
# every #[...] in the segment is applied here; the agent module supplies
# numbers and text only — including tokens, already formatted (e.g. "Σ53k")
# and already whatever total makes sense for that row. This lib never
# computes a token count itself.
paint_usage() {
  local agent=$1 now=$2 blink=${3:-0} tsess=$4 win=$5 rows out="" label pct suffix cost tokens seg pfmt cfmt
  declare -f "${agent}_usage_rows" >/dev/null 2>&1 || return 0
  rows=$("${agent}_usage_rows" "$agent" "$now" "$tsess" "$win") || return 0

  while IFS=$'\t' read -r label pct suffix cost tokens; do
    [ -n "$label" ] || continue
    printf -v pfmt '%.1f' "${pct:-0}"
    local rung="${pct%%.*}"
    seg="$(paint PILL "${rung:-0}" "$blink") ${label}: ${pfmt}% #[default]"
    # Tokens sit before cost: the count is what the dollars are derived from.
    [ -n "$tokens" ] && seg+=" #[fg=brightblack]${tokens}#[default]"
    # A cost cache can hold junk (a failed ccusage run) — show nothing, not $0.00.
    case "$cost" in ''|*[!0-9.]*) cost="" ;; esac
    if [ -n "$cost" ]; then
      printf -v cfmt '%.2f' "$cost"
      seg+=" #[fg=brightblack]\$${cfmt}#[default]"
    fi
    [ -n "$suffix" ] && seg+=" #[fg=brightblack]${suffix}#[default]"
    out="${out:+${out}${SEP}}${seg}"
  done <<< "$rows"

  printf '%s' "$out"
}

# model_style <model> — the model pill's colours, by tier. The tier lists are
# defaulted here like the rest of the palette; tmux-ctdl.conf overrides them by
# naming SAFE_MODELS/WARN_MODELS. Reuses _tier_colors so a model pill and a
# usage pill of the same tier can never drift apart.
model_style() {
  local model="${1,,}" tok tier=DIM
  for tok in ${SAFE_MODELS:-haiku luna}; do [[ "$model" == *"$tok"* ]] && { tier=SAFE; break; }; done
  if [ "$tier" = DIM ]; then
    for tok in ${WARN_MODELS:-opus fable sol}; do [[ "$model" == *"$tok"* ]] && { tier=WARN; break; }; done
  fi
  local bg fg
  IFS=$'\t' read -r bg fg <<< "$(_tier_colors "$tier")"
  printf '#[bg=%s,fg=%s]' "$bg" "$fg"
}

# render_ctx <arrayname> <blink> [show_label] [label] — the context segment for
# one window, from an already-filled context array (get_agent_context's
# output). Pure: no state read, no tmux — the caller owns fetching, this owns
# formatting, so a test builds the array by hand instead of seeding a file.
render_ctx() {
  local -n _rc_C=$1
  local blink=$2 show_label=${3:-false} label=$4
  local CTX="${_rc_C[ctx]:-0}" CTX_USED="${_rc_C[ctx_used]:-0}" CTX_MAX="${_rc_C[ctx_max]:-0}"

  local _pct="${CTX%%.*}" PCT CTX_TEXT_STYLE CTX_BAR_STYLE CTX_TOKENS BAR FILLED
  PCT=$(( ${_pct:-0} ))
  CTX_TEXT_STYLE=$(paint CTX_TEXT "$PCT" "$blink")
  CTX_BAR_STYLE=$(paint CTX_BAR  "$PCT" "$blink")
  # A fresh session reports 0/0 — still show the gauge (0k/<default>k) rather
  # than a blank, so the segment doesn't change shape once the first turn lands.
  local _used=0 _max=0
  case "$CTX_USED" in ''|*[!0-9]*) ;; *) _used=$CTX_USED ;; esac
  case "$CTX_MAX"  in ''|*[!0-9]*) ;; *) _max=$CTX_MAX ;; esac
  [ "$_max" -gt 0 ] || _max=${CTX_MAX_DEFAULT:-100000}
  CTX_TOKENS=" #[fg=brightblack]$(( _used / 1000 ))k/$(( _max / 1000 ))k#[default]"
  FILLED=$(( PCT * 20 / 100 ))
  BAR=$(awk -v n="$FILLED" 'BEGIN{for(i=1;i<=n;i++) printf "▓"; for(i=n+1;i<=20;i++) printf "░"}')

  local prefix=""
  [ "$show_label" = "true" ] && prefix="#[fg=brightblack]${label}#[default]${SEP}"
  printf '%s' "${prefix}${CTX_TEXT_STYLE}Context: ${PCT}%#[default] ${CTX_BAR_STYLE}${BAR}#[default]${CTX_TOKENS}"
}

# render_agent <agent> <tsess> <win> <blink> <now> — the full segment for one
# agent: model pill, usage rows, context, freshness.
render_agent() {
  local agent=$1 tsess=$2 win=$3 blink=$4 now=$5
  local -A F
  get_agent_usage F "$agent" "$tsess" "$win" || return 1
  local MODEL="${F[model]:-}" EFFORT="${F[effort]:-}"

  local -A C
  local have_ctx=0
  if get_agent_context C "$agent" "$tsess" "$win"; then
    have_ctx=1
    [ -n "${C[model]:-}" ] && MODEL="${C[model]}"
    [ -n "${C[effort]:-}" ] && EFFORT="${C[effort]}"
  fi

  local LABEL
  LABEL="${AGENT_LABEL:-$agent}"

  local MODEL_STYLE
  MODEL_STYLE=$(model_style "$MODEL")

  local FRESH
  FRESH=$(since "$(get_agent_usage_age "$now" "$agent" "$tsess" "$win")")

  local USAGE_SEG
  USAGE_SEG=$(paint_usage "$agent" "$now" "$blink" "$tsess" "$win")

  local CTX_SEG=""
  [ "$have_ctx" -eq 1 ] && CTX_SEG=$(render_ctx C "$blink" false)

  printf '%s' "${MODEL_STYLE} ${LABEL}: ${MODEL} ${EFFORT} #[default]${CTX_SEG:+${SEP}${CTX_SEG}}${USAGE_SEG:+${SEP}${USAGE_SEG}}${SEP}#[fg=brightblack](updated: ${FRESH})#[default]"
}

# agentbar_render <agent> <tsess> <win> <now> — the whole bar segment for one
# window. The single verb tmux-ctdl.sh's `agentbar` verb calls: derives the blink
# frame from <now> so nothing downstream needs the wall clock as a global.
agentbar_render() {
  local agent=$1 tsess=$2 win=$3 now=$4 blink
  blink=$(( now % 2 ))
  render_agent "$agent" "$tsess" "$win" "$blink" "$now"
}
