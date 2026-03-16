#!/usr/bin/env bash
set -euo pipefail

# Interview recording script
# - Creates /recordings if missing
# - Uses date + rolling sequence number for filenames
# - Captures 720p video + USB audio to MP4

OUT_DIR="${OUT_DIR:-/recordings}"
VIDEO_DEV="${VIDEO_DEV:-/dev/video0}"
AUDIO_DEV="${AUDIO_DEV:-default}"
FPS="${FPS:-30}"
SIZE="${SIZE:-1280x720}"
VIDEO_BITRATE="${VIDEO_BITRATE:-3M}"
AUDIO_BITRATE="${AUDIO_BITRATE:-128k}"
AUDIO_RATE="${AUDIO_RATE:-48000}"

DATE="$(date +%F)"
mkdir -p "$OUT_DIR"

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

exec ffmpeg \
  -hide_banner -loglevel warning \
  -f v4l2 -framerate "$FPS" -video_size "$SIZE" -i "$VIDEO_DEV" \
  -f alsa -i "$AUDIO_DEV" \
  -c:v h264_v4l2m2m -b:v "$VIDEO_BITRATE" -maxrate "$VIDEO_BITRATE" -bufsize 6M \
  -c:a aac -b:a "$AUDIO_BITRATE" -ar "$AUDIO_RATE" \
  -af aresample=async=1:first_pts=0 \
  -movflags +faststart \
  "$OUT_FILE"
