import Fluent
import Foundation
import Vapor

enum ConversationDomainEventType: String, Codable, CaseIterable, Sendable {
    case messageCreated = "message_created"
    case messageUpdated = "message_updated"
    case messageRecalled = "message_recalled"
    case readAdvanced = "read_advanced"
    case metadataUpdated = "metadata_updated"
    case membershipAdded = "membership_added"
    case membershipRemoved = "membership_removed"
    case membershipRoleUpdated = "membership_role_updated"
    case conversationRemovedForUser = "conversation_removed_for_user"
    case directPeerUpdated = "direct_peer_updated"
    case messageVisibilityChanged = "message_visibility_changed"
    case messageFavoriteChanged = "message_favorite_changed"
    case messageStreamStarted = "message_stream_started"
    case messageStreamCompleted = "message_stream_completed"
    case messageStreamFailed = "message_stream_failed"
    case messageStreamCancelled = "message_stream_cancelled"
    case conversationVisibilityChanged = "conversation_visibility_changed"
    case conversationSettingsChanged = "conversation_settings_changed"
    case inviteChanged = "invite_changed"
}

enum ConversationDomainEventStatus: String, Codable, Sendable {
    case pending
    case processing
    case processed
    case failed
}

enum ConversationVisibilityAction: String, Codable, Equatable, Sendable {
    case messageHidden = "message_hidden"
    case conversationCleared = "conversation_cleared"
    case conversationDeleted = "conversation_deleted"
}

struct ConversationMessageCreatedPreview: Codable, Equatable, Sendable {
    let senderUserID: UUID
    let serverSequence: UInt64
    let timelineSequence: UInt64
    let previewText: String
    let createdAt: Date?
}

enum ConversationDomainEventPayload: Codable, Equatable, Sendable {
    case messageCreated(messageID: UUID, recipientUserIDs: [UUID], preview: ConversationMessageCreatedPreview? = nil)
    case messageUpdated(messageID: UUID, recipientUserIDs: [UUID])
    case messageRecalled(messageID: UUID, recipientUserIDs: [UUID])
    case messageVisibilityChanged(messageIDs: [UUID], action: ConversationVisibilityAction, affectedUserID: UUID)
    case messageFavoriteChanged(messageID: UUID, isFavorited: Bool, ownerUserID: UUID)
    case conversationCreated(recipientUserIDs: [UUID])
    case metadataUpdated(recipientUserIDs: [UUID])
    case settingsChanged(ownerUserID: UUID)
    case conversationRemovedForSelf(ownerUserID: UUID)
    case conversationVisibilityChanged(action: ConversationVisibilityAction, ownerUserID: UUID, messageIDs: [UUID])
    case directPeerUpdated(recipientUserIDs: [UUID])
    case memberAdded(memberUserIDs: [UUID], recipientUserIDs: [UUID])
    case memberRemoved(memberUserIDs: [UUID], recipientUserIDs: [UUID])
    case memberRoleUpdated(memberUserID: UUID, recipientUserIDs: [UUID])
    case readAdvanced(ownerUserID: UUID)
    case inviteChanged(recipientUserIDs: [UUID])
    case streamStarted(messageID: UUID, streamID: String, recipientUserIDs: [UUID])
    case streamCompleted(messageID: UUID, streamID: String, recipientUserIDs: [UUID])
    case streamFailed(messageID: UUID, streamID: String, recipientUserIDs: [UUID])
    case streamCancelled(messageID: UUID, streamID: String, recipientUserIDs: [UUID])

    enum Kind: String, Codable {
        case messageCreated
        case messageUpdated
        case messageRecalled
        case messageVisibilityChanged
        case messageFavoriteChanged
        case conversationCreated
        case metadataUpdated
        case settingsChanged
        case conversationRemovedForSelf
        case conversationVisibilityChanged
        case directPeerUpdated
        case memberAdded
        case memberRemoved
        case memberRoleUpdated
        case readAdvanced
        case inviteChanged
        case streamStarted
        case streamCompleted
        case streamFailed
        case streamCancelled
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case messageID
        case messageIDs
        case recipientUserIDs
        case affectedUserID
        case ownerUserID
        case memberUserIDs
        case memberUserID
        case isFavorited
        case action
        case streamID
        case messagePreview
    }

