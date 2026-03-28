# Portable Interview Recorder (Raspberry Pi)

This project turns a Raspberry Pi 4 into a push-button interview recorder appliance.

## What is included

- `scripts/record_interview.sh`: FFmpeg recording script that writes MP4 files to `/recordings/YYYY/MM/` and can optionally stream live to a LAN viewer for VLC/OBS
- `scripts/gpio_recorder.py`: GPIO button controller (green ready, red recording, blue not-ready, built-in diagnostics)
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
PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile scripts/http_mjpeg_preview.py scripts/gpio_recorder.py
sudo systemctl restart interview-recorder.service
```

Or use the helper script:

```bash
cd /home/mayday/interview-recorder
./scripts/update_testpi.sh
```

That helper also refreshes the installed systemd unit so changes like the LED pin make it onto the Pi.
Your Pi-local `/etc/interview-recorder.env` settings are preserved, including any custom `STREAM_URL`.

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

## Logs and diagnostics

- `logs/controller.log`: controller events, RGB state changes, and periodic system diagnostics
- `logs/ffmpeg.log`: recorder subprocess output, including LAN livestream startup/errors
- `journalctl -u interview-recorder.service -f`: live systemd view
- `tail -F logs/controller.log`: controller and diagnostics log
- `tail -F logs/ffmpeg.log`: ffmpeg capture log

Diagnostics currently include CPU temperature, load average, memory availability, recordings disk usage, uptime, and throttling status when `vcgencmd` is available.

## Phase 1 reliability features now included

- Startup self-check runs before GPIO loop starts (camera path, audio capture discovery, output path, free-space threshold).
- Low-disk guard blocks recording when free space is below `MIN_FREE_MB` (default `1024`).
- Status LED behavior supported in controller: green when ready, red while recording, blue when not ready.
- systemd unit default sets RGB LED pins to `17`/`27`/`22`, controller logging to `logs/controller.log`, and periodic diagnostics every 30 seconds.
- Fresh installs now create `/etc/interview-recorder.env` with a default HTTP MPEG-TS `STREAM_URL` while keeping the local MP4 recording.

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

## Optional LAN livestream for VLC or OBS

This recorder can also publish a live HTTP MPEG-TS preview while still saving the normal MP4 locally.
The preview is designed for app-based viewers such as VLC or OBS on the same LAN and now includes audio.

The systemd service reads Pi-local overrides from `/etc/interview-recorder.env`.
Fresh installs create that file with this default preview target:

```bash
STREAM_URL=http://testpi:8080/stream.ts
```

The live preview uses a lightweight profile rather than the full recording quality:
`426x240`, `5 fps`, and lower video/audio bitrates so it stays responsive on the LAN.

To change it later:

```bash
sudoedit /etc/interview-recorder.env
sudo systemctl restart interview-recorder.service
```

Viewer apps on the same LAN can open:

```text
http://testpi:8080/stream.ts
```

If your LAN does not resolve `testpi`, replace it with the Pi's IP address.

Notes:

- Local recording remains the source of truth. If the preview fails, the MP4 recording keeps running.
- The live preview is intentionally lightweight, not a full-quality copy of the local MP4.
- `STREAM_URL` can be left unset or empty to disable livestreaming completely.

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
python3 scripts/gpio_recorder.py \
  --pin 2 \
  --record-script /home/mayday/interview-recorder/scripts/record_interview.sh \
  --child-log-file logs/ffmpeg.log \
  --controller-log-file logs/controller.log \
  --recordings-dir /recordings \
  --diagnostics-interval 30 \
  --status-led-red-pin 17 \
  --status-led-green-pin 27 \
  --status-led-blue-pin 22
```

Press button once to start and again to stop.
When LED is enabled, it is green when ready, red while recording, and blue when not ready.
The controller log captures the temperature and other diagnostics while the service is running.

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

If you change `VIDEO_DEV`/`AUDIO_DEV` (optional)/`AUDIO_RATE`/`FPS`/`VIDEO_INPUT_FORMAT`/`AUDIO_CHANNELS`/`START_DELAY_SECONDS`/`VIDEO_WARMUP_SECONDS`/`OUTPUT_START_TRIM_SECONDS`/`MIN_FREE_MB`/`RECORDINGS_DIR`/`CONTROLLER_LOG_FILE`/`DIAGNOSTICS_INTERVAL_SECONDS`/`STATUS_LED_RED_PIN`/`STATUS_LED_GREEN_PIN`/`STATUS_LED_BLUE_PIN` in the unit:

```bash
sudo systemctl edit --full interview-recorder.service
sudo systemctl daemon-reload
sudo systemctl restart interview-recorder.service
```

If you prefer to keep local overrides out of the unit, place them in `/etc/interview-recorder.env` instead.
That file is loaded automatically by the service and is the recommended place for `STREAM_URL`.
If you edit only that env file, just restart the service; `daemon-reload` is only needed when the unit file itself changes.



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
- Removed `-use_wallclock_as_timestamps`, `-ts abs`, and `-fflags ... nobuffer/discardcorrupt` from recording defaults because they can make V4L2/ALSA capture less predictable during stop on flaky camera streams.
- Run compile check without creating cache files:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile scripts/gpio_recorder.py
```
