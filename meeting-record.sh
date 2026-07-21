#!/usr/bin/env bash
# meeting-record.sh — record meeting audio (mic + system audio), with pause/resume/end,
# then transcribe with whisper.cpp.
#
# Two ways to drive it:
#
#   INTERACTIVE (run in a terminal):
#     ./meeting-record.sh [record] [--lang zh|en|auto] [--name my-meeting]
#       Keys:  p = pause/resume   e = end + transcribe   q = end (no transcribe)
#       Ctrl-C behaves like q.
#
#   DAEMON (no TTY — e.g. driven by Claude Code):
#     ./meeting-record.sh start [--name my-meeting]
#       Runs until told to stop. Poll-controlled via <session>/control.
#     ./meeting-record.sh ctl pause|resume|end|status [session-dir]
#       Sends a command to the running daemon (defaults to the most recent session).
#       Recording state is readable at <session>/state.
#       On `end` (or auto-end) the daemon transcribes in place when
#       AUTO_TRANSCRIBE=1 (the default) — state gains transcribe=running|done|failed.
#       With AUTO_TRANSCRIBE=0, run `transcribe` yourself afterwards.
#
#   WATCH (meeting auto-detect):
#     ./meeting-record.sh watch
#       Polls for a live call (Zoom / Slack huddle / Google Meet). When one appears
#       and nothing is recording, shows a native "Record it?" dialog — one click
#       starts the recording daemon. No extra dependencies.
#     ./meeting-record.sh watch-install | watch-uninstall
#       Install/remove a launchd agent so the watcher runs at login.
#
#   TRANSCRIBE:
#     ./meeting-record.sh transcribe <session-dir> [--lang zh|en|auto]
#
# Output: $MEETING_DIR/<timestamp>_<name>/  (default ~/meetings)
#   seg-*.wav                 raw audio segments (mic / sys)
#   full.wav                  mixed + concatenated audio
#   capture.log               ffmpeg/audiotap capture diagnostics (frame drops etc.)
#   transcript.md             speaker-labeled transcript (markdown)
#   transcript.segments.md    same, with timestamps
#
# Requirements: ffmpeg, whisper-cli (brew install whisper-cpp), model file below.
# For system audio (other meeting participants), preferred: the bundled `audiotap`
# helper (build with: swiftc -O -o audiotap audiotap.swift; macOS 14.4+, one-time
# System Audio Recording permission — no output re-routing needed). Fallback:
# BlackHole 2ch + a Multi-Output device. With neither, only your mic is recorded.
#
# Configuration: environment variables below, or put overrides in a `config.local`
# file next to this script (gitignored; see config.example).

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
[[ -f "$SCRIPT_DIR/config.local" ]] && . "$SCRIPT_DIR/config.local"

BASE_DIR="${MEETING_DIR:-$HOME/meetings}"
MODEL="${WHISPER_MODEL:-$SCRIPT_DIR/models/ggml-large-v3-turbo.bin}"
MIC_NAME="${MIC_DEVICE:-MacBook Pro Microphone}"   # always hears you, even with headphones on
SYS_NAME="${SYS_DEVICE:-BlackHole 2ch}"            # loopback of system output (Meet/Zoom audio)
ME_LABEL="${ME_LABEL:-Me}"                         # transcript label for your mic
OTHER_LABEL="${OTHER_LABEL:-Other}"                # transcript label for meeting audio
# Auto-end (daemon mode only): detect that the call was closed and stop recording.
#   Primary signal — Zoom's live UDP media connection disappears, or no Chrome tab
#   is on an in-meeting meet.google.com URL anymore (arms only after a call was seen).
#   Fallback — continuous silence on ALL recorded streams.
CALL_END_GRACE_SEC="${CALL_END_GRACE_SEC:-60}"  # call signal must be gone this long (0 = disable call detection)
AUTO_END_SEC="${AUTO_END_SEC:-300}"             # silence fallback duration (0 = disable)
SILENCE_DB="${SILENCE_DB:--45}"                 # dBFS; a stream quieter than this counts as silent
AUTO_TRANSCRIBE="${AUTO_TRANSCRIBE:-1}"         # daemon mode: transcribe in place after the recording ends (0 = off)
WATCH_POLL_SEC="${WATCH_POLL_SEC:-10}"          # watch mode: seconds between live-call checks
LANG_OPT="auto"
NAME=""

