#!/usr/bin/env python3
"""Capacity bounds, incomplete evidence, and the real SDK's read-only wire contract."""
import copy
from decimal import Decimal
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace as NS
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

import audit_v2_oss_capacity as audit


TARGET = {"bucket": "capacity-fixture", "region": "cn-shenzhen", "prefix": "imv2/"}


def item(number, namespace="objects", size=0, storage="Standard"):
    return NS(key=f"imv2/{namespace}/00000000-0000-0000-0000-{number:012d}",
              size=size, storage_class=storage, etag='"fixture"')


def page(items, token=None):
    return NS(contents=items, is_truncated=token is not None, next_continuation_token=token)


class FakeReader:
    def __init__(self, pages):
        self.pages = iter(pages)
        self.tokens, self.heads = [], []
        self.marker, self.expiration, self.storage = "true", None, "Standard"

    def versioning(self):
        return None

    def list_page(self, token):
        self.tokens.append(token)
        return next(self.pages)

    def head(self, key, etag):
        self.heads.append((key, etag))
        return NS(content_length=0, etag=etag, metadata={"im-deleted": self.marker},
                  storage_class=self.storage, expiration=self.expiration)


class Clock:
    def __init__(self):
        self.now = 0

    def sleep(self, delay):
        self.now += delay

    def budget(self, maximum=100, seconds=600):
        return audit.RequestBudget(maximum, seconds, 5, clock=lambda: self.now, sleep=self.sleep)


