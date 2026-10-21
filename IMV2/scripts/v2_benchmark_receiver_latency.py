"""Keep peer delivery completeness separate from its latency acceptance gate."""
import math


def assess_receiver_latency(visibility, maximum_p99_milliseconds=500):
    if (type(maximum_p99_milliseconds) not in (int, float)
            or not math.isfinite(maximum_p99_milliseconds)
            or maximum_p99_milliseconds <= 0):
        raise ValueError("receiver P99 limit must be finite and positive")
    latency = visibility.get('latency') or {}
    upper = latency.get('p99UpperBoundExclusiveMilliseconds')
    complete = (visibility.get('passed') is True
                and type(latency.get('count')) is int and latency['count'] > 0
                and latency['count'] == visibility.get('expectedPeerApplications')
                == visibility.get('observedPeerApplications')
                == visibility.get('sourceAcknowledged'))
    bounded = type(upper) in (int, float) and math.isfinite(upper) and upper > 0
    passed = complete and bounded and upper <= maximum_p99_milliseconds
    reason = ('incomplete_peer_observation' if not complete else
              'unbounded_or_invalid_p99' if not bounded else
              'p99_exceeds_limit' if not passed else 'within_limit')
    return dict(passed=passed, reason=reason,
                maximumP99Milliseconds=maximum_p99_milliseconds,
                observedP99UpperBoundExclusiveMilliseconds=upper,
                scope='Scheduled send to contiguous peer-body application; completeness is a separate gate')
