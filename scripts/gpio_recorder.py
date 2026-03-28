#!/usr/bin/env python3
"""GPIO-driven interview recorder controller.

What this program does:
- Watches a physical push button on a Raspberry Pi GPIO pin.
- First press starts the recording shell script (which runs ffmpeg).
- Second press sends SIGINT to stop/finalize the recording cleanly.
- Repeats forever until the process is stopped (Ctrl+C/systemd stop).
"""

from __future__ import annotations

import argparse
import logging
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Optional, TextIO

from gpiozero import Button, LED, RGBLED


class RecorderController:
    """Manage recorder process lifecycle and GPIO button wiring."""

    def __init__(
        self,
        button_pin: int,
        record_script: Path,
        bounce_time: float,
        child_log_file: Optional[Path] = None,
        status_led_pin: Optional[int] = None,
        status_led_red_pin: Optional[int] = None,
        status_led_green_pin: Optional[int] = None,
        status_led_blue_pin: Optional[int] = None,
    ) -> None:
        self.button_pin = button_pin
        self.record_script = record_script
        self.child_log_file = child_log_file
        self.status_led_pin = status_led_pin
        self.status_led_red_pin = status_led_red_pin
        self.status_led_green_pin = status_led_green_pin
        self.status_led_blue_pin = status_led_blue_pin
        if self.child_log_file is not None:
            # Ensure the log path exists even before first recording starts,
            # so tools like `tail -f` do not fail with "No such file".
            self.child_log_file.parent.mkdir(parents=True, exist_ok=True)
            self.child_log_file.touch(exist_ok=True)
        try:
            self.button = Button(button_pin, pull_up=True, bounce_time=bounce_time)
        except Exception as exc:
            raise RuntimeError(
                f"Failed to initialize GPIO pin {button_pin}. "
                "It may already be in use by another process/service."
            ) from exc
        self.status_led: Optional[LED] = None
        self.status_rgb_led: Optional[RGBLED] = None
        if (
            status_led_red_pin is not None
            or status_led_green_pin is not None
            or status_led_blue_pin is not None
        ):
            if not all(
                pin is not None
                for pin in (status_led_red_pin, status_led_green_pin, status_led_blue_pin)
            ):
                raise RuntimeError(
                    "All RGB LED pins must be provided together: red, green, and blue."
                )
            self.status_rgb_led = RGBLED(
                red=status_led_red_pin,
                green=status_led_green_pin,
                blue=status_led_blue_pin,
            )
        elif status_led_pin is not None:
            self.status_led = LED(status_led_pin)
        self._proc: Optional[subprocess.Popen[str]] = None
        self._child_log_handle: Optional[TextIO] = None
        self._recording_requested = False
        self._lock = threading.Lock()
        self._status_state: Optional[str] = None
        self._set_led_ready()

    @property
    def is_recording(self) -> bool:
        return self._proc is not None and self._proc.poll() is None

    def _open_child_log(self) -> tuple[object, object]:
        """Return stdout/stderr targets for recorder subprocess."""
        if self.child_log_file is None:
            return (subprocess.DEVNULL, subprocess.STDOUT)

        self.child_log_file.parent.mkdir(parents=True, exist_ok=True)
        # Line-buffered text file for easier live debugging via tail/journal.
        self._child_log_handle = self.child_log_file.open("a", buffering=1, encoding="utf-8")
        return (self._child_log_handle, subprocess.STDOUT)

    def _close_child_log(self) -> None:
        if self._child_log_handle is not None:
            self._child_log_handle.close()
            self._child_log_handle = None

    def _set_led_ready(self) -> None:
        """Set LED to the 'ready' state: solid green."""
        self._set_led_state("ready")

    def _set_led_recording(self) -> None:
        """Set LED to the 'recording' state: solid red."""
        self._set_led_state("recording")

    def _set_led_not_ready(self) -> None:
        """Set LED to the 'not ready' state: solid blue."""
        self._set_led_state("not_ready")

    def _set_led_state(self, state: str) -> None:
        if self._status_state == state:
            return

        self._status_state = state

        if self.status_rgb_led is not None:
            if state == "ready":
                self.status_rgb_led.color = (0, 1, 0)
            elif state == "recording":
                self.status_rgb_led.color = (1, 0, 0)
            elif state == "not_ready":
                self.status_rgb_led.color = (0, 0, 1)
            else:
                raise ValueError(f"Unknown LED state: {state}")
        elif self.status_led is not None:
            if state == "ready":
                self.status_led.on()
            elif state == "recording":
                self.status_led.blink(on_time=1.0, off_time=1.0, background=True)
            elif state == "not_ready":
                self.status_led.off()
            else:
                raise ValueError(f"Unknown LED state: {state}")

        logging.info("Status indicator set to %s", state)

    def start(self) -> bool:
        with self._lock:
            if self._recording_requested:
                logging.info("Record request ignored: recorder is already in START mode")
                return True

            self._recording_requested = True
            logging.info("Starting recording using %s", self.record_script)
            stdout_target, stderr_target = self._open_child_log()
            try:
                self._proc = subprocess.Popen(
                    [str(self.record_script)],
                    stdout=stdout_target,
                    stderr=stderr_target,
                    text=True,
                )
            except Exception:
                self._recording_requested = False
                self._close_child_log()
                self._set_led_not_ready()
                logging.exception("Failed to start recording using %s", self.record_script)
                return False
            logging.info("Recording process started (pid=%s)", self._proc.pid)
            self._set_led_recording()
            return True

    def stop(self, timeout: float = 20.0) -> None:
        with self._lock:
            self._recording_requested = False

            if not self.is_recording:
                if self._proc is not None:
                    logging.warning(
                        "Stop requested but recorder already exited (returncode=%s)",
                        self._proc.returncode,
                    )
                else:
                    logging.info("Stop request ignored: no active recording")
                self._proc = None
                self._close_child_log()
                self._set_led_ready()
                return

            assert self._proc is not None
            logging.info("Stopping recording (pid=%s)", self._proc.pid)
            self._proc.send_signal(signal.SIGINT)
            try:
                self._proc.wait(timeout=timeout)
                logging.info("Recording stopped cleanly")
            except subprocess.TimeoutExpired:
                logging.warning("Recorder did not stop in %.1fs, terminating", timeout)
                self._proc.terminate()
                try:
                    self._proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    logging.error("Recorder still running, killing process")
                    self._proc.kill()
                    self._proc.wait(timeout=5)
            finally:
                self._proc = None
                self._close_child_log()
                self._set_led_ready()

    def refresh_status(self) -> None:
        with self._lock:
            if self._proc is None:
                return

            returncode = self._proc.poll()
            if returncode is None:
                return

            logging.warning(
                "Recording process exited unexpectedly (returncode=%s)",
                returncode,
            )
            self._proc = None
            self._close_child_log()
            self._recording_requested = False
            self._set_led_not_ready()

    def toggle(self) -> None:
        # Toggle by requested mode, not by child-process liveness.
        # This keeps button semantics predictable: 1st press=start mode,
        # 2nd press=stop mode, even if ffmpeg exited unexpectedly in between.
        if self._recording_requested:
            self.stop()
        else:
            self.start()

    def shutdown(self) -> None:
        logging.info("Shutting down controller")
        self.stop()
        self.button.close()
        if self.status_rgb_led is not None:
            self.status_rgb_led.off()
            self.status_rgb_led.close()
        if self.status_led is not None:
            self.status_led.off()
            self.status_led.close()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="GPIO push-button recorder controller")
    parser.add_argument("--pin", type=int, default=2, help="BCM GPIO pin for the button (default: 2)")
    parser.add_argument(
        "--record-script",
        default="/home/mayday/interview-recorder/scripts/record_interview.sh",
        help="Path to the recording shell script",
    )
    parser.add_argument(
        "--bounce-time",
        type=float,
        default=0.05,
        help="Debounce time in seconds (default: 0.05)",
    )
    parser.add_argument(
        "--poll-interval",
        type=float,
        default=0.5,
        help="Main loop sleep interval in seconds (default: 0.5)",
    )
    parser.add_argument(
        "--log-level",
        default="INFO",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
        help="Logging level (default: INFO)",
    )
    parser.add_argument(
        "--child-log-file",
        default="",
        help="Optional file path to capture recorder (ffmpeg) output",
    )
    parser.add_argument(
        "--status-led-pin",
        type=int,
        default=-1,
        help="Optional BCM GPIO pin for a status LED (-1 disables)",
    )
    parser.add_argument(
        "--status-led-red-pin",
        type=int,
        default=-1,
        help="Optional BCM GPIO pin for the red channel of an RGB status LED (-1 disables)",
    )
    parser.add_argument(
        "--status-led-green-pin",
        type=int,
        default=-1,
        help="Optional BCM GPIO pin for the green channel of an RGB status LED (-1 disables)",
    )
    parser.add_argument(
        "--status-led-blue-pin",
        type=int,
        default=-1,
        help="Optional BCM GPIO pin for the blue channel of an RGB status LED (-1 disables)",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s %(levelname)s %(message)s",
    )

    record_script = Path(args.record_script)
    if not record_script.exists():
        logging.error("Record script does not exist: %s", record_script)
        return 1
    if not record_script.is_file():
        logging.error("Record script is not a file: %s", record_script)
        return 1

    child_log_file = Path(args.child_log_file) if args.child_log_file else None
    status_led_pin = args.status_led_pin if args.status_led_pin >= 0 else None
    rgb_led_pins = None
    rgb_pin_values = (
        args.status_led_red_pin,
        args.status_led_green_pin,
        args.status_led_blue_pin,
    )
    if any(pin >= 0 for pin in rgb_pin_values):
        if not all(pin >= 0 for pin in rgb_pin_values):
            logging.error("Provide all three RGB LED pins together or leave them all disabled.")
            return 1
        rgb_led_pins = rgb_pin_values

    if status_led_pin is not None and rgb_led_pins is not None:
        logging.error("Use either the single status LED pin or the RGB LED pins, not both.")
        return 1

    logging.info("Running recorder self-check")
    preflight = subprocess.run([str(record_script), "--self-check"], capture_output=True, text=True)
    if preflight.returncode != 0:
        logging.error("Recorder self-check failed")
        if preflight.stdout.strip():
            logging.error(preflight.stdout.strip())
        if preflight.stderr.strip():
            logging.error(preflight.stderr.strip())
        return 1
    if preflight.stdout.strip():
        logging.info("Recorder self-check summary:\n%s", preflight.stdout.strip())

    controller: Optional[RecorderController] = None
    try:
        controller = RecorderController(
            button_pin=args.pin,
            record_script=record_script,
            bounce_time=args.bounce_time,
            child_log_file=child_log_file,
            status_led_pin=status_led_pin,
            status_led_red_pin=rgb_led_pins[0] if rgb_led_pins is not None else None,
            status_led_green_pin=rgb_led_pins[1] if rgb_led_pins is not None else None,
            status_led_blue_pin=rgb_led_pins[2] if rgb_led_pins is not None else None,
        )
    except RuntimeError as exc:
        logging.error(str(exc))
        logging.error(
            "If running manually, stop the service first: "
            "sudo systemctl stop interview-recorder.service"
        )
        logging.error(
            "To check current owner: sudo lsof /dev/gpiochip0 (or /dev/gpiochip4 on newer Pi OS)."
        )
        return 1

    if controller is None:
        logging.error("Recorder controller failed to initialize")
        return 1

    stop_event = threading.Event()

    def handle_exit(signum: int, _frame: object) -> None:
        logging.info("Received signal %s", signum)
        stop_event.set()

    signal.signal(signal.SIGINT, handle_exit)
    signal.signal(signal.SIGTERM, handle_exit)

    controller.button.when_pressed = controller.toggle
    logging.info("Recorder ready on GPIO pin %s. Press button to start/stop.", args.pin)

    try:
        while not stop_event.is_set():
            controller.refresh_status()
            time.sleep(args.poll_interval)
    finally:
        controller.shutdown()

    return 0


if __name__ == "__main__":
    sys.exit(main())
