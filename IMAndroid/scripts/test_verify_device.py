import unittest

from verify_device import parse_results


def status(code, name="example", count=1):
    return (f"INSTRUMENTATION_STATUS: numtests={count}\n"
            "INSTRUMENTATION_STATUS: class=example.Tests\n"
            f"INSTRUMENTATION_STATUS: test={name}\n"
            f"INSTRUMENTATION_STATUS_CODE: {code}\n")


class ResultParsingTests(unittest.TestCase):
    def test_started_test_is_not_counted_twice(self):
        result = parse_results(status(1) + status(0) + "INSTRUMENTATION_CODE: -1\n")
        self.assertTrue(result["complete"])
        self.assertEqual(result["passed"], 1)

    def test_assumption_is_skipped_not_passed(self):
        result = parse_results(status(-4) + "INSTRUMENTATION_CODE: -1\n")
        self.assertTrue(result["complete"])
        self.assertEqual((result["passed"], result["skipped"]), (0, 1))

    def test_failure_remains_failure_even_when_runner_completes(self):
        result = parse_results(status(-2) + "INSTRUMENTATION_CODE: -1\n")
        self.assertEqual(len(result["failures"]), 1)

    def test_truncated_or_empty_run_is_incomplete(self):
        for output in (status(0), "INSTRUMENTATION_CODE: -1\n",
                       status(0, count=2) + "INSTRUMENTATION_CODE: -1\n"):
            self.assertFalse(parse_results(output)["complete"])

    def test_process_crash_is_incomplete(self):
        output = status(0) + "INSTRUMENTATION_RESULT: shortMsg=Process crashed.\nINSTRUMENTATION_CODE: -1\n"
        self.assertFalse(parse_results(output)["complete"])


if __name__ == "__main__":
    unittest.main()
