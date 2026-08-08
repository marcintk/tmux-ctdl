# Claude Code integration

Push-based — Claude Code has hooks and a `statusLine`, so `ctdl` never polls it.

| Piece | Wired via |
|---|---|
| Usage (`shared`/`ctx` state) | `statusLine` command, `agent-push-usage`, every ~5s, JSON on stdin |
| Window badge (`phase` state) | 5 hooks: `SessionStart`→CLEAR, `UserPromptSubmit`→RUNNING, `Stop`→DONE, `Notification`→DONE, `PermissionRequest`→PERMISSION |
| End-of-turn cost line | `Stop` hook, `agent-footer`, reads transcript, prices via `claude_price_for_model` |
| $ cost refresh | `claude_refresh_costs`, background, via `ccusage` |
| Liveness (which panes are it) | `claude_live_cwds`, reads `~/.claude/sessions/*.json` |

Adapter module: `adapter/adapter-claude.sh`. Settings patch:
[`integrations/claude-settings.json`](../../integrations/claude-settings.json)
(merged by `install.sh`, or apply by hand — see repo root README).

Set `CODING_AGENT="claude"` in `tmux-ctdl.conf`.
