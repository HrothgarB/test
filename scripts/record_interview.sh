#!/usr/bin/env bash
set -euo pipefail

# Interview recording script
# - Creates /recordings if missing
# - Uses date + rolling sequence number for filenames
# - Captures 720p video + USB audio to MP4

OUT_DIR="${OUT_DIR:-/recordings}"
VIDEO_DEV="${VIDEO_DEV:-/dev/video0}"
AUDIO_DEV="${AUDIO_DEV:-}"
FPS="${FPS:-30}"
SIZE="${SIZE:-1280x720}"
VIDEO_BITRATE="${VIDEO_BITRATE:-3M}"
AUDIO_BITRATE="${AUDIO_BITRATE:-128k}"
AUDIO_RATE="${AUDIO_RATE:-48000}"

DATE="$(date +%F)"
mkdir -p "$OUT_DIR"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "[record_interview] ffmpeg not found in PATH" >&2
  exit 1
fi

if [[ ! -e "$VIDEO_DEV" ]]; then
  echo "[record_interview] Video device not found: $VIDEO_DEV" >&2
  exit 1
fi

detect_audio_dev() {
  if [[ -n "$AUDIO_DEV" ]]; then
    printf "%s" "$AUDIO_DEV"
    return
  fi

  local first_card
  first_card="$(arecord -l 2>/dev/null | sed -n 's/^card \([0-9]\+\):.*/\1/p' | head -n1 || true)"
  if [[ -n "$first_card" ]]; then
    printf "hw:%s,0" "$first_card"
    return
  fi

  # Last-resort fallback for systems where ALSA has a working "default" capture.
  printf "default"
}

AUDIO_DEV="$(detect_audio_dev)"

next_index() {
  local max=0
  shopt -s nullglob
  for f in "$OUT_DIR"/${DATE}_interview_*.mp4; do
    local n="${f##*_}"
    n="${n%.mp4}"
    n="$((10#$n))"
    (( n > max )) && max=$n
  done
  printf "%03d" $((max + 1))
}

IDX="$(next_index)"
OUT_FILE="$OUT_DIR/${DATE}_interview_${IDX}.mp4"

echo "[record_interview] Recording to: $OUT_FILE"
echo "[record_interview] Using video device: $VIDEO_DEV"
echo "[record_interview] Using audio device: $AUDIO_DEV"

exec ffmpeg \
  -hide_banner -loglevel warning \
  -f v4l2 -framerate "$FPS" -video_size "$SIZE" -i "$VIDEO_DEV" \
  -f alsa -i "$AUDIO_DEV" \
  -c:v h264_v4l2m2m -b:v "$VIDEO_BITRATE" -maxrate "$VIDEO_BITRATE" -bufsize 6M \
  -c:a aac -b:a "$AUDIO_BITRATE" -ar "$AUDIO_RATE" \
  -af aresample=async=1:first_pts=0 \
  -movflags +faststart \
  "$OUT_FILE"