    var recipientUserIDs: [UUID] {
        switch self {
        case .messageCreated(_, let ids, _),
             .messageUpdated(_, let ids),
             .messageRecalled(_, let ids),
             .conversationCreated(let ids),
             .metadataUpdated(let ids),
             .directPeerUpdated(let ids),
             .memberAdded(_, let ids),
             .memberRemoved(_, let ids),
             .memberRoleUpdated(_, let ids),
             .inviteChanged(let ids),
             .streamStarted(_, _, let ids),
             .streamCompleted(_, _, let ids),
             .streamFailed(_, _, let ids),
             .streamCancelled(_, _, let ids):
            return ids
        case .messageVisibilityChanged(_, _, let ownerUserID),
             .messageFavoriteChanged(_, _, let ownerUserID),
             .settingsChanged(let ownerUserID),
             .conversationRemovedForSelf(let ownerUserID),
             .conversationVisibilityChanged(_, let ownerUserID, _),
             .readAdvanced(let ownerUserID):
            return [ownerUserID]
        }
    }

    var affectedUserID: UUID? {
        switch self {
        case .messageVisibilityChanged(_, _, let ownerUserID),
             .settingsChanged(let ownerUserID),
             .conversationRemovedForSelf(let ownerUserID),
             .conversationVisibilityChanged(_, let ownerUserID, _),
             .readAdvanced(let ownerUserID):
            return ownerUserID
        case .messageFavoriteChanged(_, _, let ownerUserID):
            return ownerUserID
        case .memberRemoved(let memberUserIDs, _):
            return memberUserIDs.first
        case .memberRoleUpdated(let memberUserID, _):
            return memberUserID
        case .messageCreated,
             .messageUpdated,
             .messageRecalled,
             .conversationCreated,
             .metadataUpdated,
             .directPeerUpdated,
             .memberAdded,
             .inviteChanged,
             .streamStarted,
             .streamCompleted,
             .streamFailed,
             .streamCancelled:
            return nil
        }
    }

    var messageID: UUID? {
        switch self {
        case .messageCreated(let id, _, _),
             .messageUpdated(let id, _),
             .messageRecalled(let id, _),
             .messageFavoriteChanged(let id, _, _),
             .streamStarted(let id, _, _),
             .streamCompleted(let id, _, _),
             .streamFailed(let id, _, _),
             .streamCancelled(let id, _, _):
            return id
        case .messageVisibilityChanged,
             .conversationCreated,
             .metadataUpdated,
             .settingsChanged,
             .conversationRemovedForSelf,
             .conversationVisibilityChanged,
             .directPeerUpdated,
             .memberAdded,
             .memberRemoved,
             .memberRoleUpdated,
             .readAdvanced,
             .inviteChanged:
            return nil
        }
    }

    var messageIDs: [UUID] {
        switch self {
        case .messageVisibilityChanged(let ids, _, _),
             .conversationVisibilityChanged(_, _, let ids):
            return ids
        case .messageCreated,
             .messageUpdated,
             .messageRecalled,
             .messageFavoriteChanged,
             .conversationCreated,
             .metadataUpdated,
             .settingsChanged,
             .conversationRemovedForSelf,
             .directPeerUpdated,
             .memberAdded,
             .memberRemoved,
             .memberRoleUpdated,
             .readAdvanced,
             .inviteChanged,
             .streamStarted,
             .streamCompleted,
             .streamFailed,
             .streamCancelled:
            return messageID.map { [$0] } ?? []
        }
    }

    var favoriteChangedMessageID: UUID? {
        guard case .messageFavoriteChanged(let id, _, _) = self else {
            return nil
        }
        return id
    }

    var messageCreatedPreview: ConversationMessageCreatedPreview? {
        guard case .messageCreated(_, _, let preview) = self else {
            return nil
        }
        return preview
    }

    var isFavorited: Bool? {
        guard case .messageFavoriteChanged(_, let value, _) = self else {
            return nil
        }
        return value
    }

    var visibilityAction: ConversationVisibilityAction? {
        switch self {
        case .messageVisibilityChanged(_, let action, _),
             .conversationVisibilityChanged(let action, _, _):
            return action
        case .messageCreated,
             .messageUpdated,
             .messageRecalled,
             .messageFavoriteChanged,
             .conversationCreated,
             .metadataUpdated,
             .settingsChanged,
             .conversationRemovedForSelf,
             .directPeerUpdated,
             .memberAdded,
             .memberRemoved,
             .memberRoleUpdated,
             .readAdvanced,
             .inviteChanged,
             .streamStarted,
             .streamCompleted,
             .streamFailed,
             .streamCancelled:
            return nil
        }
    }

    var memberUserIDs: [UUID] {
        switch self {
        case .memberAdded(let ids, _), .memberRemoved(let ids, _):
            return ids
        case .memberRoleUpdated(let id, _):
            return [id]
        default:
            return []
        }
    }

    var streamID: String? {
        switch self {
        case .streamStarted(_, let id, _),
             .streamCompleted(_, let id, _),
             .streamFailed(_, let id, _),
             .streamCancelled(_, let id, _):
            return id
        default:
            return nil
        }
    }

