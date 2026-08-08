#!/usr/bin/env bash
# Agent state store. The interface is verbs — get, put, mark, clear, exists, age
# — and the fact that state is a pile of files under AGENT_TMP_DIR is an
# implementation detail no caller sees. Nothing outside this module calls touch,
# rm, stat or cat on a state file, and nothing outside it knows a filename.
#
# Every verb ends in <kind> <agent> [keys...]. The keys are VARIADIC and their
# number is a property of the kind, so a caller passes exactly the keys its kind
# has and never pads a slot to reach an argument behind it. Anything that is not
# a key — the value to write, the clock to measure against, the array to fill —
# comes FIRST, ahead of the kind, for the same reason.
#
# Kinds, by key shape:
#   per agent      rate    <agent>            account-wide rate-limit fields
#                                              (Claude: session weekly five_reset
#                                              week_reset; Copilot: today week
#                                              month) — the SAME real number
#                                              regardless of which window's
#                                              process last reported it, so one
#                                              file, not one per window.
#   per window     shared  <agent> <sess> <win>   that window's own model/effort
#                  ctx     <agent> <sess> <win>   that window's context line
#                  phase   <agent> <sess> <win>   wintab badge phase (wintab-lib)
#                  cleared <agent> <sess> <win>   marker: /clear seen while running
#                  live    <agent> <sess> <win>   marker: agent last seen live
#   per slot       cost    <agent> <slot>     cached $-cost for one cost slot
#                  tokens  <agent> <slot>     cached token total for one usage row
#                  since   <agent> <slot>     cached anchor date for a cumulative slot (lifetime)
#
# rate used to be folded into shared and keyed per window — every tmux window
# running the agent had its OWN process pushing its OWN last-known rate-limit
# read into its OWN file. Harmless for the rate numbers themselves (same
# account, same real percentage no matter who reports it) but it meant an idle
# window never saw a number update unless ITS OWN pane ran a turn — a window
# could sit hours behind a busy sibling showing the true, current figure.
# model/effort stayed per-window on purpose: two panes can genuinely run
# different models, so THAT part keyed by agent alone is the old flicker bug
# (one window's bar randomly showing a different window's model on any given
# tick) — shared still exists, just narrowed to the two keys that actually
# vary per window.
#
# AGENT_TMP_DIR (default /tmp) is the root — tests point it at a scratch dir so a
# test run never clobbers the live status files.

_agent_tmp() { printf '%s' "${AGENT_TMP_DIR:-/tmp}"; }

# state_lockfile <name> — full path for a caller-owned lockfile (flock target),
# under the same root every state file lives in. Not a <kind>: a lock has no
# value to get/put, just a path a caller flocks against — but the root and its
# override (AGENT_TMP_DIR) stay state-lib's alone to know, same as any other
# path this module hands out.
state_lockfile() { printf '%s/%s' "$(_agent_tmp)" "$1"; }

# The whole on-disk layout, in one function. Private — callers use the verbs.
_state_path() {
  local kind=$1 agent=$2 k1=${3:-} k2=${4:-} tmp
  tmp="$(_agent_tmp)"
  case "$kind" in
    rate)   printf '%s/agent-rate-%s'         "$tmp" "$agent" ;;
    shared) printf '%s/agent-shared-%s-%s-%s' "$tmp" "$agent" "${k1:-_}" "${k2:-0}" ;;
    ctx)    printf '%s/agent-ctx-%s-%s-%s' "$tmp" "$agent" "${k1:-_}" "${k2:-0}" ;;
    cost)   printf '%s/agent-cost-%s-%s'   "$tmp" "${k1,,}" "$agent" ;;
    tokens) printf '%s/agent-tokens-%s-%s' "$tmp" "${k1,,}" "$agent" ;;
    since)  printf '%s/agent-since-%s-%s'  "$tmp" "${k1,,}" "$agent" ;;
    *)      printf '%s/agent-%s-%s-%s-%s'  "$tmp" "$kind" "$agent" "$k1" "$k2" ;;
  esac
}

