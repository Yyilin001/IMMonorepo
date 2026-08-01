import Foundation
import IMV2ClientKit
import IMV2Core

/// Boundary from the UI feature to the V2 SQLite projection. All IDs are
/// parsed at this boundary; invalid data can never become a navigation route.
actor V2GRDBConversationDataSource: V2ConversationDataSource, V2ConversationMessageSearching, V2GroupAnnouncementReading, V2GroupRolePolicyReading {
    private let localStore: GRDBV2LocalSyncStore

    init(localStore: GRDBV2LocalSyncStore) {
        self.localStore = localStore
    }

    func conversationSummaries(for userID: String) async throws -> [V2ConversationListItem] {
        let profiles = try await localStore.roomProfiles()
        let titles = Dictionary(uniqueKeysWithValues: profiles.map { ($0.roomID, $0.title) })
        let directIdentities = try await localStore.directRoomIdentities()
        let profileViews = try await localStore.profileViews(userIDs: Array(Set(directIdentities.map(\.publicIdentity.userID))))
        let directTitles = Dictionary(uniqueKeysWithValues: directIdentities.map { identity in
            (
                identity.roomID,
                V2ProfileResolver.resolve(
                    userID: identity.publicIdentity.userID,
                    profile: profileViews[identity.publicIdentity.userID],
                    alias: nil,
                    groupMember: nil,
                    surface: .directConversation
                ).displayName
            )
        })
        let groupRoomIDs = Set(profiles.map(\.roomID))
        let directRoomIDs = Set(directIdentities.map(\.roomID))
        let summaries = try await localStore.conversationSummaries()
        var messageItems: [V2ConversationListItem] = []
        messageItems.reserveCapacity(summaries.count)
        for summary in summaries {
            let message = summary.lastMessage
            let state = try await localStore.conversationState(roomID: summary.roomID)
            messageItems.append(V2ConversationListItem(
                id: summary.roomID.rawValue,
                title: titles[summary.roomID] ?? directTitles[summary.roomID] ?? Self.roomTitle(summary.roomID.rawValue),
                preview: Self.preview(for: message),
                lastActivity: message.createdAt,
                isOutgoing: message.senderUserID.rawValue == userID,
                kind: groupRoomIDs.contains(summary.roomID) ? .group : (directRoomIDs.contains(summary.roomID) ? .direct : .unknown),
                isPinned: state?.isPinned ?? false,
                isArchived: state?.isArchived ?? false,
                muteUntil: state?.muteUntil
            ))
        }
        return Self.mergingEmptyProjectionItems(
            messageItems: messageItems,
            profiles: profiles,
            directIdentities: directIdentities,
            directTitles: directTitles
        )
    }

    static func mergingEmptyProjectionItems(
        messageItems: [V2ConversationListItem],
        profiles: [V2ClientRoomProfileProjection],
        directIdentities: [V2ClientDirectRoomIdentity],
        directTitles: [RoomID: String]? = nil
    ) -> [V2ConversationListItem] {
        let messageRoomIDs = Set(messageItems.map(\.id))
        let emptyProfileItems: [V2ConversationListItem] = profiles.compactMap { profile in
            guard !messageRoomIDs.contains(profile.roomID.rawValue) else { return nil }
            return V2ConversationListItem(
                id: profile.roomID.rawValue,
                title: profile.title,
                preview: "暂无消息",
                lastActivity: profile.createdAt,
                isOutgoing: false,
                kind: .group
            )
        }
        let representedRoomIDs = messageRoomIDs.union(emptyProfileItems.map(\.id))
        let emptyDirectItems: [V2ConversationListItem] = directIdentities.compactMap { identity in
            // Direct-room profiles are durable sync projections. The local
            // lookup cache may temporarily be the only available title while
            // the creation sync is in flight, so it must still make the empty
            // direct room discoverable without exposing an opaque room ID.
            guard !representedRoomIDs.contains(identity.roomID.rawValue) else { return nil }
            return V2ConversationListItem(
                id: identity.roomID.rawValue,
                title: directTitles?[identity.roomID] ?? identity.publicIdentity.displayName,
                preview: "暂无消息",
                lastActivity: identity.updatedAt,
                isOutgoing: false,
                kind: .direct
            )
        }
        return (messageItems + emptyProfileItems + emptyDirectItems).sorted { lhs, rhs in
            if lhs.isArchived != rhs.isArchived { return !lhs.isArchived }
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.lastActivity == rhs.lastActivity ? lhs.id < rhs.id : lhs.lastActivity > rhs.lastActivity
        }
    }

    func messages(in roomID: String, for userID: String) async throws -> [V2ConversationMessageItem] {
        let parsedRoomID = try RoomID(roomID)
        let messages = try await localStore.messages(in: parsedRoomID)
        let reactions = try await localStore.reactions(in: parsedRoomID)
        let pinnedMessageIDs = try await localStore.pinnedMessageIDs(roomID: parsedRoomID)
        let directReceipt = try await localStore.directReadReceipt(roomID: parsedRoomID)
        let reactionsByMessageID = Dictionary(grouping: reactions, by: \.messageID)
        var items: [V2ConversationMessageItem] = []
        items.reserveCapacity(messages.count)
        for message in messages {
            items.append(.init(
                id: message.messageID.rawValue,
                roomSequence: message.roomSequence,
                revision: message.messageRevision,
                text: message.isWithdrawn ? "消息已撤回" : message.text,
                media: message.isWithdrawn ? [] : message.media,
                mediaPresentations: message.isWithdrawn ? [] : message.mediaPresentations,
                mentions: message.isWithdrawn ? [] : message.mentions,
                entities: message.isWithdrawn ? [] : message.entities,
                replyTo: message.isWithdrawn ? nil : message.replyTo,
                createdAt: message.createdAt,
                isOutgoing: message.senderUserID.rawValue == userID,
                isWithdrawn: message.isWithdrawn,
                reactions: Self.reactionSummaries(
                    reactionsByMessageID[message.messageID] ?? [],
                    currentUserID: userID
                ),
                isReadByPeer: message.senderUserID.rawValue == userID && (directReceipt?.readThroughRoomSequence ?? 0) >= message.roomSequence,
                isFavorited: try await localStore.isMessageFavorited(message.messageID),
                isPinnedInGroup: pinnedMessageIDs.contains(message.messageID),
                isForwarded: !message.isWithdrawn && message.forwardedFrom != nil
            ))
        }
        return items
    }

    func groupAnnouncement(in roomID: String) async throws -> V2ClientGroupAnnouncement? {
        try await localStore.groupAnnouncement(roomID: .init(roomID))
    }

    func groupRolePolicies(in roomID: String) async throws -> [V2ClientGroupRolePolicy] {
        try await localStore.groupRolePolicies(roomID: .init(roomID))
    }

    func searchMessages(_ request: V2MessageSearchRequest) async throws -> V2MessageSearchPage {
        try await localStore.searchMessages(request)
    }

    private static func roomTitle(_ roomID: String) -> String {
        // A room ID is an opaque routing key, never product-facing identity.
        // Known group and direct titles are resolved above; this conservative
        // fallback is for an in-flight sync record whose profile has not yet
        // arrived.
        _ = roomID
        return "会话"
    }

    private static func preview(for message: V2ClientMessageProjection) -> String {
        if message.isWithdrawn { return "消息已撤回" }
        if !message.text.isEmpty { return message.text }
        return message.media.isEmpty ? "" : "[附件]"
    }

    private static func reactionSummaries(_ reactions: [V2ClientMessageReaction], currentUserID: String) -> [V2ConversationMessageReaction] {
        Dictionary(grouping: reactions, by: \.reaction)
            .map { reaction, entries in
                .init(
                    reaction: reaction,
                    count: entries.count,
                    includesCurrentUser: entries.contains { $0.actorUserID.rawValue == currentUserID }
                )
            }
            .sorted { $0.reaction < $1.reaction }
    }
}
