#!/usr/bin/env python3
"""Serve a live MPEG-TS preview stream over HTTP.

This process reads a byte stream from stdin and serves it to HTTP clients
as a live video/mp2t response.
"""

from __future__ import annotations

import argparse
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse


class StreamStore:
    def __init__(self) -> None:
        self._condition = threading.Condition()
        self._latest_chunk: bytes | None = None
        self._version = 0
        self._closed = False
        self._error: str | None = None

    def publish(self, chunk: bytes) -> None:
        with self._condition:
            self._latest_chunk = chunk
            self._version += 1
            self._condition.notify_all()

    def close(self, error: str | None = None) -> None:
        with self._condition:
            self._closed = True
            self._error = error
            self._condition.notify_all()

    def snapshot(self) -> tuple[int, bytes | None, bool, str | None]:
        with self._condition:
            return self._version, self._latest_chunk, self._closed, self._error

    def wait_for_update(self, last_version: int) -> tuple[int, bytes | None, bool, str | None]:
        with self._condition:
            self._condition.wait_for(lambda: self._closed or self._version != last_version)
            return self._version, self._latest_chunk, self._closed, self._error


def _read_stream_chunks(store: StreamStore, server: ThreadingHTTPServer) -> None:
    try:
        while True:
            chunk = sys.stdin.buffer.read(4096)
            if not chunk:
                break
            store.publish(chunk)
    except Exception as exc:  # pragma: no cover - defensive logging path
        store.close(f"{exc.__class__.__name__}: {exc}")
    else:
        store.close(None)
    finally:
        server.shutdown()


def _build_handler(store: StreamStore, stream_path: str):
    class StreamHandler(BaseHTTPRequestHandler):
        server_version = "InterviewRecorderHTTPStream/1.0"
        protocol_version = "HTTP/1.1"

        def log_message(self, format: str, *args: object) -> None:  # noqa: A003
            sys.stderr.write("%s - - [%s] %s\n" % (self.client_address[0], self.log_date_time_string(), format % args))

        def do_GET(self) -> None:
            if self.path not in (stream_path, "/"):
                self.send_error(404, "Not Found")
                return

            version, chunk, closed, error = store.snapshot()
            while chunk is None and not closed:
                version, chunk, closed, error = store.wait_for_update(version)

            if chunk is None and closed:
                self.send_error(503, error or "Preview stream ended before the first chunk")
                return

            self.send_response(200)
            self.send_header("Content-Type", "video/mp2t")
            self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
            self.send_header("Pragma", "no-cache")
            self.send_header("Expires", "0")
            self.send_header("Connection", "close")
            self.end_headers()

            while True:
                try:
                    self.wfile.write(chunk)
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError, OSError):
                    return

                if closed:
                    return

                version, chunk, closed, error = store.wait_for_update(version)
                while chunk is None and not closed:
                    version, chunk, closed, error = store.wait_for_update(version)
                if chunk is None and closed:
                    return

    return StreamHandler


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Serve an MPEG-TS preview stream over HTTP.")
    parser.add_argument(
        "--url",
        required=True,
        help="Viewer URL, for example http://testpi:8080/stream.ts",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    parsed = urlparse(args.url)
    if parsed.scheme != "http":
        print(f"[http_stream_preview] Unsupported stream URL scheme: {parsed.scheme}", file=sys.stderr)
        return 1

    port = parsed.port or 8080
    stream_path = parsed.path or "/stream.ts"
    if not stream_path.startswith("/"):
        stream_path = f"/{stream_path}"

    store = StreamStore()
    handler = _build_handler(store, stream_path)
    server = ThreadingHTTPServer(("0.0.0.0", port), handler)
    server.daemon_threads = True
    reader = threading.Thread(target=_read_stream_chunks, args=(store, server), daemon=True)
    reader.start()

    print(
        f"[http_stream_preview] Serving MPEG-TS preview on 0.0.0.0:{port}{stream_path} "
        f"(viewer URL: {args.url})",
        file=sys.stderr,
    )

    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()
        server.server_close()
        store.close("server stopped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
