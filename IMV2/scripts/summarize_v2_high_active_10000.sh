#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$#" -ne 2 ]]; then
  printf 'usage: %s <report-directory> <summary-json>\n' "$0" >&2
  exit 64
fi

report_directory="$1"
summary_path="$2"
worker_a="${report_directory}/worker-a.json"
worker_b="${report_directory}/worker-b.json"

command -v jq >/dev/null 2>&1 || {
  printf 'missing required command: jq\n' >&2
  exit 69
}
[[ -s "${worker_a}" && -s "${worker_b}" ]] || {
  printf 'expected non-empty worker reports: %s and %s\n' "${worker_a}" "${worker_b}" >&2
  exit 66
}

mkdir -p "$(dirname "${summary_path}")"
umask 077

jq -es '
  def total($field): map(.[$field] // 0) | add;
  def maximum($path): map(getpath($path) // 0) | max;
  def ratio($numerator; $denominator):
    if $denominator == 0 then 0 else $numerator / $denominator end;
  def phaseSummary:
    [ .[] | .scenarioPhases[] ]
    | group_by(.name)
    | map({
        name: .[0].name,
        durationSeconds: .[0].durationSeconds,
        requestedMessagesPerSecond: (map(.requestedMessagesPerSecond) | add),
        requestedRoomLogReadsPerSecond: (map(.requestedRoomLogReadsPerSecond) | add),
        requestedSyncPullsPerSecond: (map(.requestedSyncPullsPerSecond) | add),
        messagesSent: (map(.messagesSent) | add),
        messagesAcknowledged: (map(.messagesAcknowledged) | add),
        messagesSkipped: (map(.messagesSkipped) | add),
        roomEventPullsSent: (map(.roomEventPullsSent) | add),
        roomEventRecordsReceived: (map(.roomEventRecordsReceived) | add),
        syncPullsSent: (map(.syncPullsSent) | add),
        syncRecordsReceived: (map(.syncRecordsReceived) | add),
        workloadFailed: (map(.workloadFailed) | add)
      });
  . as $reports
  | (total("requestedConnections")) as $requested
  | (total("peakActive")) as $peakActive
  | (total("directRoomAttempted")) as $directAttempts
  | (total("messagesSent")) as $messagesSent
  | (total("messagesAcknowledged")) as $messagesAcknowledged
  | (total("syncPullsSent")) as $syncPullsSent
  | (total("workloadFailed")) as $workloadFailed
  | (total("failed")) as $connectionFailures
  | {
      scenarioName: ([.[].scenarioName] | unique),
      workers: length,
      requestedConnections: $requested,
      authenticated: total("authenticated"),
      peakActive: $peakActive,
      connectionFailures: $connectionFailures,
      plannedReconnects: total("plannedReconnects"),
      directRoomAttempted: $directAttempts,
      directRoomOpened: total("directRoomOpened"),
      messagesSent: $messagesSent,
      messagesAcknowledged: $messagesAcknowledged,
      messagesSkipped: total("messagesSkipped"),
      roomEventPullsSent: total("roomEventPullsSent"),
      roomEventRecordsReceived: total("roomEventRecordsReceived"),
      syncPullsSent: $syncPullsSent,
      syncRecordsReceived: total("syncRecordsReceived"),
      workloadFailed: $workloadFailed,
      connectionFailureRate: ratio($connectionFailures; $requested),
      workloadFailureRate: ratio($workloadFailed; ($directAttempts + $messagesSent + $syncPullsSent)),
      messageAcknowledgementRate: ratio($messagesAcknowledged; $messagesSent),
      maximumRSSMegabytesPerWorker: maximum(["maximumRSSMegabytes"]),
      worstLatencyMilliseconds: {
        authenticationP95: maximum(["authenticationLatency", "p95"]),
        heartbeatP95: maximum(["heartbeatLatency", "p95"]),
        messageP95: maximum(["messageLatency", "p95"]),
        messageP99: maximum(["messageLatency", "p99"]),
        syncPullP95: maximum(["syncPullLatency", "p95"]),
        roomEventPullP95: maximum(["roomEventPullLatency", "p95"])
      },
      phases: phaseSummary,
      terminalErrors: [ .[] | select(.terminalError != null) | .terminalError ],
      executionGates: {
        expectedScenario: (all(.[]; .scenarioName == "high-active-10000-v1")),
        twoWorkers: (length == 2),
        requestedTenThousand: ($requested == 10000),
        reachedTenThousandPeak: ($peakActive == 10000),
        noTerminalError: (all(.[]; .terminalError == null)),
        workloadFailureAtMostPointOnePercent: (ratio($workloadFailed; ($directAttempts + $messagesSent + $syncPullsSent)) <= 0.001)
      }
    }
' "${worker_a}" "${worker_b}" > "${summary_path}"

jq -e '
  .executionGates.expectedScenario
  and .executionGates.twoWorkers
  and .executionGates.requestedTenThousand
  and .executionGates.reachedTenThousandPeak
  and .executionGates.noTerminalError
  and .executionGates.workloadFailureAtMostPointOnePercent
' "${summary_path}" >/dev/null || {
  printf 'high-active execution gates failed; inspect %s\n' "${summary_path}" >&2
  exit 1
}

printf 'high-active 10000 summary written: %s\n' "${summary_path}"
