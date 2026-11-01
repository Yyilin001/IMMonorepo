#!/usr/bin/env python3
"""Read-only OSS capacity evidence. Never deletes objects or changes bucket policy."""
import argparse
from datetime import datetime, timezone
from decimal import Decimal
import json
import math
import os
from pathlib import Path
import re
import tempfile
import time


class AuditError(Exception):
    """A fixed, non-sensitive reason suitable for the report."""


STORAGE_MINIMUM = {"Standard": 0, "IA": 65536, "Archive": 65536,
                   "ColdArchive": 65536, "DeepColdArchive": 65536}
UUID_KEY = r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}"
OBJECT_KEY = re.compile(r"(objects|uploads)/" + UUID_KEY)
UPLOAD_PART_KEY = re.compile(r"uploads/" + UUID_KEY + r"/parts/[0-9a-f]{64}/(?:[1-9]|[12][0-9]|3[0-2])")


def object_namespace(relative):
    match = OBJECT_KEY.fullmatch(relative)
    if match:
        return match.group(1)
    # Match the adapter's bounded part identity, not arbitrary descendants.
    return "uploads" if UPLOAD_PART_KEY.fullmatch(relative) else "unexpected"


def utc_now():
    return datetime.now(timezone.utc).isoformat()


class RequestBudget:
    def __init__(self, maximum, seconds, rate, clock=time.monotonic, sleep=time.sleep):
        self.maximum, self.seconds, self.rate = maximum, seconds, rate
        self.clock, self.sleep = clock, sleep
        self.start = clock()
        self.last = None
        self.counts = {}

    def call(self, category, operation):
        if sum(self.counts.values()) >= self.maximum:
            raise AuditError("request_budget_exhausted")
        delay = max(0, (self.last + 1 / self.rate - self.clock()) if self.last is not None else 0)
        if self.clock() + delay - self.start >= self.seconds:
            raise AuditError("time_budget_exhausted")
        if delay:
            self.sleep(delay)
        self.last = self.clock()
        self.counts[category] = self.counts.get(category, 0) + 1
        try:
            result = operation()
        except Exception:
            # Provider exceptions can contain signed URLs, keys or credentials.
            raise AuditError("remote_read_failed") from None
        if self.clock() - self.start >= self.seconds:
            raise AuditError("time_budget_exhausted")
        return result


def empty_counts():
    return {"objects": 0, "payload_bytes": 0, "zero_byte_objects": 0, "tombstones": 0}


def scan(client, target, budget):
    """Keep one page in memory; validate every zero-byte object's deletion marker."""
    report = {"format": 1, "target": target, "started_at": utc_now(), "complete": False,
              "consistency": "non_atomic_listing_interval", "counts": empty_counts(),
              "by_namespace": {name: empty_counts() for name in ("objects", "uploads", "unexpected")},
              "by_storage_class": {}, "anomalies": [], "error": None}
    token, last_key = None, None
    try:
        if budget.call("bucket", client.versioning) not in (None, ""):
            raise AuditError("versioned_bucket_unsupported")
        while True:
            page = budget.call("bucket", lambda: client.list_page(token))
            if type(page.is_truncated) is not bool or len(page.contents or []) > 1000:
                raise AuditError("invalid_list_page")
            for item in page.contents or []:
                key, size, storage = item.key, item.size, item.storage_class
                if (not isinstance(key, str) or not key.startswith(target["prefix"])
                        or (last_key is not None and key <= last_key)
                        or type(size) is not int or size < 0
                        or storage not in STORAGE_MINIMUM
                        or not isinstance(item.etag, str) or not item.etag):
                    raise AuditError("invalid_or_repeated_object")
                last_key = key
                relative = key[len(target["prefix"]):]
                namespace = object_namespace(relative)
                class_counts = report["by_storage_class"].setdefault(storage, {
                    **empty_counts(), "minimum_billable_bytes": 0, "tombstone_billable_bytes": 0})
                groups = (report["counts"], report["by_namespace"][namespace], class_counts)
                for counts in groups:
                    counts["objects"] += 1
                    counts["payload_bytes"] += size
                class_counts["minimum_billable_bytes"] += max(size, STORAGE_MINIMUM[storage])
                if size == 0:
                    for counts in groups:
                        counts["zero_byte_objects"] += 1
                    head = budget.call(storage, lambda: client.head(key, item.etag))
                    if (type(head.content_length) is not int or head.content_length != 0
                            or head.etag != item.etag or head.storage_class != storage):
                        raise AuditError("object_changed_during_audit")
                    metadata = {str(k).lower(): v for k, v in (head.metadata or {}).items()}
                    if metadata.get("im-deleted") == "true":
                        for counts in groups:
                            counts["tombstones"] += 1
                        class_counts["tombstone_billable_bytes"] += STORAGE_MINIMUM[storage]
                    else:
                        if "unmarked_zero_byte_object" not in report["anomalies"]:
                            report["anomalies"].append("unmarked_zero_byte_object")
                    if getattr(head, "expiration", None):
                        if "tombstone_has_expiration" not in report["anomalies"]:
                            report["anomalies"].append("tombstone_has_expiration")
            if not page.is_truncated:
                report["complete"] = True
                break
            next_token = page.next_continuation_token
            if not page.contents or not isinstance(next_token, str) or not next_token or next_token == token:
                raise AuditError("invalid_continuation")
            token = next_token
    except AuditError as error:
        report["error"] = str(error)
    except KeyboardInterrupt:
        report["error"] = "interrupted"
    except Exception:
        report["error"] = "invalid_provider_response"
    if report["by_namespace"]["unexpected"]["objects"]:
        report["anomalies"].append("unexpected_keys_in_managed_prefix")
    report["finished_at"] = utc_now()
    report["read_requests"] = dict(budget.counts)
    return report


