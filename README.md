# tmux-ctdl

**ctdl** = **C**oding **T**mux **D**ev **L**ayout. A tmux dev layout for
working with a coding agent (Claude Code, GitHub Copilot CLI), plus a status
bar showing usage/cost and a per-window badge showing what each agent is
doing.

## What you get

Run `ctdl` in a tmux window and it splits into three panes:

```
 mysession   1:api ●  2:web            ← wintab: window name + badge
┌─────────────┬────────────────┐
│             │  change        │
│  coding     │  tracker       │
│  agent      │  (lazygit)     │
│  (claude |  ├────────────────┤
│  copilot)   │  terminal      │
└─────────────┴────────────────┘
 claude  ctx 42%  session 18%  $3.20     ← agentbar
```

- wintab (window name badge): running / waiting on you / done
- agentbar (own status bar line): model, context %, session/weekly usage,
  (Claude) running lifetime cost
- `ctdl` — one window, current repo, no new session (uses whatever session
  you're already in)
- `ctdlm` — same session, one window per git repo under a dir
- `ctdlm <dir1> <dir2> ...` — first dir uses the current session; each extra
  dir gets its own new session, named after that dir's basename

**Key bindings**

| Key | Pane | Runs | Effect |
|---|---|---|---|
| prefix + C | Left | `AGENT_CMD` (`claude`) | kill + restart the pane |
| prefix + Space | Top right | `CHANGE_TRACKER_CMD` (`lazygit`) ↔ `EDITOR_CMD` (`nvim`) | respawn-swap in place, not a new split |

## Install

```sh
git clone https://github.com/marcintk/tmux-ctdl.git <DIR>
cd <DIR>
./install.sh
```

Deploys to `$TMUX_CTDL_HOME` (default `~/.config/tmux/tmux-ctdl`), patches
(idempotent, safe to re-run):

| File | Snippet | Note |
|---|---|---|
| `~/.config/zsh/.zshrc` | [`integrations/zshrc.sh`](integrations/zshrc.sh) | |
| `~/.config/tmux/tmux.conf` | [`integrations/tmux.conf`](integrations/tmux.conf) | |
| `~/.claude/settings.json` | [`integrations/claude-settings.json`](integrations/claude-settings.json) | needs `jq` |

## Configure

Edit `tmux-ctdl.conf` (deployed to `$TMUX_CTDL_HOME/tmux-ctdl.conf` on first
install, then left alone on every reinstall after):

| Var | Meaning |
|---|---|
| `CODING_AGENT` | `claude` or `copilot` — picks the adapter module, which then hard-sets `AGENT_CMD` itself (not settable here) |
| `CHANGE_TRACKER_CMD` / `EDITOR_CMD` | what the top-right pane runs, and what it swaps to on toggle |
| status bar colours/thresholds | every one has a default, only name the ones you want different |

## How data flows

```mermaid
graph TD
  claude["Claude Code hooks<br/>+ statusLine"]:::src
  copilot["Copilot CLI<br/>session-store.db"]:::src

  subgraph ctdl["tmux + ctdl"]
    tick["agent-refresh<br/>status-interval 1s"]:::sched
    adapterClaude["adapter-claude<br/>parse"]:::adapter
    adapterCopilot["adapter-copilot<br/>parse (pulled)"]:::adapter
    state[("state files<br/>/tmp, atomic write")]:::store
    subgraph render["render"]
      agentbar["agentbar<br/>(status data)"]:::out
      wintab["wintab<br/>(badge)"]:::out
    end
  end

  claude -- statusLine push, every 5s --> adapterClaude
  tick -- pull, throttled --> adapterCopilot
  copilot --> adapterCopilot

  adapterClaude -- tokens, context %, cost history --> state
  adapterCopilot -- model, tokens --> state
  claude -. phase: running/blocked/done .-> wintab

  tick --> agentbar
  tick --> wintab
  state -- reads current snapshot --> agentbar

  classDef src fill:#1e3a5f,stroke:#5b9bd5,color:#fff
  classDef adapter fill:#4a2f6b,stroke:#a97fd6,color:#fff
  classDef store fill:#444,stroke:#999,color:#fff
  classDef sched fill:#6b4a1e,stroke:#d69a3f,color:#fff
  classDef out fill:#1e5f3a,stroke:#5bd68a,color:#fff
  style ctdl fill:none,stroke:#888,color:#aaa
  style render fill:none,stroke:#5bd68a,stroke-dasharray:2 2,color:#aaa
```

## Development

Needs: `bash`, `kcov`, `shfmt`, `shellcheck`.

```sh
bash tests/run-tests.sh          # discovers every test-*.sh under tests/
bash tests/run-coverage.sh       # kcov, writes .coverage/
```

| Hook | Runs |
|---|---|
| pre-commit | shfmt + shellcheck + tests |
| pre-push | 100% coverage gate (`kcov`) |

Enable once per clone:

```sh
./dev_setup.sh
```
