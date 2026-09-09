import Foundation
import IMV2ClientKit
import IMV2Core

/// Boundary from the UI feature to the V2 SQLite projection. All IDs are
/// parsed at this boundary; invalid data can never become a navigation route.
actor V2GRDBConversationDataSource: V2ConversationDataSource, V2ConversationWindowReading, V2ConversationSendingCapabilityReading, V2ConversationFavoritesReading, V2ConversationMessageSearching, V2ConversationMessageSearchProgressReading, V2GroupAnnouncementReading, V2GroupRolePolicyAccessing {
    private let localStore: GRDBV2LocalSyncStore

    init(localStore: GRDBV2LocalSyncStore) {
        self.localStore = localStore
    }

    func conversationSummaryPage(
        for userID: String,
        isArchived: Bool,
        before cursor: V2ClientConversationListCursor?,
        limit: Int
    ) async throws -> V2ConversationListPage {
        let page = try await localStore.conversationListPage(
            isArchived: isArchived,
            before: cursor,
            limit: limit
        )
        return Self.listPage(page, userID: userID)
    }

    func conversationWindow(for userID: String, isArchived: Bool, around anchor: V2ClientConversationListCursor, limit: Int, precedingCount: Int) async throws -> V2ConversationListWindow {
        let result = try await localStore.conversationListWindow(isArchived: isArchived, around: anchor, limit: limit, precedingCount: precedingCount)
        return .init(page: Self.listPage(result.page, userID: userID), anchorID: result.anchor?.roomID.rawValue, hasEarlier: result.hasEarlier)
    }

    private static func listPage(_ page: V2ClientConversationListPage, userID: String) -> V2ConversationListPage {
        let items = page.entries.map { entry in
            let directTitle = entry.directIdentity.map { identity in
                V2ProfileResolver.resolve(
                    userID: identity.publicIdentity.userID,
                    profile: entry.directProfileView,
                    alias: nil,
                    groupMember: nil,
                    surface: .directConversation
                ).displayName
            }
            let kind: V2ConversationKind = if entry.roomProfile != nil {
                .group
            } else if let identity = entry.directIdentity {
                .direct(accountKind: identity.publicIdentity.accountKind)
            } else {
                .unknown
            }
            return V2ConversationListItem(
                id: entry.roomID.rawValue,
                title: entry.roomProfile?.title ?? directTitle ?? Self.roomTitle(entry.roomID.rawValue),
                preview: entry.lastMessage.map { Self.preview(for: $0) } ?? "暂无消息",
                lastActivity: entry.lastActivity,
                isOutgoing: entry.lastMessage?.senderUserID.rawValue == userID,
                kind: kind,
                isPinned: entry.isPinned,
                isArchived: entry.isArchived,
                muteUntil: entry.muteUntil
            )
        }
        return .init(items: items, nextCursor: page.nextCursor)
    }

    static func mergingEmptyProjectionItems(
        messageItems: [V2ConversationListItem],
        profiles: [V2ClientRoomProfileProjection],
        directIdentities: [V2ClientDirectRoomIdentity],
        directTitles: [RoomID: String]? = nil,
        conversationStates: [RoomID: V2ClientConversationState] = [:]
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
                kind: .group,
                isPinned: conversationStates[profile.roomID]?.isPinned ?? false,
                isArchived: conversationStates[profile.roomID]?.isArchived ?? false,
                muteUntil: conversationStates[profile.roomID]?.muteUntil
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
                kind: .direct(accountKind: identity.publicIdentity.accountKind),
                isPinned: conversationStates[identity.roomID]?.isPinned ?? false,
                isArchived: conversationStates[identity.roomID]?.isArchived ?? false,
                muteUntil: conversationStates[identity.roomID]?.muteUntil
            )
        }
        return (messageItems + emptyProfileItems + emptyDirectItems).sorted { lhs, rhs in
            if lhs.isArchived != rhs.isArchived { return !lhs.isArchived }
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.lastActivity == rhs.lastActivity ? lhs.id < rhs.id : lhs.lastActivity > rhs.lastActivity
        }
    }

    func timelinePage(
        in roomID: String,
        for userID: String,
        before cursor: V2ConversationTimelineCursor?,
        limit: Int
    ) async throws -> V2ConversationTimelinePage {
        let parsedRoomID = try RoomID(roomID)
        let page = try await localStore.conversationTimelinePage(
            in: parsedRoomID,
            before: cursor.map {
                .init(timelineSequence: $0.timelineSequence, itemID: $0.itemID, kind: $0.kind)
            },
            limit: limit
        )
        return Self.timelinePage(page, userID: userID)
    }

    func timelineWindow(in roomID: String, for userID: String, around messageID: String, before: Int, after: Int) async throws -> V2ConversationTimelineLocation {
        let location = try await localStore.conversationTimelineWindow(in: RoomID(roomID), for: UserID(userID), around: MessageID(messageID), before: before, after: after)
        switch location {
        case .unavailable: return .unavailable
        case .withdrawn: return .withdrawn
        case .found(let window):
            return .found(page: Self.timelinePage(window.page, userID: userID), newerBoundary: window.newerBoundary.map {
                .init(timelineSequence: $0.timelineSequence, itemID: $0.itemID, kind: $0.kind)
            })
        }
    }

    private static func timelinePage(_ page: V2ClientConversationTimelinePage, userID: String) -> V2ConversationTimelinePage {
        let reactionsByMessageID = Dictionary(grouping: page.reactions, by: \.messageID)
        let renderedMessages: [V2ConversationTimelineItem] = page.messages.map { message in
            .message(
                Self.messageItem(
                    message,
                    userID: userID,
                    reactions: reactionsByMessageID[message.messageID] ?? [],
                    pinnedMessageIDs: page.pinnedMessageIDs,
                    favoritedMessageIDs: page.favoritedMessageIDs,
                    directReceipt: page.directReadReceipt
                ),
                timelineSequence: message.timelineSequence
            )
        }
        let renderedActivities: [V2ConversationTimelineItem] = page.activities.map { activity in
            let kind: V2ConversationTimelineItem.Activity.Kind = switch activity.kind {
            case .directMessageRestricted: .directMessageRestricted
            case .systemAccountReadOnly: .systemAccountReadOnly
            }
            return .activity(.init(id: activity.id, timelineSequence: activity.timelineSequence, kind: kind, createdAt: activity.createdAt))
        }
        let items = (renderedMessages + renderedActivities).sorted { lhs, rhs in
            if lhs.timelineSequence != rhs.timelineSequence { return lhs.timelineSequence < rhs.timelineSequence }
            if lhs.storageItemID != rhs.storageItemID { return lhs.storageItemID < rhs.storageItemID }
            return lhs.cursor.kind.rawValue < rhs.cursor.kind.rawValue
        }
        return .init(
            items: items,
            olderCursor: page.olderCursor.map {
                .init(timelineSequence: $0.timelineSequence, itemID: $0.itemID, kind: $0.kind)
            }
        )
    }

    func directSendingCapability(in roomID: String) async throws -> Bool? {
        try await localStore.directSendingCapability(roomID: .init(roomID))?.canSend
    }

    func groupAnnouncement(in roomID: String) async throws -> V2ClientGroupAnnouncement? {
        try await localStore.groupAnnouncement(roomID: .init(roomID))
    }

    func groupRolePolicyState(in roomID: String) async throws -> V2ClientGroupRolePolicyState {
        try await localStore.groupRolePolicyState(roomID: .init(roomID))
    }

    func retryGroupRolePolicyRecovery(in roomID: String) async throws -> V2ClientGroupRolePolicyState {
        _ = try await localStore.resumeRolePolicyBaseline(roomID: .init(roomID))
        return try await localStore.groupRolePolicyState(roomID: .init(roomID))
    }

    func searchMessages(_ request: V2MessageSearchRequest) async throws -> V2MessageSearchPage {
        try await localStore.searchMessages(request)
    }

    func searchSenderDisplayName(userID: UserID) async throws -> String? {
        guard let profile = try await localStore.profileView(userID: userID) else { return nil }
        return V2ProfileResolver.resolve(
            userID: userID, profile: profile, alias: nil, groupMember: nil,
            surface: .groupMessage(allowsPrivateAlias: false)
        ).displayName
    }

    func messageSearchIndexUpdates() async -> AsyncThrowingStream<V2MessageSearchIndexSnapshot, any Error> {
        localStore.messageSearchIndexUpdates()
    }

    func messageSearchIndexProgress() async throws -> V2MessageSearchIndexProgress {
        try await localStore.messageSearchIndexProgress()
    }

    func favoriteMessages(
        for _: String,
        before cursor: V2ClientFavoriteMessageCursor?,
        limit: Int
    ) async throws -> V2ConversationFavoriteMessagesPage {
        let page = try await localStore.favoritedMessages(before: cursor, limit: limit)
        let titles = try await localStore.conversationTitles(for: Array(Set(page.messages.map(\.roomID))))
        let items: [V2FavoriteConversationMessageItem] = page.messages.map { message in
            V2FavoriteConversationMessageItem(
                id: message.messageID.rawValue,
                roomID: message.roomID.rawValue,
                roomTitle: titles[message.roomID] ?? Self.roomTitle(message.roomID.rawValue),
                text: Self.preview(for: message),
                createdAt: message.createdAt
            )
        }
        return .init(items: items, nextCursor: page.nextCursor)
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

    private static func messageItem(
        _ message: V2ClientMessageProjection,
        userID: String,
        reactions: [V2ClientMessageReaction],
        pinnedMessageIDs: Set<MessageID>,
        favoritedMessageIDs: Set<MessageID>,
        directReceipt: V2DirectReadReceiptProjection?
    ) -> V2ConversationMessageItem {
        .init(
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
            reactions: reactionSummaries(reactions, currentUserID: userID),
            isReadByPeer: message.senderUserID.rawValue == userID
                && (directReceipt?.readThroughRoomSequence ?? 0) >= message.roomSequence,
            isFavorited: favoritedMessageIDs.contains(message.messageID),
            isPinnedInGroup: pinnedMessageIDs.contains(message.messageID),
            isForwarded: !message.isWithdrawn && message.forwardedFrom != nil
        )
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
