#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import parse_qs, urlparse


class CodeStore:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._codes: dict[tuple[str, str], dict[str, Any]] = {}

    def put(self, payload: dict[str, Any]) -> None:
        code_type = str(payload.get("type") or "")
        email = str(payload.get("email") or "").lower()
        code = str(payload.get("code") or "")
        if not code_type or not email or not code:
            raise ValueError("payload requires type, email, and code")
        with self._lock:
            self._codes[(code_type, email)] = {
                "type": code_type,
                "email": email,
                "code": code,
                "expiresIn": payload.get("expiresIn"),
                "receivedAt": time.time(),
            }

    def get(self, code_type: str, email: str) -> dict[str, Any] | None:
        with self._lock:
            value = self._codes.get((code_type, email.lower()))
            return dict(value) if value else None


def make_handler(store: CodeStore, secret: str | None) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        server_version = "IMAuthEmailWebhookSink/1.0"

        def do_GET(self) -> None:
            parsed = urlparse(self.path)
            if parsed.path == "/health":
                self.write_json(200, {"status": "ok"})
                return
            if parsed.path != "/codes":
                self.write_json(404, {"error": "not_found"})
                return

            query = parse_qs(parsed.query)
            code_type = (query.get("type") or [""])[0]
            email = (query.get("email") or [""])[0]
            if not code_type or not email:
                self.write_json(400, {"error": "type and email are required"})
                return

            record = store.get(code_type, email)
            if not record:
                self.write_json(404, {"error": "code_not_found"})
                return
            self.write_json(200, record)

        def do_POST(self) -> None:
            if self.path != "/auth-email":
                self.write_json(404, {"error": "not_found"})
                return
            if secret and self.headers.get("X-IMApp-Auth-Email-Secret") != secret:
                self.write_json(401, {"error": "unauthorized"})
                return

            length = int(self.headers.get("Content-Length") or "0")
            raw = self.rfile.read(length)
            try:
                payload = json.loads(raw.decode("utf-8"))
                store.put(payload)
            except Exception as error:
                self.write_json(400, {"error": str(error)})
                return
            self.write_json(200, {"status": "stored"})

        def log_message(self, format: str, *args: Any) -> None:
            print(f"{self.address_string()} - {format % args}")

        def write_json(self, status: int, payload: dict[str, Any]) -> None:
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    return Handler


def main() -> int:
    parser = argparse.ArgumentParser(description="Capture IM auth email webhook codes for k6 account lifecycle confirm tests.")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=18080)
    parser.add_argument("--secret", default="")
    args = parser.parse_args()

    store = CodeStore()
    server = ThreadingHTTPServer((args.host, args.port), make_handler(store, args.secret or None))
    print(f"auth email webhook sink listening on http://{args.host}:{args.port}/auth-email")
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