    func validate(for eventType: ConversationDomainEventType) throws {
        switch (eventType, self) {
        case (.messageCreated, .messageCreated),
             (.messageUpdated, .messageUpdated),
             (.messageRecalled, .messageRecalled),
             (.messageVisibilityChanged, .messageVisibilityChanged),
             (.messageFavoriteChanged, .messageFavoriteChanged),
             (.metadataUpdated, .metadataUpdated),
             (.conversationSettingsChanged, .settingsChanged),
             (.conversationRemovedForUser, .conversationRemovedForSelf),
             (.conversationVisibilityChanged, .conversationVisibilityChanged),
             (.directPeerUpdated, .directPeerUpdated),
             (.membershipAdded, .memberAdded),
             (.membershipRemoved, .memberRemoved),
             (.membershipRoleUpdated, .memberRoleUpdated),
             (.readAdvanced, .readAdvanced),
             (.inviteChanged, .inviteChanged),
             (.messageStreamStarted, .streamStarted),
             (.messageStreamCompleted, .streamCompleted),
             (.messageStreamFailed, .streamFailed),
             (.messageStreamCancelled, .streamCancelled):
            break
        default:
            throw Abort(.internalServerError, reason: "领域事件 payload 与事件类型不匹配。")
        }

        switch self {
        case .messageCreated(let messageID, _, _):
            try Self.require(messageID)
        case .messageUpdated(let messageID, let recipients),
             .messageRecalled(let messageID, let recipients):
            try Self.require(messageID)
            try Self.requireRecipients(recipients)
        case .messageVisibilityChanged(let messageIDs, _, let ownerUserID):
            try Self.require(ownerUserID)
            guard !messageIDs.isEmpty else {
                throw Abort(.internalServerError, reason: "消息可见性事件缺少 messageIDs。")
            }
        case .messageFavoriteChanged(let messageID, _, let ownerUserID):
            try Self.require(messageID)
            try Self.require(ownerUserID)
        case .conversationCreated(let recipients),
             .metadataUpdated(let recipients),
             .directPeerUpdated(let recipients),
             .inviteChanged(let recipients):
            try Self.requireRecipients(recipients)
        case .settingsChanged(let ownerUserID),
             .conversationRemovedForSelf(let ownerUserID),
             .readAdvanced(let ownerUserID):
            try Self.require(ownerUserID)
        case .conversationVisibilityChanged(_, let ownerUserID, _):
            try Self.require(ownerUserID)
        case .memberAdded(let memberUserIDs, let recipients),
             .memberRemoved(let memberUserIDs, let recipients):
            guard !memberUserIDs.isEmpty else {
                throw Abort(.internalServerError, reason: "成员事件缺少 memberUserIDs。")
            }
            try Self.requireRecipients(recipients)
        case .memberRoleUpdated(let memberUserID, let recipients):
            try Self.require(memberUserID)
            try Self.requireRecipients(recipients)
        case .streamStarted(let messageID, let streamID, let recipients),
             .streamCompleted(let messageID, let streamID, let recipients),
             .streamFailed(let messageID, let streamID, let recipients),
             .streamCancelled(let messageID, let streamID, let recipients):
            try Self.require(messageID)
            guard !streamID.isEmpty else {
                throw Abort(.internalServerError, reason: "流式事件缺少 streamID。")
            }
            try Self.requireRecipients(recipients)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .messageCreated:
            self = .messageCreated(
                messageID: try container.decode(UUID.self, forKey: .messageID),
                recipientUserIDs: try container.decode([UUID].self, forKey: .recipientUserIDs),
                preview: try container.decodeIfPresent(ConversationMessageCreatedPreview.self, forKey: .messagePreview)
            )
        case .messageUpdated:
            self = .messageUpdated(
                messageID: try container.decode(UUID.self, forKey: .messageID),
                recipientUserIDs: try container.decode([UUID].self, forKey: .recipientUserIDs)
            )
        case .messageRecalled:
            self = .messageRecalled(
                messageID: try container.decode(UUID.self, forKey: .messageID),
                recipientUserIDs: try container.decode([UUID].self, forKey: .recipientUserIDs)
            )
        case .messageVisibilityChanged:
            self = .messageVisibilityChanged(
                messageIDs: try container.decode([UUID].self, forKey: .messageIDs),
                action: try container.decode(ConversationVisibilityAction.self, forKey: .action),
                affectedUserID: try container.decode(UUID.self, forKey: .affectedUserID)
            )
        case .messageFavoriteChanged:
            self = .messageFavoriteChanged(
                messageID: try container.decode(UUID.self, forKey: .messageID),
                isFavorited: try container.decode(Bool.self, forKey: .isFavorited),
                ownerUserID: try container.decode(UUID.self, forKey: .ownerUserID)
            )
        case .conversationCreated:
            self = .conversationCreated(recipientUserIDs: try container.decode([UUID].self, forKey: .recipientUserIDs))
        case .metadataUpdated:
            self = .metadataUpdated(recipientUserIDs: try container.decode([UUID].self, forKey: .recipientUserIDs))
        case .settingsChanged:
            self = .settingsChanged(ownerUserID: try container.decode(UUID.self, forKey: .ownerUserID))
        case .conversationRemovedForSelf:
            self = .conversationRemovedForSelf(ownerUserID: try container.decode(UUID.self, forKey: .ownerUserID))
        case .conversationVisibilityChanged:
            self = .conversationVisibilityChanged(
                action: try container.decode(ConversationVisibilityAction.self, forKey: .action),
                ownerUserID: try container.decode(UUID.self, forKey: .ownerUserID),
                messageIDs: try container.decodeIfPresent([UUID].self, forKey: .messageIDs) ?? []
            )
        case .directPeerUpdated:
            self = .directPeerUpdated(recipientUserIDs: try container.decode([UUID].self, forKey: .recipientUserIDs))
        case .memberAdded:
            self = .memberAdded(
                memberUserIDs: try container.decode([UUID].self, forKey: .memberUserIDs),
                recipientUserIDs: try container.decode([UUID].self, forKey: .recipientUserIDs)
            )
        case .memberRemoved:
            self = .memberRemoved(
                memberUserIDs: try container.decode([UUID].self, forKey: .memberUserIDs),
                recipientUserIDs: try container.decode([UUID].self, forKey: .recipientUserIDs)
            )
        case .memberRoleUpdated:
            self = .memberRoleUpdated(
                memberUserID: try container.decode(UUID.self, forKey: .memberUserID),
                recipientUserIDs: try container.decode([UUID].self, forKey: .recipientUserIDs)
            )
        case .readAdvanced:
            self = .readAdvanced(ownerUserID: try container.decode(UUID.self, forKey: .ownerUserID))
        case .inviteChanged:
            self = .inviteChanged(recipientUserIDs: try container.decode([UUID].self, forKey: .recipientUserIDs))
        case .streamStarted:
            self = .streamStarted(
                messageID: try container.decode(UUID.self, forKey: .messageID),
                streamID: try container.decode(String.self, forKey: .streamID),
                recipientUserIDs: try container.decode([UUID].self, forKey: .recipientUserIDs)
            )
        case .streamCompleted:
            self = .streamCompleted(
                messageID: try container.decode(UUID.self, forKey: .messageID),
                streamID: try container.decode(String.self, forKey: .streamID),
                recipientUserIDs: try container.decode([UUID].self, forKey: .recipientUserIDs)
            )
        case .streamFailed:
            self = .streamFailed(
                messageID: try container.decode(UUID.self, forKey: .messageID),
                streamID: try container.decode(String.self, forKey: .streamID),
                recipientUserIDs: try container.decode([UUID].self, forKey: .recipientUserIDs)
            )
        case .streamCancelled:
            self = .streamCancelled(
                messageID: try container.decode(UUID.self, forKey: .messageID),
                streamID: try container.decode(String.self, forKey: .streamID),
                recipientUserIDs: try container.decode([UUID].self, forKey: .recipientUserIDs)
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .messageCreated(let messageID, let recipients, let preview):
            try container.encode(Kind.messageCreated, forKey: .kind)
            try container.encode(messageID, forKey: .messageID)
            try container.encode(recipients, forKey: .recipientUserIDs)
            try container.encodeIfPresent(preview, forKey: .messagePreview)
        case .messageUpdated(let messageID, let recipients):
            try container.encode(Kind.messageUpdated, forKey: .kind)
            try container.encode(messageID, forKey: .messageID)
            try container.encode(recipients, forKey: .recipientUserIDs)
        case .messageRecalled(let messageID, let recipients):
            try container.encode(Kind.messageRecalled, forKey: .kind)
            try container.encode(messageID, forKey: .messageID)
            try container.encode(recipients, forKey: .recipientUserIDs)
        case .messageVisibilityChanged(let messageIDs, let action, let affectedUserID):
            try container.encode(Kind.messageVisibilityChanged, forKey: .kind)
            try container.encode(messageIDs, forKey: .messageIDs)
            try container.encode(action, forKey: .action)
            try container.encode(affectedUserID, forKey: .affectedUserID)
        case .messageFavoriteChanged(let messageID, let isFavorited, let ownerUserID):
            try container.encode(Kind.messageFavoriteChanged, forKey: .kind)
            try container.encode(messageID, forKey: .messageID)
            try container.encode(isFavorited, forKey: .isFavorited)
            try container.encode(ownerUserID, forKey: .ownerUserID)
        case .conversationCreated(let recipients):
            try container.encode(Kind.conversationCreated, forKey: .kind)
            try container.encode(recipients, forKey: .recipientUserIDs)
        case .metadataUpdated(let recipients):
            try container.encode(Kind.metadataUpdated, forKey: .kind)
            try container.encode(recipients, forKey: .recipientUserIDs)
        case .settingsChanged(let ownerUserID):
            try container.encode(Kind.settingsChanged, forKey: .kind)
            try container.encode(ownerUserID, forKey: .ownerUserID)
        case .conversationRemovedForSelf(let ownerUserID):
            try container.encode(Kind.conversationRemovedForSelf, forKey: .kind)
            try container.encode(ownerUserID, forKey: .ownerUserID)
        case .conversationVisibilityChanged(let action, let ownerUserID, let messageIDs):
            try container.encode(Kind.conversationVisibilityChanged, forKey: .kind)
            try container.encode(action, forKey: .action)
            try container.encode(ownerUserID, forKey: .ownerUserID)
            try container.encode(messageIDs, forKey: .messageIDs)
        case .directPeerUpdated(let recipients):
            try container.encode(Kind.directPeerUpdated, forKey: .kind)
            try container.encode(recipients, forKey: .recipientUserIDs)
        case .memberAdded(let memberUserIDs, let recipients):
            try container.encode(Kind.memberAdded, forKey: .kind)
            try container.encode(memberUserIDs, forKey: .memberUserIDs)
            try container.encode(recipients, forKey: .recipientUserIDs)
        case .memberRemoved(let memberUserIDs, let recipients):
            try container.encode(Kind.memberRemoved, forKey: .kind)
            try container.encode(memberUserIDs, forKey: .memberUserIDs)
            try container.encode(recipients, forKey: .recipientUserIDs)
        case .memberRoleUpdated(let memberUserID, let recipients):
            try container.encode(Kind.memberRoleUpdated, forKey: .kind)
            try container.encode(memberUserID, forKey: .memberUserID)
            try container.encode(recipients, forKey: .recipientUserIDs)
        case .readAdvanced(let ownerUserID):
            try container.encode(Kind.readAdvanced, forKey: .kind)
            try container.encode(ownerUserID, forKey: .ownerUserID)
        case .inviteChanged(let recipients):
            try container.encode(Kind.inviteChanged, forKey: .kind)
            try container.encode(recipients, forKey: .recipientUserIDs)
        case .streamStarted(let messageID, let streamID, let recipients):
            try encodeStream(.streamStarted, messageID: messageID, streamID: streamID, recipients: recipients, into: &container)
        case .streamCompleted(let messageID, let streamID, let recipients):
            try encodeStream(.streamCompleted, messageID: messageID, streamID: streamID, recipients: recipients, into: &container)
        case .streamFailed(let messageID, let streamID, let recipients):
            try encodeStream(.streamFailed, messageID: messageID, streamID: streamID, recipients: recipients, into: &container)
        case .streamCancelled(let messageID, let streamID, let recipients):
            try encodeStream(.streamCancelled, messageID: messageID, streamID: streamID, recipients: recipients, into: &container)
        }
    }

    private func encodeStream(
        _ kind: Kind,
        messageID: UUID,
        streamID: String,
        recipients: [UUID],
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        try container.encode(kind, forKey: .kind)
        try container.encode(messageID, forKey: .messageID)
        try container.encode(streamID, forKey: .streamID)
        try container.encode(recipients, forKey: .recipientUserIDs)
    }

    private static func requireRecipients(_ ids: [UUID]) throws {
        guard !ids.isEmpty else {
            throw Abort(.internalServerError, reason: "领域事件缺少 recipientUserIDs。")
        }
    }

    private static func require(_ id: UUID) throws {
        guard id != UUID(uuidString: "00000000-0000-0000-0000-000000000000") else {
            throw Abort(.internalServerError, reason: "领域事件 UUID 无效。")
        }
    }
}

enum ContactDomainEventType: String, Codable, CaseIterable, Sendable {
    case contactRequestCreated = "contact_request_created"
    case contactRequestAccepted = "contact_request_accepted"
    case contactRequestUpdated = "contact_request_updated"
    case contactRemoved = "contact_removed"
}

enum DomainEventSourceType: String, Codable, Sendable {
    case conversation
    case contact
}

enum ContactDomainEventPayload: Codable, Equatable, Sendable {
    case requestCreated(request: FriendRequestResponse)
    case requestAccepted(request: FriendRequestResponse, contact: ContactResponse, contactUserID: UUID, affectedConversationIDs: [UUID])
    case requestUpdated(request: FriendRequestResponse)
    case contactUpdated(contact: ContactResponse, contactUserID: UUID)
    case contactRemoved(contactUserID: UUID, affectedConversationIDs: [UUID])

