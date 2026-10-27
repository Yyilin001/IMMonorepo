#!/usr/bin/env python3
"""Run the explicit OSS contract gate without writing credentials to logs or files."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--bucket", required=True)
parser.add_argument("--region", required=True)
parser.add_argument("--aliyun-profile", help="Use an already authenticated local aliyun CLI profile")
parser.add_argument("--http-pipeline", action="store_true", help="Run the HTTP/PostgreSQL pipeline against IMV2_RESOURCE_TEST_DATABASE_URL")
parser.add_argument("--native-output", type=Path, help="Run the owned Account/Gateway/ClientKit acceptance and save evidence here")
parser.add_argument("--oss-test-parent", help="Authorized native test parent ending in validation/, e.g. ecs-test/validation/")
parser.add_argument("--resource-center", action="store_true", help="Require both resource-center and group-avatar native cloud scenarios")
parser.add_argument("--app-xctestrun", type=Path, help="prebuilt iOS App integration test manifest")
parser.add_argument("--app-simulator", help="dedicated simulator UDID")
parser.add_argument("--app-ui-simulator", help="dedicated simulator for real two-account photo UI")
parser.add_argument("--app-ui-derived-data", type=Path, help="owned Xcode build directory for the UI scenario")
args = parser.parse_args()
if args.oss_test_parent and not args.native_output:
    parser.error("--oss-test-parent requires --native-output")
if bool(args.app_xctestrun) != bool(args.app_simulator) or (args.app_xctestrun and not args.resource_center):
    parser.error("App integration requires resource-center and both App options")
if bool(args.app_ui_simulator) != bool(args.app_ui_derived_data) or (args.app_ui_simulator and not args.resource_center):
    parser.error("App UI closure requires resource-center and both UI options")
if args.http_pipeline and args.native_output:
    parser.error("select only one pipeline")
if args.resource_center and not args.native_output:
    parser.error("--resource-center requires --native-output")
if args.http_pipeline and not os.environ.get("IMV2_RESOURCE_TEST_DATABASE_URL"):
    parser.error("--http-pipeline requires an isolated IMV2_RESOURCE_TEST_DATABASE_URL")
environment = os.environ.copy()
if args.aliyun_profile:
    configuration = json.loads((Path.home() / ".aliyun/config.json").read_text())
    profile = next((item for item in configuration["profiles"] if item["name"] == args.aliyun_profile), None)
    if profile is None:
        parser.error("The requested aliyun profile does not exist")
    for source, target in [("access_key_id", "ACCESS_KEY_ID"), ("access_key_secret", "ACCESS_KEY_SECRET"),
                           ("sts_token", "SECURITY_TOKEN")]:
        value = profile.get(source)
        if value:
            environment["IM_V2_OSS_" + target] = value
        else:
            environment.pop("IM_V2_OSS_" + target, None)
    # Do not attempt to print or refresh secret values; CLI login remains a separate action.
    environment.pop("IM_V2_OSS_CREDENTIAL_EXPIRATION", None)
    expiration = profile.get("sts_expiration")
    if profile.get("sts_token") and expiration:
        if int(expiration) <= int(datetime.now(timezone.utc).timestamp()) + 90:
            parser.error("The cached OSS credentials are expired or about to expire; refresh the existing aliyun CLI profile before running the gate")
        environment["IM_V2_OSS_CREDENTIAL_EXPIRATION"] = datetime.fromtimestamp(
            int(expiration), tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
for required in ["IM_V2_OSS_ACCESS_KEY_ID", "IM_V2_OSS_ACCESS_KEY_SECRET"]:
    if not environment.get(required):
        parser.error("Missing runtime credentials; configure the environment or an authenticated aliyun profile")
environment.update(IM_V2_OSS_LIVE_TEST="1", IM_V2_OSS_BUCKET=args.bucket, IM_V2_OSS_REGION=args.region)
root = Path(__file__).resolve().parents[1]
if args.native_output:
    import sys
    command = [sys.executable, str(root / "scripts/verify_v2_live_resource_authors.py"), "--oss", "--output", str(args.native_output)]
    if args.oss_test_parent:
        command += ["--oss-test-parent", args.oss_test_parent]
    if args.resource_center:
        command.append("--resource-center")
    if args.app_xctestrun:
        command += ["--app-xctestrun", str(args.app_xctestrun), "--app-simulator", args.app_simulator]
    if args.app_ui_simulator:
        command += ["--app-ui-simulator", args.app_ui_simulator, "--app-ui-derived-data", str(args.app_ui_derived_data)]
    result = subprocess.run(command, env=environment)
    raise SystemExit(result.returncode)
result = subprocess.run([
    "swift", "test", "--package-path", str(root / "IMV2Server"), "--disable-automatic-resolution", "--jobs", "4",
    "--filter", "V2ResourceHTTPPostgresTests" if args.http_pipeline else "V2OSS|V2ResourceStorageContractTests|V2ResourceDeliveryContractTests",
], env=environment)
raise SystemExit(result.returncode)
