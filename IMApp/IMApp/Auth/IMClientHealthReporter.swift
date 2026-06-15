import Foundation
import IMClientKit

@MainActor
extension ConversationRuntimeController {
    func reportClientHealthIfNeeded(reason: String, force: Bool = false) async {
        guard currentUserProvider() != nil else {
            return
        }

        let now = Date()
        if !force,
           let lastClientHealthReportAt,
           now.timeIntervalSince(lastClientHealthReportAt) < HistoryConfig.clientHealthReportMinimumInterval {
            return
        }

        lastClientHealthReportAt = now
        let snapshot = healthSnapshotIncludingRuntimeConfiguration()
        do {
            try await sessionClient.reportIMClientHealth(
                snapshot: snapshot,
                reason: reason,
                reportedAt: now
            )
            markServerOnline()
        } catch is CancellationError {
            return
        } catch {
            // Health reporting is observational; it must not affect IM sync or session state.
        }
    }

    func reportTimelineCatchUpHealthIfNeeded(reason: String, force: Bool = false) async {
        let now = Date()
        if !force,
           let lastTimelineCatchUpHealthReportAt,
           now.timeIntervalSince(lastTimelineCatchUpHealthReportAt) <
            HistoryConfig.timelineCatchUpHealthReportMinimumInterval {
            return
        }

        lastTimelineCatchUpHealthReportAt = now
        await reportClientHealthIfNeeded(reason: reason, force: true)
    }

    func reportTimelineCatchUpSlowHealthIfNeeded(reason: String) async {
        let diagnostics = imConversationStore.healthSnapshot.timelineCatchUpDiagnostics
        let slowestMilliseconds = [
            diagnostics.lastHintToRequestMilliseconds,
            diagnostics.lastRequestMilliseconds,
            diagnostics.lastHintToApplyMilliseconds
        ]
            .compactMap { $0 }
            .max() ?? 0
        guard slowestMilliseconds >= HistoryConfig.timelineCatchUpSlowReportThresholdMilliseconds else {
            return
        }

        await reportTimelineCatchUpHealthIfNeeded(reason: reason)
    }

    private func healthSnapshotIncludingRuntimeConfiguration() -> IMConversationHealthSnapshot {
        let snapshot = imConversationStore.healthSnapshot
        return IMConversationHealthSnapshot(
            domainEventCursor: snapshot.domainEventCursor,
            deferredDomainEventCount: snapshot.deferredDomainEventCount,
            fullRefreshConversationCount: snapshot.fullRefreshConversationCount,
            domainEventMetrics: snapshot.domainEventMetrics,
            timelineCatchUpDiagnostics: snapshot.timelineCatchUpDiagnostics,
            timelineCatchUpConfiguration: IMTimelineCatchUpConfigurationSnapshot(
                selectedHintInitialJitterMilliseconds: milliseconds(
                    timelineCatchUpConfiguration.selectedHintInitialJitterNanoseconds
                ),
                selectedHintMinimumIntervalMilliseconds: milliseconds(
                    timelineCatchUpConfiguration.selectedHintMinimumIntervalNanoseconds
                ),
                selectedHintMicroBatchMilliseconds: milliseconds(
                    timelineCatchUpConfiguration.selectedHintMicroBatchNanoseconds
                )
            )
        )
    }

    private func milliseconds(_ nanoseconds: UInt64) -> Int {
        Int((Double(nanoseconds) / 1_000_000).rounded())
    }
}