    private enum CodingKeys: String, CodingKey {
        case kind
        case request
        case contact
        case contactUserID
        case affectedConversationIDs
    }

    private enum Kind: String, Codable {
        case requestCreated
        case requestAccepted
        case requestUpdated
        case contactUpdated
        case contactRemoved
    }

    var request: FriendRequestResponse? {
        switch self {
        case .requestCreated(let request), .requestAccepted(let request, _, _, _), .requestUpdated(let request):
            return request
        case .contactUpdated, .contactRemoved:
            return nil
        }
    }

    var contact: ContactResponse? {
        switch self {
        case .requestAccepted(_, let contact, _, _), .contactUpdated(let contact, _):
            return contact
        case .requestCreated, .requestUpdated, .contactRemoved:
            return nil
        }
    }

    var contactUserID: UUID? {
        switch self {
        case .requestAccepted(_, _, let contactUserID, _),
             .contactUpdated(_, let contactUserID),
             .contactRemoved(let contactUserID, _):
            return contactUserID
        case .requestCreated, .requestUpdated:
            return nil
        }
    }

    var affectedConversationIDs: [UUID] {
        switch self {
        case .requestAccepted(_, _, _, let ids), .contactRemoved(_, let ids):
            return ids
        case .requestCreated, .requestUpdated, .contactUpdated:
            return []
        }
    }