def price_table(path):
    if path is None:
        return None
    value = json.loads(path.read_text())
    if not re.fullmatch(r"[A-Z]{3}", value.get("currency", "")):
        raise ValueError("invalid currency")
    for field, allowed in (("storage_per_gib_month", STORAGE_MINIMUM),
                           ("read_per_10000", {"bucket", *STORAGE_MINIMUM})):
        entries = value[field]
        if not isinstance(entries, dict) or entries.keys() - set(allowed):
            raise ValueError("invalid price classes")
        for key, raw in entries.items():
            amount = Decimal(str(raw))
            if not amount.is_finite() or amount < 0:
                raise ValueError("invalid price")
            entries[key] = amount
    return value


def assess(report, object_budget, warning_fraction, prices=None, previous=None):
    observed = report["counts"]["objects"]
    report["capacity"] = {"object_budget": object_budget, "warning_fraction": warning_fraction,
                          "observed_fraction": observed / object_budget}
    report["trend"] = None
    if previous is not None:
        try:
            elapsed = (datetime.fromisoformat(report["finished_at"]) -
                       datetime.fromisoformat(previous["finished_at"])).total_seconds() / 86400
            if (previous["format"] != 1 or previous["target"] != report["target"]
                    or previous["complete"] is not True or not report["complete"] or elapsed <= 0):
                raise ValueError()
            old = previous["counts"]
            if any(type(old[k]) is not int or old[k] < 0 for k in ("objects", "tombstones")):
                raise ValueError()
            growth = (observed - old["objects"]) / elapsed
            tombstone_growth = (report["counts"]["tombstones"] - old["tombstones"]) / elapsed
            report["trend"] = {"days": elapsed, "objects_per_day": growth,
                               "tombstones_per_day": tombstone_growth,
                               "days_to_object_budget_at_observed_rate":
                                   max(0, (object_budget - observed) / growth) if growth > 0 else None}
            if growth < 0 or tombstone_growth < 0:
                report["anomalies"].append("permanent_object_count_decreased")
        except (KeyError, ValueError, TypeError):
            report["anomalies"].append("previous_report_not_comparable")
    report["cost"] = {"currency": prices["currency"] if prices else None,
                      "tombstone_storage_per_month": None, "audit_read_requests": None,
                      "missing_prices": [], "basis": "operator_rates_excluding_other_bill_items"}
    if prices:
        missing = []
        storage_cost, request_cost = Decimal(0), Decimal(0)
        for storage, counts in report["by_storage_class"].items():
            billed = counts["tombstone_billable_bytes"]
            if billed and storage not in prices["storage_per_gib_month"]:
                missing.append("storage:" + storage)
            elif billed:
                storage_cost += Decimal(billed) / (1024 ** 3) * prices["storage_per_gib_month"][storage]
        for category, count in report["read_requests"].items():
            if category not in prices["read_per_10000"]:
                missing.append("read:" + category)
            else:
                request_cost += Decimal(count) / 10000 * prices["read_per_10000"][category]
        report["cost"]["missing_prices"] = missing
        if report["complete"] and not any(p.startswith("storage:") for p in missing):
            report["cost"]["tombstone_storage_per_month"] = str(storage_cost)
        if not any(p.startswith("read:") for p in missing):
            report["cost"]["audit_read_requests"] = str(request_cost)
    if not report["complete"]:
        report["status"], exit_code = "incomplete", 3
    elif observed >= object_budget or report["anomalies"]:
        report["status"], exit_code = "action_required", 2
    elif observed >= object_budget * warning_fraction:
        report["status"], exit_code = "warning", 1
    else:
        report["status"], exit_code = "within_budget", 0
    return exit_code


def runtime_credentials():
    """Read the current atomic credential file for every signed request."""
    path = os.environ.get("IM_V2_OSS_CREDENTIAL_FILE")
    if path:
        if not Path(path).is_absolute():
            raise AuditError("credentials_unavailable")
        with open(path, "rb") as stream:
            raw = stream.read(16385)
        if len(raw) > 16384:
            raise AuditError("credentials_unavailable")
        credentials = json.loads(raw)
        if not credentials.get("SecurityToken") or not credentials.get("Expiration"):
            raise AuditError("credentials_unavailable")
    else:
        credentials = {name: os.environ.get("IM_V2_OSS_" + source) for name, source in (
            ("AccessKeyId", "ACCESS_KEY_ID"), ("AccessKeySecret", "ACCESS_KEY_SECRET"),
            ("SecurityToken", "SECURITY_TOKEN"), ("Expiration", "CREDENTIAL_EXPIRATION"))}
    if not credentials.get("AccessKeyId") or not credentials.get("AccessKeySecret"):
        raise AuditError("credentials_unavailable")
    expiration = credentials.get("Expiration")
    if expiration:
        expires = datetime.fromisoformat(expiration.replace("Z", "+00:00"))
        if expires.tzinfo is None or expires.timestamp() <= time.time() + 30:
            raise AuditError("credentials_expired")
    return {"access_key_id": credentials["AccessKeyId"], "access_key_secret": credentials["AccessKeySecret"],
            "security_token": credentials.get("SecurityToken") or None}


