---
name: meeting-notes
description: Full meeting workflow — record a live meeting (Meet/Zoom/Slack huddle), pause/resume/end on request, transcribe with whisper.cpp, and summarize into notes. Use when the user says they're starting a meeting, wants to record/pause/resume/end a recording, or asks to summarize a meeting transcript.
---

# Meeting Notes

End-to-end meeting workflow using `meeting-record.sh` from the meeting-transcriber project (adjust `$REC` below to where you cloned it). Sessions live in `$MEETING_DIR/<date>_<name>/` (default `~/meetings`).

Decide the mode from the user's intent:

- **"I'm in / starting a meeting", "record this meeting"** → Record (below)
- **"pause" / "resume" / "how long so far?"** → send the matching control command
- **"meeting is done", "end it"** → End: stop → transcribe → summarize, all in one go
- **"summarize the meeting" (recording already done elsewhere)** → skip to Summarize

## Record

1. Start the daemon as a **background** Bash task (never foreground — it runs until told to end):
   ```
   $REC start --name <short-slug>
   ```
   Derive `<short-slug>` from what the user says the meeting is; omit `--name` if unknown.
2. Read the task output after a few seconds to confirm it's recording, and check for the `⚠️ No system-audio source` warning — if present, tell the user only their mic is being captured (fine on speakers, misses other participants on headphones) and point them to the README's system-audio setup (build the `audiotap` helper, or BlackHole on older macOS).
3. Report the session dir and tell the user: say **pause**, **resume**, or **end** here anytime — or just close the call, which is auto-detected. Then wait — do not poll during the meeting.

## Auto-end

The daemon ends itself when the call closes (Zoom/Slack UDP media flows gone, or no Chrome tab on an in-meeting `meet.google.com` URL; 60s grace) or after 5 min of continuous silence on all recorded streams.

When the daemon background task completes WITHOUT the user having said "end": read `<session>/state` — `reason=call_closed` or `reason=silence` means auto-end. Tell the user the meeting end was detected (and why), then proceed directly to transcribe → summarize without waiting for input. Meet caveat: leaving a call but keeping the tab open is NOT detected — the silence fallback covers that.

## Control (during recording)

- Pause: `$REC ctl pause` — Resume: `$REC ctl resume` — Status: `$REC ctl status` (shows `status=` and `recorded_seconds=`).
- These target the most recent session automatically.

## End → transcribe → summarize

1. `$REC ctl end`, then confirm with `$REC ctl status` that `status=ended`.
2. Transcribe as a **background** task (~5x realtime, so a 1h meeting ≈ 12 min — too long for a foreground call):
   ```
   $REC transcribe <session-dir> --lang auto
   ```
   Tell the user transcription is running and roughly how long it will take (`recorded_seconds` / 5).
3. When the transcription task completes, verify `transcript.md` exists and is non-trivial, then continue to Summarize without waiting for further input.

## Summarize

1. Session dir: whatever was just transcribed; or the path the user gave; or the most recent session folder. Confirm with the user only if ambiguous.
2. Read `transcript.md` fully (chunked if long). `transcript.segments.md` has per-line timestamps — consult it for timelines/ordering.
3. Speaker labels: when the session had both streams, lines are labeled `Me:` (the user's mic) and `Other:` (meeting audio = ALL remote participants lumped together — distinguish among them by context/names, don't guess). Mic-only sessions are unlabeled; infer speakers from context. Normalize obvious mis-transcriptions of names and domain jargon from context.
4. Write notes to `notes.md` in the session dir AND show them in the conversation. In the notes header, link the transcript: `**Full transcript:** [[transcript]] · [[transcript.segments|with timestamps]] · audio: \`full.wav\``.

**Notes format:**
1. Header — date, participants (if inferable), purpose
2. TL;DR — 3-5 sentences
3. Discussion — by topic, decisions called out in **bold**
4. Action items — grouped by owner, with any mentioned deadlines
5. Open questions / follow-ups

## After writing

Report where notes were saved; nothing further by default. Revise `notes.md` in place if the user wants changes.
