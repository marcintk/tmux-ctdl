# Copilot CLI integration

Pull-based — Copilot CLI has no hook mechanism, so `ctdl` polls it instead.

| Piece | Wired via |
|---|---|
| Usage (`shared` state) | `wintab-tick` (1s) → `adapter_pull_usage` → `copilot_collect`, rate-limited by `USAGE_REFRESH`. Read-only query against `~/.copilot/session-store.db` (SQLite, WAL) for model/reasoning-effort |
| Window badge (`phase` state) | **missing** — no hook mechanism exists in the Copilot CLI |
| Context-window % | **missing** — no `ctx_max` column in the db, `copilot_parse_context` emits nothing |
| AI-credit quota % | **missing** — lives behind `GET /copilot_internal/user`, not called yet |
| Liveness (which panes are it) | `copilot_live_cwds`, `pgrep -x copilot` + `/proc/<pid>/cwd` — unreliable once the CLI wrapper execs into a node binary (open issue) |
| $ cost refresh | omitted — Copilot bills in AI credits, not $ |

Adapter module: `adapter/adapter-copilot.sh`. No settings.json patch needed —
there's nothing to hook.

Set `CODING_AGENT="copilot"` in `tmux-ctdl.conf`.
