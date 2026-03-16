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

from gpiozero import Button


class RecorderController:
    """Manage recorder process lifecycle and GPIO button wiring."""

    def __init__(
        self,
        button_pin: int,
        record_script: Path,
        bounce_time: float,
        child_log_file: Optional[Path] = None,
    ) -> None:
        self.button_pin = button_pin
        self.record_script = record_script
        self.child_log_file = child_log_file
        self.button = Button(button_pin, pull_up=True, bounce_time=bounce_time)
        self._proc: Optional[subprocess.Popen[str]] = None
        self._child_log_handle: Optional[TextIO] = None
        self._lock = threading.Lock()

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

    def start(self) -> None:
        with self._lock:
            if self.is_recording:
                logging.info("Record request ignored: already recording")
                return

            logging.info("Starting recording using %s", self.record_script)
            stdout_target, stderr_target = self._open_child_log()
            self._proc = subprocess.Popen(
                [str(self.record_script)],
                stdout=stdout_target,
                stderr=stderr_target,
                text=True,
            )
            logging.info("Recording process started (pid=%s)", self._proc.pid)

    def stop(self, timeout: float = 20.0) -> None:
        with self._lock:
            if not self.is_recording:
                logging.info("Stop request ignored: no active recording")
                self._proc = None
                self._close_child_log()
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

    def toggle(self) -> None:
        if self.is_recording:
            self.stop()
        else:
            self.start()

    def shutdown(self) -> None:
        logging.info("Shutting down controller")
        self.stop()
        self.button.close()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="GPIO push-button recorder controller")
    parser.add_argument("--pin", type=int, default=2, help="BCM GPIO pin for the button (default: 2)")
    parser.add_argument(
        "--record-script",
        default="/home/pi/interview-recorder/scripts/record_interview.sh",
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

    controller = RecorderController(
        button_pin=args.pin,
        record_script=record_script,
        bounce_time=args.bounce_time,
        child_log_file=child_log_file,
    )

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
            time.sleep(args.poll_interval)
    finally:
        controller.shutdown()

    return 0


if __name__ == "__main__":
    sys.exit(main())
