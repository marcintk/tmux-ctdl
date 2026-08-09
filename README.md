# tmux-ctdl

**ctdl** = **C**oding **T**mux **D**ev **L**ayout. A tmux dev layout for
working with a coding agent (Claude Code, GitHub Copilot CLI), plus a status
bar showing usage/cost and a per-window badge showing what each agent is
doing.

## What you get

Run `ctdl` in a tmux window and it splits into three panes:

```mermaid
graph TD
  ctdl["ctdl<br/>current session, 1 window"]:::cmd
  ctdlm["ctdlm<br/>current session,<br/>1 window per repo"]:::cmd
  ctdlm2["ctdlm dir1 dir2 ...<br/>+1 new session per extra dir"]:::cmd

  subgraph win["ctdl window"]
    direction LR
    agent["Left<br/>coding agent<br/>claude | copilot"]:::pane
    subgraph right[" "]
      direction TB
      tracker["Top right<br/>change tracker<br/>lazygit"]:::pane
      term["Bottom right<br/>terminal"]:::pane
    end
  end

  ctdl --> win
  ctdlm --> win
  ctdlm2 -. per extra dir .-> win

  win --> statusbar["status bar<br/>context %, usage/cost,<br/>Claude: lifetime total"]:::out
  win --> badge["window badge<br/>running / waiting / done"]:::out

  classDef cmd fill:#1e5f3a,stroke:#5bd68a,color:#fff
  classDef pane fill:#1e3a5f,stroke:#5b9bd5,color:#fff
  classDef out fill:#4a2f6b,stroke:#a97fd6,color:#fff
  style win fill:none,stroke:#888,color:#aaa
  style right fill:none,stroke:#888,color:#aaa
```

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
| `CODING_AGENT` | `claude` or `copilot` |
| `AGENT_CMD` | command that starts your agent in the left pane |
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
