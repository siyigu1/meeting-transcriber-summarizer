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
#       `end` stops the daemon WITHOUT transcribing — run `transcribe` after.
#
#   TRANSCRIBE:
#     ./meeting-record.sh transcribe <session-dir> [--lang zh|en|auto]
#
# Output: $MEETING_DIR/<timestamp>_<name>/  (default ~/meetings)
#   seg-*.wav                 raw audio segments (mic / sys)
#   full.wav                  mixed + concatenated audio
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
  ffmpeg -hide_banner -loglevel error -f avfoundation -i ":${MIC_IDX}" \
    -ac 1 -ar 16000 -c:a pcm_s16le "$SESSION/${tag}-mic.wav" &
  MIC_PID=$!
  case "$SYS_MODE" in
    tap)
      "$SCRIPT_DIR/audiotap" "$SESSION/${tag}-sys.wav" 2>/dev/null &
      SYS_PID=$! ;;
    blackhole)
      ffmpeg -hide_banner -loglevel error -f avfoundation -i ":${SYS_IDX}" \
        -ac 1 -ar 16000 -c:a pcm_s16le "$SESSION/${tag}-sys.wav" &
      SYS_PID=$! ;;
  esac
  SEG_START=$SECONDS
}

stop_segment() {  # SIGINT lets ffmpeg finalize the wav header cleanly
  [[ -n "${MIC_PID:-}" ]] && kill -INT "$MIC_PID" 2>/dev/null
  [[ -n "${SYS_PID:-}" ]] && kill -INT "$SYS_PID" 2>/dev/null
  wait "${MIC_PID:-}" 2>/dev/null
  [[ -n "${SYS_PID:-}" ]] && wait "$SYS_PID" 2>/dev/null
  MIC_PID="" ; SYS_PID=""
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

call_active() {  # true if a Zoom call, Slack huddle, or Google Meet tab is currently live
  # Zoom / Slack keep live UDP media flows only while in a call/huddle
  local app
  for app in zoom.us Slack; do
    if pgrep -xq "$app" && lsof -a -c "$app" -iUDP -nP 2>/dev/null | grep -q -- '->'; then
      return 0
    fi
  done
  # Meet: an open Chrome tab on an in-meeting URL (guard pgrep — osascript would launch Chrome)
  if pgrep -xq "Google Chrome"; then
    osascript -e 'tell application "Google Chrome" to get URL of tabs of every window' 2>/dev/null |
      grep -qE 'meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}' && return 0
  fi
  return 1
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
  local mic sys out found=0 diarize=1 mixdur base micp sysp
  for mic in "$dir"/seg-*-mic.wav; do
    [[ -e "$mic" ]] || continue
    found=1
    sys="${mic%-mic.wav}-sys.wav"
    out="${mic%-mic.wav}-mixed.wav"
    if [[ -s "$sys" ]]; then
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

  log "Transcribing with whisper.cpp (large-v3-turbo, lang=$LANG_OPT)... this runs ~5x realtime."
  local extra=()
  [[ -n "${WHISPER_PROMPT:-}" ]] && extra+=(--prompt "$WHISPER_PROMPT")
  whisper-cli -m "$MODEL" -f "$dir/full.wav" -l "$LANG_OPT" \
    -otxt -of "$dir/transcript" --print-progress ${extra[@]+"${extra[@]}"} > "$dir/.segments.raw" \
    || die "whisper-cli failed."

  # markdown outputs so Obsidian picks them up
  local title
  title=$(basename "$dir")
  if [[ "$diarize" == 1 ]]; then
    log "Labeling speakers (mic vs system energy per segment)..."
    local line ts te text t0 dur micdb sysdb who prev=""
    { echo "# Transcript — $title" ; echo ; } > "$dir/transcript.md"
    { echo "# Transcript (timestamped) — $title" ; echo ; echo '```' ; } > "$dir/transcript.segments.md"
    while IFS= read -r line; do
      ts="${line:1:12}" ; te="${line:18:12}" ; text="${line:31}"
      text="${text#"${text%%[![:space:]]*}"}"   # ltrim
      [[ -z "$text" ]] && continue
      t0=$(to_sec "$ts")
      dur=$(awk -v a="$t0" -v b="$(to_sec "$te")" 'BEGIN{d=b-a; if(d<0.3)d=0.3; printf "%.3f", d}')
      micdb=$(win_db "$dir/.mic-full.wav" "$t0" "$dur")
      sysdb=$(win_db "$dir/.sys-full.wav" "$t0" "$dur")
      who=$(awk -v m="$micdb" -v s="$sysdb" -v me="$ME_LABEL" -v other="$OTHER_LABEL" \
        'BEGIN{print (m>=s) ? me : other}')
      if [[ "$who" != "$prev" ]]; then
        printf '\n**%s:** %s\n' "$who" "$text" >> "$dir/transcript.md"
        prev="$who"
      else
        printf '%s\n' "$text" >> "$dir/transcript.md"
      fi
      printf '[%s --> %s]  %s: %s\n' "$ts" "$te" "$who" "$text" >> "$dir/transcript.segments.md"
    done < <(grep '^\[' "$dir/.segments.raw")
    echo '```' >> "$dir/transcript.segments.md"
    log "Speaker labels: $ME_LABEL = your mic; $OTHER_LABEL = meeting audio (all remote participants)."
  else
    { echo "# Transcript — $title" ; echo ; cat "$dir/transcript.txt" ; } > "$dir/transcript.md"
    { echo "# Transcript (timestamped) — $title" ; echo ; echo '```' ; grep '^\[' "$dir/.segments.raw" ; echo '```' ; } > "$dir/transcript.segments.md"
    log "No system-audio stream — transcript is unlabeled (speaker attribution needs BlackHole)."
  fi
  rm -f "$dir/transcript.txt" "$dir/.segments.raw" "$dir/.mic-full.wav" "$dir/.sys-full.wav"

  log ""
  log "Done. Transcript: $dir/transcript.md"
  log "Timestamped: $dir/transcript.segments.md"
}

# ---------- arg parsing ----------

CMD="record"
case "${1:-}" in
  record|start) CMD="$1"; shift ;;
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
    log "Transcribe with: $0 transcribe $SESSION --lang $LANG_OPT"
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
