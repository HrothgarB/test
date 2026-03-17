# Portable Interview Recorder (Raspberry Pi)

This project turns a Raspberry Pi 4 into a push-button interview recorder appliance.

## What is included

- `scripts/record_interview.sh`: FFmpeg recording script that writes MP4 files to `/recordings`
- `scripts/gpio_recorder.py`: GPIO button controller (press once start, press again stop)
- `systemd/interview-recorder.service`: systemd unit example for boot-time startup

## Hardware

- Raspberry Pi 4
- Logitech C270 webcam
- USB microphone
- External SSD mounted at `/recordings`
- Momentary push button wired to **GPIO2 (BCM pin 2)** and **GND**

## Quick start for your setup (`mayday@testpi`)

SSH to your Pi:

```bash
ssh mayday@testpi
```

Install `git` if needed, then clone:

```bash
sudo apt update
sudo apt install -y git
git clone https://github.com/HrothgarB/test.git /home/mayday/interview-recorder
cd /home/mayday/interview-recorder
```

If you used a ZIP instead of `git clone`, `git status` will fail because there is no `.git` directory.

## Path quick rules (avoids common "No such file or directory" errors)

- `/scripts` means a folder at filesystem root (wrong for this project).
- `scripts` means the `scripts/` folder inside the repo.
- Run `pwd` before commands if unsure where you are.

Examples:

```bash
# from repo root
bash -n scripts/record_interview.sh

# from inside scripts/
cd scripts
bash -n record_interview.sh
```

## Install dependencies (Pi OS)

```bash
sudo apt install -y ffmpeg python3-gpiozero v4l-utils alsa-utils
```

## Verify camera and mic devices

```bash
v4l2-ctl --list-devices
arecord -l
```

Based on your sample output, likely choices are:
- Video: `/dev/video0` (C270 HD WEBCAM)
- Audio: `plughw:3,0` (C270 mic) or `plughw:4,0` (USB PnP mic)

## Create and test recordings directory

```bash
sudo mkdir -p /recordings
sudo chown -R mayday:mayday /recordings
```

Ensure your SSD is mounted there at boot (`/etc/fstab`).

## Manual test (before systemd)

```bash
cd /home/mayday/interview-recorder
chmod +x scripts/record_interview.sh scripts/gpio_recorder.py
python3 scripts/gpio_recorder.py \
  --pin 2 \
  --record-script /home/mayday/interview-recorder/scripts/record_interview.sh \
  --child-log-file /home/mayday/interview-recorder/logs/ffmpeg.log
```

Press button once to start and again to stop.

Verify recordings:

```bash
ls -lh /recordings
```

If recording fails, test ffmpeg directly with known device values:

```bash
cd /home/mayday/interview-recorder
AUDIO_DEV=plughw:3,0 AUDIO_CHANNELS=1 VIDEO_DEV=/dev/video0 timeout 10s ./scripts/record_interview.sh
```

If that works, switch to `AUDIO_DEV=plughw:4,0` and compare.


If you see `cannot set channel count to 2`, force mono input:

```bash
AUDIO_DEV=plughw:3,0 AUDIO_CHANNELS=1 VIDEO_DEV=/dev/video0 ./scripts/record_interview.sh
```

## Install as systemd service

```bash
sudo cp systemd/interview-recorder.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now interview-recorder.service
sudo systemctl status interview-recorder.service
```

If you change `VIDEO_DEV`/`AUDIO_DEV`/`AUDIO_CHANNELS` in the unit:

```bash
sudo systemctl edit --full interview-recorder.service
sudo systemctl daemon-reload
sudo systemctl restart interview-recorder.service
```

## Useful troubleshooting commands

```bash
journalctl -u interview-recorder.service -f
ls -lh /recordings
tail -f /home/mayday/interview-recorder/logs/ffmpeg.log
```

## Notes

- `gpio_recorder.py` sends SIGINT to FFmpeg so MP4 files finalize cleanly.
- Button presses toggle an internal start/stop mode, so the second press is treated as stop even if ffmpeg exited unexpectedly.
- If graceful stop hangs, the controller escalates to terminate/kill.
- Run compile check without creating cache files:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile scripts/gpio_recorder.py
```
