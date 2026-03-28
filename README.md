# Portable Interview Recorder (Raspberry Pi)

This project turns a Raspberry Pi 4 into a push-button interview recorder appliance.

## What is included

- `scripts/record_interview.sh`: FFmpeg recording script that writes MP4 files to `/recordings/YYYY/MM/` using timestamp filenames
- `scripts/gpio_recorder.py`: GPIO button controller (press once start, press again stop)
- `scripts/install_testpi.sh`: one-time Pi setup helper
- `scripts/update_testpi.sh`: fast-forward update helper for an existing Pi install
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

## Update `testpi` to the latest version

If this repo was cloned with `git`, update it in place on the Pi:

```bash
cd /home/mayday/interview-recorder
git pull --ff-only
bash -n scripts/record_interview.sh
PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile scripts/gpio_recorder.py
sudo systemctl restart interview-recorder.service
```

Or use the helper script:

```bash
cd /home/mayday/interview-recorder
./scripts/update_testpi.sh
```

That helper also refreshes the installed systemd unit so changes like the LED pin make it onto the Pi.

If `git pull` complains about local changes in `scripts/install_testpi.sh`, `scripts/update_testpi.sh`, or `scripts/record_interview.sh`, reset just those managed helper files and try again:

```bash
git restore --worktree --staged -- scripts/install_testpi.sh scripts/update_testpi.sh scripts/record_interview.sh
```

For a fresh Pi, use the installer helper:

```bash
cd /home/mayday/interview-recorder
./scripts/install_testpi.sh
```

If your filesystem stripped execute bits, run them through `bash` instead:

```bash
bash scripts/update_testpi.sh
bash scripts/install_testpi.sh
```

If the repo was copied as a ZIP and does not have git history, back it up and re-clone it instead:

```bash
mv /home/mayday/interview-recorder /home/mayday/interview-recorder.backup
git clone https://github.com/HrothgarB/test.git /home/mayday/interview-recorder
```

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

The systemd service now runs with `audio`, `video`, and `gpio` access so the button, camera, and microphone can be reached without the process silently failing on permissions.

## Phase 1 reliability features now included

- Startup self-check runs before GPIO loop starts (camera path, audio capture discovery, output path, free-space threshold).
- Low-disk guard blocks recording when free space is below `MIN_FREE_MB` (default `1024`).
- Status LED behavior supported in controller: solid ON when ready, slow blinking while recording.
- systemd unit default sets `STATUS_LED_PIN=17` (use `-1` to disable LED output).

## Verify camera and mic devices

```bash
v4l2-ctl --list-devices
arecord -l
```

Based on your sample output, likely choices are:
- Video: `/dev/video0` (C270 HD WEBCAM)
- Audio: `plughw:3,0` (C270 mic) or `plughw:4,0` (USB PnP mic)


This recorder script now mirrors your previously-working ffmpeg profile:
- Uses a simplified input path (no wallclock/ts-abs/discardcorrupt flags) for cleaner stop behavior
- `-f v4l2 -input_format mjpeg -framerate 20 -video_size 1280x720`
- `-f alsa -ar 44100 -i auto-detected card (or AUDIO_DEV override)`
- Optional output trim via `OUTPUT_START_TRIM_SECONDS` (default `0`)
- `-c:v libx264 -preset ultrafast -tune zerolatency`

## Create and test recordings directory

```bash
sudo mkdir -p /recordings
sudo chown -R mayday:mayday /recordings
```

Ensure your SSD is mounted there at boot (`/etc/fstab`).


## Recording output layout

Videos are stored under the base `OUT_DIR` (default `/recordings`) using year/month folders:

```text
/recordings/YYYY/MM/YYYY-MM-DD_HH-MM-SS.mp4
```

Example:

```text
/recordings/2026/03/2026-03-17_14-32-05.mp4
```

Directories are created automatically, and timestamp collisions are avoided by waiting for the next second when needed.

## Manual test (before systemd)

```bash
cd /home/mayday/interview-recorder
chmod +x scripts/record_interview.sh scripts/gpio_recorder.py
python3 scripts/gpio_recorder.py \
  --pin 2 \
  --record-script /home/mayday/interview-recorder/scripts/record_interview.sh \
  --child-log-file /home/mayday/interview-recorder/logs/ffmpeg.log \
  --status-led-pin 17
```

