#!/usr/bin/env bash
set -euo pipefail

# Interview recording script
# - Creates recording directories if missing
# - Organizes files by year/month
# - Uses timestamp filenames (YYYY-MM-DD_HH-MM-SS.mp4)
# - Captures 720p video + USB audio to MP4

OUT_DIR="${OUT_DIR:-/recordings}"
VIDEO_DEV="${VIDEO_DEV:-/dev/video0}"
AUDIO_DEV="${AUDIO_DEV:-}"
FPS="${FPS:-20}"
SIZE="${SIZE:-1280x720}"
AUDIO_BITRATE="${AUDIO_BITRATE:-128k}"
AUDIO_RATE="${AUDIO_RATE:-44100}"
AUDIO_CHANNELS="${AUDIO_CHANNELS:-1}"
VIDEO_INPUT_FORMAT="${VIDEO_INPUT_FORMAT:-mjpeg}"
OUTPUT_START_TRIM_SECONDS="${OUTPUT_START_TRIM_SECONDS:-0}"
START_DELAY_SECONDS="${START_DELAY_SECONDS:-0}"
VIDEO_WARMUP_SECONDS="${VIDEO_WARMUP_SECONDS:-0}"
MIN_FREE_MB="${MIN_FREE_MB:-1024}"

mkdir -p "$OUT_DIR"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "[record_interview] ffmpeg not found in PATH" >&2
  exit 1
fi

if [[ ! -e "$VIDEO_DEV" ]]; then
  echo "[record_interview] Video device not found: $VIDEO_DEV" >&2
  exit 1
fi

if [[ ! -d "$OUT_DIR" ]]; then
  echo "[record_interview] Output directory does not exist: $OUT_DIR" >&2
  exit 1
fi

if [[ ! -w "$OUT_DIR" ]]; then
  echo "[record_interview] Output directory is not writable: $OUT_DIR" >&2
  echo "[record_interview] Fix ownership/permissions for user $(id -un)." >&2
  exit 1
fi

check_free_space_mb() {
  local avail_mb
  avail_mb="$(df -Pm "$OUT_DIR" | awk 'NR==2 {print $4}')"
  if [[ -z "$avail_mb" ]]; then
    echo "[record_interview] Unable to determine free space for $OUT_DIR" >&2
    exit 1
  fi
  if (( avail_mb < MIN_FREE_MB )); then
    echo "[record_interview] Not enough free space in $OUT_DIR: ${avail_mb}MB available, ${MIN_FREE_MB}MB required" >&2
    exit 1
  fi
  echo "[record_interview] Free space check passed: ${avail_mb}MB available"
}

list_capture_cards() {
  arecord -l 2>/dev/null | sed -n 's/^card \([0-9]\+\):.*/\1/p'
}

resolve_audio_dev() {
  local requested cards first_card requested_card

  requested="$AUDIO_DEV"
  cards="$(list_capture_cards || true)"

  if [[ -z "$cards" ]]; then
    echo "[record_interview] No ALSA capture devices found (arecord -l)." >&2
    exit 1
  fi

  if [[ -n "$requested" ]]; then
    if [[ "$requested" =~ ^plughw:([0-9]+),0$ ]]; then
      requested_card="${BASH_REMATCH[1]}"
      if echo "$cards" | grep -qx "$requested_card"; then
        printf "%s" "$requested"
        return
      fi
      echo "[record_interview] Requested AUDIO_DEV '$requested' is unavailable; falling back." >&2
    else
      # Keep explicit non-plughw user selections (e.g. default, hw:1,0, plughw:1,1)
      printf "%s" "$requested"
      return
    fi
  fi

  first_card="$(echo "$cards" | head -n1)"
  printf "plughw:%s,0" "$first_card"
}

AUDIO_DEV="$(resolve_audio_dev)"

check_free_space_mb

