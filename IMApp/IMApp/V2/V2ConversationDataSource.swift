import Foundation
import IMV2ClientKit
import IMV2Core

/// 界面功能到 V2 SQLite 投影的边界。
///
/// 所有标识都在该边界完成解析，非法数据绝不会变成可导航的路由。
protocol V2ConversationTitleReading: Sendable {
    func currentTitle(in roomID: RoomID) async throws -> String?
}

actor V2GRDBConversationDataSource: V2ConversationTitleReading, V2ConversationDataSource, V2ConversationWindowReading, V2ConversationSendingCapabilityReading, V2ConversationFavoritesReading, V2ConversationMessageSearching, V2ConversationMessageSearchProgressReading, V2GroupAnnouncementReading, V2GroupRolePolicyAccessing {
    private let localStore: GRDBV2LocalSyncStore
    private let requestLatestVisible: @Sendable ([RoomID]) async throws -> Void
    init(localStore: GRDBV2LocalSyncStore, requestLatestVisible: @escaping @Sendable ([RoomID]) async throws -> Void) {
        self.localStore = localStore
        self.requestLatestVisible = requestLatestVisible
    }

    func currentTitle(in roomID: RoomID) async throws -> String? {
        try await localStore.conversationTitles(for: [roomID])[roomID]
    }

    private func requestMissingSummaries(_ entries: [V2ClientConversationListEntry]) async throws {
        let rooms = entries.filter { $0.latestVisible == nil }.map(\.roomID)
        for start in stride(from: 0, to: rooms.count, by: 100) {
            try Task.checkCancellation()
            do {
                try await requestLatestVisible(Array(rooms[start..<min(start + 100, rooms.count)]))
            } catch V2RoomRecoveryEngineError.notStarted {
                // Local pages remain available before the connection starts.
                return
            } catch V2RoomRecoveryEngineError.coverageLost {
                // The next connection rebuilds recovery demand.
                return
            }
        }
    }

    /// 该房间是否已被服务端保留裁剪掉一段历史。
    ///
    /// 缺口是永久的：服务端已经删掉那段事件，任何客户端都补不回来。界面必须显式告知，
    /// 而不是把最近窗口当成完整历史展示。
    func roomLogHistoryIsIncomplete(roomID: String) async throws -> Bool {
        try await localStore.roomLogHistoryIsIncomplete(roomID: .init(roomID))
    }

    /// 按房间标识读取展示未读；目录不可用时返回空映射（界面显示无角标）。
    private func displayedUnread(roomIDs: [RoomID]) async -> [RoomID: UInt64] {
        guard !roomIDs.isEmpty else { return [:] }
        guard let rows = try? await localStore.roomUnreadSnapshot(roomIDs: roomIDs) else { return [:] }
        return rows.mapValues(\.displayedUnread)
    }

    /// 读取进入房间推进已读线所需的本地事实。
    ///
    /// 房间头来自已验证的房间同步状态，本地已应用序号来自投影库。两者
    /// 都可能缺失：恢复任务尚未核对该房间，或本地还没有任何该房间的事件证据。
    ///
    /// - Parameter roomID: 目标房间标识。
    /// - Returns: 已知的房间头与本地已应用序号。
    /// - Throws: 本地读取失败。
    func roomReadCheckpoint(roomID: String) async throws -> V2ConversationRoomReadCheckpoint {
        let parsedRoomID = try RoomID(roomID)
        let applied = try await localStore.roomAppliedRoomSequence(roomID: parsedRoomID)
        // 状态未知时房间头未知：界面只按本地已应用序号推进，不会凭空跳到未知的 head。
        let states = try await localStore.roomUnreadSnapshot(roomIDs: [parsedRoomID])
        return .init(
            knownHead: states[parsedRoomID]?.head,
            appliedRoomSequence: applied > 0 ? applied : nil
        )
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
        let unread = await displayedUnread(roomIDs: page.entries.map(\.roomID))
        try await requestMissingSummaries(page.entries)
        return Self.listPage(page, userID: userID, unread: unread)
    }

    func conversationWindow(for userID: String, isArchived: Bool, around anchor: V2ClientConversationListCursor, limit: Int, precedingCount: Int) async throws -> V2ConversationListWindow {
        let result = try await localStore.conversationListWindow(isArchived: isArchived, around: anchor, limit: limit, precedingCount: precedingCount)
        let unread = await displayedUnread(roomIDs: result.page.entries.map(\.roomID))
        try await requestMissingSummaries(result.page.entries)
        return .init(page: Self.listPage(result.page, userID: userID, unread: unread), anchorID: result.anchor?.roomID.rawValue, hasEarlier: result.hasEarlier)
    }

    private static func listPage(_ page: V2ClientConversationListPage, userID: String, unread: [RoomID: UInt64]) -> V2ConversationListPage {
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
                preview: entry.latestVisible.map { snapshot in
                    snapshot.latest.map { $0.preview.isEmpty && $0.mediaCount > 0 ? "[附件]" : $0.preview } ?? "暂无消息"
                } ?? entry.lastMessage.map { Self.preview(for: $0) } ?? "暂无消息",
                lastActivity: entry.lastActivity,
                isOutgoing: entry.latestVisible.map { $0.latest?.senderID.rawValue == userID } ?? (entry.lastMessage?.senderUserID.rawValue == userID),
                kind: kind,
                isPinned: entry.isPinned,
                isArchived: entry.isArchived,
                muteUntil: entry.muteUntil,
                unreadCount: unread[entry.roomID],
                presentationKey: entry.directIdentity.map { .init(userID: $0.publicIdentity.userID, context: .directConversation) }
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
                lastActivity: identity.roomCreatedAt,
                isOutgoing: false,
                kind: .direct(accountKind: identity.publicIdentity.accountKind),
                isPinned: conversationStates[identity.roomID]?.isPinned ?? false,
                isArchived: conversationStates[identity.roomID]?.isArchived ?? false,
                muteUntil: conversationStates[identity.roomID]?.muteUntil,
                presentationKey: .init(userID: identity.publicIdentity.userID, context: .directConversation)
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
            limit: limit,
            presentationUserID: try .init(userID)
        )
        return Self.timelinePage(page, userID: userID)
    }

    func timelineWindow(in roomID: String, for userID: String, around messageID: String, before: Int, after: Int) async throws -> V2ConversationTimelineLocation {
        let location = try await localStore.conversationTimelineWindow(in: RoomID(roomID), for: UserID(userID), around: MessageID(messageID), before: before, after: after, aggregateReactions: true)
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
        let summariesByMessageID = page.reactionSummaries.map { Dictionary(grouping: $0, by: \.messageID) }
        let renderedMessages: [V2ConversationTimelineItem] = page.messages.map { message in
            .message(
                Self.messageItem(
                    message,
                    userID: userID,
                    reactions: reactionsByMessageID[message.messageID] ?? [],
                    pinnedMessageIDs: page.pinnedMessageIDs,
                    favoritedMessageIDs: page.favoritedMessageIDs,
                    directReceipt: page.directReadReceipt,
                    reactionSummary: summariesByMessageID.map { $0[message.messageID] ?? [] }
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

    func searchConversationContext(roomID: RoomID) async throws -> V2ClientConversationLookupContext? {
        try await localStore.conversationLookupContexts(for: [roomID])[roomID]
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
        let contexts = try await localStore.conversationLookupContexts(for: Array(Set(page.messages.map(\.roomID))))
        let items: [V2FavoriteConversationMessageItem] = page.messages.map { message in
            V2FavoriteConversationMessageItem(
                id: message.messageID.rawValue,
                roomID: message.roomID.rawValue,
                label: .init(context: contexts[message.roomID]),
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
        directReceipt: V2DirectReadReceiptProjection?,
        reactionSummary: [V2ClientMessageReactionSummary]? = nil
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
            reactions: reactionSummary.map { summaries in
                summaries.map { .init(reaction: $0.reaction, count: $0.count, includesCurrentUser: $0.includesCurrentUser) }
            } ?? reactionSummaries(reactions, currentUserID: userID),
            isReadByPeer: message.senderUserID.rawValue == userID
                && (directReceipt?.readThroughRoomSequence ?? 0) >= message.roomSequence,
            isFavorited: favoritedMessageIDs.contains(message.messageID),
            isPinnedInGroup: pinnedMessageIDs.contains(message.messageID),
            isForwarded: !message.isWithdrawn && message.forwardedFrom != nil,
            senderUserID: message.senderUserID
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
