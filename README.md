# meeting-transcriber-summarizer

Record meetings (Google Meet, Zoom, Slack huddles, …) on a Mac and transcribe them locally with [whisper.cpp](https://github.com/ggerganov/whisper.cpp). Everything runs on-device — no audio or text leaves your machine. Pairs naturally with terminal AI agents (Claude Code, Codex, or any agent that can run shell commands) for a fully hands-free record → transcribe → summarize workflow.

**Features**

- Records **both sides** of a call: your mic + the meeting audio (via a loopback device), as separate streams
- **Speaker labels** without any ML: `Me:` vs `Other:`, attributed by comparing per-segment energy between the two streams
- Pause / resume / end controls — interactive keys in a terminal, or file-based control for driving it from scripts and agents
- **Auto-end**: detects when the call closes (Zoom & Slack huddle media connections, Google Meet tabs), with a silence fallback
- Transcribes with whisper.cpp `large-v3-turbo` (~5x realtime on Apple Silicon, strong multilingual support), outputs Markdown

## Requirements

- macOS (uses `avfoundation`, `osascript`, `lsof`)
- `brew install ffmpeg whisper-cpp`
- The whisper model (~1.6 GB):
  ```
  curl -L -o models/ggml-large-v3-turbo.bin \
    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
  ```
- Your terminal needs Microphone permission (System Settings → Privacy & Security → Microphone); macOS prompts on first recording.

### System audio (one-time, ~3 min)

The mic only captures you. To capture the other participants, install [BlackHole](https://github.com/ExistentialAudio/BlackHole) and mirror your output through it:

1. `brew install blackhole-2ch` (needs your password)
2. Open **Audio MIDI Setup** → **+** → **Create Multi-Output Device** → check both your real output (speakers/headphones) **and** BlackHole 2ch. Keep your real output first (it's the clock source) and enable **Drift Correction** on BlackHole.
3. During meetings, set the Mac's sound output to that Multi-Output Device. You hear everything normally; BlackHole gets a copy for recording.

Notes: macOS volume keys don't work while a Multi-Output Device is selected — set your volume before switching. Without BlackHole the recorder still works, but mic-only (fine on speakers in a quiet room) and without speaker labels.

## Usage

### Interactive (terminal)

```
./meeting-record.sh --name weekly-sync
```

| key | action |
|-----|--------|
| `p` | pause / resume |
| `e` | end + transcribe |
| `q` | end without transcribing (audio kept) |

### Daemon (scriptable / agent-driven)

```
./meeting-record.sh start --name weekly-sync     # runs until told to stop
./meeting-record.sh ctl pause|resume|end|status  # control the running session
./meeting-record.sh transcribe <session-dir>     # after `ctl end`, or to re-run
```

`ctl` targets the most recent session (tracked in `$MEETING_DIR/.current-session`); pass a session dir to target another. Live state is readable at `<session>/state`.

### Auto-end (daemon mode)

The daemon ends recording by itself when the call closes:

- **Zoom / Slack huddles**: these apps hold live UDP media connections only during a call; when the flows disappear for `CALL_END_GRACE_SEC` (60s default, 0 = off), recording ends.
- **Google Meet**: while in a call, a Chrome tab sits on a `meet.google.com/xxx-yyyy-zzz` URL; when no such tab exists, recording ends. Caveat: leaving the call but keeping the tab open isn't detected (the URL doesn't change) — close the tab, or the silence fallback catches it. Requires granting your terminal Automation permission for Chrome (macOS prompts once).
- **Silence fallback**: `AUTO_END_SEC` (5 min default, 0 = off) of continuous quiet below `SILENCE_DB` (−45 dBFS default) on **all** recorded streams. Both mic and system audio must be quiet, so presenting to a muted room won't false-trigger.

Call detection arms only after a live call is first observed, so starting the recorder before joining is safe. The end reason is written to `<session>/state` (`reason=call_closed|silence|manual`).

## Output

Each session is a folder, `$MEETING_DIR/<timestamp>_<name>/`:

- `transcript.md` — speaker-labeled transcript:

  ```markdown
  **Me:** Let me walk you through the agenda for today.

  **Other:** Thanks. I reviewed the document yesterday and it looks good.
  ```

- `transcript.segments.md` — the same lines with timestamps
- `full.wav` — the mixed audio; `seg-*.wav` — raw per-stream segments

Speaker attribution works because your voice lives only on the mic stream and remote voices live only on the loopback stream — each whisper segment is labeled by whichever stream is louder in that window. All remote participants share the `Other` label. Mic-only recordings are unlabeled.

## Configuration

Environment variables, or a `config.local` file next to the script (gitignored) — copy `config.example`. Main knobs: `MEETING_DIR`, `MIC_DEVICE`, `SYS_DEVICE`, `ME_LABEL`/`OTHER_LABEL`, auto-end tuning, and `WHISPER_PROMPT` (a context prompt with names/jargon whisper tends to mis-hear).

Transcription language is auto-detected; force it with `--lang zh`, `--lang en`, etc.

## Using with terminal agents (optional)

The daemon mode is designed to be driven by any terminal AI agent — Claude Code, Codex, or anything that can run shell commands: the agent starts `meeting-record.sh start` as a background task, relays your "pause"/"resume"/"end" (auto-end handles the common case), reads `<session>/state` to know what happened, runs `transcribe`, then summarizes `transcript.md` into meeting notes — a fully hands-free record → transcribe → summarize workflow.

For Claude Code specifically, `examples/claude-code-skill/SKILL.md` is a ready-made skill implementing exactly that: copy the folder to `~/.claude/skills/meeting-notes/` and adjust to taste. For other agents, the same file doubles as a prompt/playbook you can adapt.