# ---------- helpers ----------

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

list_devices() {
  ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 |
    sed -n '/audio devices/,$p' | grep -oE '\[[0-9]+\] .*' || true
}

device_index() {  # $1 = device name -> prints index or nothing
  list_devices | grep -F "] $1" | head -1 | sed -E 's/^\[([0-9]+)\].*/\1/'
}

fmt_dur() { printf '%dm%02ds' $(($1/60)) $(($1%60)); }

start_segment() {  # spawns ffmpeg recorders for segment $SEG
  local tag
  tag=$(printf 'seg-%03d' "$SEG")
  # aresample=async=1 pads timestamp gaps with silence: without it, dropped
  # capture buffers silently shorten the track and drift it out of sync with
  # the system stream. Capture diagnostics go to capture.log.
  ffmpeg -hide_banner -loglevel warning -f avfoundation -i ":${MIC_IDX}" \
    -af "aresample=async=1" \
    -ac 1 -ar 16000 -c:a pcm_s16le "$SESSION/${tag}-mic.wav" 2>>"$SESSION/capture.log" &
  MIC_PID=$!
  case "$SYS_MODE" in
    tap)
      "$SCRIPT_DIR/audiotap" "$SESSION/${tag}-sys.wav" 2>>"$SESSION/capture.log" &
      SYS_PID=$! ;;
    blackhole)
      ffmpeg -hide_banner -loglevel warning -f avfoundation -i ":${SYS_IDX}" \
        -af "aresample=async=1" \
        -ac 1 -ar 16000 -c:a pcm_s16le "$SESSION/${tag}-sys.wav" 2>>"$SESSION/capture.log" &
      SYS_PID=$! ;;
  esac
  SEG_START=$SECONDS
}

wav_dur() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null; }

check_segment_sync() {  # $1 = segment tag; warn if mic and sys tracks diverged
  local micf="$SESSION/$1-mic.wav" sysf="$SESSION/$1-sys.wav" md sd
  [[ -s "$micf" && -s "$sysf" ]] || return 0
  md=$(wav_dur "$micf") ; sd=$(wav_dur "$sysf")
  [[ -n "$md" && -n "$sd" ]] || return 0
  if awk -v a="$md" -v b="$sd" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d>3)}'; then
    log "⚠️  $1: mic (${md%.*}s) and system (${sd%.*}s) tracks diverged — audio was dropped during capture; check capture.log. Transcript alignment may suffer."
  fi
}

wait_or_kill() {  # $1 = pid (SIGINT already sent) — escalate so a stalled capture can't hang the daemon
  local pid="$1" i
  [[ -n "$pid" ]] || return 0
  for i in $(seq 1 80); do kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; return 0; }; sleep 0.1; done
  kill -TERM "$pid" 2>/dev/null
  for i in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; return 0; }; sleep 0.1; done
  kill -KILL "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  log "⚠️  capture process $pid had to be force-killed — its last segment may be truncated (see capture.log)."
}

stop_segment() {  # SIGINT lets ffmpeg finalize the wav header cleanly
  local tag
  tag=$(printf 'seg-%03d' "$SEG")
  [[ -n "${MIC_PID:-}" ]] && kill -INT "$MIC_PID" 2>/dev/null
  [[ -n "${SYS_PID:-}" ]] && kill -INT "$SYS_PID" 2>/dev/null
  wait_or_kill "${MIC_PID:-}"
  wait_or_kill "${SYS_PID:-}"
  MIC_PID="" ; SYS_PID=""
  check_segment_sync "$tag"
  RECORDED=$((RECORDED + SECONDS - SEG_START))
  SEG=$((SEG + 1))
}

write_state() {  # $1 = status, $2 = recorded seconds
  {
    echo "status=$1"
    echo "recorded_seconds=$2"
    echo "silence_seconds=${SILENCE_ACC:-0}"
    [[ -n "${END_REASON:-}" ]] && echo "reason=$END_REASON"
    echo "session=$SESSION"
  } > "$SESSION/state"
}

mean_volume_db() {  # mean volume (dBFS) of the last ~15s of a wav still being written
  tail -c 480000 "$1" 2>/dev/null |
    ffmpeg -nostats -hide_banner -v info -f s16le -ar 16000 -ac 1 -i - -af volumedetect -f null /dev/null 2>&1 |
    sed -n 's/.*mean_volume: \([-0-9.a-z]*\) dB.*/\1/p' | head -1
}

