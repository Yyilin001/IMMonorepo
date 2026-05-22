import Foundation
import IMClientKit

@MainActor
extension AuthManager {
    func reconnectIMConnection() async {
        guard currentUser != nil else {
            return
        }

        await disconnectIMConnection()
        scheduleIMConnectionIfNeeded()
    }


    func blockUser(_ userID: UUID, reason: String? = nil) async -> Bool {
        await contactRuntimeController.blockUser(userID, reason: reason)
    }

    func unblockUser(_ userID: UUID) async -> Bool {
        await contactRuntimeController.unblockUser(userID)
    }

    func loadBlockedUsers() async {
        await contactRuntimeController.loadBlockedUsers()
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
        guard currentUser != nil else {
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
        contactRuntimeController.markIncomingRequestsSeen()
    }
}
