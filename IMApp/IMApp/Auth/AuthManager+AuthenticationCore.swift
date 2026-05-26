import Foundation
import IMClientKit
import SwiftUI
import UIKit

@MainActor
extension AuthManager {
    func authenticate(action: SessionFacade.Action, email: String, password: String) async {
        await sessionRuntimeController.authenticate(action: action, email: email, password: password)
    }

    func clearSession(message: String?) async {
        await sessionRuntimeController.clearSession(message: message)
    }

    func applySignedInState(_ user: AuthUser) {
        sessionRuntimeController.applySignedInState(user)
    }

    func replaceSignedInUser(_ user: AuthUser) {
        sessionRuntimeController.replaceSignedInUser(user)
    }

    func resetApplicationStateForSignedOut(signedOutUserID: UUID?) async {
        imConversationListTask?.cancel()
        imConversationListTask = nil
        contactRuntimeController.cancelRuntimeTasksForSignedOut()
        imConversationCachePersistTask?.cancel()
        imConversationCachePersistTask = nil
        lastIMConversationSummaryRefreshAt = nil
        imConversationSummarySyncToken = nil
        latestIMConversationSummaries = []
        lastContactStateRefreshAt = nil
        lastSeenIncomingContactRequestAt = nil
        await conversationRuntimeController.resetForSignedOut(flushCache: false)
        probeManager.stopAllForSignedOut()
        fileTransferManager.stopAllForSignedOut()
        await sessionFacade.clearSession()
        if let signedOutUserID {
            try? await imConversationCache.clearSnapshot(for: signedOutUserID)
            try? await sessionFacade.clearContactStateCacheSnapshot(for: signedOutUserID)
        } else {
            try? await imConversationCache.clearAll()
            try? await sessionFacade.clearAllContactStateCacheSnapshots()
        }
        imConversationStore.reset()
        sessions = []
        sessionsMessage = nil
        contactStore.resetForSignedOut()
        isUpdatingProfile = false
        profileMessage = nil
        serverStatus = .unknown
        setIMConnectionStatus(.disconnected)
    }

    func startSignedInFeatures(for user: AuthUser) {
        profileMessage = nil
        scheduleIMConnectionIfNeeded()
        scheduleIMConversationBootstrap(for: user)
        Task { [weak self] in
            await self?.restoreContactStateCacheIfAvailable(for: user)
            await self?.reloadContacts()
            await self?.reloadContactRequests()
            await self?.loadBlockedUsers()
        }
    }
}
