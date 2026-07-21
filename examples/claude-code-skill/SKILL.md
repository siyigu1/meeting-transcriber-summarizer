---
name: meeting-notes
description: Full meeting workflow — record a live meeting (Meet/Zoom/Slack huddle), pause/resume/end on request, transcribe with whisper.cpp, and summarize into notes. Use when the user says they're starting a meeting, wants to record/pause/resume/end a recording, or asks to summarize a meeting transcript.
---

# Meeting Notes

End-to-end meeting workflow using `meeting-record.sh` from the meeting-transcriber project (adjust `$REC` below to where you cloned it). Sessions live in `$MEETING_DIR/<date>_<name>/` (default `~/meetings`).

The optional **meeting watcher** (`$REC watch-install`; the `meetingbar` menu bar app when built, headless dialog watcher otherwise) may start recordings outside Claude Code: on detecting a live call it asks the user via a floating panel / dialog and launches the recorder daemon detached. Those sessions auto-end when the call closes and auto-transcribe in place (`AUTO_TRANSCRIBE=1` default) — so a session can be fully captured+transcribed without the agent involved, and the typical entry point here is just summarizing it.

Decide the mode from the user's intent:

- **"I'm in / starting a meeting", "record this meeting"** → Record (below)
- **"pause" / "resume" / "how long so far?"** → send the matching control command
- **"meeting is done", "end it"** → End: stop → (auto-)transcribe → summarize, all in one go
- **"summarize the meeting" (recording already done elsewhere)** → skip to Summarize
- **No specific intent** → resolve from the latest session's state, in this order:
  1. `status=recording|paused` → attach: report status and offer pause/resume/end control.
  2. `status=ended` + `transcribe=running` → wait for it (until-loop on state), then Summarize.
  3. `status=ended`, no `transcript.md` (or `transcribe=failed`) → run Transcribe, then Summarize.
  4. `transcript.md` exists but no `notes.md` → Summarize immediately, no questions asked.
  5. Everything already has notes → nothing pending; ask what the user wants.

## Record

0. First check nothing is already recording (`$REC ctl status`) — the watcher may have beaten you to it. If `status=recording`, attach to that session instead of starting a second daemon.
1. Start the daemon as a **background** Bash task (never foreground — it runs until told to end):
   ```
   $REC start --name <short-slug>
   ```
   Derive `<short-slug>` from what the user says the meeting is; omit `--name` if unknown.
2. Read the task output after a few seconds to confirm it's recording, and check for the `⚠️ No system-audio source` warning — if present, tell the user only their mic is being captured (fine on speakers, misses other participants on headphones) and point them to the README's system-audio setup (build the `audiotap` helper, or BlackHole on older macOS).
3. Report the session dir and tell the user: say **pause**, **resume**, or **end** here anytime — or just close the call, which is auto-detected. Then wait — do not poll during the meeting.

## Auto-end

The daemon ends itself when the call closes (Zoom/Slack UDP media flows gone, or no Chrome tab on an in-meeting `meet.google.com` URL; 60s grace) or after 5 min of continuous silence on all recorded streams.

When the daemon background task completes WITHOUT the user having said "end": read `<session>/state` — `reason=call_closed` or `reason=silence` means auto-end. Tell the user the meeting end was detected (and why). By the time the daemon task completes, auto-transcription has already run inside it (check `transcribe=done|failed` in state), so proceed directly to Summarize without waiting for input. Meet caveat: leaving a call but keeping the tab open is NOT detected — the silence fallback covers that.

## Control (during recording)

- Pause: `$REC ctl pause` — Resume: `$REC ctl resume` — Status: `$REC ctl status` (shows `status=` and `recorded_seconds=`).
- These target the most recent session automatically.

## End → transcribe → summarize

1. `$REC ctl end`, then confirm with `$REC ctl status` that `status=ended`.
2. **The daemon transcribes by itself** (`AUTO_TRANSCRIBE=1`): state shows `transcribe=running`, then `transcribe=done|failed`. Do NOT also run `transcribe` — you'd double-transcribe. Just wait: if the daemon is a background task of this session, its completion is the signal; otherwise (watcher-started, detached) run a **background** until-loop on `<session>/state` for `transcribe=(done|failed)`. It's ~2.5x realtime (each channel transcribed separately) — a 1h meeting ≈ 25 min; tell the user the ETA (`recorded_seconds` / 2.5).
3. Only run `$REC transcribe <session-dir> --lang auto` yourself (background task) if `transcribe=failed` (check `<session>/transcribe.log` first) or the state has no `transcribe=` line at all (AUTO_TRANSCRIBE was off).
4. Check `<session>/transcribe.log` (or the task output) for a `⚠️ … tracks diverged` warning — it means audio was dropped during capture (check `<session>/capture.log`) and transcript ordering may be off; tell the user if it appears.
5. When transcription completes, verify `transcript.md` exists and is non-trivial, then continue to Summarize without waiting for further input.

## Summarize

1. Session dir: whatever was just transcribed; or the path the user gave; or the most recent session folder. Confirm with the user only if ambiguous.
2. Read `transcript.md` fully (chunked if long). `transcript.segments.md` has per-line timestamps — consult it for timelines/ordering.
3. Speaker labels: when the session had both streams, each channel is transcribed separately, so labels are exact: `Me:` (the user's mic) and `Other:` (meeting audio = ALL remote participants lumped together — distinguish among them by context/names, don't guess). If the user's voice echoes back through the meeting audio, the same words can appear under both labels at overlapping timestamps — treat those as one utterance by `Me`, not a repeat. Mic-only sessions are unlabeled; infer speakers from context. Normalize obvious mis-transcriptions of names and domain jargon from context.
4. Write notes to `notes.md` in the session dir AND show them in the conversation. In the notes header, link the transcript: `**Full transcript:** [[transcript]] · [[transcript.segments|with timestamps]] · audio: \`full.wav\``.

**Notes format:**
1. Header — date, participants (if inferable), purpose
2. TL;DR — 3-5 sentences
3. Discussion — by topic, decisions called out in **bold**
4. Action items — grouped by owner, with any mentioned deadlines
5. Open questions / follow-ups

## After writing

Report where notes were saved; nothing further by default. Revise `notes.md` in place if the user wants changes.
