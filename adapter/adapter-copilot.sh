#!/usr/bin/env bash
# Copilot agent module — SKELETON. Sourced by workspace-boot (as
# CODING_AGENT_MODULE) for every verb that needs Copilot's identity or its
# parsers. Defines Copilot's identity and all Copilot-specific functions.
# Standalone: sources adapter-lib.sh if not already loaded.
#
# Enable by setting CODING_AGENT=copilot in tmux-ctdl.conf.

if ! declare -f get_agent_usage >/dev/null 2>&1; then
  . "${TMUX_CTDL_HOME:-$HOME/.config/tmux/tmux-ctdl}/libs/boot-lib.sh"
  tmux_ctdl_boot adapter
fi

AGENT_LABEL="Copilot"
AGENT_CMD="copilot"
# No <agent>_refresh_costs hook: Copilot bills in AI credits, not per-block $
# like ccusage.

# Copilot has no hooks, so it has no push — tmux-ctdl.sh agent-pull-usage drives it
# via <agent>_collect instead of a statusLine.
COPILOT_DB="${COPILOT_DB:-$HOME/.copilot/session-store.db}"

# ── Collect + parsers (pull) ─────────────────────────────────────────────────
# copilot_collect — read-only query against Copilot's own session-store.db
# (SQLite, WAL). Prints one JSON object so parse_shared/parse_context can jq it
# exactly like Claude's stdin payload — same contract, different source. Prints
# "{}" when the db doesn't exist yet (Copilot installed but never run).
copilot_collect() {
  [ -f "$COPILOT_DB" ] || { printf '{}'; return 0; }
  sqlite3 -readonly -json "$COPILOT_DB" 'SELECT model, reasoning_effort FROM assistant_usage_events ORDER BY id DESC LIMIT 1' 2>/dev/null | jq -c '.[0] // {}' # KCOV_TRACER_LOST
}

# Usage keys: today week month (not sourced yet — see below), plus model/effort,
# now read for real from the latest assistant_usage_events row.
copilot_parse_shared() {
  jq -r '[["model", (.model // "")], ["effort", (.reasoning_effort // "")]][] | @tsv' 2>/dev/null
}

# today/week/month are AI-credit quota percentages, which live behind
# GET /copilot_internal/user (quota_snapshots), not in session-store.db — a
# network call, not a collect query. Out of scope here; copilot_usage_rows
# still returns 1 (no row) until that endpoint is wired.
#
# Context-window telemetry isn't in the db either (no ctx_max column) → emit
# nothing, same as before, but now because the data genuinely doesn't exist
# rather than because nothing was wired.
copilot_parse_context() {
  :
}

# ── Display / probe ──────────────────────────────────────────────────────────
# Live workspace cwds for the wintab pulse. Copilot has no hooks, so process
# cwd is the only state source.
# TODO(copilot): replace with real session cwds from ~/.copilot once schema known.
copilot_live_cwds() {
  local pid
  for pid in $(pgrep -x copilot 2>/dev/null); do
    readlink "/proc/$pid/cwd" 2>/dev/null
  done
}

# copilot_usage_rows <agent> <now> <tsess> <win> — three usage rows as
# label⇥pct⇥suffix⇥cost. Cost is always empty: Copilot bills in AI credits,
# not dollars. Returns 1 when no usage has been reported.
copilot_usage_rows() {
  local agent=$1 now=$2 tsess=$3 win=$4

  local -A F
  get_agent_usage F "$agent" "$tsess" "$win" || return 1
  local today="${F[today]:-}" week="${F[week]:-}" month="${F[month]:-}"
  [ -z "${today}${week}${month}" ] && return 1

  printf 'Today\t%s\t⟳%s\t\n' "${today:-0}" "$(date -d 'tomorrow 00:00' '+%H:%M' 2>/dev/null)"
  printf 'Week\t%s\t⟳%s\t\n'  "${week:-0}"  "$(date -d 'next monday' '+%a' 2>/dev/null)"
  printf 'Month\t%s\t⟳%s\t\n' "${month:-0}" "$(date -d "$(date '+%Y-%m-01') +1 month" '+%b %-d' 2>/dev/null)"
}