    func validate(for eventType: ContactDomainEventType) throws {
        switch (eventType, self) {
        case (.contactRequestCreated, .requestCreated),
             (.contactRequestAccepted, .requestAccepted),
             (.contactRequestUpdated, .requestUpdated),
             (.contactRequestUpdated, .contactUpdated),
             (.contactRemoved, .contactRemoved):
            return
        case (.contactRequestCreated, _),
             (.contactRequestAccepted, _),
             (.contactRequestUpdated, _),
             (.contactRemoved, _):
            throw Abort(.internalServerError, reason: "联系人领域事件 payload 与事件类型不匹配。")
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .requestCreated:
            self = .requestCreated(request: try container.decode(FriendRequestResponse.self, forKey: .request))
        case .requestAccepted:
            self = .requestAccepted(
                request: try container.decode(FriendRequestResponse.self, forKey: .request),
                contact: try container.decode(ContactResponse.self, forKey: .contact),
                contactUserID: try container.decode(UUID.self, forKey: .contactUserID),
                affectedConversationIDs: try container.decodeIfPresent([UUID].self, forKey: .affectedConversationIDs) ?? []
            )
        case .requestUpdated:
            self = .requestUpdated(request: try container.decode(FriendRequestResponse.self, forKey: .request))
        case .contactUpdated:
            self = .contactUpdated(
                contact: try container.decode(ContactResponse.self, forKey: .contact),
                contactUserID: try container.decode(UUID.self, forKey: .contactUserID)
            )
        case .contactRemoved:
            self = .contactRemoved(
                contactUserID: try container.decode(UUID.self, forKey: .contactUserID),
                affectedConversationIDs: try container.decodeIfPresent([UUID].self, forKey: .affectedConversationIDs) ?? []
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .requestCreated(let request):
            try container.encode(Kind.requestCreated, forKey: .kind)
            try container.encode(request, forKey: .request)
        case .requestAccepted(let request, let contact, let contactUserID, let affectedConversationIDs):
            try container.encode(Kind.requestAccepted, forKey: .kind)
            try container.encode(request, forKey: .request)
            try container.encode(contact, forKey: .contact)
            try container.encode(contactUserID, forKey: .contactUserID)
            try container.encode(affectedConversationIDs, forKey: .affectedConversationIDs)
        case .requestUpdated(let request):
            try container.encode(Kind.requestUpdated, forKey: .kind)
            try container.encode(request, forKey: .request)
        case .contactUpdated(let contact, let contactUserID):
            try container.encode(Kind.contactUpdated, forKey: .kind)
            try container.encode(contact, forKey: .contact)
            try container.encode(contactUserID, forKey: .contactUserID)
        case .contactRemoved(let contactUserID, let affectedConversationIDs):
            try container.encode(Kind.contactRemoved, forKey: .kind)
            try container.encode(contactUserID, forKey: .contactUserID)
            try container.encode(affectedConversationIDs, forKey: .affectedConversationIDs)
        }
    }
}

struct ConversationEventStreamEnvelope: Codable, Equatable, Sendable {
    let eventID: UUID
    let eventVersion: Int
    let aggregateType: String
    let conversationID: UUID
    let actorUserID: UUID?
    let aggregateSequence: Int
    let eventType: String
    let payload: ConversationDomainEventPayload
    let occurredAt: Date
    let producerShard: String