streams_silent() {  # true if every stream currently recording is below SILENCE_DB
  local tag f v any=0
  tag=$(printf 'seg-%03d' "$SEG")
  for f in "$SESSION/$tag-mic.wav" "$SESSION/$tag-sys.wav"; do
    [[ -s "$f" ]] || continue
    any=1
    v=$(mean_volume_db "$f")
    [[ -z "$v" ]] && return 1        # unmeasurable — don't treat as silent
    if [[ "$v" != "-inf" ]]; then
      awk -v v="$v" -v t="$SILENCE_DB" 'BEGIN{exit !(v >= t)}' && return 1
    fi
  done
  [[ "$any" == 1 ]]
}

call_udp_media() {  # $1 = process name — true if it holds a live UDP media flow.
  # Exclude :443 — that's QUIC (HTTP/3) web traffic; Slack and Chrome hold such
  # flows while completely idle, which is NOT a call.
  lsof -a -c "$1" -iUDP -nP 2>/dev/null | grep -- '->' | grep -qvE ':443$'
}

call_active() {  # true if a Zoom call, Slack huddle, or Google Meet call is currently live
  # Zoom / Slack keep live UDP media flows only while in a call/huddle
  local app
  for app in zoom.us Slack; do
    pgrep -xq "$app" && call_udp_media "$app" && return 0
  done
  if pgrep -xq "Google Chrome"; then
    # Meet media: in-call Chrome streams to Google over UDP 193xx (no permissions needed)
    lsof -a -c "Google Chrome" -iUDP -nP 2>/dev/null | grep -qE ':193[0-9]{2}$' && return 0
    # Meet tab: an open tab on an in-meeting URL (needs Automation-for-Chrome permission)
    osascript -e 'tell application "Google Chrome" to get URL of tabs of every window' 2>/dev/null |
      grep -qE 'meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}' && return 0
  fi
  return 1
}

recording_active() {  # true if the most recent session is currently recording or paused
  local cur now mtime
  cur=$(cat "$BASE_DIR/.current-session" 2>/dev/null) || return 1
  [[ -n "$cur" && -f "$cur/state" ]] || return 1
  grep -qE '^status=(recording|paused)$' "$cur/state" || return 1
  # a live daemon rewrites state every second — a stale file means it died
  now=$(date +%s) ; mtime=$(stat -f %m "$cur/state" 2>/dev/null || echo 0)
  (( now - mtime < 20 ))
}

notify() {  # $1 = title, $2 = message — best-effort banner (may be hidden by Focus/notification settings)
  osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true
}

prompt_record() {  # modal dialog: 0 = Record clicked, 1 = Ignore/dismissed, 2 = timed out
  local out
  out=$(osascript -e 'display dialog "A meeting looks live. Record it?" with title "Meeting detected" buttons {"Ignore","Record"} default button "Record" giving up after 45' 2>/dev/null) || return 1
  case "$out" in
    *"gave up:true"*)          return 2 ;;
    *"button returned:Record"*) return 0 ;;
    *)                          return 1 ;;
  esac
}

setup_session() {
  command -v ffmpeg >/dev/null || die "ffmpeg not found."
  MIC_IDX=$(device_index "$MIC_NAME")
  [[ -n "$MIC_IDX" ]] || die "Mic device '$MIC_NAME' not found. Devices:
$(list_devices)"
  local stamp
  stamp=$(date +%Y-%m-%d_%H%M)
  SESSION="$BASE_DIR/${stamp}${NAME:+_$NAME}"
  mkdir -p "$SESSION"
  echo "$SESSION" > "$BASE_DIR/.current-session"
  # system-audio source: native process tap (preferred, macOS 14.4+) > BlackHole > none
  SYS_MODE="none" ; SYS_IDX="" ; SYS_DESC=""
  if [[ -x "$SCRIPT_DIR/audiotap" ]] &&
     "$SCRIPT_DIR/audiotap" "$SESSION/.tap-probe.wav" 0.3 >/dev/null 2>&1; then
    SYS_MODE="tap" ; SYS_DESC="system: native audio tap"
  else
    SYS_IDX=$(device_index "$SYS_NAME")
    if [[ -n "$SYS_IDX" ]]; then
      SYS_MODE="blackhole" ; SYS_DESC="system: [$SYS_IDX] $SYS_NAME"
    fi
  fi
  rm -f "$SESSION/.tap-probe.wav"
  if [[ "$SYS_MODE" == "none" ]]; then
    log "⚠️  No system-audio source (audiotap helper or '$SYS_NAME') — recording MIC ONLY"
    log "   (other participants will be missed unless you're on speakers). See README."
  fi
  SEG=1 ; RECORDED=0 ; MIC_PID="" ; SYS_PID="" ; SEG_START=$SECONDS ; PAUSED=0
}

