#!/usr/bin/env bash
# Claude agent module — sourced by workspace-boot (as CODING_AGENT_MODULE) for
# every verb that needs Claude's identity or its parsers. Defines Claude's
# identity and all Claude-specific functions. Standalone: sources adapter-lib.sh
# if not already loaded.

if ! declare -f get_agent_usage >/dev/null 2>&1; then
  . "${TMUX_CTDL_HOME:-$HOME/.config/tmux/tmux-ctdl}/tmux-ctdl-boot.sh"
  tmux_ctdl_boot adapter
fi

AGENT_LABEL="Claude"
AGENT_CMD="claude --dangerously-skip-permissions"

# ── Parsers (push) ───────────────────────────────────────────────────────────
# Usage keys: session weekly five_reset week_reset, plus model/effort. An
# empty payload ({}, or no rate_limits at all) prints nothing — the sentinel
# defaults on five_reset/week_reset would otherwise read as "non-empty" to
# adapter_main's generic have-anything-to-write check and write a bogus row.
# One physical line: kcov's bash line tracer only credits the opening line of
# a multi-line quoted jq script, not the interior lines, even though they run.
claude_parse_shared() {
  jq -r 'if .rate_limits == null then empty else [["session", (.rate_limits.five_hour.used_percentage // "")], ["weekly", (.rate_limits.seven_day.used_percentage // "")], ["five_reset", (.rate_limits.five_hour.resets_at // 9999999999)], ["week_reset", (.rate_limits.seven_day.resets_at // 9999999999)], ["model", (.model.display_name // "")], ["effort", (.effort.level // "")]][] | @tsv end' 2>/dev/null
}

# Reject an OLDER rate-limit block than what's on disk (out-of-order delivery
# across a block boundary). 9999999999 sentinel → always allow overwriting.
#
# Within the SAME block, `rate` is now account-wide (one file, every window
# pushes into it — see state-lib.sh), and Claude Code re-sends each window's
# own cached session% on every 5s statusLine tick whether or not it has
# talked to the API since. An idle window's stale-but-unchanged cache and a
# busy window's freshly-higher real figure then fight over the same file
# every few seconds, flickering between the two. A small same-block DROP is
# that idle echo, not new information — reject it. A big drop is Claude
# Code's rare spike-correction bug (an erroneous ~100% self-corrected down to
# the real figure) and must still go through, which is why this isn't a flat
# "never decreases" rule.
claude_incoming_stale() {
  local agent=$1 incoming=$2
  local -A NEW OLD
  kv_fill NEW <<< "$incoming"
  state_get_kv OLD rate "$agent"
  local new_five="${NEW[five_reset]:-}"
  local old_five="${OLD[five_reset]:-9999999999}"
  [ "$old_five" = "9999999999" ] && return 1
  [ -z "$new_five" ] && return 1
  [ "$new_five" -lt "$old_five" ] 2>/dev/null && return 0
  if [ "$new_five" = "$old_five" ]; then
    local new_session="${NEW[session]:-0}" old_session="${OLD[session]:-0}"
    awk -v n="$new_session" -v o="$old_session" \
      'BEGIN{ exit !(n < o && (o - n) <= 30) }' && return 0
  fi
  return 1
}

# The three keys agentbar-lib's render_ctx reads, and no more. cache_write,
# cache_read, cost_usd and ctx_output used to be written here too — nothing ever
# read them back out. The statusLine payload still carries them, so re-adding a
# key is a one-line change the day a reader exists.
claude_parse_context() {
  jq -r 'if .context_window != null then [["ctx", (.context_window.used_percentage // 0)], ["ctx_used", (.context_window.total_input_tokens // 0)], ["ctx_max", (.context_window.context_window_size // 0)]][] | @tsv else empty end' 2>/dev/null
}

# ── Display / probe ──────────────────────────────────────────────────────────
# Parse pid+cwd from a single session JSON file. Pure: no kill, no HOME — testable
# with fixture files. Prints "pid\tcwd" on success, nothing on parse failure.
claude_parse_session() {
  local f=$1
  jq -r '[(.pid|tostring), .cwd] | @tsv' "$f" 2>/dev/null
}

