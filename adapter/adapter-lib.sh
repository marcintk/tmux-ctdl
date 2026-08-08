#!/usr/bin/env bash
# Shared adapter machinery. An agent adapter sources this and defines the hooks
# below; the verbs at the bottom acquire a payload and drive them.
#
# Everything crosses this seam as an ARGUMENT or on STDIN — there is no ambient
# AGENT or INPUT. The agent id is the first argument of every verb and is passed
# on to every hook; the raw payload arrives on the hook's stdin. That is what
# lets a test call any function here directly, and it is why two agents' hooks
# can never read each other's half-set state.
#
# Contract for the sourcing adapter — <agent> is its own id (claude, copilot):
#   <agent>_parse_shared   <<< payload
#                    prints key<TAB>value lines, one per field, any order.
#                    Keys are agent-defined and OPAQUE to this lib (claude:
#                    session weekly five_reset week_reset; copilot: today week
#                    month) except for two that every agent includes: model,
#                    effort.
#   <agent>_parse_context  <<< payload
#                    prints key<TAB>value lines: ctx ctx_used ctx_max (prints
#                    nothing when no context data is available). Exactly the
#                    three keys agentbar-lib reads — don't emit fields no
#                    reader asks for.
#
# Optional per-agent hooks:
#   <agent>_collect
#       Pull-based agents only: gather and print the raw payload
#       parse_shared/parse_context read (a sqlite query, a process probe, ...).
#       Push-based agents (Claude) omit it — their payload already arrives on
#       stdin via tmux-ctdl.sh agent-push-usage. Pull-based agents (Copilot) are
#       driven by tmux-ctdl.sh agent-pull-usage, called off the wintab-tick, rate-
#       limited by USAGE_REFRESH so a per-second tick doesn't hammer the store.
#   <agent>_incoming_stale <agent> <incoming-shared-value>
#       Return 0 (true) to SKIP the write because incoming data is older than
#       what's on disk (out-of-order events). Push-based agents define it;
#       poll-based agents omit it and always overwrite with the freshest read.
#   <agent>_refresh_costs <agent>
#       Repopulate the agent's $-cost caches (state kind `cost`), in the
#       background and rate-limited by the agent itself. Agents that don't bill
#       in dollars omit it.
#   <agent>_footer <<< payload
#       The end-of-turn line, over the agent's own end-of-turn hook payload on
#       stdin. Prints whatever that agent's hook protocol expects — the response
#       shape is the agent's, not this lib's. Agents with no end-of-turn hook
#       omit it.
#
# Display-side contract (read by agentbar-lib.sh via tmux-ctdl.sh agentbar, not by
# this lib):
#   <agent>_usage_rows <agent> <now>
#       Prints the agent's usage rows, one per line:
#         label<TAB>pct<TAB>suffix<TAB>cost<TAB>tokens
#       Data only — no colours, no tmux #[...] syntax. agentbar-lib paints.
#       cost/tokens are last because they're optional: TAB is IFS whitespace,
#       so `read` collapses an empty field sitting BEFORE a non-empty one —
#       only a genuinely trailing empty field is safe. If cost can be empty
#       while tokens isn't (Claude: cost lags tokens by one ccusage refresh),
#       give the earlier field a non-empty sentinel ("-") instead of "" — see
#       claude_usage_rows. tokens is a row's own already-formatted total (kfmt
#       below) —
#       whatever total makes sense for THAT row (Claude: ccusage's per-block
#       totalTokens for Session, summed daily totalTokens for Weekly — two
#       different real numbers, not one figure copied onto both). agentbar-lib
#       never computes a token count; it only paints what the row hands it.
#
# State lives in state-lib.sh (verbs, not paths) and every tmux call goes through
# tmux-lib.sh — this module touches neither the filesystem nor tmux directly.

. "${WORKSPACE_HOME:-$HOME/.config/tmux/workspace}/workspace-boot.sh"
workspace_boot state tmux

# ── State value schema ───────────────────────────────────────────────────────
# Shared/ctx values are key<TAB>value lines (kv_fill / state_get_kv, from
# state-lib.sh) — this lib never learns key names, so adding a field touches
# only the writing agent module and its readers.

# get_agent_usage <arrayname> <agent> <tsess> <win> — fills the array with the
# agent's account-wide rate fields (kind `rate`, one file for every window)
# overlaid with this window's own model/effort (kind `shared`, per window —
# two panes can run different models). Returns 1 only when NEITHER has ever
# reported; a window with one half but not the other still returns 0 with
# whatever it has.
get_agent_usage() {
  local arrname=$1 agent=$2 tsess=$3 win=$4 ok=1 k
  local -n _gau_out=$arrname
  _gau_out=()
  local -A _gau_rate
  state_get_kv _gau_rate rate "$agent" && { for k in "${!_gau_rate[@]}"; do _gau_out[$k]="${_gau_rate[$k]}"; done; ok=0; }
  local -A _gau_shared
  state_get_kv _gau_shared shared "$agent" "$tsess" "$win" && { for k in "${!_gau_shared[@]}"; do _gau_out[$k]="${_gau_shared[$k]}"; done; ok=0; }
  return $ok
}

