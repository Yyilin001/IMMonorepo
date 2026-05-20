import Combine
import Foundation
import IMClientKit
import SwiftUI
import UIKit

@MainActor
extension AuthManager {
    func sendDirectConversationFriendRequest(conversationID: String) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return false
        }

        guard !sendingDirectConversationFriendRequestConversationIDs.contains(trimmedConversationID) else {
            return false
        }

        guard let peer = await ensureDirectConversationPeer(for: trimmedConversationID) else {
            setDirectConversationRelationshipActionMessage("暂时无法识别对方信息。", for: trimmedConversationID)
            return false
        }

        sendingDirectConversationFriendRequestConversationIDs.insert(trimmedConversationID)
        setDirectConversationRelationshipActionMessage(nil, for: trimmedConversationID)
        contactRequestActionMessage = nil
        defer {
            sendingDirectConversationFriendRequestConversationIDs.remove(trimmedConversationID)
            contactRequestActionMessage = nil
        }

        let didSend = await sendContactRequest(email: peer.email)
        let message = contactRequestActionMessage ?? (didSend ? "好友申请已发送。" : "好友申请发送失败。")
        setDirectConversationRelationshipActionMessage(message, for: trimmedConversationID)
        return didSend
    }

    func acceptDirectConversationFriendRequest(conversationID: String, remark: String? = nil) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let relationship = directPeerRelationshipPresentation(for: trimmedConversationID),
              relationship.state == .incomingPending,
              let requestID = relationship.requestID
        else {
            setDirectConversationRelationshipActionMessage("当前没有可接受的好友申请。", for: trimmedConversationID)
            return false
        }

        setDirectConversationRelationshipActionMessage(nil, for: trimmedConversationID)
        contactRequestActionMessage = nil
        let didAccept = await acceptContactRequest(id: requestID, remark: remark)
        let message = contactRequestActionMessage ?? (didAccept ? "已添加好友。" : "好友申请处理失败。")
        contactRequestActionMessage = nil
        setDirectConversationRelationshipActionMessage(message, for: trimmedConversationID)
        return didAccept
    }

    func declineDirectConversationFriendRequest(conversationID: String) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let relationship = directPeerRelationshipPresentation(for: trimmedConversationID),
              relationship.state == .incomingPending,
              let requestID = relationship.requestID
        else {
            setDirectConversationRelationshipActionMessage("当前没有可拒绝的好友申请。", for: trimmedConversationID)
            return false
        }

        setDirectConversationRelationshipActionMessage(nil, for: trimmedConversationID)
        contactRequestActionMessage = nil
        let didDecline = await declineContactRequest(id: requestID)
        let message = contactRequestActionMessage ?? (didDecline ? "已拒绝好友申请。" : "好友申请处理失败。")
        contactRequestActionMessage = nil
        setDirectConversationRelationshipActionMessage(message, for: trimmedConversationID)
        return didDecline
    }

    func cancelDirectConversationFriendRequest(conversationID: String) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let relationship = directPeerRelationshipPresentation(for: trimmedConversationID),
              relationship.state == .outgoingPending,
              let requestID = relationship.requestID
        else {
            setDirectConversationRelationshipActionMessage("当前没有可取消的好友申请。", for: trimmedConversationID)
            return false
        }

        setDirectConversationRelationshipActionMessage(nil, for: trimmedConversationID)
        contactRequestActionMessage = nil
        let didCancel = await cancelContactRequest(id: requestID)
        let message = contactRequestActionMessage ?? (didCancel ? "好友申请已取消。" : "好友申请处理失败。")
        contactRequestActionMessage = nil
        setDirectConversationRelationshipActionMessage(message, for: trimmedConversationID)
        return didCancel
    }
}
