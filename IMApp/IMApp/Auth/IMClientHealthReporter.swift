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
        let snapshot = imConversationStore.healthSnapshot
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
}
