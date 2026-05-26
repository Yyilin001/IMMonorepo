import Foundation
import IMClientKit
import SwiftUI
import UIKit

@MainActor
extension AuthManager {
    func sendDirectConversationFriendRequestResult(conversationID: String) async -> ContactOperationResult {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return setDirectRelationshipResult(
                .failure("暂时无法识别会话信息。"),
                conversationID: trimmedConversationID
            )
        }

        guard !sendingDirectConversationFriendRequestConversationIDs.contains(trimmedConversationID) else {
            return setDirectRelationshipResult(
                .warning("好友申请正在发送。"),
                conversationID: trimmedConversationID
            )
        }

        guard let peer = await ensureDirectConversationPeer(for: trimmedConversationID) else {
            return setDirectRelationshipResult(
                .failure("暂时无法识别对方信息。"),
                conversationID: trimmedConversationID
            )
        }

        sendingDirectConversationFriendRequestConversationIDs.insert(trimmedConversationID)
        clearDirectConversationRelationshipNotice(for: trimmedConversationID)
        defer {
            sendingDirectConversationFriendRequestConversationIDs.remove(trimmedConversationID)
        }

        let result = await sendContactRequestResult(email: peer.email)
        return setDirectRelationshipResult(
            normalizeDirectResult(result, fallback: "好友申请发送失败。"),
            conversationID: trimmedConversationID
        )
    }

    func acceptDirectConversationFriendRequestResult(
        conversationID: String,
        remark: String? = nil
    ) async -> ContactOperationResult {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let requestID = await directConversationPendingRequestID(
            conversationID: trimmedConversationID,
            direction: .incoming,
            reloadIfMissing: true
        ) else {
            return setDirectRelationshipResult(
                .warning("当前没有可接受的好友申请。"),
                conversationID: trimmedConversationID
            )
        }

        clearDirectConversationRelationshipNotice(for: trimmedConversationID)
        let result = await acceptContactRequestResult(id: requestID, remark: remark)
        return setDirectRelationshipResult(
            normalizeDirectResult(result, fallback: "好友申请处理失败。"),
            conversationID: trimmedConversationID
        )
    }

    func declineDirectConversationFriendRequestResult(conversationID: String) async -> ContactOperationResult {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let requestID = await directConversationPendingRequestID(
            conversationID: trimmedConversationID,
            direction: .incoming,
            reloadIfMissing: true
        ) else {
            return setDirectRelationshipResult(
                .warning("当前没有可拒绝的好友申请。"),
                conversationID: trimmedConversationID
            )
        }

        clearDirectConversationRelationshipNotice(for: trimmedConversationID)
        let result = await declineContactRequestResult(id: requestID)
        return setDirectRelationshipResult(
            normalizeDirectResult(result, fallback: "好友申请处理失败。"),
            conversationID: trimmedConversationID
        )
    }

    func cancelDirectConversationFriendRequestResult(conversationID: String) async -> ContactOperationResult {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let requestID = await directConversationPendingRequestID(
            conversationID: trimmedConversationID,
            direction: .outgoing,
            reloadIfMissing: true
        ) else {
            return setDirectRelationshipResult(
                .warning("当前没有可取消的好友申请。"),
                conversationID: trimmedConversationID
            )
        }

        clearDirectConversationRelationshipNotice(for: trimmedConversationID)
        let result = await cancelContactRequestResult(id: requestID)
        return setDirectRelationshipResult(
            normalizeDirectResult(result, fallback: "好友申请处理失败。"),
            conversationID: trimmedConversationID
        )
    }

    func setDirectRelationshipNotice(
        _ result: ContactOperationResult,
        conversationID: String
    ) {
        guard !result.message.isEmpty else {
            return
        }
        contactStore.setDirectRelationshipNotice(result.message, conversationID: conversationID, tone: result.tone)
    }

    private func setDirectRelationshipResult(
        _ result: ContactOperationResult,
        conversationID: String
    ) -> ContactOperationResult {
        setDirectRelationshipNotice(result, conversationID: conversationID)
        return result
    }

    private func normalizeDirectResult(
        _ result: ContactOperationResult,
        fallback: String
    ) -> ContactOperationResult {
        guard result.message.isEmpty else {
            return result
        }
        if result.succeeded {
            return .success(fallback)
        }
        return .failure(fallback)
    }

    private func clearDirectConversationRelationshipNotice(for conversationID: String) {
        contactStore.clearDirectRelationshipNotice(conversationID: conversationID)
    }

    private enum DirectConversationFriendRequestDirection {
        case incoming
        case outgoing
    }

    private func directConversationPendingRequestID(
        conversationID: String,
        direction: DirectConversationFriendRequestDirection,
        reloadIfMissing: Bool
    ) async -> UUID? {
        if let requestID = directConversationPendingRequestIDFromCache(
            conversationID: conversationID,
            direction: direction
        ) {
            return requestID
        }

        guard reloadIfMissing else {
            return nil
        }

        await reloadContactRequests()
        guard !Task.isCancelled else {
            return nil
        }

        return directConversationPendingRequestIDFromCache(
            conversationID: conversationID,
            direction: direction
        )
    }

    private func directConversationPendingRequestIDFromCache(
        conversationID: String,
        direction: DirectConversationFriendRequestDirection
    ) -> UUID? {
        guard let conversation = imConversationStore.conversations.first(where: { $0.id == conversationID }),
              conversation.kind == .direct,
              let peer = conversation.directPeer
        else {
            return nil
        }

        switch direction {
        case .incoming:
            return contactStore.contactRequests.first {
                $0.status == .pending && $0.requester.id == peer.id
            }?.id
        case .outgoing:
            return contactStore.contactRequests.first {
                $0.status == .pending && $0.addressee.id == peer.id
            }?.id
        }
    }
}