Press button once to start and again to stop.
When LED is enabled, it is solid ON in ready state and blinks while recording.
Use `--status-led-pin -1` to disable LED output.

Verify recordings:

```bash
ls -lh /recordings
```

If recording fails, test ffmpeg directly with known device values:

```bash
cd /home/mayday/interview-recorder
AUDIO_RATE=44100 FPS=20 VIDEO_INPUT_FORMAT=mjpeg OUTPUT_START_TRIM_SECONDS=0 VIDEO_DEV=/dev/video0 timeout 10s ./scripts/record_interview.sh
```

If auto-detection picks the wrong mic, override explicitly with `AUDIO_DEV=plughw:3,0` or `AUDIO_DEV=plughw:4,0`.


If you see `cannot set channel count to 2`, force mono input:

```bash
AUDIO_DEV=plughw:3,0 AUDIO_CHANNELS=1 VIDEO_DEV=/dev/video0 ./scripts/record_interview.sh
```


Stable profile (recommended default):

```bash
AUDIO_RATE=44100 FPS=20 VIDEO_INPUT_FORMAT=mjpeg OUTPUT_START_TRIM_SECONDS=0 AUDIO_CHANNELS=1 START_DELAY_SECONDS=0 VIDEO_WARMUP_SECONDS=0 VIDEO_DEV=/dev/video0 ./scripts/record_interview.sh
```

## Install as systemd service

```bash
sudo cp systemd/interview-recorder.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now interview-recorder.service
sudo systemctl status interview-recorder.service
```

If you change `VIDEO_DEV`/`AUDIO_DEV` (optional)/`AUDIO_RATE`/`FPS`/`VIDEO_INPUT_FORMAT`/`AUDIO_CHANNELS`/`START_DELAY_SECONDS`/`VIDEO_WARMUP_SECONDS`/`OUTPUT_START_TRIM_SECONDS`/`MIN_FREE_MB`/`STATUS_LED_PIN` in the unit:

```bash
sudo systemctl edit --full interview-recorder.service
sudo systemctl daemon-reload
sudo systemctl restart interview-recorder.service
```



If logs show `cannot open audio device plughw:X,0 (No such file or directory)`, your configured card index is wrong for the current boot.
Use auto-detect (unset `AUDIO_DEV`) or set the current card explicitly:

```bash
arecord -l
AUDIO_DEV=plughw:<card>,0 ./scripts/record_interview.sh
```


If logs show low-space errors, check available storage and adjust threshold if needed:

```bash
df -h /recordings
# temporary manual test with lower guard
MIN_FREE_MB=256 ./scripts/record_interview.sh --self-check
```

If logs show `Permission denied` for `/recordings/...`, fix storage permissions:

```bash
sudo mkdir -p /recordings
sudo chown -R mayday:mayday /recordings
ls -ld /recordings
```

If `/recordings` is a mounted SSD, set ownership/mount options so it stays writable after reboot (for example `uid=1000,gid=1000` on vfat/exfat mounts).


If you get `GPIO busy` when starting manually, another process already owns the pin (often the systemd service):

```bash
sudo systemctl stop interview-recorder.service
# optional: identify process using GPIO chip
sudo lsof /dev/gpiochip0
sudo lsof /dev/gpiochip4
```

Then run the script manually again. Restart the service when done:

```bash
sudo systemctl start interview-recorder.service
```


If you hit a `NameError` when launching `gpio_recorder.py`, make sure you are on the latest code:

```bash
cd /home/mayday/interview-recorder
git pull
python3 -m py_compile scripts/gpio_recorder.py
```

## Useful troubleshooting commands

```bash
journalctl -u interview-recorder.service -f
ls -lh /recordings
tail -F /home/mayday/interview-recorder/logs/ffmpeg.log
```

## Notes


- The controller now creates `logs/ffmpeg.log` at startup, so `tail -F` works even before the first recording.
- `gpio_recorder.py` sends SIGINT to FFmpeg so MP4 files finalize cleanly.
- Button presses toggle an internal start/stop mode, so the second press is treated as stop even if ffmpeg exited unexpectedly.
- If graceful stop hangs, the controller escalates to terminate/kill.
- Removed `-use_wallclock_as_timestamps`, `-ts abs`, and `-fflags ... nobuffer/discardcorrupt` from recording defaults because they can make V4L2/ALSA capture less predictable during stop on flaky MJPEG streams.
- Run compile check without creating cache files:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile scripts/gpio_recorder.py
```