# get_agent_usage_age <now> <agent> <tsess> <win> — seconds since the freshest
# of rate (account-wide) or shared (this window) was last written. Owns the
# same rate/shared split get_agent_usage does, so a caller (agentbar) never
# has to name state-lib's kinds itself to answer "how fresh is this display".
get_agent_usage_age() {
  local now=$1 agent=$2 tsess=$3 win=$4 age_rate age_shared
  age_rate=$(state_age "$now" rate "$agent")
  age_shared=$(state_age "$now" shared "$agent" "$tsess" "$win")
  printf '%s' "$(( age_rate < age_shared ? age_rate : age_shared ))"
}

# get_agent_context <arrayname> <agent> <tsess> <win> — fills the array with
# that window's context fields. Returns 1 when it has no context data.
get_agent_context() { state_get_kv "$1" ctx "$2" "$3" "$4"; }

# write_shared <agent> <content> — content is model/effort as key<TAB>value
# lines. Stored per WINDOW (tmux_here), same as write_ctx: two panes can
# genuinely run different models, so this is the part of a push that must NOT
# be shared across windows. Plain overwrite — there's no "out of order" for a
# model name the way there is for a rate-limit block. Which window is
# tmux-lib's judgment — no-op when there isn't one, so nothing is stored under
# a half-known key.
write_shared() {
  local agent=$1 content=$2
  local here tsess win
  here=$(tmux_here) || return 0
  IFS=$'\t' read -r tsess win <<< "$here"
  state_put "$content" shared "$agent" "$tsess" "$win"
}

# write_rate <agent> <content> — content is the agent's opaque rate-limit keys
# (Claude: session weekly five_reset week_reset; Copilot: today week month) as
# key<TAB>value lines, model/effort already stripped out by the caller. ONE
# file per agent, not per window: this is an account-wide real number, the
# same regardless of which window's process last reported it, so whichever
# window pushes freshest updates what every window displays.
#
# The stale hook, when defined, compares incoming against what's on disk —
# both go through kv_fill, so neither it nor this function counts lines.
#
# Body split into its own function so the subshell below collapses to one
# physical line — kcov's bash line tracer doesn't credit a bare `(` / `)
# 9>...` pair on their own lines even though they run.
_write_rate_locked() {
  local agent=$1 content=$2
  flock -x 9
  if state_exists rate "$agent" && declare -f "${agent}_incoming_stale" >/dev/null 2>&1; then
    "${agent}_incoming_stale" "$agent" "$content" && exit 0
  fi
  state_put "$content" rate "$agent"
}
write_rate() {
  local agent=$1 content=$2
  ( _write_rate_locked "$agent" "$content" ) 9>"$(state_lockfile "agent-rate-lock-${agent}")"
}

# write_ctx <agent> <content> <model> <effort> — content is key<TAB>value lines
# (as produced by <agent>_parse_context); model/effort come from the shared read
# so a window shows the model it was actually run with. Which window is
# tmux-lib's judgment (tmux_here) — no-op when there isn't one, so nothing is
# stored under a half-known key.
write_ctx() {
  local agent=$1 content=$2 model=$3 effort=$4
  local here tsess win
  here=$(tmux_here) || return 0
  IFS=$'\t' read -r tsess win <<< "$here"
  content+=$'\n'"model"$'\t'"$model"$'\n'"effort"$'\t'"$effort"
  state_put "$content" ctx "$agent" "$tsess" "$win"
}

# interval_secs <value> — "30s" | "1m" | "2h" as seconds. Shared by every
# workspace-wide timing setting (USAGE_REFRESH, ...). A bare number (no
# suffix) is seconds too, for old configs — but write the unit.
interval_secs() {
  local v=$1
  case "$v" in
    *s) printf '%s' "${v%s}" ;;
    *m) printf '%s' $(( ${v%m} * 60 )) ;;
    *h) printf '%s' $(( ${v%h} * 3600 )) ;;
    *)  printf '%s' "$v" ;;
  esac
}

# kfmt <value> <varname> — <value> as a compact k-suffixed count in the
# caller's variable (nameref-free: printf -v respects the caller's scope by
# name). For every <agent>_usage_rows building a tokens field.
kfmt() {
  local v=${1:-0}
  (( v >= 1000 )) && printf -v "$2" '%dk' "$(( v / 1000 ))" || printf -v "$2" '%s' "$v"
}

# ── Time formatting ──────────────────────────────────────────────────────────
# Naming: a name ending in _at takes a point in time (an epoch); a bare name
# takes a duration in seconds; a name ending in _secs returns a NUMBER rather
# than a display string (interval_secs, usage_refresh_secs above). One ladder
# serves both directions, so a countdown and a staleness reading can never
# disagree about what 90 minutes looks like.

# _ladder <secs> — one duration, compact: seconds under a minute, whole minutes
# under an hour, one-decimal hours above. Private — callers come through
# since/until_at, which own the direction and its wording.
_ladder() {
  local s=${1:-0}
  if   [ "$s" -lt 60 ];   then printf '%ds' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%dm' "$(( s / 60 ))"
  else awk -v s="$s" 'BEGIN{ printf "%.1fh", s/3600 }'
  fi
}

