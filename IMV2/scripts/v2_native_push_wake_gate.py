"""Owned simulator OS Push proof; no direct App delegate invocation."""
import json
from pathlib import Path
import re
import subprocess
import threading
import time
import uuid


class NativePushWakeGate:
    def __init__(self, simulator, root, send_message, read_room):
        self.simulator = simulator
        self.root = root
        self.send_message = send_message
        self.read_room = read_room
        self.lock = threading.Lock()
        self.cancelled = threading.Event()
        self.worker = None
        self.state = {"stage": "idle", "delivered": False, "projected": False}

    def snapshot(self):
        with self.lock:
            return dict(self.state)

    def update(self, **values):
        with self.lock:
            self.state.update(values)

    def start(self, request):
        if not isinstance(request, dict) or set(request) != {"accountHandle", "scope", "title"} or not all(isinstance(value, str) for value in request.values()):
            raise ValueError("invalid owned Push scope")
        uuid.UUID(request["scope"])
        if not re.fullmatch(r"twor_[0-9a-f]{20}", request["accountHandle"]):
            raise ValueError("invalid owned account")
        if not re.fullmatch(r"自测群[0-9a-f]{6}", request["title"]):
            raise ValueError("invalid owned room")
        with self.lock:
            if self.worker is not None:
                raise ValueError("Push proof already started")
            self.state["stage"] = "sending"
            self.worker = threading.Thread(target=self.perform, args=(dict(request),), name="OwnedSimulatorPush")
            self.worker.start()

    def perform(self, request):
        try:
            container = subprocess.run(["xcrun", "simctl", "get_app_container", self.simulator,
                                        "com.stskcxfz.imapp", "data"], check=True, capture_output=True,
                                       timeout=10).stdout.decode().strip()
            before = self.read_room(Path(container), request["scope"], request["title"])
            (self.root / "push-before-send.json").write_text(json.dumps(before, indent=2) + "\n")
            message = self.send_message(request["accountHandle"], request["title"])
            original = message["messageID"].lower()
            before_push = self.read_room(Path(container), request["scope"], request["title"])
            if any(row["message_id"].lower() == original for row in before_push["messages"]):
                raise RuntimeError("message arrived before system Push")
            if before_push["roomID"].lower() != message["roomID"].lower():
                raise RuntimeError("room identity mismatch")
            (self.root / "push-before-notification.json").write_text(json.dumps(before_push, indent=2) + "\n")
            self.update(stage="delivering", messageID=message["messageID"], roomSequence=message["roomSequence"])
            if self.cancelled.is_set():
                return
            delivery = subprocess.run(["xcrun", "simctl", "push", self.simulator, "com.stskcxfz.imapp", "-"],
                                      input=b'{"aps":{"content-available":1}}',
                                      capture_output=True, timeout=10)
            visible_rejection = (delivery.returncode != 0 and b"UNErrorDomain" in delivery.stderr
                                 and b"code=1401" in delivery.stderr
                                 and b"Notification has no user visible content" in delivery.stderr)
            self.update(deliveryToolExitCode=delivery.returncode, visibleContentRejected=visible_rejection)
            if delivery.returncode != 0 and not visible_rejection:
                delivery.check_returncode()
            # 1401 describes the visible-notification branch. Do not infer a
            # background fetch succeeded OR failed from it; prove the actual
            # original SQLite commit while the UI remains backgrounded.
            self.update(stage="synchronizing", delivered=delivery.returncode == 0)
            deadline = time.monotonic() + 45
            while not self.cancelled.is_set() and time.monotonic() < deadline:
                after = self.read_room(Path(container), request["scope"], request["title"])
                matches = [row for row in after["messages"] if row["message_id"].lower() == original]
                if len(matches) == 1 and any(row["applied_room_sequence"] >= message["roomSequence"]
                                             for row in after["cursor"]):
                    (self.root / "push-after-notification.json").write_text(json.dumps(after, indent=2) + "\n")
                    self.update(stage="passed", delivered=True, projected=True, originalMessageCount=1)
                    return
                self.cancelled.wait(.2)
            if not self.cancelled.is_set():
                raise TimeoutError("system Push did not commit original room message")
        except Exception as error:
            # Error types only: credentials and signed targets stay process-private.
            reason = None
            if isinstance(error, subprocess.CalledProcessError):
                # Only a bounded server error code; never export raw stderr.
                match = re.search(rb'ProbeError\.serverRejected\("([A-Z0-9_]{1,64})"\)', error.stderr or b'')
                if match:
                    reason = match.group(1).decode()
                else:
                    known = [b"sendResponseCorrelation", b"sendResponseType", b"sendResultPending",
                             b"sendReceiptMismatch", b"invalidConfiguration", b"unexpectedResponse",
                             b"fingerprintMismatch", b"connectionClosed"]
                    reason = next((code.decode() for code in known if code in (error.stderr or b"")), None)
            self.update(stage="failed", failedAt=self.snapshot()["stage"], error=type(error).__name__, code=reason)

    def close(self):
        self.cancelled.set()
        if self.worker is not None:
            self.worker.join(timeout=45)
            if self.worker.is_alive():
                raise RuntimeError("owned Push worker did not drain")
