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

echo "[install_testpi] Verifying scripts"
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