# state_get <kind> <agent> [keys...] — print the stored value. Returns 1 when the
# entry does not exist, so callers can branch without a separate check.
state_get() {
  local f; f="$(_state_path "$@")"
  [ -f "$f" ] || return 1
  cat "$f"
}

# state_exists <kind> <agent> [keys...] — true when the entry is present, whether
# or not it carries a value. Markers (cleared, live) are tested with this.
state_exists() { [ -f "$(_state_path "$@")" ]; }

# _state_write <path> <value> — atomic (tmp + rename), so a reader on the 1s
# status tick never sees a half-written file. An empty value writes an empty
# file, which is what a marker is.
_state_write() {
  local f=$1 value=$2 t="${1}.tmp.$$"
  if [ -n "$value" ]; then printf '%s\n' "$value" > "$t"; else : > "$t"; fi
  mv -f "$t" "$f"
}

# state_put <value> <kind> <agent> [keys...] — store a value. The value leads so
# that the keys stay variadic behind it; a kind with one key passes one key.
state_put() {
  local value=$1; shift
  _state_write "$(_state_path "$@")" "$value"
}

# state_mark <kind> <agent> [keys...] — stamp a marker: empty content, fresh
# mtime, read back with state_exists or state_age. Its own verb rather than
# "state_put with the value left off": the markers (cleared, live) are a
# different operation, and expressing them as a missing trailing argument is the
# kind of positional accident this interface exists to prevent.
state_mark() { _state_write "$(_state_path "$@")" ""; }

# state_clear <kind> <agent> [keys...] — forget the entry.
state_clear() { rm -f "$(_state_path "$@")"; }

# kv_fill <arrayname> — read key<TAB>value lines on stdin into the caller's
# associative array (nameref). Keys are whatever the writer chose; this
# function never learns their names, so adding a field needs no change here.
kv_fill() {
  local -n _kv_fill_arr=$1
  _kv_fill_arr=()
  local key val
  while IFS=$'\t' read -r key val; do
    [ -n "$key" ] && _kv_fill_arr["$key"]="$val"
  done
}

# state_get_kv <arrayname> <kind> <agent> [keys...] — fill the caller's
# associative array from a stored key/value value. Returns 1 (array left
# empty) when the entry doesn't exist.
state_get_kv() {
  local arrname=$1; shift
  local raw
  raw="$(state_get "$@")" || { local -n _e=$arrname; _e=(); return 1; }
  kv_fill "$arrname" <<< "$raw"
}

# state_age <now> <kind> <agent> [keys...] — seconds since the entry was last
# written. A missing entry reads as 99999999, i.e. "long ago", so a caller can
# compare against a grace window without a separate existence check. <now> is a
# parameter, not a clock read, so every rate limit built on this is assertable —
# and it leads, so a per-agent or per-slot kind reaches it without padding the
# key slots it doesn't have.
state_age() {
  local now=$1; shift
  local f mtime
  f="$(_state_path "$@")"
  mtime=$(stat -c %Y "$f" 2>/dev/null)
  [ -n "$mtime" ] || { printf '99999999'; return 0; }
  printf '%s' "$(( now - mtime ))"
}

# state_reap_stale <now> — delete state files older than STATE_MAX_AGE
# (default 6h). tmux's window-id counter resets to 0 on every fresh SERVER
# start (not a session restart), so a new window can be handed an id an old,
# long-dead window used — and silently inherit its leftover file as if it
# were live data, with no way to tell the two apart by content alone. Age is
# the only signal available. Rate-limited by its own marker (STATE_REAP_INTERVAL,
# default 10m) so a per-second caller (wintab_tick) isn't running `find` every
# tick.
state_reap_stale() {
  local now=$1 tmp marker mtime
  tmp="$(_agent_tmp)"
  marker="$tmp/agent-reap-marker"
  mtime=$(stat -c %Y "$marker" 2>/dev/null || printf 0)
  [ "$(( now - mtime ))" -lt "${STATE_REAP_INTERVAL:-600}" ] && return 0
  : > "$marker"
  find "$tmp" -maxdepth 1 -name 'agent-*' ! -name 'agent-reap-marker' \
    -mmin "+$(( ${STATE_MAX_AGE:-21600} / 60 ))" -delete 2>/dev/null
  return 0
}
