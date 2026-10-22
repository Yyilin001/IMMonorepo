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
args = parser.parse_args()
if args.http_pipeline and args.native_output:
    parser.error("select only one pipeline")
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
        environment["IM_V2_OSS_CREDENTIAL_EXPIRATION"] = datetime.fromtimestamp(
            int(expiration), tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
for required in ["IM_V2_OSS_ACCESS_KEY_ID", "IM_V2_OSS_ACCESS_KEY_SECRET"]:
    if not environment.get(required):
        parser.error("Missing runtime credentials; configure the environment or an authenticated aliyun profile")
environment.update(IM_V2_OSS_LIVE_TEST="1", IM_V2_OSS_BUCKET=args.bucket, IM_V2_OSS_REGION=args.region)
root = Path(__file__).resolve().parents[1]
if args.native_output:
    import sys
    result = subprocess.run([sys.executable, str(root / "scripts/verify_v2_live_resource_authors.py"),
        "--oss", "--output", str(args.native_output)], env=environment)
    raise SystemExit(result.returncode)
result = subprocess.run([
    "swift", "test", "--package-path", str(root / "IMV2Server"), "--disable-automatic-resolution", "--jobs", "4",
    "--filter", "V2ResourceHTTPPostgresTests" if args.http_pipeline else "V2OSS|V2ResourceStorageContractTests|V2ResourceDeliveryContractTests",
], env=environment)
raise SystemExit(result.returncode)
