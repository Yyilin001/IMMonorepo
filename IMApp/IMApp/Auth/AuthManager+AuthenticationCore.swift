import Combine
import Foundation
import IMClientKit
import SwiftUI
import UIKit

@MainActor
extension AuthManager {
    func authenticate(action: SessionFacade.Action, email: String, password: String) async {
        guard !isBusy else {
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let device = Self.deviceMetadata()
            let user = try await sessionFacade.authenticate(
                action: action,
                email: email,
                password: password,
                device: device
            )

            markServerOnline()
            sessionsMessage = nil
            applySignedInState(user)
        } catch {
            if await shouldPreserveSession(for: error) {
                await markServerUnavailableIfNeeded(for: error)
            }
            phase = .signedOut(message: error.localizedDescription)
        }
    }

    func clearSession(message: String?) async {
        let signedOutUserID = currentUser?.id
        imConversationListTask?.cancel()
        imConversationListTask = nil
        contactStateCorrectionTask?.cancel()
        contactStateCorrectionTask = nil
        imConversationCachePersistTask?.cancel()
        imConversationCachePersistTask = nil
        contactStateCachePersistTask?.cancel()
        contactStateCachePersistTask = nil
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
        contacts = []
        contactsMessage = nil
        isLoadingContacts = false
        contactRequests = []
        unseenIncomingContactRequestCount = 0
        contactRequestsLoadMessage = nil
        contactRequestActionMessage = nil
        isUpdatingProfile = false
        profileMessage = nil
        directConversationRelationshipActionMessages = [:]
        isLoadingContactRequests = false
        acceptingRequestIDs = []
        decliningRequestIDs = []
        cancellingRequestIDs = []
        sendingDirectConversationFriendRequestConversationIDs = []
        blockedUsers = []
        isLoadingBlockedUsers = false
        serverStatus = .unknown
        setIMConnectionStatus(.disconnected)
        phase = .signedOut(message: message)
    }

    func applySignedInState(_ user: AuthUser) {
        profileMessage = nil
        replaceSignedInUser(user)
        scheduleIMConnectionIfNeeded()
        scheduleIMConversationBootstrap(for: user)
        Task { [weak self] in
            await self?.restoreContactStateCacheIfAvailable(for: user)
            await self?.reloadContacts()
            await self?.reloadContactRequests()
            await self?.loadBlockedUsers()
        }
    }

    func replaceSignedInUser(_ user: AuthUser) {
        phase = .signedIn(user)
    }
}