    init(
        eventID: UUID,
        eventVersion: Int = 1,
        aggregateType: String = "conversation",
        conversationID: UUID,
        actorUserID: UUID? = nil,
        aggregateSequence: Int = 1,
        eventType: String,
        payload: ConversationDomainEventPayload,
        occurredAt: Date,
        producerShard: String
    ) {
        self.eventID = eventID
        self.eventVersion = eventVersion
        self.aggregateType = aggregateType
        self.conversationID = conversationID
        self.actorUserID = actorUserID
        self.aggregateSequence = aggregateSequence
        self.eventType = eventType
        self.payload = payload
        self.occurredAt = occurredAt
        self.producerShard = producerShard
    }
}

final class ConversationDomainEvent: Model, @unchecked Sendable {
    static let schema = "conversation_domain_events"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "conversation_id")
    var conversationID: UUID

    @Field(key: "event_type")
    var eventType: String

    @OptionalField(key: "actor_user_id")
    var actorUserID: UUID?

    @Field(key: "aggregate_sequence")
    var aggregateSequence: Int

    @OptionalField(key: "side_effect_key")
    var sideEffectKey: String?

    @Field(key: "payload_json")
    private var payloadJSON: String

    @Field(key: "status")
    var status: String

    @OptionalField(key: "error_message")
    var errorMessage: String?

