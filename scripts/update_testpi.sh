#!/usr/bin/env bash
set -euo pipefail

# Update helper for the Raspberry Pi deployment.
# Run this from anywhere; it finds the repo root automatically.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVICE_NAME="${SERVICE_NAME:-interview-recorder.service}"
SYSTEMD_UNIT_PATH="${SYSTEMD_UNIT_PATH:-/etc/systemd/system/$SERVICE_NAME}"

cd "$REPO_ROOT"

if [[ ! -d ".git" ]]; then
  echo "[update_testpi] This checkout does not have git history." >&2
  echo "[update_testpi] Re-clone the repository instead of running an in-place update." >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "[update_testpi] git is not installed." >&2
  exit 1
fi

echo "[update_testpi] Resetting managed helper scripts to repo versions"
if ! git restore --worktree --staged -- scripts/install_testpi.sh scripts/record_interview.sh scripts/update_testpi.sh >/dev/null 2>&1; then
  git checkout -- scripts/install_testpi.sh scripts/record_interview.sh scripts/update_testpi.sh
fi

echo "[update_testpi] Updating repository in $REPO_ROOT"
git pull --ff-only

echo "[update_testpi] Verifying shell script syntax"
bash -n scripts/install_testpi.sh scripts/update_testpi.sh scripts/record_interview.sh

echo "[update_testpi] Verifying Python syntax"
PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile scripts/http_mjpeg_preview.py scripts/gpio_recorder.py

if [[ -f "systemd/$SERVICE_NAME" ]]; then
  echo "[update_testpi] Refreshing systemd unit at $SYSTEMD_UNIT_PATH"
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    cp "systemd/$SERVICE_NAME" "$SYSTEMD_UNIT_PATH"
  else
    sudo cp "systemd/$SERVICE_NAME" "$SYSTEMD_UNIT_PATH"
  fi
fi

load_state=""
if command -v systemctl >/dev/null 2>&1; then
  load_state="$(systemctl show "$SERVICE_NAME" --property=LoadState --value 2>/dev/null || true)"
fi

if [[ "$load_state" == "loaded" ]]; then
  echo "[update_testpi] Restarting $SERVICE_NAME"
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    systemctl daemon-reload
    systemctl restart "$SERVICE_NAME"
  else
    sudo systemctl daemon-reload
    sudo systemctl restart "$SERVICE_NAME"
  fi
else
  echo "[update_testpi] $SERVICE_NAME is not loaded; skipping service restart"
fi

echo "[update_testpi] Update complete"
