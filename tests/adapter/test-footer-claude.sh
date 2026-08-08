#!/usr/bin/env bash
# claude_footer — the end-of-turn Stop-hook line. Covers the price table, the
# per-turn cost arithmetic, the transcript tail, and every path that must say
# nothing at all. Nothing here ever blocks: the line is reported through
# systemMessage. The transcript is a real JSONL file in a scratch dir; nothing
# here touches the live session.
DIR="$(cd "$(dirname "$0")" && pwd)" || exit 1
. "$DIR/../helpers.sh"
SCRIPTS="$DIR/../.."

export TMUX_CTDL_HOME="$(cd "$DIR/../.." && pwd)"
CONF_DIR=$(mktemp -d)
cat > "$CONF_DIR/tmux-ctdl.conf" << CONF
CODING_AGENT="claude"
CONF
export TMUX_CTDL_CONF="$CONF_DIR/tmux-ctdl.conf"

export AGENT_TMP_DIR
AGENT_TMP_DIR=$(mktemp -d)
WORK=$(mktemp -d)
trap 'rm -rf "$AGENT_TMP_DIR" "$CONF_DIR" "$WORK"' EXIT

. "$TMUX_CTDL_HOME/adapter/adapter-claude.sh"

# effortLevel is read from Claude's own settings — point it at a scratch copy so
# the assertions don't drift when the real setting changes.
printf '{"effortLevel":"high"}\n' > "$WORK/settings.json"
export CLAUDE_SETTINGS="$WORK/settings.json"

# _transcript <model> <in> <out> <cache_read> <cache_write> — a JSONL transcript
# whose LAST assistant line carries that usage, preceded by a user line and an
# earlier assistant line so the tail is actually doing something.
_transcript() {
  local f="$WORK/transcript.jsonl"
  {
    printf '{"role":"assistant","message":{"model":"stale","usage":{"input_tokens":1,"output_tokens":1}}}\n'
    printf '{"role":"user","message":{"content":"hi"}}\n'
    printf '{"role":"assistant","message":{"model":"%s","usage":{"input_tokens":%s,"output_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s}}}\n' \
      "$1" "$2" "$3" "$4" "$5"
  } > "$f"
  printf '%s' "$f"
}

# _footer <transcript> [stop_active] — run claude_footer over a Stop payload.
_footer() {
  printf '{"transcript_path":"%s","stop_hook_active":%s}' "$1" "${2:-false}" \
    | claude_footer
}

# ── Pricing ─────────────────────────────────────────────────────────────────

test_price_table_known_models() {
  [ "$(claude_price_for_model claude-opus-5)" = "5 25" ] &&
  [ "$(claude_price_for_model claude-sonnet-5)" = "2 10" ] &&
  [ "$(claude_price_for_model claude-haiku-4-5-20251001)" = "1 5" ] &&
  [ "$(claude_price_for_model claude-fable-5)" = "10 50" ] &&
  [ "$(claude_price_for_model claude-mythos-5)" = "10 50" ] &&
  [ "$(claude_price_for_model claude-sonnet-4-6)" = "3 15" ]
}

test_price_table_unknown_model_is_empty() {
  assert_empty "$(claude_price_for_model some-other-llm)" "unknown model has no price"
}

# 1M input at $5/Mtok = $5.0000 exactly — the plain input leg, no cache.
test_turn_cost_input_leg() {
  [ "$(claude_turn_cost claude-opus-5 1000000 0 0 0)" = "5.0000" ]
}

# Cache reads bill at 10% of input: 1M reads at $5/Mtok = $0.50.
test_turn_cost_cache_read_is_tenth() {
  [ "$(claude_turn_cost claude-opus-5 0 0 1000000 0)" = "0.5000" ]
}

# Cache writes bill at 125% of input: 1M writes at $5/Mtok = $6.25.
test_turn_cost_cache_write_is_surcharged() {
  [ "$(claude_turn_cost claude-opus-5 0 0 0 1000000)" = "6.2500" ]
}

# 1M output at $25/Mtok = $25.
test_turn_cost_output_leg() {
  [ "$(claude_turn_cost claude-opus-5 0 1000000 0 0)" = "25.0000" ]
}

test_turn_cost_unpriced_model_is_empty() {
  assert_empty "$(claude_turn_cost mystery-model 999 999 999 999)" "no price → no cost"
}

# ── The footer line ─────────────────────────────────────────────────────────

# Reported, never demanded: a `decision` here would make Claude Code render the
# hook as an error and buy an extra model turn to echo the line.
test_footer_reports_usage_line_without_blocking() {
  local out; out=$(_footer "$(_transcript claude-opus-5 2 141 120860 0)")
  [ "$(jq -r '.continue' <<< "$out")" = "true" ] &&
  [ "$(jq -r '.decision // "none"' <<< "$out")" = "none" ] &&
  assert_contains "$(jq -r '.systemMessage' <<< "$out")" "Σ121k" "total is in+out+cache, kfmt-shortened" &&
  assert_contains "$(jq -r '.systemMessage' <<< "$out")" "Σ121k(⊕0,⇄100.0%) ↑141" "output, new-cache-write, hit rate" &&
  assert_contains "$(jq -r '.systemMessage' <<< "$out")" "claude-opus-5" "model from the transcript"
}

