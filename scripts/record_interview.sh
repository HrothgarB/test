#!/usr/bin/env bash
set -euo pipefail

# Interview recording script
# - Creates recording directories if missing
# - Organizes files by year/month
# - Uses timestamp filenames (YYYY-MM-DD_HH-MM-SS.mp4)
# - Captures 720p video + USB audio to MP4

OUT_DIR="${OUT_DIR:-/recordings}"
VIDEO_DEV="${VIDEO_DEV:-/dev/video0}"
AUDIO_DEV="${AUDIO_DEV:-plughw:4,0}"
FPS="${FPS:-20}"
SIZE="${SIZE:-1280x720}"
AUDIO_BITRATE="${AUDIO_BITRATE:-128k}"
AUDIO_RATE="${AUDIO_RATE:-44100}"
AUDIO_CHANNELS="${AUDIO_CHANNELS:-1}"
VIDEO_INPUT_FORMAT="${VIDEO_INPUT_FORMAT:-mjpeg}"
OUTPUT_START_TRIM_SECONDS="${OUTPUT_START_TRIM_SECONDS:-2}"
START_DELAY_SECONDS="${START_DELAY_SECONDS:-0}"
VIDEO_WARMUP_SECONDS="${VIDEO_WARMUP_SECONDS:-0}"

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

exec ffmpeg \
  -loglevel warning \
  -fflags +genpts+discardcorrupt \
  -use_wallclock_as_timestamps 1 \
  -thread_queue_size 1024 \
  -f v4l2 -ts abs -input_format "$VIDEO_INPUT_FORMAT" -framerate "$FPS" -video_size "$SIZE" -i "$VIDEO_DEV" \
  -thread_queue_size 1024 \
  -f alsa -ar "$AUDIO_RATE" -i "$AUDIO_DEV" \
  -c:v libx264 \
  -preset ultrafast \
  -tune zerolatency \
  -vf "format=yuv420p" \
  -c:a aac \
  -b:a "$AUDIO_BITRATE" \
  -ac "$AUDIO_CHANNELS" \
  -af "aresample=async=1000:first_pts=0" \
  -movflags +faststart \
  "$OUT_FILE"
