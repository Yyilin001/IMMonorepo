import Foundation
import IMClientKit

@MainActor
extension AuthManager {
    func reconnectIMConnection() async {
        guard case .signedIn = phase else {
            return
        }

        await disconnectIMConnection()
        scheduleIMConnectionIfNeeded()
    }


    func blockUser(_ userID: UUID, reason: String? = nil) async -> Bool {
        do {
            let block = try await sessionClient.blockUser(userID: userID, reason: reason)
            blockedUsers.removeAll { $0.blockedUserID == block.blockedUserID }
            blockedUsers.append(block)
            blockedUsers.sort { $0.createdAt > $1.createdAt }
            markServerOnline()
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }

    func unblockUser(_ userID: UUID) async -> Bool {
        do {
            _ = try await sessionClient.unblockUser(userID: userID)
            blockedUsers.removeAll { $0.blockedUserID == userID }
            markServerOnline()
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }

    func loadBlockedUsers() async {
        guard currentUser != nil else {
            return
        }

        isLoadingBlockedUsers = true
        defer {
            isLoadingBlockedUsers = false
        }

        do {
            blockedUsers = try await sessionClient.fetchBlocks()
                .sorted { $0.createdAt > $1.createdAt }
            markServerOnline()
        } catch {
            await handleIMDataRequestError(error)
        }
    }

    func createReport(
        targetType: String,
        targetID: String,
        conversationID: UUID? = nil,
        messageID: UUID? = nil,
        reason: String,
        detail: String? = nil
    ) async -> Bool {
        do {
            _ = try await sessionClient.createReport(
                targetType: targetType,
                targetID: targetID,
                conversationID: conversationID,
                messageID: messageID,
                reason: reason,
                detail: detail
            )
            markServerOnline()
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }

    func registerPushDeviceToken(_ token: String) async -> Bool {
        do {
            _ = try await sessionClient.registerPushDeviceToken(token: token)
            markServerOnline()
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }

    func appDidBecomeActive() async {
        guard case .signedIn = phase else {
            return
        }

        conversationRuntimeController.appDidBecomeActive()
        await refreshIMConversationSummaryReadModelIfNeeded()
    }

    func appDidEnterBackground() async {
        await flushIMConversationCache()
        await flushContactStateCache()
    }

    func markIncomingContactRequestsSeen() {
        if let latestIncomingContactRequestAt {
            lastSeenIncomingContactRequestAt = latestIncomingContactRequestAt
        }

        recomputeIncomingContactRequestUnreadState()
        scheduleContactStateCachePersist()
    }
}