# claude_footer_line is the pure core: no stdin, no transcript, no retry —
# same six values claude_footer would have extracted, asserted directly.
test_footer_line_pure_format() {
  local out; out=$(claude_footer_line claude-opus-5 high 2 141 120860 0)
  assert_contains "$out" "Σ121k(⊕0,⇄100.0%) ↑141" "icons, hit rate not raw cache count" &&
  assert_contains "$out" "\$0.0640" "cost, no 'cost:' label" &&
  assert_contains "$out" "6.4AIU" "cost in AI Units, \$0.01 flat" &&
  ! printf '%s' "$out" | grep -q 'cost:' &&
  assert_contains "$out" "claude-opus-5 high" "model + level, no 'model:' label" &&
  ! printf '%s' "$out" | grep -q 'model:'
}

test_footer_reads_effort_from_claude_settings() {
  local out; out=$(_footer "$(_transcript claude-opus-5 2 141 120860 0)")
  assert_contains "$(jq -r '.systemMessage' <<< "$out")" "claude-opus-5 high" "effortLevel read from settings, trails the model"
}

# Cost of that same turn, at opus-5's $5/$25 with cache reads at a tenth of
# input: (2*5 + 141*25 + 120860*0.5) / 1e6 = 63965/1e6 = $0.0640.
test_footer_includes_cost() {
  local out; out=$(_footer "$(_transcript claude-opus-5 2 141 120860 0)")
  assert_contains "$(jq -r '.systemMessage' <<< "$out")" '$0.0640' "per-turn cost"
}

test_footer_omits_cost_for_unpriced_model() {
  local out; out=$(_footer "$(_transcript some-other-llm 10 10 0 0)")
  local reason; reason=$(jq -r '.systemMessage' <<< "$out")
  assert_contains "$reason" "Σ20" "still reports tokens" &&
  ! printf '%s' "$reason" | grep -qF '$'
}

# The output must be valid JSON even when the model name carries a quote —
# the old heredoc would have emitted a broken object here.
test_footer_survives_quote_in_model_name() {
  local out; out=$(_footer "$(_transcript 'weird"model' 5 5 0 0)")
  jq -e . >/dev/null 2>&1 <<< "$out"
}

test_footer_takes_the_last_assistant_message() {
  local out; out=$(_footer "$(_transcript claude-sonnet-5 7 3 0 0)")
  assert_contains "$(jq -r '.systemMessage' <<< "$out")" "Σ10" "tail, not the stale first line"
}

# ── Passthrough paths ───────────────────────────────────────────────────────

# The re-entry guard. This hook no longer blocks, but any OTHER blocking Stop
# hook re-enters the chain — and a duplicate cost report is noise.
test_footer_stop_hook_active_passes_through() {
  local out; out=$(_footer "$(_transcript claude-opus-5 2 141 120860 0)" true)
  [ "$(jq -r '.continue' <<< "$out")" = "true" ] &&
  [ "$(jq -r '.decision // "none"' <<< "$out")" = "none" ]
}

test_footer_no_transcript_path_passes_through() {
  [ "$(printf '{"stop_hook_active":false}' | claude_footer | jq -r '.continue')" = "true" ]
}

test_footer_missing_transcript_file_passes_through() {
  local out; out=$(_footer "$WORK/does-not-exist.jsonl")
  [ "$(jq -r '.continue' <<< "$out")" = "true" ]
}

# A transcript with no assistant line yet (Stop fired before the write landed
# and the retries all missed) must not emit a half-built line.
test_footer_transcript_without_assistant_passes_through() {
  printf '{"role":"user","message":{"content":"hi"}}\n' > "$WORK/user-only.jsonl"
  local out; out=$(_footer "$WORK/user-only.jsonl")
  [ "$(jq -r '.continue' <<< "$out")" = "true" ]
}

# ── Wiring ──────────────────────────────────────────────────────────────────

# The verb Claude Code's Stop hook actually calls, end to end through tmux-ctdl.sh.
test_ctdl_agent_footer_verb() {
  local t; t=$(_transcript claude-opus-5 2 141 120860 0)
  local out
  out=$(printf '{"transcript_path":"%s","stop_hook_active":false}' "$t" \
        | CLAUDE_SETTINGS="$WORK/settings.json" bash "$SCRIPTS/tmux-ctdl.sh" agent-footer)
  assert_contains "$(jq -r '.systemMessage' <<< "$out")" "Σ121k" "verb produced the line"
}

# adapter_footer is silent for an agent that defines no footer, so wiring the
# hook up under a different CODING_AGENT costs nothing.
test_adapter_footer_without_hook_is_silent() {
  local out; out=$(adapter_footer nosuchagent < /dev/null 2>&1)
  assert_empty "$out" "no footer hook → nothing said"
}

run_tests \
  test_price_table_known_models \
  test_price_table_unknown_model_is_empty \
  test_turn_cost_input_leg \
  test_turn_cost_cache_read_is_tenth \
  test_turn_cost_cache_write_is_surcharged \
  test_turn_cost_output_leg \
  test_turn_cost_unpriced_model_is_empty \
  test_footer_reports_usage_line_without_blocking \
  test_footer_line_pure_format \
  test_footer_reads_effort_from_claude_settings \
  test_footer_includes_cost \
  test_footer_omits_cost_for_unpriced_model \
  test_footer_survives_quote_in_model_name \
  test_footer_takes_the_last_assistant_message \
  test_footer_stop_hook_active_passes_through \
  test_footer_no_transcript_path_passes_through \
  test_footer_missing_transcript_file_passes_through \
  test_footer_transcript_without_assistant_passes_through \
  test_ctdl_agent_footer_verb \
  test_adapter_footer_without_hook_is_silent
