"""Finite cold-room and isolated owner-failure observations for capacity runs.

Only the explicit disposable Compose project supplied by the runner is touched.
The native client owns protocol validation; these counters prove progress while
one of exactly two physical owner databases is unavailable.
"""

from __future__ import annotations

import json
import re
import time
from typing import Any

from virtual_actor_capacity_measurement import MeasurementFailure


LEASE_COUNTS_SQL = """
SELECT json_build_object(
 'rows', count(*),
 'live', count(*) FILTER (WHERE expires_at > clock_timestamp()),
 'released', count(*) FILTER (WHERE expires_at IS NULL),
 'reacquired', count(*) FILTER (WHERE activation_epoch > 1),
 'maximumEpoch', coalesce(max(activation_epoch), 0))
FROM im_v2.room_activation_leases;
"""


def validate_cold_retirement(before: dict[str, dict], after: dict[str, dict]) -> dict:
    """Require actual release facts, not merely a 480-second elapsed interval."""
    if before.keys() != after.keys() or not before:
        raise MeasurementFailure("cold owner observations changed")
    for key in before:
        if before[key]["rows"] != 0:
            raise MeasurementFailure("cold fixture already had activation history")
        if after[key]["rows"] < before[key]["rows"]:
            raise MeasurementFailure("cold activation history disappeared")
    released = sum(row["released"] for row in after.values())
    activated = sum(row["rows"] for row in after.values())
    if activated <= 0 or released <= 0:
        raise MeasurementFailure("cold workload did not observe actual idle lease release")
    return {"activatedRooms": activated, "releasedRoomsAtEnd": released,
            "reacquiredRooms": sum(row["reacquired"] for row in after.values()),
            "defaultIdleTimeoutSeconds": 300,
            "before": before, "after": after}


class OwnerFailureWindow:
    """Stop one owner at steady +60s, restart at +80s, and require recovery.

    No SQL inspection targets the stopped owner during this window. Each
    progress row is emitted by the validating native protocol client. With a
    fresh two-owner fixture, query-only traffic and exactly owner00 stopped,
    successful room results during the outage must come from owner01.
    """

    START_SECONDS = 60
    DOWN_SECONDS = 20

    def __init__(self, compose: list[str], execute: Any, *, now: Any = time.monotonic):
        self.compose = compose
        self.execute = execute
        self.now = now
        self.started: float | None = None
        self.stopped_at: float | None = None
        self.restarted_at: float | None = None
        self.stopped = False
        self.stop_issued = False
        self.events: list[dict] = []
        self.progress: list[dict] = []

    def begin_steady(self, *, at: float | None = None) -> None:
        if self.started is not None:
            raise MeasurementFailure("owner failure window started twice")
        self.started = self.now() if at is None else at

    def tick(self) -> None:
        if self.started is None:
            return
        if self.stopped_at is None and self.now() - self.started >= self.START_SECONDS:
            self.stop_issued = True
            self.execute(self.compose + ["stop", "--timeout", "10", "owner00"],
                         "owner-fault.log", 30)
            self.stopped = True
            self.stopped_at = self.now()
            container = self.execute(self.compose + ["ps", "--all", "--quiet", "owner00"],
                                     "owner-fault.log", 10).strip()
            if not re.fullmatch(r"[a-f0-9]{64}", container):
                raise MeasurementFailure("stopped owner identity missing")
            docker = self.compose[:self.compose.index("compose")]
            state = json.loads(self.execute(docker + ["inspect", "--format", "{{json .State}}", container],
                                            "owner-fault.log", 10))
            if state.get("Running") is not False or state.get("OOMKilled") is not False or state.get("ExitCode") != 0:
                raise MeasurementFailure("owner did not exit cleanly; SQL counter continuity is unproven")
            self.events.append({"event": "owner00-stopped", "monotonic": self.stopped_at,
                                "containerID": container, "exitCode": state["ExitCode"]})
        elif self.stopped and self.now() - self.stopped_at >= self.DOWN_SECONDS:
            self.execute(self.compose + ["start", "owner00"], "owner-fault.log", 30)
            self.stopped = False
            self.stop_issued = False
            self.restarted_at = self.now()
            self.events.append({"event": "owner00-start-issued", "monotonic": self.restarted_at})

    def observe(self, line: str, *, at: float | None = None) -> None:
        if not re.match(r"^scenario phase=steady second=\d+ ", line):
            return
        values = dict(re.findall(r"([a-z_]+)=(\d+)(?: |$)", line.strip()))
        # These names are a versioned interface of the common native loader.
        names = ("room_sync_state_success_rooms", "room_sync_state_retry_rooms",
                 "room_latest_visible_success_rooms", "room_latest_visible_retry_rooms")
        if "second" not in values or any(name not in values for name in names):
            raise MeasurementFailure("native recovery progress fields are missing")
        self.progress.append({"monotonic": self.now() if at is None else at,
                              "second": int(values["second"]),
                              **{name: int(values[name]) for name in names}})

    def finish(self) -> dict:
        if self.stopped_at is None or self.restarted_at is None or self.stopped:
            raise MeasurementFailure("owner fault injection did not finish")
        outage = [row for row in self.progress
                  if self.stopped_at + 2 <= row["monotonic"] < self.restarted_at]
        if len(outage) < 3:
            raise MeasurementFailure("owner outage lacks native progress observations")
        names = ("room_sync_state", "room_latest_visible")
        deltas = {name: {kind: outage[-1][name + "_" + kind + "_rooms"] -
                         outage[0][name + "_" + kind + "_rooms"]
                         for kind in ("success", "retry")} for name in names}
        if any(item["success"] <= 0 or item["retry"] <= 0 for item in deltas.values()):
            raise MeasurementFailure("outage did not preserve healthy owner results with failed-owner retries")
        recovered: float | None = None
        candidates = [row for row in self.progress if row["monotonic"] >= self.restarted_at]
        for index in range(3, len(candidates)):
            points = candidates[index - 3:index + 1]
            if all(right["second"] == left["second"] + 1 and
                   all(right[name + "_success_rooms"] > left[name + "_success_rooms"] and
                       right[name + "_retry_rooms"] == left[name + "_retry_rooms"]
                       for name in names)
                   for left, right in zip(points, points[1:])):
                recovered = points[-1]["monotonic"]
                break
        if recovered is None:
            raise MeasurementFailure("room batches did not resume successful service after owner restart")
        return {"injection": "graceful-stop-owner00-timeout10-start-after-20s", "events": self.events,
                "outageRoomResultDeltas": deltas,
                "recoveryMilliseconds": (recovered - self.restarted_at) * 1000,
                "recoveryDefinition": "three consecutive one-second intervals with both families succeeding and no added retry items",
                "nativeProgress": self.progress}

    def cleanup(self) -> None:
        if self.stop_issued:
            self.execute(self.compose + ["start", "owner00"], "owner-fault-cleanup.log", 30)
            self.stopped = False
            self.stop_issued = False
