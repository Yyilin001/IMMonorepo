"""Explicit observation-only mode for faults that would trip load failure guards."""


def loader_failure_guard_percent(observe_through_failures, *, prefill=False):
    # Fixture preparation must still fail fast. Actual diagnostic workload may
    # continue after authentication, connection-loss, or workload failures.
    return "100" if observe_through_failures and not prefill else "0.1"


def mark_observation_only(result, enabled):
    if enabled:
        result["diagnosticObservation"] = dict(
            observeThroughFailures=True,
            qualityChecksPassed=result["passed"],
            capacityEvidence=False,
        )
        result["capacityComparable"] = False
        result["passed"] = False
    return result
