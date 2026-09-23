#!/usr/bin/env python3
"""Freeze explicit budgets after three stable frozen-main measurement runs.

Run this before any candidate measurement. The thresholds JSON is an explicit
reviewed policy input; the script never invents numeric regression budgets.
"""

import argparse
import json
import os
from pathlib import Path
import sys

from virtual_actor_capacity_measurement import MeasurementFailure, freeze_calibrations


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--main-run", type=Path, action="append", required=True,
                        help="repeat exactly three times with distinct private main evidence directories")
    parser.add_argument("--thresholds-json", type=Path, required=True,
                        help="reviewed positive numeric budgets, keyed by metric name")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if len(args.main_run) != 3 or args.output.exists():
        parser.error("exactly three runs and a new output path are required")
    thresholds = json.loads(args.thresholds_json.read_text())
    if not isinstance(thresholds, dict):
        parser.error("thresholds JSON must be an object")
    frozen = freeze_calibrations([path.resolve() for path in args.main_run], thresholds)
    with args.output.open("x", encoding="utf-8") as stream:
        os.fchmod(stream.fileno(), 0o600)
        json.dump(frozen, stream, indent=2, sort_keys=True)
        stream.write("\n")
    print("VA_CAPACITY_MAIN_CALIBRATION_FROZEN file=" + str(args.output))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (MeasurementFailure, OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print("VA_CAPACITY_MAIN_CALIBRATION_REJECTED type=" + type(error).__name__, file=sys.stderr)
        raise SystemExit(1)
