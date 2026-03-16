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

Clone the project on the Pi:

```bash
git clone https://github.com/HrothgarB/test.git /home/mayday/interview-recorder
cd /home/mayday/interview-recorder
```

## Install dependencies (Pi OS)

```bash
sudo apt update
sudo apt install -y ffmpeg python3-gpiozero v4l-utils alsa-utils
```

## Verify camera and mic devices

```bash
v4l2-ctl --list-devices
arecord -l
```

If your devices are not `/dev/video0` and `default`, set env vars in the service:
- `VIDEO_DEV`
- `AUDIO_DEV`

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
  --child-log-file /tmp/interview-recorder-ffmpeg.log
```

Press button once to start and again to stop.

Verify recordings:

```bash
ls -lh /recordings
```

## Install as systemd service

```bash
sudo cp systemd/interview-recorder.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now interview-recorder.service
sudo systemctl status interview-recorder.service
```

## Useful troubleshooting commands

```bash
journalctl -u interview-recorder.service -f
ls -lh /recordings
tail -f /var/log/interview-recorder/ffmpeg.log
```

## Notes

- `gpio_recorder.py` sends SIGINT to FFmpeg so MP4 files finalize cleanly.
- If graceful stop hangs, the controller escalates to terminate/kill.
- Controller options:

```bash
python3 scripts/gpio_recorder.py --help
```