win_db() {  # mean volume (dBFS) of window: $1=file $2=start-sec $3=dur-sec; -inf → -999
  local v
  v=$(ffmpeg -nostats -hide_banner -v info -ss "$2" -t "$3" -i "$1" -af volumedetect -f null /dev/null 2>&1 |
    sed -n 's/.*mean_volume: \([-0-9.a-z]*\) dB.*/\1/p' | head -1)
  [[ -z "$v" || "$v" == "-inf" ]] && v=-999
  echo "$v"
}

to_sec() {  # HH:MM:SS.mmm -> seconds
  awk -F: -v t="$1" 'BEGIN{split(t,a,":"); printf "%.3f", a[1]*3600+a[2]*60+a[3]}'
}

transcribe() {  # $1 = session dir
  local dir="$1"
  [[ -f "$MODEL" ]] || die "Model not found at $MODEL — download ggml-large-v3-turbo.bin first."

  log "Mixing segments..."
  local concat_list="$dir/concat.txt" mic_list="$dir/.mic.txt" sys_list="$dir/.sys.txt"
  : > "$concat_list" ; : > "$mic_list" ; : > "$sys_list"
  local mic sys out found=0 diarize=1 mixdur base micp sysp micd sysd
  for mic in "$dir"/seg-*-mic.wav; do
    [[ -e "$mic" ]] || continue
    found=1
    sys="${mic%-mic.wav}-sys.wav"
    out="${mic%-mic.wav}-mixed.wav"
    if [[ -s "$sys" ]]; then
      micd=$(wav_dur "$mic") ; sysd=$(wav_dur "$sys")
      if [[ -n "$micd" && -n "$sysd" ]] &&
         awk -v a="$micd" -v b="$sysd" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d>3)}'; then
        log "⚠️  $(basename "${mic%-mic.wav}"): mic (${micd%.*}s) and system (${sysd%.*}s) tracks diverged — audio was dropped during capture; transcript alignment may suffer."
      fi
      ffmpeg -hide_banner -loglevel error -y -i "$mic" -i "$sys" \
        -filter_complex "amix=inputs=2:duration=longest:normalize=0" \
        -ac 1 -ar 16000 -c:a pcm_s16le "$out" || cp "$mic" "$out"
    else
      cp "$mic" "$out"
      diarize=0   # no system stream for this span — can't attribute speakers
    fi
    printf "file '%s'\n" "$out" >> "$concat_list"
    # per-track copies padded to the mixed length, so timestamps line up for attribution
    if [[ "$diarize" == 1 ]]; then
      mixdur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$out")
      base="$dir/.$(basename "${mic%-mic.wav}")"
      micp="${base}-micpad.wav" ; sysp="${base}-syspad.wav"
      ffmpeg -hide_banner -loglevel error -y -i "$mic" -af "apad=whole_dur=${mixdur}" -t "$mixdur" \
        -ac 1 -ar 16000 -c:a pcm_s16le "$micp"
      ffmpeg -hide_banner -loglevel error -y -i "$sys" -af "apad=whole_dur=${mixdur}" -t "$mixdur" \
        -ac 1 -ar 16000 -c:a pcm_s16le "$sysp"
      printf "file '%s'\n" "$micp" >> "$mic_list"
      printf "file '%s'\n" "$sysp" >> "$sys_list"
    fi
  done
  [[ "$found" == 1 ]] || die "No audio segments found in $dir"

  ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i "$concat_list" \
    -c copy "$dir/full.wav" || die "Concatenation failed."
  if [[ "$diarize" == 1 ]]; then
    ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i "$mic_list" -c copy "$dir/.mic-full.wav" &&
    ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i "$sys_list" -c copy "$dir/.sys-full.wav" ||
      diarize=0
  fi
  rm -f "$dir"/seg-*-mixed.wav "$dir"/.seg-*pad.wav "$concat_list" "$mic_list" "$sys_list"

  local extra=()
  [[ -n "${WHISPER_PROMPT:-}" ]] && extra+=(--prompt "$WHISPER_PROMPT")

  # markdown outputs so Obsidian picks them up
  local title
  title=$(basename "$dir")
  if [[ "$diarize" == 1 ]]; then
    # Transcribe each channel separately: a single mixed-stream pass can only
    # keep one voice wherever speech overlaps, so cross-talk (or drifted
    # tracks) silently loses words. Per-channel also makes speaker labels
    # exact instead of an energy-based guess.
    log "Transcribing each channel with whisper.cpp (large-v3-turbo, lang=$LANG_OPT)... ~2.5x realtime."
    whisper-cli -m "$MODEL" -f "$dir/.mic-full.wav" -l "$LANG_OPT" \
      --print-progress ${extra[@]+"${extra[@]}"} > "$dir/.mic-segments.raw" \
      || die "whisper-cli failed (mic channel)."
    whisper-cli -m "$MODEL" -f "$dir/.sys-full.wav" -l "$LANG_OPT" \
      --print-progress ${extra[@]+"${extra[@]}"} > "$dir/.sys-segments.raw" \
      || die "whisper-cli failed (system channel)."

    log "Merging channels by timestamp..."
    local merged="$dir/.merged.tsv" ch src who line ts te text t0 dur db prev=""
    : > "$merged"
    for ch in mic sys; do
      src="$dir/.$ch-full.wav"
      [[ "$ch" == mic ]] && who="$ME_LABEL" || who="$OTHER_LABEL"
      while IFS= read -r line; do
        ts="${line:1:12}" ; te="${line:18:12}" ; text="${line:31}"
        text="${text#"${text%%[![:space:]]*}"}"   # ltrim
        [[ -z "$text" ]] && continue
        t0=$(to_sec "$ts")
        dur=$(awk -v a="$t0" -v b="$(to_sec "$te")" 'BEGIN{d=b-a; if(d<0.3)d=0.3; printf "%.3f", d}')
        # drop whisper hallucinations over silence: no energy on this channel here
        db=$(win_db "$src" "$t0" "$dur")
        awk -v v="$db" -v t="$SILENCE_DB" 'BEGIN{exit !(v < t)}' && continue
        printf '%s\t%s\t%s\t%s\t%s\n' "$t0" "$ts" "$te" "$who" "$text" >> "$merged"
      done < <(grep '^\[' "$dir/.$ch-segments.raw")
    done
    sort -n -o "$merged" "$merged"

    { echo "# Transcript — $title" ; echo ; } > "$dir/transcript.md"
    { echo "# Transcript (timestamped) — $title" ; echo ; echo '```' ; } > "$dir/transcript.segments.md"
    while IFS=$'\t' read -r t0 ts te who text; do
      if [[ "$who" != "$prev" ]]; then
        printf '\n**%s:** %s\n' "$who" "$text" >> "$dir/transcript.md"
        prev="$who"
      else
        printf '%s\n' "$text" >> "$dir/transcript.md"
      fi
      printf '[%s --> %s]  %s: %s\n' "$ts" "$te" "$who" "$text" >> "$dir/transcript.segments.md"
    done < "$merged"
    echo '```' >> "$dir/transcript.segments.md"
    log "Speaker labels: $ME_LABEL = your mic; $OTHER_LABEL = meeting audio (all remote participants)."
    log "(If your voice echoes through the meeting audio, it may appear on both channels at the same timestamps.)"
  else
    log "Transcribing with whisper.cpp (large-v3-turbo, lang=$LANG_OPT)... ~5x realtime."
    whisper-cli -m "$MODEL" -f "$dir/full.wav" -l "$LANG_OPT" \
      -otxt -of "$dir/transcript" --print-progress ${extra[@]+"${extra[@]}"} > "$dir/.segments.raw" \
      || die "whisper-cli failed."
    { echo "# Transcript — $title" ; echo ; cat "$dir/transcript.txt" ; } > "$dir/transcript.md"
    { echo "# Transcript (timestamped) — $title" ; echo ; echo '```' ; grep '^\[' "$dir/.segments.raw" ; echo '```' ; } > "$dir/transcript.segments.md"
    log "No system-audio stream — transcript is unlabeled (speaker attribution needs BlackHole)."
  fi
  rm -f "$dir/transcript.txt" "$dir/.segments.raw" "$dir/.mic-segments.raw" "$dir/.sys-segments.raw" \
    "$dir/.merged.tsv" "$dir/.mic-full.wav" "$dir/.sys-full.wav"

  log ""
  log "Done. Transcript: $dir/transcript.md"
  log "Timestamped: $dir/transcript.segments.md"
}