if [[ "${1:-}" == "--self-check" ]]; then
  AUDIO_DEV="$(resolve_audio_dev)"
  echo "[record_interview] Self-check OK"
  echo "[record_interview] Video device: $VIDEO_DEV"
  echo "[record_interview] Audio device: $AUDIO_DEV"
  echo "[record_interview] Output dir: $OUT_DIR"
  echo "[record_interview] Min free space (MB): $MIN_FREE_MB"
  exit 0
fi

next_output_file() {
  while true; do
    local ts year month target_dir candidate
    ts="$(date +%Y-%m-%d_%H-%M-%S)"
    year="$(date +%Y)"
    month="$(date +%m)"
    target_dir="$OUT_DIR/$year/$month"
    mkdir -p "$target_dir"

    if [[ ! -w "$target_dir" ]]; then
      echo "[record_interview] Output directory is not writable: $target_dir" >&2
      exit 1
    fi

    candidate="$target_dir/$ts.mp4"
    if [[ ! -e "$candidate" ]]; then
      printf "%s" "$candidate"
      return
    fi

    # If there is a rare same-second collision, wait for next second timestamp.
    sleep 1
  done
}

OUT_FILE="$(next_output_file)"

# For logging clarity, extract timestamp components from selected output path.
FILE_NAME="$(basename "$OUT_FILE")"
YEAR_DIR="$(basename "$(dirname "$(dirname "$OUT_FILE")")")"
MONTH_DIR="$(basename "$(dirname "$OUT_FILE")")"

echo "[record_interview] Recording to: $OUT_FILE"
echo "[record_interview] Year directory: $YEAR_DIR"
echo "[record_interview] Month directory: $MONTH_DIR"
echo "[record_interview] Filename: $FILE_NAME"
echo "[record_interview] Using video device: $VIDEO_DEV"
echo "[record_interview] Using audio device: $AUDIO_DEV"
echo "[record_interview] Using FPS: $FPS"
echo "[record_interview] Using input format: $VIDEO_INPUT_FORMAT"
echo "[record_interview] Startup delay (seconds): $START_DELAY_SECONDS"
echo "[record_interview] Video warmup (seconds): $VIDEO_WARMUP_SECONDS"
echo "[record_interview] Output start trim (seconds): $OUTPUT_START_TRIM_SECONDS"

if [[ "$START_DELAY_SECONDS" != "0" ]]; then
  sleep "$START_DELAY_SECONDS"
fi

if [[ "$VIDEO_WARMUP_SECONDS" != "0" ]]; then
  echo "[record_interview] Warming camera for $VIDEO_WARMUP_SECONDS second(s)"
  ffmpeg -hide_banner -loglevel error \
    -f v4l2 -input_format "$VIDEO_INPUT_FORMAT" -framerate "$FPS" -video_size "$SIZE" -i "$VIDEO_DEV" \
    -t "$VIDEO_WARMUP_SECONDS" -f null - >/dev/null 2>&1 || true
fi

TRIM_ARGS=()
if [[ "$OUTPUT_START_TRIM_SECONDS" != "0" ]]; then
  TRIM_ARGS=(-ss "$OUTPUT_START_TRIM_SECONDS")
fi

exec ffmpeg \
  -loglevel warning \
  -thread_queue_size 1024 \
  -f v4l2 -input_format "$VIDEO_INPUT_FORMAT" -framerate "$FPS" -video_size "$SIZE" -i "$VIDEO_DEV" \
  -thread_queue_size 1024 \
  -f alsa -ar "$AUDIO_RATE" -i "$AUDIO_DEV" \
  "${TRIM_ARGS[@]}" \
  -c:v libx264 \
  -preset ultrafast \
  -tune zerolatency \
  -vf "scale=in_range=pc:out_range=tv,format=yuv420p" \
  -c:a aac \
  -b:a "$AUDIO_BITRATE" \
  -ac "$AUDIO_CHANNELS" \
  -af "pan=mono|c0=.5*c0+.5*c1,aresample=async=1000:first_pts=0" \
  -movflags +faststart \
  "$OUT_FILE"
