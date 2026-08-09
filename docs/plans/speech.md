# Speak agent attention events (TTS)

## Context

The bell feature (flash + sound on Stop/Notification/PermissionRequest) got built,
tested, and then explicitly dropped — the user wants to go further: hear a short
spoken summary of what the agent just did or what it's stuck on, so they don't
have to look at the screen at all. The wrinkle: with two Claude sessions running
in parallel tmux windows, spoken summaries from a background agent would be noise
— only the window currently on screen should ever talk. Bell (flash/sound) stays
a broadcast signal for "something happened somewhere"; speech is reserved for
"something happened in front of you."

Research already done this session (via an Explore agent that decompiled the
installed `claude` binary's hook-payload builders):

- **Stop** hook payload already includes `last_assistant_message` — a flattened,
  trimmed string of the final assistant turn. No transcript parsing needed.
- **Notification** hook payload includes `message` (human-authored, e.g. "Claude
  is waiting for your input") and `notification_type`. Also no parsing needed.
- **PermissionRequest** payload has no `message` — only `tool_name`, `tool_input`,
  `tool_use_id`. Text has to be synthesized (e.g. "wants to run: <command>" for
  Bash, else "wants permission to use <tool>").

Spiked both engines live before committing:
- `espeak-ng` (pacman, `extra`, 1.52.0-1) — installed, works, sounds robotic.
- `piper` (neural TTS, offline after setup) — installed via `pipx install
  piper-tts` (not packaged in pacman/AUR as a binary). Voice model
  `en_US-ryan-high` (~120MB `.onnx` + `.onnx.json`) downloaded once to
  `~/.local/share/piper-voices/` from the `rhasspy/piper-voices` HuggingFace
  repo, then fully offline. Confirmed the no-temp-file streaming pipeline
  works: `piper -m <model> --output-raw | paplay --raw --rate=22050
  --format=s16le --channels=1` — piper's raw stdout is 22050Hz/s16le/mono
  per the model's own `.onnx.json` (`audio.sample_rate`), same PulseAudio/
  PipeWire-pulse stack `paplay` already uses elsewhere in this codebase.
  Sounded clearly more natural than espeak-ng in the live comparison — this
  is the engine going into the plan.

## Design

**New file: `libs/speech-lib.sh`**
- `speech_say <text>` — the one mechanism function. Streams
  `printf '%s' "$text" | piper -m "${SPEECH_MODEL:-$HOME/.local/share/piper-voices/en_US-ryan-high.onnx}" --output-raw 2>/dev/null | paplay --raw --rate=22050 --format=s16le --channels=1 2>/dev/null &`
  in the background, capped at `${SPEECH_MAX_CHARS:-240}` chars first (plain
  char cut + `…`, no word-boundary trimming — good enough for a spoken
  approximation). No-op, not an error, when `piper`/`paplay` is missing, the
  model file doesn't exist, or `text` is empty — same degrade-silently
  contract every other effect in this codebase follows (`wintab_bell_sound`,
  `tmux_bell`).

**`libs/tmux-lib.sh` — two additions**
- `tmux_focused_windows` — prints `session\twindow_id`, one line per attached
  client's current window (`tmux list-panes -a -F '#{session_name}\t#{window_id}\t#{window_active}\t#{session_attached}'`
  filtered to `window_active==1 && session_attached>=1`). Pure fact-reporting,
  same shape as `tmux_session_panes`.
- `tmux_is_focused <session> <window>` — true if that pair appears in
  `tmux_focused_windows`. This is the "are you actually looking at this
  window right now" check the multi-agent concern needs.

**`adapter/adapter-lib.sh` — one addition, contract doc updated**
- `adapter_speak <agent>` — mirrors `adapter_footer`'s shape exactly:
  no-op if `<agent>_speak_text` isn't defined; reads the hook payload via
  the existing `_hook_payload` helper, pipes it to `<agent>_speak_text` to
  get the line to say; bails if empty; resolves `tmux_here`; bails unless
  `tmux_is_focused` says yes; calls `speech_say`. `SPEECH_ENABLED` (default
  on) gates the whole function, same pattern as `wintab_bell_for`'s
  `BELL_ENABLED`.
- Contract doc comment (top of file) gets a new optional hook entry:
  `<agent>_speak_text <<< payload` — prints one line to speak, or nothing.

**`adapter/adapter-claude.sh` — one addition**
- `claude_speak_text` — a single `jq` dispatch on `.hook_event_name`:
  `Stop` → `.last_assistant_message`, `Notification` → `.message`,
  `PermissionRequest` → synthesized sentence from `.tool_name`/`.tool_input`
  (special-cased for `Bash`'s `.tool_input.command`, generic fallback
  otherwise). Pure data extraction, no truncation/speaking here — same
  division of labor `claude_parse_context` already has (agent module
  extracts, generic layer paints/plays).

**`tmux-ctdl.sh` — one new verb**
- `agent-speak` → `_ctdl_boot adapter agent tmux state` then
  `adapter_speak "$CODING_AGENT"`. Same shape as the existing `agent-footer`
  verb.

**`integrations/claude-settings.json`**
- Add `tmux-ctdl.sh agent-speak` as an additional command alongside the
  existing `wintab-badge` command in the `Stop`, `Notification`, and
  `PermissionRequest` hook arrays (Stop already runs two commands today —
  this makes it three; each command gets its own independent stdin copy of
  the payload, confirmed by the existing `wintab-badge` + `agent-footer`
  pair already working that way).

**`tmux-ctdl.conf`** — new documented knobs, all optional/defaulted at the
reader like every other palette value in this file:
```
SPEECH_ENABLED=1
SPEECH_MODEL=$HOME/.local/share/piper-voices/en_US-ryan-high.onnx
SPEECH_MAX_CHARS=240
```

**`README.md`** — one bullet under "What you get" and the new knobs listed
under "Configure", plus a note that `piper` (`pipx install piper-tts`) and a
downloaded voice model are required for speech (same tier as `jq`/`npm`
being implicit deps for other features) — with the exact download command
for `en_US-ryan-high` from the spike.

**Already done, nothing left to confirm:** `piper` installed via pipx, voice
model downloaded to `~/.local/share/piper-voices/en_US-ryan-high.onnx`,
streaming playback confirmed working.

## Tests

Follow the exact patterns already in the repo:
- `tests/libs/test-speech-lib.sh` (new) — `speech_say` truncation, no-op on
  missing binary / empty text (same shape as the bell tests I wrote earlier
  this session: `tests/libs/test-tmux-lib.sh`'s `test_bell_*`).
- `tests/libs/test-tmux-lib.sh` — add cases for `tmux_focused_windows` /
  `tmux_is_focused` against `tests/fixtures/tmux`, which needs a small
  extension: a `list-panes -a` case reading new `MOCK_*` env vars for
  window_active/session_attached, plus a `list-clients` case.
- `tests/adapter/test-adapter-lib.sh` — `adapter_speak`: fires when focused
  and `<agent>_speak_text` defined, silent when unfocused, silent when
  `SPEECH_ENABLED=0`, silent when the agent defines no `_speak_text` hook
  (mirrors the existing `adapter_footer` test block).
- `tests/adapter/test-adapter-claude.sh` — `claude_speak_text` for all three
  `hook_event_name` values plus the Bash-specific PermissionRequest case and
  the generic-tool fallback.

## Verification

1. `bash tests/run-tests.sh` — full suite green.
2. `shfmt -i 2 -ci -d .` and `find . -name '*.sh' -print0 | xargs -0 shellcheck --severity=error` — clean, same gates CI runs.
3. Live, same manual-fire style already used for the bell:
   ```
   export TMUX_PANE=<pane-in-focused-window>
   echo '{"hook_event_name":"Notification","message":"Claude is waiting for your input"}' \
     | ~/.config/tmux/tmux-ctdl/tmux-ctdl.sh agent-speak
   ```
   Confirm it speaks when the target window is focused, stays silent when
   you run the same command with `TMUX_PANE` pointed at a window that isn't
   currently on screen.
4. End-to-end: install the two hook commands via `install.sh`'s existing
   settings-merge (or hand-patch `~/.claude/settings.json` from
   `integrations/claude-settings.json` for a quick test), run Claude Code
   for real, confirm a finished turn/permission prompt speaks only in the
   window you're looking at.