# ---------- arg parsing ----------

CMD="record"
case "${1:-}" in
  record|start|watch|watch-start|watch-install|watch-uninstall|call-check|info) CMD="$1"; shift ;;
  transcribe)
    CMD="transcribe" ; shift
    TARGET="${1:-}" ; shift || true
    [[ -n "${TARGET:-}" && -d "$TARGET" ]] || die "Usage: meeting-record.sh transcribe <session-dir>"
    ;;
  ctl)
    CMD="ctl" ; shift
    ACTION="${1:-}" ; shift || true
    case "$ACTION" in pause|resume|end|status) ;; *) die "Usage: meeting-record.sh ctl pause|resume|end|status [session-dir]" ;; esac
    TARGET="${1:-}" ; shift || true
    ;;
esac
while [[ $# -gt 0 ]]; do
  case "$1" in
    --lang) LANG_OPT="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    *) die "Unknown option: $1" ;;
  esac
done

# ---------- ctl ----------

if [[ "$CMD" == "ctl" ]]; then
  if [[ -z "${TARGET:-}" ]]; then
    TARGET=$(cat "$BASE_DIR/.current-session" 2>/dev/null) || true
  fi
  [[ -n "${TARGET:-}" && -d "$TARGET" ]] || die "No session found. Pass a session dir explicitly."
  if [[ "$ACTION" == "status" ]]; then
    cat "$TARGET/state" 2>/dev/null || echo "status=unknown"
    exit 0
  fi
  [[ -f "$TARGET/state" ]] && grep -q 'status=ended' "$TARGET/state" && die "Session already ended: $TARGET"
  echo "$ACTION" > "$TARGET/control"
  log "Sent '$ACTION' to $TARGET"
  exit 0
fi

# ---------- helpers for external UIs (e.g. the meetingbar menu bar app) ----------

if [[ "$CMD" == "call-check" ]]; then  # exit 0 if a call is live right now
  call_active
  exit $?
fi

if [[ "$CMD" == "info" ]]; then
  echo "base_dir=$BASE_DIR"
  exit 0
fi

# ---------- watch mode (meeting auto-detect) ----------

if [[ "$CMD" == "watch-start" ]]; then  # click target of the watch notification
  if recording_active; then
    log "Recording already active — nothing to do."
    exit 0
  fi
  mkdir -p "$BASE_DIR"
  nohup "$SCRIPT_DIR/meeting-record.sh" start >> "$BASE_DIR/.watch-daemon.log" 2>&1 &
  for _ in $(seq 1 12); do recording_active && break; sleep 1; done
  if recording_active; then
    notify "🔴 Recording started" "Auto-ends when the call closes; transcript follows automatically."
    log "Recorder daemon launched (log: $BASE_DIR/.watch-daemon.log)"
  else
    notify "⚠️ Recording failed to start" "Check $BASE_DIR/.watch-daemon.log"
    log "Recorder daemon did not reach recording state — see $BASE_DIR/.watch-daemon.log"
    exit 1
  fi
  exit 0
fi

if [[ "$CMD" == "watch" ]]; then
  PROMPTED=0 ; INACTIVE_POLLS=0 ; TIMEOUTS=0
  log "👀 Watching for a live call every ${WATCH_POLL_SEC}s (Zoom / Slack huddle / Meet)."
  while true; do
    if call_active; then
      INACTIVE_POLLS=0
      if [[ "$PROMPTED" == 0 ]] && ! recording_active; then
        log "$(date '+%F %T') meeting detected — prompting"
        prompt_record ; rc=$?
        if (( rc == 0 )); then
          log "$(date '+%F %T') accepted — starting recorder"
          "$SCRIPT_DIR/meeting-record.sh" watch-start
          PROMPTED=1
        elif (( rc == 2 )); then
          # unanswered — the user may have missed it; retry a couple of times
          TIMEOUTS=$((TIMEOUTS + 1))
          if (( TIMEOUTS >= 3 )); then
            log "$(date '+%F %T') dialog unanswered ${TIMEOUTS}x — giving up for this call"
            PROMPTED=1
          else
            log "$(date '+%F %T') dialog unanswered — will retry in 2 min"
            sleep 120
          fi
        else
          log "$(date '+%F %T') declined"
          PROMPTED=1   # explicit Ignore: stay quiet until this call ends
        fi
      fi
    else
      INACTIVE_POLLS=$((INACTIVE_POLLS + 1))
      (( INACTIVE_POLLS >= 3 )) && { PROMPTED=0 ; TIMEOUTS=0 ; }  # call over — re-arm
    fi
    sleep "$WATCH_POLL_SEC"
  done
fi

if [[ "$CMD" == "watch-install" || "$CMD" == "watch-uninstall" ]]; then
  LABEL="local.meeting-transcriber.watch"
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  if [[ "$CMD" == "watch-uninstall" ]]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    log "Watcher launch agent removed."
    exit 0
  fi
  mkdir -p "$HOME/Library/LaunchAgents" "$BASE_DIR"
  # Prefer the meetingbar menu bar app (build: swiftc -O -o meetingbar meetingbar.swift);
  # fall back to the headless dialog watcher when it isn't built.
  if [[ -x "$SCRIPT_DIR/meetingbar" ]]; then
    PROG_ARGS="<string>$SCRIPT_DIR/meetingbar</string>"
    WATCH_KIND="meetingbar menu bar app"
  else
    PROG_ARGS="<string>$SCRIPT_DIR/meeting-record.sh</string><string>watch</string>"
    WATCH_KIND="headless watcher"
  fi
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>$PROG_ARGS</array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$BASE_DIR/.watch.log</string>
  <key>StandardErrorPath</key><string>$BASE_DIR/.watch.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST" || die "launchctl bootstrap failed."
  log "Watcher installed + running ($WATCH_KIND; launchd: $LABEL). Log: $BASE_DIR/.watch.log"
  log "Uninstall with: $0 watch-uninstall"
  exit 0
fi

# ---------- transcribe ----------

if [[ "$CMD" == "transcribe" ]]; then
  command -v whisper-cli >/dev/null || die "whisper-cli not found (brew install whisper-cpp)."
  transcribe "$TARGET"
  exit 0
fi

# ---------- daemon mode (no TTY; controlled via <session>/control) ----------

if [[ "$CMD" == "start" ]]; then
  setup_session
  : > "$SESSION/control"
  SILENCE_ACC=0 ; END_REASON="" ; CALL_SEEN=0 ; CALL_GONE=0 ; LAST_CHECK=$SECONDS
  daemon_stop() {
    [[ "$PAUSED" == 0 ]] && stop_segment
    END_REASON="${END_REASON:-manual}"
    write_state ended "$RECORDED"
    log "Ended (reason: $END_REASON). $(fmt_dur "$RECORDED") of audio in $SESSION"
    if [[ "$AUTO_TRANSCRIBE" == 1 ]] && command -v whisper-cli >/dev/null && (( RECORDED > 0 )); then
      echo "transcribe=running" >> "$SESSION/state"
      log "Transcribing (auto, ~2.5x realtime)... log: $SESSION/transcribe.log"
      if ( transcribe "$SESSION" ) >> "$SESSION/transcribe.log" 2>&1; then
        write_state ended "$RECORDED" ; echo "transcribe=done" >> "$SESSION/state"
        log "Transcript ready: $SESSION/transcript.md"
      else
        write_state ended "$RECORDED" ; echo "transcribe=failed" >> "$SESSION/state"
        log "⚠️  Auto-transcription FAILED — see $SESSION/transcribe.log. Retry: $0 transcribe $SESSION"
      fi
    else
      log "Transcribe with: $0 transcribe $SESSION --lang $LANG_OPT"
    fi
    exit 0
  }
  trap daemon_stop INT TERM
  log "🔴 Recording (daemon) to $SESSION"
  log "   mic: [$MIC_IDX] $MIC_NAME ${SYS_DESC:+ |  $SYS_DESC}"
  log "   Control with: $0 ctl pause|resume|end|status"
  log "   Auto-end: call-closed detection${CALL_END_GRACE_SEC:+ (grace ${CALL_END_GRACE_SEC}s)}, silence fallback ${AUTO_END_SEC}s"
  start_segment
  write_state recording 0
  while true; do
    cmd=$(cat "$SESSION/control" 2>/dev/null)
    if [[ -n "$cmd" ]]; then
      : > "$SESSION/control"
      case "$cmd" in
        pause)
          if [[ "$PAUSED" == 0 ]]; then
            stop_segment ; PAUSED=1 ; SILENCE_ACC=0
            log "⏸  Paused at $(fmt_dur "$RECORDED")"
          fi ;;
        resume)
          if [[ "$PAUSED" == 1 ]]; then
            start_segment ; PAUSED=0 ; SILENCE_ACC=0
            log "🔴 Resumed"
          fi ;;
        end) daemon_stop ;;
      esac
    fi
    # auto-end checks (every ~15s)
    if (( SECONDS - LAST_CHECK >= 15 )); then
      elapsed=$((SECONDS - LAST_CHECK)) ; LAST_CHECK=$SECONDS
      # 1) call-closed: arms once a live call is seen; ends when the signal stays gone
      if (( CALL_END_GRACE_SEC > 0 )); then
        if call_active; then
          CALL_SEEN=1 ; CALL_GONE=0
        elif [[ "$CALL_SEEN" == 1 ]]; then
          CALL_GONE=$((CALL_GONE + elapsed))
          if (( CALL_GONE >= CALL_END_GRACE_SEC )); then
            END_REASON="call_closed"
            log "🏁 Call closed — auto-ending."
            daemon_stop
          fi
        fi
      fi
      # 2) silence fallback: all recorded streams quiet for AUTO_END_SEC
      if [[ "$PAUSED" == 0 ]] && (( AUTO_END_SEC > 0 )); then
        if streams_silent; then
          SILENCE_ACC=$((SILENCE_ACC + elapsed))
        else
          SILENCE_ACC=0
        fi
        if (( SILENCE_ACC >= AUTO_END_SEC )); then
          END_REASON="silence"
          log "🏁 $(fmt_dur "$SILENCE_ACC") of silence — auto-ending."
          daemon_stop
        fi
      fi
    fi
    if [[ "$PAUSED" == 1 ]]; then
      write_state paused "$RECORDED"
    else
      write_state recording "$((RECORDED + SECONDS - SEG_START))"
    fi
    sleep 1
  done