# since <secs> — how long ago: "42s ago". Takes the elapsed count, not a start
# time: its one caller reads it out of state_age, which has already subtracted.
since() { printf '%s ago' "$(_ladder "$1")"; }

# until_at <epoch> <now> — how long until: "in 42m". A target already reached
# reads "now" rather than counting down past zero — that state lasts only until
# the next payload carries a fresher target. <now> is a parameter, not a clock
# read, so both branches are assertable.
until_at() {
  local secs=$(( $1 - $2 ))
  [ "$secs" -le 0 ] && { printf 'now'; return 0; }
  printf 'in %s' "$(_ladder "$secs")"
}

# usage_refresh_secs — USAGE_REFRESH ("30s", "1m", "2h") as seconds. One knob
# for "how stale is OK before paying for an expensive re-fetch" — Claude's
# claude_refresh_costs (ccusage) and a pull-based agent's whole collect
# (tmux-ctdl.sh agent-pull-usage) both rate-limit against it.
usage_refresh_secs() { interval_secs "${USAGE_REFRESH:-1m}"; }

# ── Usage verbs ──────────────────────────────────────────────────────────────
# The two ways a usage payload gets in, named after the tmux-ctdl.sh verbs that call
# them (agent-push-usage → adapter_push_usage, agent-pull-usage →
# adapter_pull_usage) so the routing table reads straight across. How a payload
# is acquired, and how often, is this module's business, not the router's.

# _hook_payload — whatever a hook piped in, or empty when nothing is piped. The
# tty test is what lets these verbs be run by hand from a shell without hanging
# on a `cat` that will never see EOF.
_hook_payload() { [ -t 0 ] || cat; }

# adapter_push_usage <agent> — the agent handed us a payload on stdin (Claude's
# statusLine). No rate limit: the agent decides when to push.
adapter_push_usage() {
  adapter_main "$1" <<< "$(_hook_payload)"
}

# adapter_pull_usage <agent> <now> — no hook exists, so fetch the payload
# ourselves via <agent>_collect. No-op twice over: for a push-based agent (no
# collect defined), and for a stored read still fresher than USAGE_REFRESH.
# Gated on `rate` (account-wide, one file for every window) rather than a
# per-window kind: the wintab tick fires every second in EVERY window, so
# gating per-window would mean N windows each re-collecting on their own
# clock for a number that's identical across all of them. One global cooldown
# means at most one collect per USAGE_REFRESH, cluster-wide. <now> is a
# parameter, not a clock read, so the rate limit is assertable.
adapter_pull_usage() {
  local agent=$1 now=$2 age refresh
  declare -f "${agent}_collect" >/dev/null 2>&1 || return 0
  age=$(state_age "$now" rate "$agent")
  refresh=$(usage_refresh_secs)
  [ "$age" -lt "$refresh" ] && return 0
  "${agent}_collect" | adapter_main "$agent"
}

# adapter_footer <agent> — the end-of-turn footer. Same shape as the usage
# verbs: the payload arrives on stdin and is handed straight through, the agent
# module owns everything about what it means. Silent for an agent that defines
# no footer, so wiring the hook up for an agent that has none costs nothing.
adapter_footer() {
  local agent=$1
  declare -f "${agent}_footer" >/dev/null 2>&1 || return 0
  _hook_payload | "${agent}_footer"
}

# adapter_main <agent> — decode the payload on stdin and store what it carries.
# Read once into a local, then handed to each parser on its own stdin: the two
# parsers see the same bytes without either of them consuming the other's.
adapter_main() {
  local agent=$1 payload; payload=$(cat)

  local shared_kv; shared_kv="$("${agent}_parse_shared" <<< "$payload")"
  local -A F; kv_fill F <<< "$shared_kv"

  # Write only if we have anything worth showing (any field non-empty). model/
  # effort (per-window) and every other key (account-wide rate fields) split
  # into their own stores here — write_shared/write_rate each own how THEIR
  # half is kept, this just sorts the mail.
  local have=0 v
  for v in "${F[@]}"; do [ -n "$v" ] && { have=1; break; }; done
  if [ "$have" -eq 1 ]; then
    local mw_kv="" rate_kv="" k
    for k in "${!F[@]}"; do
      case "$k" in
        model|effort) mw_kv+="${mw_kv:+$'\n'}${k}"$'\t'"${F[$k]}" ;;
        *)            rate_kv+="${rate_kv:+$'\n'}${k}"$'\t'"${F[$k]}" ;;
      esac
    done
    write_shared "$agent" "$mw_kv"
    [ -n "$rate_kv" ] && write_rate "$agent" "$rate_kv"
  fi

  local ctx_kv; ctx_kv="$("${agent}_parse_context" <<< "$payload")"
  local -A C; kv_fill C <<< "$ctx_kv"
  [ -n "${C[ctx]:-}" ] && write_ctx "$agent" "$ctx_kv" "${F[model]:-}" "${F[effort]:-}"

  declare -f "${agent}_refresh_costs" >/dev/null 2>&1 && "${agent}_refresh_costs" "$agent"
  return 0
}
