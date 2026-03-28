#!/usr/bin/env bash
set -euo pipefail

# Setup helper for a Raspberry Pi deployment.
# Run this once on a fresh Pi after cloning the repository.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVICE_NAME="${SERVICE_NAME:-interview-recorder.service}"
INSTALL_DIR="${INSTALL_DIR:-/home/mayday/interview-recorder}"
RECORDINGS_DIR="${RECORDINGS_DIR:-/recordings}"
SERVICE_USER="${SERVICE_USER:-${SUDO_USER:-$(id -un)}}"
ENV_FILE="${ENV_FILE:-/etc/interview-recorder.env}"

cd "$REPO_ROOT"

if [[ ! -d ".git" ]]; then
  echo "[install_testpi] This checkout does not have git history." >&2
  echo "[install_testpi] Clone the repository before running the installer." >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "[install_testpi] git is not installed." >&2
  exit 1
fi

if command -v apt-get >/dev/null 2>&1; then
  echo "[install_testpi] Installing Pi dependencies"
  sudo apt-get update
  sudo apt-get install -y ffmpeg python3-gpiozero v4l-utils alsa-utils
else
  echo "[install_testpi] apt-get not found; skipping dependency install"
fi

echo "[install_testpi] Ensuring $SERVICE_USER can access audio/video/gpio devices"
sudo usermod -aG audio,video,gpio "$SERVICE_USER"

echo "[install_testpi] Creating recordings directory: $RECORDINGS_DIR"
sudo mkdir -p "$RECORDINGS_DIR"

if [[ "$(id -un)" == "mayday" ]]; then
  sudo chown -R mayday:mayday "$RECORDINGS_DIR"
fi

if [[ "$REPO_ROOT" != "$INSTALL_DIR" ]]; then
  echo "[install_testpi] Warning: repo root is $REPO_ROOT"
  echo "[install_testpi] Expected install dir is $INSTALL_DIR"
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[install_testpi] Creating optional environment file: $ENV_FILE"
  sudo tee "$ENV_FILE" >/dev/null <<'EOF'
# Optional Pi-local overrides for interview-recorder.service.
# Enable LAN multicast livestreaming for VLC/OBS viewers:
# STREAM_URL=udp://239.1.1.1:5000?pkt_size=1316&ttl=1
EOF
  sudo chmod 600 "$ENV_FILE"
else
  echo "[install_testpi] Preserving existing environment file: $ENV_FILE"
fi

echo "[install_testpi] Verifying scripts"
chmod +x scripts/install_testpi.sh scripts/update_testpi.sh scripts/record_interview.sh
bash -n scripts/record_interview.sh
bash -n scripts/update_testpi.sh
PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile scripts/gpio_recorder.py

if [[ -f "systemd/$SERVICE_NAME" ]]; then
  echo "[install_testpi] Installing systemd unit"
  sudo cp "systemd/$SERVICE_NAME" "/etc/systemd/system/$SERVICE_NAME"
  sudo systemctl daemon-reload
  sudo systemctl enable --now "$SERVICE_NAME"
else
  echo "[install_testpi] systemd/$SERVICE_NAME not found; skipping service install"
fi

echo "[install_testpi] Installation complete"
