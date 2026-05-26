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


    func blockUserResult(_ userID: UUID, reason: String? = nil) async -> ContactOperationResult {
        await contactRuntimeController.blockUserResult(userID, reason: reason)
    }

    func unblockUserResult(_ userID: UUID) async -> ContactOperationResult {
        await contactRuntimeController.unblockUserResult(userID)
    }

    func loadBlockedUsers() async {
        await contactRuntimeController.loadBlockedUsers()
    }

    func createReportResult(
        targetType: String,
        targetID: String,
        conversationID: UUID? = nil,
        messageID: UUID? = nil,
        reason: String,
        detail: String? = nil
    ) async -> ContactOperationResult {
        do {
            _ = try await sessionClient.createReport(
                targetType: targetType,
                targetID: targetID,
                conversationID: conversationID,
                messageID: messageID,
                reason: reason,
                detail: detail
            )
            guard !Task.isCancelled else {
                return .failure("")
            }
            markServerOnline()
            return .success("举报已提交。")
        } catch {
            guard !(error is CancellationError) else {
                return .failure("")
            }
            await handleIMDataRequestError(error)
            return .failure(ContactOperationErrorMapper.message(for: error))
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
