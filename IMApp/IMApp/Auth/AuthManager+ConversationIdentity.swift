import Combine
import Foundation
import IMClientKit
import SwiftUI
import UIKit

@MainActor
extension AuthManager {
    var currentUser: AuthUser? {
        sessionStore.currentUser
    }

    func conversationIdentityPresentation(
        for conversationID: String
    ) -> IMConversationIdentityPresentation? {
        guard let conversation = imConversationStore.conversations.first(where: { $0.id == conversationID }) else {
            return nil
        }

        return conversationIdentityPresentation(for: conversation)
    }

    func conversationIdentityPresentation(
        for conversation: IMConversation
    ) -> IMConversationIdentityPresentation {
        let fallbackTitle = normalizedConversationTitle(conversation.title, conversationID: conversation.id)

        guard conversation.kind == .direct,
              let currentUser
        else {
            let groupSummary = groupConversationSummary(for: conversation)
            return IMConversationIdentityPresentation(
                title: fallbackTitle,
                detailSummary: groupSummary,
                rowSecondaryLabel: conversation.members.isEmpty ? nil : groupSummary
            )
        }

        guard let peer = directConversationPeer(in: conversation, currentUserID: currentUser.id) else {
            let fallbackSummary = conversationStoreIsLoadingDirectPeer(for: conversation.id)
                ? "正在加载对方信息"
                : "当前还没有成员信息"
            return IMConversationIdentityPresentation(
                title: fallbackTitle,
                detailSummary: fallbackSummary,
                rowSecondaryLabel: nil
            )
        }

        let contact = contacts.first(where: { $0.id == peer.id })
        let contactTitle = contact?.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPeerEmail = peer.email.trimmingCharacters(in: .whitespacesAndNewlines)

        let title: String
        if let contactTitle, !contactTitle.isEmpty {
            title = contactTitle
        } else if !normalizedPeerEmail.isEmpty {
            title = normalizedPeerEmail
        } else {
            title = fallbackTitle
        }

        let detailSummary: String
        if !normalizedPeerEmail.isEmpty {
            detailSummary = normalizedPeerEmail
        } else {
            detailSummary = fallbackSummary(for: conversation)
        }

        let rowSecondaryLabel: String?
        if !normalizedPeerEmail.isEmpty && normalizedPeerEmail != title {
            rowSecondaryLabel = normalizedPeerEmail
        } else {
            rowSecondaryLabel = nil
        }

        return IMConversationIdentityPresentation(
            title: title,
            detailSummary: detailSummary,
            rowSecondaryLabel: rowSecondaryLabel
        )
    }

    func directPeerRelationshipPresentation(for conversationID: String) -> DirectPeerRelationshipPresentation? {
        guard let currentUser,
              let conversation = imConversationStore.conversations.first(where: { $0.id == conversationID }),
              conversation.kind == .direct,
              conversation.isDirectMessagingFrozen
        else {
            return nil
        }

        if sendingDirectConversationFriendRequestConversationIDs.contains(conversationID) {
            return DirectPeerRelationshipPresentation(
                state: .resolving,
                message: "正在发送好友申请…",
                peerUserID: nil,
                peerEmail: nil,
                requestID: nil
            )
        }

        guard let peer = directConversationPeer(in: conversation, currentUserID: currentUser.id) else {
            let message = conversationStoreIsLoadingDirectPeer(for: conversationID)
                ? "正在加载对方信息…"
                : "暂时无法识别对方信息。"
            return DirectPeerRelationshipPresentation(
                state: .unavailable,
                message: message,
                peerUserID: nil,
                peerEmail: nil,
                requestID: nil
            )
        }

        if contacts.contains(where: { $0.id == peer.id }) {
            return DirectPeerRelationshipPresentation(
                state: .friend,
                message: "好友关系已恢复，等待当前会话状态同步。",
                peerUserID: peer.id,
                peerEmail: peer.email,
                requestID: nil
            )
        }

        if let request = incomingPendingContactRequests.first(where: {
            $0.requester.id == peer.id && $0.addressee.id == currentUser.id
        }) {
            if acceptingRequestIDs.contains(request.id) || decliningRequestIDs.contains(request.id) {
                return DirectPeerRelationshipPresentation(
                    state: .resolving,
                    message: "正在处理好友申请…",
                    peerUserID: peer.id,
                    peerEmail: peer.email,
                    requestID: request.id
                )
            }

            return DirectPeerRelationshipPresentation(
                state: .incomingPending,
                message: "对方向你发来了好友申请。",
                peerUserID: peer.id,
                peerEmail: peer.email,
                requestID: request.id
            )
        }

        if let request = outgoingPendingContactRequests.first(where: {
            $0.requester.id == currentUser.id && $0.addressee.id == peer.id
        }) {
            if cancellingRequestIDs.contains(request.id) {
                return DirectPeerRelationshipPresentation(
                    state: .resolving,
                    message: "正在取消好友申请…",
                    peerUserID: peer.id,
                    peerEmail: peer.email,
                    requestID: request.id
                )
            }

            return DirectPeerRelationshipPresentation(
                state: .outgoingPending,
                message: "已发送好友申请，等待对方处理。",
                peerUserID: peer.id,
                peerEmail: peer.email,
                requestID: request.id
            )
        }

        return DirectPeerRelationshipPresentation(
            state: .none,
            message: "添加好友后可继续在当前会话发送消息。",
            peerUserID: peer.id,
            peerEmail: peer.email,
            requestID: nil
        )
    }

    func directConversationRelationshipActionMessage(for conversationID: String) -> String? {
        directConversationRelationshipActionMessages[conversationID]
    }
}