fi

# ---------- interactive record mode ----------

command -v whisper-cli >/dev/null || die "whisper-cli not found (brew install whisper-cpp)."
setup_session
TRANSCRIBE_AFTER=0

cleanup_and_exit() {
  [[ "$PAUSED" == 0 ]] && stop_segment
  write_state ended "$RECORDED"
  log ""
  log "Recording saved: $SESSION ($(fmt_dur "$RECORDED") of audio)"
  if [[ "$TRANSCRIBE_AFTER" == 1 ]]; then
    transcribe "$SESSION"
    log "Next: in Claude Code, run /meeting-notes to summarize."
  else
    log "Transcribe later with:"
    log "  $0 transcribe $SESSION --lang $LANG_OPT"
  fi
  exit 0
}
trap 'TRANSCRIBE_AFTER=0; cleanup_and_exit' INT

log "🔴 Recording to $SESSION"
log "   mic: [$MIC_IDX] $MIC_NAME ${SYS_DESC:+ |  $SYS_DESC}"
log "   Keys:  p = pause/resume   e = end + transcribe   q = end (no transcribe)"
start_segment

while true; do
  if [[ "$PAUSED" == 1 ]]; then
    status="⏸  PAUSED"
    total=$RECORDED
  else
    status="🔴 REC   "
    total=$((RECORDED + SECONDS - SEG_START))
  fi
  write_state "$([[ "$PAUSED" == 1 ]] && echo paused || echo recording)" "$total"
  printf '\r%s  %s  ' "$status" "$(fmt_dur "$total")"
  key=""
  read -r -s -t 1 -n 1 key 2>/dev/null
  case "$key" in
    p|P)
      if [[ "$PAUSED" == 0 ]]; then
        stop_segment ; PAUSED=1
      else
        start_segment ; PAUSED=0
      fi
      ;;
    e|E) TRANSCRIBE_AFTER=1 ; cleanup_and_exit ;;
    q|Q) TRANSCRIBE_AFTER=0 ; cleanup_and_exit ;;
  esac
done
