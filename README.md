# meeting-transcriber-summarizer

Record meetings (Google Meet, Zoom, Slack huddles, …) on a Mac and transcribe them locally with [whisper.cpp](https://github.com/ggerganov/whisper.cpp). Everything runs on-device — no audio or text leaves your machine. Pairs naturally with terminal AI agents (Claude Code, Codex, or any agent that can run shell commands) for a fully hands-free record → transcribe → summarize workflow.

**Features**

- Records **both sides** of a call: your mic + the meeting audio, as separate streams — meeting audio via a native Core Audio system tap (no virtual devices, no output re-routing, works with headphones), with BlackHole as a fallback for older macOS
- **Speaker labels** without any ML: `Me:` vs `Other:` — each stream is transcribed separately and merged by timestamp, so attribution is exact and cross-talk never loses a voice
- Pause / resume / end controls — interactive keys in a terminal, or file-based control for driving it from scripts and agents
- **Auto-end**: detects when the call closes (Zoom & Slack huddle media connections, Google Meet tabs), with a silence fallback
- **Auto-start watcher** (optional): a launchd agent detects a meeting starting and posts a clickable macOS notification — one click and recording is running; combined with auto-end + auto-transcribe, the whole capture pipeline is hands-free
- Transcribes with whisper.cpp `large-v3-turbo` (~5x realtime on Apple Silicon per stream, ~2.5x for a two-stream session; strong multilingual support), outputs Markdown — automatically after the recording ends in daemon mode

## Requirements

- macOS (uses `avfoundation`, `osascript`, `lsof`)
- `brew install ffmpeg whisper-cpp`
- The whisper model (~1.6 GB):
  ```
  curl -L -o models/ggml-large-v3-turbo.bin \
    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
  ```
- The silero VAD model (~1 MB, strongly recommended — without it, quiet or choppy stretches send whisper into repetition-loop hallucinations):
  ```
  curl -L -o models/ggml-silero-v5.1.2.bin \
    https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin
  ```
- Your terminal needs Microphone permission (System Settings → Privacy & Security → Microphone); macOS prompts on first recording.

### System audio (one-time)

The mic only captures you. To capture the other participants, the recorder uses a **native Core Audio process tap** (the same mechanism commercial meeting recorders use) — build the bundled helper once:

```
swiftc -O -o audiotap audiotap.swift
```

(needs Xcode or the Command Line Tools; macOS 14.4+). The first recording triggers a one-time **System Audio Recording** permission prompt for your terminal — approve it (manage later under System Settings → Privacy & Security → Screen & System Audio Recording). That's it: no virtual devices, no output switching, headphones work as-is. The recorder auto-detects the helper.

<details>
<summary>Fallback for macOS &lt; 14.4: BlackHole loopback</summary>

1. `brew install blackhole-2ch`
2. Open **Audio MIDI Setup** → **+** → **Create Multi-Output Device** → check both your real output (speakers/headphones) **and** BlackHole 2ch. Keep your real output first (it's the clock source) and enable **Drift Correction** on BlackHole.
3. During meetings, set the Mac's sound output to that Multi-Output Device. You hear everything normally; BlackHole gets a copy for recording. (Volume keys don't work while it's selected — set volume first.)

The recorder uses BlackHole automatically when the `audiotap` helper isn't available.
</details>

With neither, the recorder still works but is mic-only (fine on speakers in a quiet room) and transcripts are unlabeled.

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
./meeting-record.sh transcribe <session-dir>     # re-run, or if AUTO_TRANSCRIBE=0
```

`ctl` targets the most recent session (tracked in `$MEETING_DIR/.current-session`); pass a session dir to target another. Live state is readable at `<session>/state`.

On `end` (manual or auto), the daemon transcribes the session in place by default (`AUTO_TRANSCRIBE=1`): `<session>/state` gains `transcribe=running`, then `transcribe=done` (or `failed`; whisper output goes to `<session>/transcribe.log`). Set `AUTO_TRANSCRIBE=0` to get the old stop-only behavior.

**Back-to-back meetings:** set `AUTO_TRANSCRIBE=ask` and the daemon instead marks the session `transcribe=pending`; the UI (meetingbar panel, or a dialog in headless watch mode) asks whether to transcribe now or **after the next meeting** — unanswered, it auto-starts in 5 minutes. Deferring keeps the watcher free to catch and record the next meeting; afterwards you're asked again, and `transcribe-pending` processes every pending session oldest-first. Run `./meeting-record.sh transcribe-pending` to process the queue manually.

### Meeting watcher (auto-start) + menu bar app

```
swiftc -O -o meetingbar meetingbar.swift   # build the menu bar app (recommended)
./meeting-record.sh watch-install          # install + start at login (uses meetingbar if built)
./meeting-record.sh watch-uninstall
```

**meetingbar** (recommended) is a tiny always-on menu bar app: a 🎙 icon shows the recorder state and offers **Start Recording Now** manually. When it detects a live call and nothing is recording, a small floating panel appears at the top-right of the main display — **Record** starts the daemon, **Ignore** stays quiet until that call ends. While recording, the panel stays up with a red dot, elapsed time, and Stop/Pause; after stopping it shows transcription progress and a "transcript ready" confirmation. It's a thin UI over `meeting-record.sh` — all recording logic stays in the script.

Without the binary, `watch-install` falls back to a headless watcher (`./meeting-record.sh watch`) that shows a native "Record it?" dialog instead. (Deliberately not a notification: notification CLIs like terminal-notifier are silently dropped on recent macOS.)

Detection polls every `WATCH_POLL_SEC` (10s) for: Zoom / Slack huddle UDP media flows (QUIC `:443` traffic is excluded — Slack and Chrome hold those while idle), Chrome UDP media flows on Google Meet's `193xx` ports, or a Chrome tab on an in-meeting `meet.google.com` URL.

Notes:
- Recordings started this way run detached; daemon output goes to `$MEETING_DIR/.watch-daemon.log`, the watcher's own log to `$MEETING_DIR/.watch.log`.
- The Meet tab check needs the Automation-for-Chrome permission in the watcher's context; the Meet media-port check needs no permissions and covers the in-call case regardless.
- Meetings in apps/browsers other than Zoom, Slack, and Chrome-based Meet aren't detected.

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
- `capture.log` — ffmpeg/audiotap capture diagnostics

Speaker attribution works because your voice lives only on the mic stream and remote voices live only on the loopback stream — each stream is transcribed separately (segments that whisper hallucinates over silence are dropped by an energy check) and the two segment lists are merged by timestamp. All remote participants share the `Other` label. If your voice echoes back through the meeting audio, the same words can show up on both channels at the same timestamps. Mic-only recordings are transcribed as a single stream and unlabeled.

The recorder pads any capture-buffer gaps with silence (`aresample=async=1`) so the two streams can't drift out of sync; if they still diverge by more than a few seconds, the recorder and transcriber print a `⚠️ tracks diverged` warning.

## Configuration

Environment variables, or a `config.local` file next to the script (gitignored) — copy `config.example`. Main knobs: `MEETING_DIR`, `MIC_DEVICE`, `SYS_DEVICE`, `ME_LABEL`/`OTHER_LABEL`, auto-end tuning, and `WHISPER_PROMPT` (a context prompt with names/jargon whisper tends to mis-hear).

**Bluetooth headset mics:** `MIC_DEVICE=default` follows the system default input — but when that default is a Bluetooth (HFP) mic held by the call app, ffmpeg's capture gets badly fragmented audio. Build the bundled native capture helper once:

```
swiftc -O -o miccap miccap.swift
```

With it present, the recorder captures the Bluetooth mic through CoreAudio at its native format (gap-padded, format-change tolerant) — the startup line shows `via native mic tap`. Without it, the recorder falls back to the built-in mic's room pickup (often too muffled to transcribe well); `BT_MIC_OK=1` forces ffmpeg onto the Bluetooth mic anyway.

The recorder also sanity-checks each track after recording: if a captured track is much shorter than the session, it logs a warning and sets `capture_warning=` in `<session>/state`.

Transcription language is auto-detected; force it with `--lang zh`, `--lang en`, etc.

## Using with terminal agents (optional)

The daemon mode is designed to be driven by any terminal AI agent — Claude Code, Codex, or anything that can run shell commands: the agent starts `meeting-record.sh start` as a background task, relays your "pause"/"resume"/"end" (auto-end handles the common case), reads `<session>/state` to know what happened, runs `transcribe`, then summarizes `transcript.md` into meeting notes — a fully hands-free record → transcribe → summarize workflow.

For Claude Code specifically, `examples/claude-code-skill/SKILL.md` is a ready-made skill implementing exactly that: copy the folder to `~/.claude/skills/meeting-notes/` and adjust to taste. For other agents, the same file doubles as a prompt/playbook you can adapt.