class OSSReader:
    """Only bucket versioning, LIST and HEAD; no object bodies or writes."""
    def __init__(self, args):
        import ssl
        if ssl.OPENSSL_VERSION_INFO < (1, 1, 1) or not ssl.OPENSSL_VERSION.startswith("OpenSSL"):
            raise AuditError("python_with_supported_openssl_required")
        import alibabacloud_oss_v2 as oss
        from alibabacloud_oss_v2.types import Credentials, CredentialsProvider
        class RuntimeCredentials(CredentialsProvider):
            def get_credentials(self):
                return Credentials(**runtime_credentials())
        self.oss, self.bucket, self.prefix = oss, args.bucket, args.prefix
        config = oss.config.load_default()
        config.region = args.region
        config.credentials_provider = RuntimeCredentials()
        config.signature_version = "v4"
        config.retry_max_attempts = 1
        config.connect_timeout, config.readwrite_timeout = 5, 10
        config.enabled_redirect = False
        config.use_internal_endpoint = args.internal
        self.client = oss.Client(config)

    def versioning(self):
        return self.client.get_bucket_versioning(self.oss.GetBucketVersioningRequest(bucket=self.bucket)).version_status

    def list_page(self, token):
        return self.client.list_objects_v2(self.oss.ListObjectsV2Request(
            bucket=self.bucket, prefix=self.prefix, max_keys=1000, continuation_token=token))

    def head(self, key, etag):
        return self.client.head_object(self.oss.HeadObjectRequest(bucket=self.bucket, key=key, if_match=etag))


def write_report(path, report):
    # Publish a complete local report without overwriting a prior observation.
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as temporary:
        temporary_path = Path(temporary.name)
        try:
            json.dump(report, temporary, ensure_ascii=False, indent=2, allow_nan=False)
            temporary.write("\n")
            temporary.flush()
            os.fsync(temporary.fileno())
            os.link(temporary_path, path)
        finally:
            temporary_path.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--region", required=True)
    parser.add_argument("--prefix", required=True, help="Exact configured binding prefix, ending in /")
    parser.add_argument("--object-budget", required=True, type=int, help="Operator's total object capacity budget")
    parser.add_argument("--warning-fraction", type=float, default=0.8)
    parser.add_argument("--max-requests", type=int, default=10000)
    parser.add_argument("--max-seconds", type=float, default=600)
    parser.add_argument("--requests-per-second", type=float, default=5)
    parser.add_argument("--internal", action="store_true")
    parser.add_argument("--prices", type=Path, help="Optional deployment-specific unit prices JSON")
    parser.add_argument("--previous", type=Path, help="Prior complete report for this exact bucket/region/prefix")
    parser.add_argument("--output", type=Path, required=True, help="New local report; existing files are never replaced")
    args = parser.parse_args()
    if (not re.fullmatch(r"[a-z0-9][a-z0-9-]{1,61}[a-z0-9]", args.bucket)
            or not re.fullmatch(r"[a-z0-9-]{1,64}", args.region)
            or not re.fullmatch(r"(?:[a-z0-9-]+/)+", args.prefix) or len(args.prefix) > 256
            or args.object_budget <= 0 or args.max_requests <= 0
            or not 0 < args.warning_fraction < 1
            or any(not math.isfinite(v) or v <= 0 for v in (args.max_seconds, args.requests_per_second))):
        parser.error("Invalid target or capacity/request budget")
    if args.output.exists() or not args.output.parent.is_dir():
        parser.error("Output must be a new file in an existing directory")
    try:
        prices = price_table(args.prices)
        previous = json.loads(args.previous.read_text()) if args.previous else None
        client = OSSReader(args)
    except Exception:
        parser.error("Cannot initialize audit: check SDK/OpenSSL, runtime credentials and report/price input files")
    target = {"bucket": args.bucket, "region": args.region, "prefix": args.prefix}
    budget = RequestBudget(args.max_requests, args.max_seconds, args.requests_per_second)
    report = scan(client, target, budget)
    report["limits"] = {"max_requests": args.max_requests, "max_seconds": args.max_seconds,
                        "requests_per_second": args.requests_per_second}
    code = assess(report, args.object_budget, args.warning_fraction, prices, previous)
    write_report(args.output, report)
    print(json.dumps({"status": report["status"], "complete": report["complete"],
                      "observed": report["counts"], "report": str(args.output)}))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
