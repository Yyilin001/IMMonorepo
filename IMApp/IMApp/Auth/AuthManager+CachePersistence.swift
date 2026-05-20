import Combine
import Foundation
import IMClientKit
import SwiftUI
import UIKit

@MainActor
extension AuthManager {
    func restoreContactStateCacheIfAvailable(for user: AuthUser) async {
        do {
            let snapshot = try await sessionFacade.loadContactStateCacheSnapshot(for: user.id)
            guard currentUser?.id == user.id else {
                return
            }

            contacts = snapshot.contacts.map(\.contact).sorted { $0.email < $1.email }
            contactRequests = sessionFacade.normalizeRequests(
                snapshot.incomingRequests.map(\.request)
                    + snapshot.outgoingRequests.map(\.request)
                    + snapshot.resolvedRequests.map(\.request),
                currentUserID: user.id
            )
            lastContactStateRefreshAt = snapshot.lastRefreshAt
            lastSeenIncomingContactRequestAt = snapshot.lastSeenIncomingContactRequestAt
            recomputeIncomingContactRequestUnreadState()
        } catch {
            // Ignore cache restore failures and fall back to HTTP recovery.
        }
    }

    func restoreIMConversationCacheIfAvailable(for user: AuthUser) async {
        do {
            let snapshot = try await imConversationCache.loadSnapshot(for: user.id)
            guard currentUser?.id == user.id else {
                return
            }

            guard !snapshot.conversations.isEmpty else {
                return
            }

            imConversationStore.restoreCacheSnapshot(snapshot)
            conversationRuntimeController.restoreTransferSnapshots(snapshot.transferSnapshots)
            conversationRuntimeController.resumeRecoverableMediaUploadsIfNeeded()
            conversationRuntimeController.reconcileBackgroundMediaDownloadSnapshots()
            conversationRuntimeController.syncActiveMessageStreamSnapshots()
            lastIMConversationSummaryRefreshAt = snapshot.lastSummaryRefreshAt
            imConversationSummarySyncToken = snapshot.metadata.summarySyncToken
            latestIMConversationSummaries = []
        } catch {
            // Ignore cache restore failures and continue with network bootstrap.
        }
    }

    func scheduleIMConversationCachePersist() {
        guard currentUser != nil else {
            return
        }

        imConversationCachePersistTask?.cancel()
        imConversationCachePersistTask = Task { [weak self] in
            guard let self else {
                return
            }

            try? await Task.sleep(nanoseconds: IMHistoryPage.cachePersistDebounceNanoseconds)

            guard !Task.isCancelled else {
                return
            }

            await self.flushIMConversationCache()
        }
    }

    func persistIMConversationCacheSoon() {
        scheduleIMConversationCachePersist()
    }

    func flushIMConversationCache() async {
        let task = imConversationCachePersistTask
        imConversationCachePersistTask = nil
        task?.cancel()

        guard let user = currentUser else {
            return
        }

        let snapshot = imConversationStore.makeCacheSnapshot(
            lastSummaryRefreshAt: lastIMConversationSummaryRefreshAt,
            summarySyncToken: imConversationSummarySyncToken,
            transferSnapshots: conversationRuntimeController.cachedTransferSnapshots()
        )
        try? await imConversationCache.saveSnapshot(snapshot, for: user.id)
    }
}
