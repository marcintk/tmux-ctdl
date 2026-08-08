#!/usr/bin/env bash
# ctdl.sh agent-pull-usage — the pull path. Covers copilot_collect against a
# real (fixture) session-store.db, parse_shared/parse_context over that payload,
# and the USAGE_REFRESH rate limit.
DIR="$(cd "$(dirname "$0")" && pwd)" || exit 1
. "$DIR/../helpers.sh"
. "$DIR/../../libs/state-lib.sh"
SCRIPTS="$DIR/../.."

command -v sqlite3 >/dev/null 2>&1 || { echo "skip: sqlite3 not installed"; exit 0; }

# WORKSPACE_HOME points the boot module at the repo; WORKSPACE_CONF pins
# CODING_AGENT=copilot regardless of the live workspace.conf's setting.
export WORKSPACE_HOME="$(cd "$DIR/../.." && pwd)"
CONF_DIR=$(mktemp -d)
export WORKSPACE_CONF="$CONF_DIR/workspace.conf"

# _write_conf <usage_refresh> — regenerate the scratch conf. Default 0 so a
# pull always re-queries the db; the rate-limit test asks for a real interval.
_write_conf() {
  cat > "$WORKSPACE_CONF" << CONF
CODING_AGENT="copilot"
USAGE_REFRESH="${1:-0}"
CONF
}

# Scratch state dir so a test run never clobbers the live /tmp status files.
export AGENT_TMP_DIR
AGENT_TMP_DIR=$(mktemp -d)
DB_DIR=$(mktemp -d)
trap 'rm -rf "$AGENT_TMP_DIR" "$CONF_DIR" "$DB_DIR"' EXIT

# _make_db <model> <effort> — a session-store.db fixture with the one table
# copilot_collect reads, mirroring the real CREATE TABLE shape.
_make_db() {
  local db=$1 model=$2 effort=$3
  sqlite3 "$db" "
    CREATE TABLE assistant_usage_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      model TEXT NOT NULL,
      reasoning_effort TEXT
    );
    INSERT INTO assistant_usage_events (model, reasoning_effort)
    VALUES ('$model', '$effort');
  "
}

setup() {
  rm -f "$AGENT_TMP_DIR"/agent-shared-copilot-* "$AGENT_TMP_DIR"/agent-ctx-copilot-* "$AGENT_TMP_DIR"/agent-rate-copilot
  rm -f "$DB_DIR"/db.sqlite
  export PATH="$FIXTURES:$PATH"
  export MOCK_SESSION=test-session MOCK_WIN=@1
  export TMUX_PANE=mock-pane
  _write_conf "${1:-0}"
}

# The real path: collect reads model/effort from the latest usage event.
test_writes_shared_from_db() {
  setup
  _make_db "$DB_DIR/db.sqlite" GPT-5 high
  COPILOT_DB="$DB_DIR/db.sqlite" bash "$SCRIPTS/ctdl.sh" agent-pull-usage
  assert_file_exists "$AGENT_TMP_DIR/agent-shared-copilot-test-session-@1" &&
  local -A F; kv_fill F < "$AGENT_TMP_DIR/agent-shared-copilot-test-session-@1"
  assert_contains "${F[model]}" "GPT-5" "model written from db" &&
  assert_contains "${F[effort]}" "high" "effort written from db"
}

# copilot_collect/copilot_parse_shared called directly in-process, same real
# db as test_writes_shared_from_db above but without the ctdl.sh subprocess
# hop — belt and suspenders against losing this path to that indirection.
test_collect_and_parse_shared_direct() {
  setup
  _make_db "$DB_DIR/db.sqlite" GPT-5 high
  local out
  out=$(bash -c '. "$1"; COPILOT_DB="$2" copilot_collect | copilot_parse_shared' \
        _ "$WORKSPACE_HOME/adapter/adapter-copilot.sh" "$DB_DIR/db.sqlite")
  assert_contains "$out" "$(printf 'model\tGPT-5')" "model parsed directly" &&
  assert_contains "$out" "$(printf 'effort\thigh')" "effort parsed directly"
}

# No db yet (Copilot installed, never run a session) → collect prints "{}",
# nothing to write, no crash.
test_silent_without_db() {
  setup
  COPILOT_DB="$DB_DIR/nope.sqlite" bash "$SCRIPTS/ctdl.sh" agent-pull-usage
  [ ! -f "$AGENT_TMP_DIR/agent-shared-copilot-test-session-@1" ]
}

# No context telemetry in the db → no ctx file, even with a model present.
test_no_ctx_file() {
  setup
  _make_db "$DB_DIR/db.sqlite" GPT-5 high
  COPILOT_DB="$DB_DIR/db.sqlite" bash "$SCRIPTS/ctdl.sh" agent-pull-usage
  [ ! -f "$AGENT_TMP_DIR/agent-ctx-copilot-test-session-@1" ]
}

# Copilot has no cost commands → refresh_costs must not spawn / error.
test_no_cost_refresh() {
  setup
  _make_db "$DB_DIR/db.sqlite" GPT-5 high
  local out
  out=$(COPILOT_DB="$DB_DIR/db.sqlite" bash "$SCRIPTS/ctdl.sh" agent-pull-usage 2>&1)
  assert_empty "$out" "no output from cost refresh" &&
  [ -z "$(ls "$AGENT_TMP_DIR"/agent-cost-*-copilot 2>/dev/null)" ]
}

# USAGE_REFRESH rate-limits the collect: a fresh `rate` file (account-wide,
# not the per-window shared file) blocks the next pull from re-querying the
# db until the interval elapses.
test_rate_limit_skips_recent_pull() {
  setup 3600
  _make_db "$DB_DIR/db.sqlite" GPT-5 high
  printf 'model\tOLD\neffort\tlow\n' > "$AGENT_TMP_DIR/agent-shared-copilot-test-session-@1"
  : > "$AGENT_TMP_DIR/agent-rate-copilot"
  COPILOT_DB="$DB_DIR/db.sqlite" bash "$SCRIPTS/ctdl.sh" agent-pull-usage
  local -A F; kv_fill F < "$AGENT_TMP_DIR/agent-shared-copilot-test-session-@1"
  assert_contains "${F[model]}" "OLD" "recent write held, db not re-queried"
}

run_tests \
  test_collect_and_parse_shared_direct \
  test_writes_shared_from_db \
  test_silent_without_db \
  test_no_ctx_file \
  test_no_cost_refresh \
  test_rate_limit_skips_recent_pull