    @Field(key: "created_at")
    var createdAt: Date

    @OptionalField(key: "processing_started_at")
    var processingStartedAt: Date?

    @OptionalField(key: "processed_at")
    var processedAt: Date?

    @OptionalField(key: "stream_published_at")
    var streamPublishedAt: Date?

    @OptionalField(key: "stream_publish_error")
    var streamPublishError: String?

    @OptionalField(key: "stream_publish_started_at")
    var streamPublishStartedAt: Date?

    @OptionalField(key: "stream_publish_claimed_by")
    var streamPublishClaimedBy: String?

    @Field(key: "retry_count")
    var retryCount: Int

    init() { }

    init(
        id: UUID? = nil,
        conversationID: UUID,
        eventType: ConversationDomainEventType,
        aggregateSequence: Int = 1,
        sideEffectKey: String? = nil,
        actorUserID: UUID? = nil,
        payload: ConversationDomainEventPayload,
        status: ConversationDomainEventStatus = .pending,
        createdAt: Date = Date()
    ) throws {
        try payload.validate(for: eventType)
        self.id = id
        self.conversationID = conversationID
        self.eventType = eventType.rawValue
        self.aggregateSequence = aggregateSequence
        self.sideEffectKey = sideEffectKey
        self.actorUserID = actorUserID
        self.payloadJSON = try Self.encodePayload(payload)
        self.status = status.rawValue
        self.createdAt = createdAt
        self.retryCount = 0
    }

    var eventTypeEnum: ConversationDomainEventType {
        get throws {
            guard let eventType = ConversationDomainEventType(rawValue: eventType) else {
                throw Abort(.internalServerError, reason: "未知 conversation domain event 类型：\(self.eventType)。")
            }
            return eventType
        }
    }

    var statusEnum: ConversationDomainEventStatus {
        get { ConversationDomainEventStatus(rawValue: status) ?? .pending }
        set { status = newValue.rawValue }
    }

    func decodedPayload() throws -> ConversationDomainEventPayload {
        guard let data = payloadJSON.data(using: .utf8) else {
            throw ConversationProjectionCodingError.invalidJSON
        }
        let payload = try JSONDecoder().decode(ConversationDomainEventPayload.self, from: data)
        try payload.validate(for: eventTypeEnum)
        return payload
    }

    func replacePayload(_ payload: ConversationDomainEventPayload) throws {
        try payload.validate(for: eventTypeEnum)
        payloadJSON = try Self.encodePayload(payload)
    }

    private static func encodePayload(_ payload: ConversationDomainEventPayload) throws -> String {
        let data = try JSONEncoder().encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ConversationProjectionCodingError.invalidJSON
        }
        return json
    }
}

