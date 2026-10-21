"""Validate peer-body visibility samples for the paired-foreground workload."""
import uuid
from run_v2_actor_realtime_benchmark import merge_latency_histograms


def summarize_visibility(reports, phase, expected_run_id):
    events, domains, runs, histograms = {}, set(), set(), []
    expected = acknowledged = 0
    valid = bool(reports)
    for report in reports:
        visibility = report.get('receiverVisibility', {})
        cohort = report.get('messageSendCohorts', {}).get(phase)
        try:
            domains.add(str(uuid.UUID(visibility['clockDomain'])))
            runs.add(str(uuid.UUID(visibility['runID'])))
            valid = valid and visibility.get('enabled') is True and cohort is not None
            if any(not isinstance(cohort[k], int) or cohort[k] < 0 for k in ('messagesSent','messagesAcknowledged')):
                raise ValueError('invalid source count')
            expected += cohort['messagesSent']
            acknowledged += cohort['messagesAcknowledged']
            for name, count in visibility.get('events', {}).items():
                if not isinstance(count, int) or count < 0:
                    raise ValueError('invalid event count')
                events[name] = events.get(name, 0) + count
            histogram = visibility.get('cohorts', {}).get(phase, dict(count=0, maximum=0, histogramBuckets=[]))
            histograms.append(histogram)
        except (KeyError, TypeError, ValueError, AttributeError):
            valid = False
    merged = merge_latency_histograms(histograms) if valid else None
    fatal_events = ('foreignClock', 'capacityExceeded', 'conflictingBody', 'invalidClockSamples', 'unknownCohort')
    complete = (valid and len(domains) == 1 and runs == {str(uuid.UUID(expected_run_id))}
                and expected > 0 and acknowledged == expected and merged is not None
                and merged['count'] == expected and not any(events.get(k, 0) for k in fatal_events))
    return dict(passed=complete, phase=phase, expectedPeerApplications=expected,
        sourceAcknowledged=acknowledged, observedPeerApplications=merged['count'] if merged else None,
        latency=merged if complete else None, partialLatency=merged if not complete else None,
        clockDomains=sorted(domains), runIDs=sorted(runs), events=events,
        scope='One peer per accepted message in paired foreground direct rooms; scheduled send to simulated continuous body application, not UI rendering',
        clockBasis='All sender and receiver loaders must share the same verified Linux boot clock; server clocks are not subtracted')