# Live workspace cwds for the wintab run/idle pulse. One cwd per live session.
# sessions_dir defaults to ~/.claude/sessions; injectable for tests.
claude_live_cwds() {
  local sessions_dir="${1:-$HOME/.claude/sessions}"
  for f in "$sessions_dir"/*.json; do
    [ -f "$f" ] || continue
    IFS=$'\t' read -r pid cwd <<< "$(claude_parse_session "$f")"
    [ -z "$pid" ] || [ -z "$cwd" ] && continue
    kill -0 "$pid" 2>/dev/null && printf '%s\n' "$cwd"
  done
}

# _fmt_tokens <raw-state-value> <varname> — kfmt applied to a `tokens` state
# read, empty (not "0") when the cache holds nothing usable yet.
_fmt_tokens() {
  local raw=$1
  case "$raw" in '' | *[!0-9]*) printf -v "$2" ''; return 0 ;; esac
  [ "$raw" -gt 0 ] || { printf -v "$2" ''; return 0; }
  local k; kfmt "$raw" k
  printf -v "$2" 'Σ%s' "$k"
}

# claude_usage_rows <agent> <now> <tsess> <win> — the two usage rows for the
# agentbar, as label⇥pct⇥suffix⇥cost⇥tokens. Data only: no colours, no tmux
# syntax — agentbar-lib paints. Returns 1 when this window has never reported
# a percentage. tokens is each row's OWN total (ccusage's per-block total for
# Session, the 7-day sum for Weekly) — two different real numbers, not one
# figure copied onto both.
claude_usage_rows() {
  local agent=$1 now=$2 tsess=$3 win=$4

  local -A F
  get_agent_usage F "$agent" "$tsess" "$win" || return 1
  local session="${F[session]:-}" weekly="${F[weekly]:-}"
  local five_reset="${F[five_reset]:-}" week_reset="${F[week_reset]:-}"
  [ -z "${session}${weekly}" ] && return 1

  # The 9999999999 sentinel is Claude's own protocol (claude_parse_shared writes
  # it, claude_incoming_stale reads it), so it is decided here — until_at never
  # sees one, it only ever gets a real epoch.
  local block
  if [ "$five_reset" = "9999999999" ]; then
    block="⟳?:??"
  else
    block="⟳$(date -d "@${five_reset}" '+%H:%M' 2>/dev/null)($(until_at "$five_reset" "$now"))"
  fi

  local reset
  [ "$week_reset" = "9999999999" ] \
    && reset="⟳?@?:??" \
    || reset="⟳$(date -d "@${week_reset}" '+%a@%H:%M' 2>/dev/null)"

  local session_tok weekly_tok
  _fmt_tokens "$(state_get tokens "$agent" session)" session_tok
  _fmt_tokens "$(state_get tokens "$agent" weekly)"  weekly_tok

  # cost is never a truly empty string here — a missing cache reads as "-",
  # not "". Tab is bash's IFS-whitespace, so `read` COLLAPSES an empty field
  # sitting before a non-empty one (cost before tokens): tokens would slide
  # into cost's read slot. "-" keeps the field non-empty (paint_usage's own
  # numeric check already discards it, same as any other junk cost value).
  local session_cost weekly_cost
  session_cost=$(state_get cost "$agent" session); session_cost="${session_cost:--}"
  weekly_cost=$(state_get cost "$agent" weekly);   weekly_cost="${weekly_cost:--}"

  printf 'Session\t%s\t%s\t%s\t%s\n' "${session:-0}" "$block" "$session_cost" "$session_tok"
  printf 'Weekly\t%s\t%s\t%s\t%s\n'  "${weekly:-0}"  "$reset" "$weekly_cost"  "$weekly_tok"

  # Lifetime: no rate to show (pct left empty — paint_usage drops the "N%"
  # for a blank pct), just the running total since the earliest ccusage
  # record. Label carries the anchor date so the row is self-explanatory.
  local lifetime_cost lifetime_tok lifetime_since lifetime_label
  lifetime_cost=$(state_get cost "$agent" lifetime); lifetime_cost="${lifetime_cost:--}"
  _fmt_tokens "$(state_get tokens "$agent" lifetime)" lifetime_tok
  lifetime_since=$(state_get since "$agent" lifetime)
  if [ -n "$lifetime_since" ]; then
    lifetime_label="Since $(date -d "$lifetime_since" +"%b'%y" 2>/dev/null || printf '%s' "$lifetime_since")"
  else
    lifetime_label="Lifetime"
  fi
  # pct and suffix are "-", not "": read's IFS-whitespace splitting on a tab
  # stream collapses a genuinely empty field into its neighbour (same reason
  # session/weekly's cost falls back to "-" above) — paint_usage treats "-"
  # here as "omit", same sentinel, same reader.
  [ -n "$lifetime_tok" ] && printf '%s\t-\t-\t%s\t%s\n' "$lifetime_label" "$lifetime_cost" "$lifetime_tok"
  return 0
}

# ── End-of-turn footer ───────────────────────────────────────────────────────
# The Stop-hook line: what THIS turn cost. Deliberately NOT read back out of the
# ctx state the statusLine writes — that carries session totals on a
# refreshInterval, so it is both cumulative and always one message behind the
# turn that just ended. The transcript is the only per-turn source.

# claude_effort_level — Claude Code's own effortLevel knob. It lives in Claude's
# settings, not tmux-ctdl.conf, so reading it is this module's business.
# CLAUDE_SETTINGS is injectable for tests.
claude_effort_level() {
  jq -r '.effortLevel // "default"' "${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}" 2>/dev/null \
    || printf 'default'
}

# claude_price_for_model <model> — "<in_per_mtok> <out_per_mtok>", empty for a
# model with no published rate here.
# ponytail: hand-maintained table. ccusage (already used by claude_refresh_costs)
# knows real pricing but only aggregates per block/day — switch to it the day it
# grows a per-message mode.
claude_price_for_model() {
  case "$1" in
    *fable-5*|*mythos-5*)                      printf '10 50' ;;
    *opus-5*|*opus-4-8*|*opus-4-7*|*opus-4-6*) printf '5 25' ;;
    *sonnet-5*)                                printf '2 10' ;;  # intro pricing through 2026-08-31
    *sonnet-4-6*)                              printf '3 15' ;;
    *haiku-4-5*)                               printf '1 5' ;;
  esac
}

# claude_turn_cost <model> <in> <out> <cache_read> <cache_write> — dollars for
# one turn. Cache reads bill at 10% of the input rate, cache writes at 125%.
# Prints nothing for an unpriced model: no figure beats a wrong figure.
claude_turn_cost() {
  local prices price_in price_out
  prices=$(claude_price_for_model "$1")
  [ -z "$prices" ] && return 0
  read -r price_in price_out <<< "$prices"
  awk -v i="$2" -v o="$3" -v cr="$4" -v cw="$5" -v pin="$price_in" -v pout="$price_out" \
    'BEGIN{ printf "%.4f", (i*pin + o*pout + cr*pin*0.1 + cw*pin*1.25) / 1000000 }'
}

# claude_footer_line <model> <level> <in> <out> <cr> <cw> — the human-readable
# turn line. Pure: no stdin, no clock, no transcript — claude_footer owns
# getting these six values, this owns only how they read as one line.
#
# input_tokens (in) is near-constant regardless of turn size — Claude Code
# puts a cache_control breakpoint around everything except a small fixed
# trailing chunk, so `in` measures protocol overhead, not what changed. The
# real per-turn signal is cache_creation_input_tokens (cw): content that
# missed cache and got freshly written. So `in` is folded into the total but
# not broken out on its own.
#
# Σ = total billed footprint (in+out+cr+cw), ↑ = output generated,
# ⊕ = new content written to cache this turn (cw), ⇄ = cache hit rate
# (cr / (cr+cw+in)) — efficiency, not a raw count: a near-100% turn used
# almost no fresh tokens even on a huge total. AIU = AI Unit, $0.01 flat, so
# cost reads in a currency-agnostic unit alongside the dollar figure.
claude_footer_line() {
  local model=$1 level=$2 in=$3 out=$4 cr=$5 cw=$6
  local cost total_k new_k hit_pct aiu line
  cost=$(claude_turn_cost "$model" "$in" "$out" "$cr" "$cw")
  kfmt "$(( in + out + cr + cw ))" total_k
  kfmt "$cw" new_k
  hit_pct=$(awk -v cr="$cr" -v cw="$cw" -v i="$in" 'BEGIN{ d = cr + cw + i; printf "%.1f", (d > 0 ? cr / d * 100 : 0) }') # KCOV_TRACER_LOST
  line="Used Σ${total_k}(⊕${new_k},⇄${hit_pct}%) ↑${out}"
  if [ -n "$cost" ]; then
    aiu=$(awk -v c="$cost" 'BEGIN{ printf "%.1f", int(c / 0.01 * 10) / 10 }')
    line+=" | \$${cost} ${aiu}AIU"
  fi
  line+=" | ${model} ${level}"
  printf '%s' "$line"
}

# claude_footer — the Stop-hook response over the hook payload on stdin. Reports
# the turn through `systemMessage`, which puts the line in front of the user
# without blocking. stop_hook_active is still honoured: any OTHER blocking Stop
# hook re-enters this one, and a duplicate cost report is noise.
# Answers {"continue": true} whenever there is nothing to say.
claude_footer() {
  local payload; payload=$(cat)
  local transcript stop_active
  transcript=$(jq -r '.transcript_path // empty' <<< "$payload" 2>/dev/null)
  stop_active=$(jq -r '.stop_hook_active // false' <<< "$payload" 2>/dev/null)
  if [ "$stop_active" = true ] || [ -z "$transcript" ]; then
    printf '{"continue": true}\n'; return 0
  fi

  # The transcript write can lag the Stop event firing — retry briefly.
  local last usage model i
  for i in 1 2 3 4 5; do
    last=$(tac "$transcript" 2>/dev/null | grep -m1 '"role":"assistant"')
    usage=$(jq -c '.message.usage // empty' <<< "$last" 2>/dev/null)
    model=$(jq -r '.message.model // empty' <<< "$last" 2>/dev/null)
    [ -n "$usage" ] && break
    sleep 0.1
  done
  [ -n "$usage" ] || { printf '{"continue": true}\n'; return 0; }

  local in out cr cw
  IFS=$'\t' read -r in out cr cw < <(jq -r '[(.input_tokens // 0), (.output_tokens // 0), (.cache_read_input_tokens // 0), (.cache_creation_input_tokens // 0)] | @tsv' <<< "$usage" 2>/dev/null)

  local level line
  level=$(claude_effort_level)
  line=$(claude_footer_line "$model" "$level" "$in" "$out" "$cr" "$cw")

  # Reported, not demanded. This used to answer decision:"block" with an
  # instruction to append the line — the only way to get text into the
  # assistant's own message, since a Stop hook has no "print this" channel. It
  # cost two things: Claude Code renders any blocking Stop hook as an ERROR, and
  # the block buys a whole extra model turn whose only job is echoing one line.
  # systemMessage shows the user the same text with neither cost. The trade: the
  # line is a UI notice, so it is not part of the transcript the model reads.
  #
  # Built with jq, not a heredoc: the model name and the line both land inside a
  # JSON string, and a stray quote in either would otherwise emit invalid JSON
  # that Claude Code reports as a real hook failure.
  jq -n --arg msg "$line" '{continue: true, systemMessage: $msg}'
}

# ── Cost + tokens ────────────────────────────────────────────────────────────
# One function per slot, named. A third slot is a third function plus a word in
# the loop below — no registry, no eval. Each prints "cost<TAB>tokens" — one
# ccusage call already carries both, no reason to shell out twice.

claude_cost_weekly() {
  npm exec ccusage -- daily --since "$(date -d '7 days ago' +%Y-%m-%d)" --json 2>/dev/null \
    | jq -r '([.daily[].totalCost // 0] | add // 0) as $c | ([.daily[].totalTokens // 0] | add // 0) as $t | "\($c)\t\($t)"'
}

claude_cost_session() {
  npm exec ccusage -- blocks --json 2>/dev/null \
    | jq -r '.blocks[-1] | "\(.costUSD // 0)\t\(.totalTokens // 0)"'
}

# claude_cost_lifetime — cost<TAB>tokens<TAB>since (earliest daily record's
# date), summed over every day ccusage has on disk. No --since flag needed:
# an absent one is "everything", which is exactly the anchor we want.
claude_cost_lifetime() {
  npm exec ccusage -- daily --json 2>/dev/null \
    | jq -r '(.daily // []) as $d | ($d | map(.totalCost // 0) | add // 0) as $c | ($d | map(.totalTokens // 0) | add // 0) as $t | ($d | map(.date) | min // "") as $s | "\($c)\t\($t)\t\($s)"'
}

# claude_refresh_costs <agent> — repopulate both slots' cost+tokens caches in
# the background, skipping any slot refreshed within USAGE_REFRESH.
#
# Every tmux window runs its own statusLine hook against the SAME cache files
# (AGENT_TMP_DIR is shared, not per-window), so the staleness check above is
# not enough on its own: N windows ticking past USAGE_REFRESH at once all read
# "stale" before any of them finishes writing (ccusage takes over a second),
# and all N shell out. flock makes losing that race a no-op instead of a
# duplicate ccusage call — one window's background job runs, the rest skip.
claude_refresh_costs() {
  local agent=$1 now refresh slot
  now=$(date +%s)
  refresh=$(usage_refresh_secs)
  for slot in weekly session lifetime; do
    [ "$(state_age "$now" cost "$agent" "$slot")" -gt "$refresh" ] && \
      ( flock -n 9 || exit 0
        out=$("claude_cost_${slot}") &&
        IFS=$'\t' read -r cost_val tok_val since_val <<< "$out" &&
        state_put "$cost_val" cost   "$agent" "$slot" &&
        state_put "$tok_val"  tokens "$agent" "$slot" &&
        { [ -z "$since_val" ] || state_put "$since_val" since "$agent" "$slot"; }
      ) 9>"$(state_lockfile "agent-cost-refresh-${slot}-${agent}.lock")" &
  done
  return 0
}