final class ContactDomainEvent: Model, @unchecked Sendable {
    static let schema = "contact_domain_events"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "owner_user_id")
    var ownerUserID: UUID

    @Field(key: "event_type")
    var eventType: String

    @Field(key: "aggregate_id")
    var aggregateID: UUID

    @Field(key: "owner_sequence")
    var ownerSequence: Int

    @OptionalField(key: "actor_user_id")
    var actorUserID: UUID?

    @Field(key: "payload_json")
    private var payloadJSON: String

    @Field(key: "status")
    var status: String

    @OptionalField(key: "error_message")
    var errorMessage: String?

    @Field(key: "created_at")
    var createdAt: Date

    @OptionalField(key: "processing_started_at")
    var processingStartedAt: Date?

    @OptionalField(key: "processed_at")
    var processedAt: Date?

    @Field(key: "retry_count")
    var retryCount: Int

    init() { }

    init(
        id: UUID? = nil,
        ownerUserID: UUID,
        eventType: ContactDomainEventType,
        aggregateID: UUID,
        ownerSequence: Int,
        actorUserID: UUID?,
        payload: ContactDomainEventPayload,
        status: ConversationDomainEventStatus = .pending,
        createdAt: Date = Date()
    ) throws {
        try payload.validate(for: eventType)
        self.id = id
        self.ownerUserID = ownerUserID
        self.eventType = eventType.rawValue
        self.aggregateID = aggregateID
        self.ownerSequence = ownerSequence
        self.actorUserID = actorUserID
        self.payloadJSON = try Self.encodePayload(payload)
        self.status = status.rawValue
        self.createdAt = createdAt
        self.retryCount = 0
    }

    var eventTypeEnum: ContactDomainEventType {
        get throws {
            guard let eventType = ContactDomainEventType(rawValue: eventType) else {
                throw Abort(.internalServerError, reason: "未知 contact domain event 类型：\(self.eventType)。")
            }
            return eventType
        }
    }

    var statusEnum: ConversationDomainEventStatus {
        get { ConversationDomainEventStatus(rawValue: status) ?? .pending }
        set { status = newValue.rawValue }
    }

    func decodedPayload() throws -> ContactDomainEventPayload {
        guard let data = payloadJSON.data(using: .utf8) else {
            throw ConversationProjectionCodingError.invalidJSON
        }
        let payload = try JSONDecoder().decode(ContactDomainEventPayload.self, from: data)
        try payload.validate(for: eventTypeEnum)
        return payload
    }

    private static func encodePayload(_ payload: ContactDomainEventPayload) throws -> String {
        let data = try JSONEncoder().encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ConversationProjectionCodingError.invalidJSON
        }
        return json
    }
}

final class OwnerDomainEventDelivery: Model, @unchecked Sendable {
    static let schema = "owner_domain_event_deliveries"

    @ID(custom: .id, generatedBy: .user)
    var id: String?

    @Field(key: "owner_user_id")
    var ownerUserID: UUID

    @Field(key: "owner_cursor")
    var ownerCursor: UInt64

    @Field(key: "owner_aggregate_sequence")
    var ownerAggregateSequence: UInt64

    @Field(key: "aggregate_type")
    var aggregateType: String

    @Field(key: "aggregate_id")
    var aggregateID: UUID

    @Field(key: "event_id")
    var eventID: UUID

    @Field(key: "source_type")
    var sourceType: String

    @Field(key: "source_event_id")
    var sourceEventID: UUID

    @Field(key: "event_pb_base64")
    var eventPBBase64: String

    @Field(key: "created_at")
    var createdAt: Date

    init() { }

    init(
        ownerUserID: UUID,
        ownerCursor: UInt64,
        ownerAggregateSequence: UInt64,
        aggregateType: String,
        aggregateID: UUID,
        eventID: UUID,
        sourceType: DomainEventSourceType,
        sourceEventID: UUID,
        eventPBBase64: String,
        createdAt: Date = Date()
    ) {
        self.id = Self.recordID(ownerUserID: ownerUserID, eventID: eventID)
        self.ownerUserID = ownerUserID
        self.ownerCursor = ownerCursor
        self.ownerAggregateSequence = ownerAggregateSequence
        self.aggregateType = aggregateType
        self.aggregateID = aggregateID
        self.eventID = eventID
        self.sourceType = sourceType.rawValue
        self.sourceEventID = sourceEventID
        self.eventPBBase64 = eventPBBase64
        self.createdAt = createdAt
    }

    static func recordID(ownerUserID: UUID, eventID: UUID) -> String {
        "\(ownerUserID.uuidString.lowercased()):\(eventID.uuidString.lowercased())"
    }
}

final class ConversationDomainEventSideEffect: Model, @unchecked Sendable {
    static let schema = "conversation_domain_event_side_effects"

    @ID(custom: "side_effect_key", generatedBy: .user)
    var id: String?

    @Field(key: "event_id")
    var eventID: UUID

    @Field(key: "created_at")
    var createdAt: Date

    init() { }

    init(sideEffectKey: String, eventID: UUID, createdAt: Date = Date()) {
        self.id = sideEffectKey
        self.eventID = eventID
        self.createdAt = createdAt
    }
}