class CapacityAuditTests(unittest.TestCase):
    def scan(self, reader, maximum=100):
        return audit.scan(reader, TARGET, Clock().budget(maximum))

    def test_multipart_objects_and_markers_count_toward_upload_capacity(self):
        parts = []
        for number in range(1, 33):
            part = item(1, "uploads")
            part.key += "/parts/" + "a" * 64 + "/" + str(number)
            parts.append(part)
        objects = sorted([item(1, size=123), item(1, "uploads"), *parts], key=lambda entry: entry.key)
        reader = FakeReader([page(objects)])
        report = self.scan(reader)
        self.assertTrue(report["complete"])
        self.assertEqual(report["counts"], {"objects": 34, "payload_bytes": 123,
                                            "zero_byte_objects": 33, "tombstones": 33})
        self.assertEqual(report["by_namespace"]["uploads"]["objects"], 33)
        self.assertEqual(report["by_namespace"]["uploads"]["tombstones"], 33)
        self.assertEqual(len(reader.heads), 33)
        self.assertEqual(report["by_namespace"]["unexpected"]["objects"], 0)
        self.assertEqual(audit.assess(report, 40, 0.8), 1)
        self.assertEqual(audit.assess(report, 34, 0.8), 2)

    def test_invalid_part_identities_remain_unexpected(self):
        base = item(1, "uploads").key + "/parts/" + "a" * 64 + "/"
        keys = [base + n for n in ("0", "33", "01", "1/extra")]
        keys += [base.replace("/uploads/", "/objects/") + "1",
                 base.replace("a" * 64, "a" * 63) + "1",
                 base.replace("a" * 64, "A" * 64) + "1"]
        for key in keys:
            with self.subTest(key=key):
                entry = item(1); entry.key = key
                report = self.scan(FakeReader([page([entry])]))
                self.assertTrue(report["complete"])
                self.assertEqual(report["by_namespace"]["unexpected"]["objects"], 1)
                self.assertEqual(audit.assess(report, 1000, 0.8), 2)

    def test_pagination_verified_markers_costs_growth_and_capacity(self):
        reader = FakeReader([page([item(1, size=123), item(2)], "second"),
                             page([item(3, "uploads", storage="IA")])])
        original_head = reader.head
        def head(key, etag):
            reader.storage = "IA" if "/uploads/" in key else "Standard"
            return original_head(key, etag)
        reader.head = head
        report = self.scan(reader)
        self.assertTrue(report["complete"])
        self.assertEqual(reader.tokens, [None, "second"])
        self.assertEqual(len(reader.heads), 2)
        self.assertEqual(report["counts"], {"objects": 3, "payload_bytes": 123,
                                            "zero_byte_objects": 2, "tombstones": 2})
        self.assertEqual(report["by_namespace"]["uploads"]["tombstones"], 1)
        self.assertEqual(report["by_storage_class"]["IA"]["tombstone_billable_bytes"], 65536)
        previous = copy.deepcopy(report)
        previous["finished_at"] = "2026-11-01T00:00:00+00:00"
        previous["counts"]["objects"], previous["counts"]["tombstones"] = 1, 1
        report["finished_at"] = "2026-11-03T00:00:00+00:00"
        prices = {"currency": "CNY", "storage_per_gib_month": {"IA": Decimal("1")},
                  "read_per_10000": {"bucket": Decimal("2"), "Standard": Decimal("2"), "IA": Decimal("3")}}
        self.assertEqual(audit.assess(report, 10, 0.8, prices, previous), 0)
        self.assertEqual(report["trend"]["objects_per_day"], 1)
        self.assertEqual(report["trend"]["days_to_object_budget_at_observed_rate"], 7)
        self.assertEqual(Decimal(report["cost"]["tombstone_storage_per_month"]), Decimal(1) / 16384)
        self.assertEqual(Decimal(report["cost"]["audit_read_requests"]), Decimal("0.0011"))
        self.assertEqual(audit.assess(report, 4, 0.7), 1)
        self.assertEqual(audit.assess(report, 3, 0.8), 2)
        self.assertNotIn("00000000-", json.dumps(report))

    def test_request_and_time_budgets_never_accept_partial_counts(self):
        reader = FakeReader([page([item(1)])])
        report = self.scan(reader, maximum=2)
        self.assertEqual(report["error"], "request_budget_exhausted")
        self.assertFalse(reader.heads)
        self.assertEqual(audit.assess(report, 1000, 0.8), 3)
        self.assertIsNone(report["cost"]["tombstone_storage_per_month"])
        clock = Clock()
        reader = FakeReader([page([item(1)])])
        report = audit.scan(reader, TARGET, clock.budget(seconds=0.1))
        self.assertEqual(report["error"], "time_budget_exhausted")
        self.assertFalse(reader.tokens)
        clock = Clock()
        reader.versioning = lambda: clock.sleep(10)
        report = audit.scan(reader, TARGET, clock.budget(seconds=1))
        self.assertEqual(report["error"], "time_budget_exhausted")

    def test_incomplete_pagination_invalid_provider_data_and_errors_are_not_green(self):
        outside = item(1)
        outside.key = "outside/secret-key"
        cases = [
            [page([item(1)], "same"), page([item(2)], "same")],
            [page([item(1)], "next"), page([item(1)])],
            [page([], "empty")], [page([outside])], [page([item(1, size=-1)])],
            [NS(contents=None, is_truncated=None)],
        ]
        for pages in cases:
            with self.subTest(pages=pages):
                report = self.scan(FakeReader(pages))
                self.assertFalse(report["complete"])
                self.assertEqual(audit.assess(report, 1000, 0.8), 3)
        reader = FakeReader([])
        def fail():
            raise RuntimeError("signed-url-and-secret-must-not-leak")
        reader.versioning = fail
        report = self.scan(reader)
        self.assertEqual(report["error"], "remote_read_failed")
        self.assertNotIn("signed-url", json.dumps(report))

    def test_unmarked_zero_expiration_unexpected_key_and_versioning_require_action(self):
        for field, value, anomaly in (("marker", "false", "unmarked_zero_byte_object"),
                                      ("expiration", "expiry-date=fixture", "tombstone_has_expiration")):
            reader = FakeReader([page([item(1)])])
            setattr(reader, field, value)
            report = self.scan(reader)
            self.assertIn(anomaly, report["anomalies"])
            self.assertEqual(audit.assess(report, 1000, 0.8), 2)
        report = self.scan(FakeReader([page([item(1, "other")])]))
        self.assertIn("unexpected_keys_in_managed_prefix", report["anomalies"])
        for version in ("Enabled", "Suspended"):
            reader = FakeReader([])
            reader.versioning = lambda: version
            report = self.scan(reader)
            self.assertEqual(report["error"], "versioned_bucket_unsupported")
            self.assertFalse(reader.tokens)
        reader = FakeReader([page([item(1)])])
        reader.storage = "IA"
        self.assertEqual(self.scan(reader)["error"], "object_changed_during_audit")

    def test_prior_target_or_incomplete_report_cannot_drive_growth_projection(self):
        report = self.scan(FakeReader([page([item(1)])]))
        previous = copy.deepcopy(report)
        previous["target"]["prefix"] = "another/"
        previous["finished_at"] = "2026-10-01T00:00:00+00:00"
        self.assertEqual(audit.assess(report, 10, 0.8, previous=previous), 2)
        self.assertIsNone(report["trend"])
        self.assertIn("previous_report_not_comparable", report["anomalies"])
        previous["target"] = TARGET
        previous["counts"]["objects"] = 2
        previous["counts"]["tombstones"] = 2
        audit.assess(report, 10, 0.8, previous=previous)
        self.assertIn("permanent_object_count_decreased", report["anomalies"])

    def test_partial_prices_stay_unknown_and_reports_do_not_replace_history(self):
        reader = FakeReader([page([item(1, storage="IA")])])
        reader.storage = "IA"
        report = self.scan(reader)
        prices = {"currency": "CNY", "storage_per_gib_month": {}, "read_per_10000": {}}
        audit.assess(report, 10, 0.8, prices)
        self.assertIsNone(report["cost"]["tombstone_storage_per_month"])
        self.assertIsNone(report["cost"]["audit_read_requests"])
        self.assertIn("storage:IA", report["cost"]["missing_prices"])
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            audit.write_report(path, report)
            self.assertEqual(json.loads(path.read_text()), report)
            with self.assertRaises(FileExistsError):
                audit.write_report(path, {"replacement": True})
            self.assertEqual(json.loads(path.read_text()), report)

    def test_real_sdk_serializes_only_versioning_list_and_conditional_head(self):
        import alibabacloud_oss_v2 as oss
        from requests.structures import CaseInsensitiveDict
        requests = []
        key = item(1).key
        class Transport:
            def send(self, request, **kwargs):
                requests.append(request)
                if "versioning" in request.url:
                    body = b"<VersioningConfiguration/>"
                    headers = {}
                    audit.os.environ["IM_V2_OSS_ACCESS_KEY_ID"] = "rotated-synthetic-id"
                elif request.method == "GET":
                    body = ("<ListBucketResult><Name>capacity-fixture</Name><Prefix>imv2/</Prefix>"
                            "<IsTruncated>false</IsTruncated><Contents><Key>" + key + "</Key>"
                            "<Size>0</Size><ETag>&quot;fixture&quot;</ETag><StorageClass>Standard</StorageClass>"
                            "</Contents></ListBucketResult>").encode()
                    headers = {}
                else:
                    body = b""
                    headers = {"Content-Length": "0", "ETag": '"fixture"',
                               "x-oss-meta-im-deleted": "true", "x-oss-storage-class": "Standard"}
                return NS(request=request, status_code=200, reason="OK", content=body,
                          headers=CaseInsensitiveDict(headers), is_closed=False, is_stream_consumed=False,
                          read=lambda: body, close=lambda: None, iter_bytes=lambda **kw: iter([body]))
        config = oss.config.load_default()
        config.http_client = Transport()
        args = NS(**TARGET, internal=False)
        with patch.object(oss.config, "load_default", return_value=config), patch.dict(audit.os.environ, {
                "IM_V2_OSS_ACCESS_KEY_ID": "synthetic-id", "IM_V2_OSS_ACCESS_KEY_SECRET": "synthetic-secret"}, clear=True):
            reader = audit.OSSReader(args)
            report = self.scan(reader)
        self.assertTrue(report["complete"], report["error"])
        self.assertEqual(report["counts"]["tombstones"], 1)
        self.assertEqual([r.method for r in requests], ["GET", "GET", "HEAD"])
        self.assertEqual(parse_qs(urlsplit(requests[1].url).query)["prefix"], ["imv2/"])
        self.assertEqual(parse_qs(urlsplit(requests[1].url).query)["max-keys"], ["1000"])
        self.assertEqual(requests[2].headers["If-Match"], '"fixture"')
        self.assertTrue(all(r.headers["Authorization"].startswith("OSS4-HMAC-SHA256 ") for r in requests))
        self.assertIn("Credential=synthetic-id/", requests[0].headers["Authorization"])
        self.assertIn("Credential=rotated-synthetic-id/", requests[1].headers["Authorization"])
        self.assertEqual(config.retry_max_attempts, 1)
        self.assertFalse(config.enabled_redirect)

    def test_rotating_credential_file_is_reloaded_and_never_falls_back(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "credentials.json"
            credentials = {"AccessKeyId": "first", "AccessKeySecret": "synthetic-secret",
                           "SecurityToken": "synthetic-token", "Expiration": "2099-01-01T00:00:00Z"}
            path.write_text(json.dumps(credentials))
            with patch.dict(audit.os.environ, {"IM_V2_OSS_CREDENTIAL_FILE": str(path),
                    "IM_V2_OSS_ACCESS_KEY_ID": "must-not-fall-back", "IM_V2_OSS_ACCESS_KEY_SECRET": "unused"}, clear=True):
                self.assertEqual(audit.runtime_credentials()["access_key_id"], "first")
                credentials["AccessKeyId"] = "second"
                replacement = path.with_suffix(".replacement")
                replacement.write_text(json.dumps(credentials))
                replacement.replace(path)
                self.assertEqual(audit.runtime_credentials()["access_key_id"], "second")
                credentials["Expiration"] = "2000-01-01T00:00:00Z"
                path.write_text(json.dumps(credentials))
                with self.assertRaises(audit.AuditError):
                    audit.runtime_credentials()
                path.unlink()
                with self.assertRaises(FileNotFoundError):
                    audit.runtime_credentials()


if __name__ == "__main__":
    unittest.main()
