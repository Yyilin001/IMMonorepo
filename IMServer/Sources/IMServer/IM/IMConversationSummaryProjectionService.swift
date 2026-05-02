import Fluent
import Foundation
import Vapor

struct ConversationSummaryVerificationResult: Equatable, Sendable {
    var ownerUserCount: Int = 0
    var tombstoneSummaryCount: Int = 0
    var missingSummaryCount: Int = 0
    var staleActiveSummaryCount: Int = 0
    var latestVisibleMessageMismatchCount: Int = 0
    var unreadMismatchCount: Int = 0

    mutating func accumulate(_ other: ConversationSummaryVerificationResult) {
        ownerUserCount += other.ownerUserCount
        tombstoneSummaryCount += other.tombstoneSummaryCount
        missingSummaryCount += other.missingSummaryCount
        staleActiveSummaryCount += other.staleActiveSummaryCount
        latestVisibleMessageMismatchCount += other.latestVisibleMessageMismatchCount
        unreadMismatchCount += other.unreadMismatchCount
    }
}

struct IMConversationSummaryProjectionService {
    private struct PageCursor: Codable {
        let isPinned: Bool
        let pinnedAt: Date?
        let lastActivityAt: Date
        let recordID: String
    }

    private struct ChangeToken: Codable {
        let updatedAt: Date
        let recordID: String
    }

    let sourceDB: any Database
    let readModelDB: any Database

    init(db: any Database) {
        self.init(sourceDB: db, readModelDB: db)
    }

    init(sourceDB: any Database, readModelDB: any Database) {
        self.sourceDB = sourceDB
        self.readModelDB = readModelDB
    }

    func refreshConversationSummaries(
        conversationID: UUID,
        recipientUserIDs: [UUID],
        on database: (any Database)? = nil,
        writeChangeLog: Bool = true
    ) async throws {
        let database = database ?? sourceDB
        let readModelDatabase = readModelDB
        let uniqueUserIDs = Array(Set(recipientUserIDs)).sorted { $0.uuidString < $1.uuidString }
        guard !uniqueUserIDs.isEmpty else {
            return
        }

        guard let conversation = try await Conversation.find(conversationID, on: database) else {
            return
        }

        let memberships = try await ConversationMember.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .with(\.$user)
            .all()
        guard !memberships.isEmpty else {
            return
        }

        let memberUserIDs = memberships.map(\.$user.id).sorted { $0.uuidString < $1.uuidString }
        let updatedAt = Date()

        for recipientUserID in uniqueUserIDs {
            guard let membership = memberships.first(where: { $0.$user.id == recipientUserID }) else {
                continue
            }

            let summary = try await findOrCreateSummary(
                ownerUserID: recipientUserID,
                conversationID: conversationID,
                on: readModelDatabase
            )
            summary.ownerUserID = recipientUserID
            summary.conversationID = conversationID
            summary.title = conversation.title
            summary.kind = conversation.kind
            summary.directMessagingState = conversation.conversationKind == .direct ? conversation.directMessagingState : nil
            let directPeer = directPeer(from: memberships, currentUserID: recipientUserID)
            summary.directPeerUserID = directPeer?.id
            summary.directPeerEmail = directPeer?.email
            summary.directPeerDisplayName = directPeer?.displayName
            summary.directPeerAvatarPresetEnum = directPeer?.avatarPreset
            summary.notice = conversation.notice
            summary.avatarPresetEnum = conversation.avatarPresetEnum
            summary.memberUserIDs = memberUserIDs
            let lastVisibleMessage = try await ConversationMessage.query(on: database)
                .filter(\.$conversation.$id == conversationID)
                .filter(\.$serverSequence >= membership.visibleFromSequence)
                .sort(\.$serverSequence, .descending)
                .first()
            let preview = try lastVisibleMessage.map(makePreview)
            let latestVisibleSequence = max(
                lastVisibleMessage?.serverSequence ?? 0,
                max(0, membership.visibleFromSequence - 1)
            )
            let effectiveLastReadSequence = max(
                membership.lastReadSequence,
                max(0, membership.visibleFromSequence - 1)
            )
            summary.lastMessage = preview
            summary.lastReadSequence = effectiveLastReadSequence
            summary.unreadCount = max(0, latestVisibleSequence - effectiveLastReadSequence)
            summary.lastActivityAt = preview?.createdAt ?? conversation.updatedAt
            summary.updatedAt = updatedAt
            summary.isRemoved = false
            try await save(summary, on: readModelDatabase)
            if writeChangeLog {
                try await upsertChangeLog(
                    ownerUserID: recipientUserID,
                    conversationID: conversationID,
                    summaryRecordID: summary.id ?? ConversationUserSummary.recordID(
                        ownerUserID: recipientUserID,
                        conversationID: conversationID
                    ),
                    updatedAt: updatedAt,
                    isRemoved: false,
                    on: readModelDatabase
                )
            }
        }
    }

    func markConversationRemoved(
        conversationID: UUID,
        recipientUserID: UUID,
        on database: (any Database)? = nil,
        writeChangeLog: Bool = true
    ) async throws {
        _ = database ?? sourceDB
        let readModelDatabase = readModelDB
        let summary = try await findOrCreateSummary(
            ownerUserID: recipientUserID,
            conversationID: conversationID,
            on: readModelDatabase
        )
        summary.ownerUserID = recipientUserID
        summary.conversationID = conversationID
        summary.isRemoved = true
        summary.updatedAt = Date()
        try await save(summary, on: readModelDatabase)
        if writeChangeLog {
            try await upsertChangeLog(
                ownerUserID: recipientUserID,
                conversationID: conversationID,
                summaryRecordID: summary.id ?? ConversationUserSummary.recordID(
                    ownerUserID: recipientUserID,
                    conversationID: conversationID
                ),
                updatedAt: summary.updatedAt,
                isRemoved: true,
                on: readModelDatabase
            )
        }
    }

    func recordConversationSummaryChanges(
        conversationID: UUID,
        recipientUserIDs: [UUID]
    ) async throws {
        let uniqueUserIDs = Array(Set(recipientUserIDs)).sorted { $0.uuidString < $1.uuidString }
        guard !uniqueUserIDs.isEmpty else {
            return
        }

        for recipientUserID in uniqueUserIDs {
            let summaryRecordID = ConversationUserSummary.recordID(
                ownerUserID: recipientUserID,
                conversationID: conversationID
            )
            guard let summary = try await ConversationUserSummary.find(summaryRecordID, on: readModelDB) else {
                continue
            }
            try await upsertChangeLog(
                ownerUserID: recipientUserID,
                conversationID: conversationID,
                summaryRecordID: summaryRecordID,
                updatedAt: summary.updatedAt,
                isRemoved: summary.isRemoved,
                on: readModelDB
            )
        }
    }

    func recordConversationRemovedChange(
        conversationID: UUID,
        recipientUserID: UUID
    ) async throws {
        let summaryRecordID = ConversationUserSummary.recordID(
            ownerUserID: recipientUserID,
            conversationID: conversationID
        )
        guard let summary = try await ConversationUserSummary.find(summaryRecordID, on: readModelDB) else {
            return
        }
        try await upsertChangeLog(
            ownerUserID: recipientUserID,
            conversationID: conversationID,
            summaryRecordID: summaryRecordID,
            updatedAt: summary.updatedAt,
            isRemoved: true,
            on: readModelDB
        )
    }

    func rebuildSummaries(for userID: UUID) async throws {
        let memberships = try await ConversationMember.query(on: sourceDB)
            .filter(\.$user.$id == userID)
            .all()
        let activeConversationIDs = memberships.map(\.$conversation.id)

        for conversationID in activeConversationIDs {
            try await refreshConversationSummaries(
                conversationID: conversationID,
                recipientUserIDs: [userID],
                on: sourceDB,
                writeChangeLog: true
            )
        }

        let existing = try await ConversationUserSummary.query(on: readModelDB)
            .filter(\.$ownerUserID == userID)
            .all()
        let activeSet = Set(activeConversationIDs)
        for summary in existing where !activeSet.contains(summary.conversationID) && !summary.isRemoved {
            summary.isRemoved = true
            summary.updatedAt = Date()
            try await save(summary, on: readModelDB)
            try await upsertChangeLog(
                ownerUserID: userID,
                conversationID: summary.conversationID,
                summaryRecordID: summary.id ?? ConversationUserSummary.recordID(ownerUserID: userID, conversationID: summary.conversationID),
                updatedAt: summary.updatedAt,
                isRemoved: true,
                on: readModelDB
            )
        }
    }

    func rebuildAllSummaries() async throws -> Int {
        let membershipOwnerUserIDs = try await ConversationMember.query(on: sourceDB)
            .all()
            .map(\.$user.id)
        let summaryOwnerUserIDs = try await ConversationUserSummary.query(on: readModelDB)
            .all()
            .map(\.ownerUserID)
        let ownerUserIDs = Array(Set(membershipOwnerUserIDs + summaryOwnerUserIDs))
            .sorted { $0.uuidString < $1.uuidString }

        for ownerUserID in ownerUserIDs {
            try await rebuildSummaries(for: ownerUserID)
        }

        return ownerUserIDs.count
    }

    func verifySummaries(for userID: UUID) async throws -> ConversationSummaryVerificationResult {
        let memberships = try await ConversationMember.query(on: sourceDB)
            .filter(\.$user.$id == userID)
            .all()
        let summaries = try await ConversationUserSummary.query(on: readModelDB)
            .filter(\.$ownerUserID == userID)
            .all()

        let activeMembershipsByConversationID = Dictionary(
            uniqueKeysWithValues: memberships.map { ($0.$conversation.id, $0) }
        )
        let summariesByConversationID = Dictionary(
            uniqueKeysWithValues: summaries.map { ($0.conversationID, $0) }
        )

        var result = ConversationSummaryVerificationResult(ownerUserCount: 1)
        result.tombstoneSummaryCount = summaries.filter(\.isRemoved).count

        for membership in memberships {
            let conversationID = membership.$conversation.id
            guard let summary = summariesByConversationID[conversationID],
                  !summary.isRemoved
            else {
                result.missingSummaryCount += 1
                continue
            }

            let lastVisibleMessage = try await ConversationMessage.query(on: sourceDB)
                .filter(\.$conversation.$id == conversationID)
                .filter(\.$serverSequence >= membership.visibleFromSequence)
                .sort(\.$serverSequence, .descending)
                .first()
            let expectedLastVisibleMessage = try lastVisibleMessage.map(makePreview)

            if summary.lastMessage != expectedLastVisibleMessage {
                result.latestVisibleMessageMismatchCount += 1
            }

            let latestVisibleSequence = max(
                lastVisibleMessage?.serverSequence ?? 0,
                max(0, membership.visibleFromSequence - 1)
            )
            let effectiveLastReadSequence = max(
                membership.lastReadSequence,
                max(0, membership.visibleFromSequence - 1)
            )
            let expectedUnreadCount = max(0, latestVisibleSequence - effectiveLastReadSequence)
            if summary.lastReadSequence != effectiveLastReadSequence
                || summary.unreadCount != expectedUnreadCount {
                result.unreadMismatchCount += 1
            }
        }

        for summary in summaries where activeMembershipsByConversationID[summary.conversationID] == nil && !summary.isRemoved {
            result.staleActiveSummaryCount += 1
        }

        return result
    }

    func verifyAllSummaries() async throws -> ConversationSummaryVerificationResult {
        let membershipOwnerUserIDs = try await ConversationMember.query(on: sourceDB)
            .all()
            .map(\.$user.id)
        let summaryOwnerUserIDs = try await ConversationUserSummary.query(on: readModelDB)
            .all()
            .map(\.ownerUserID)
        let ownerUserIDs = Array(Set(membershipOwnerUserIDs + summaryOwnerUserIDs))
            .sorted { $0.uuidString < $1.uuidString }

        var result = ConversationSummaryVerificationResult()
        for ownerUserID in ownerUserIDs {
            let ownerResult = try await verifySummaries(for: ownerUserID)
            result.accumulate(ownerResult)
        }
        return result
    }

    func listConversations(
        for userID: UUID,
        cursor rawCursor: String?,
        limit requestedLimit: Int?,
        kind rawKind: String? = nil
    ) async throws -> IMConversationPageResponse {
        let limit = normalizedPageLimit(requestedLimit)
        let cursor = try rawCursor.map(Self.decodePageCursor)
        let kind = try normalizedConversationKind(rawKind)
        let query = ConversationUserSummary.query(on: readModelDB)
            .filter(\.$ownerUserID == userID)
            .filter(\.$isRemoved == false)
            .sort(\.$isPinned, .descending)
            .sort(\.$pinnedAt, .descending)
            .sort(\.$lastActivityAt, .descending)
            .sort(\.$id, .descending)

        if let kind {
            query.filter(\.$kind == kind.rawValue)
        }

        if let cursor {
            query.group(.or) { group in
                if cursor.isPinned {
                    group.group(.and) { pinnedBefore in
                        pinnedBefore.filter(\.$isPinned == true)
                        pinnedBefore.filter(\.$pinnedAt < (cursor.pinnedAt ?? cursor.lastActivityAt))
                    }
                    group.group(.and) { pinnedTieBreaker in
                        pinnedTieBreaker.filter(\.$isPinned == true)
                        pinnedTieBreaker.filter(\.$pinnedAt == (cursor.pinnedAt ?? cursor.lastActivityAt))
                        pinnedTieBreaker.filter(\.$id < cursor.recordID)
                    }
                    group.filter(\.$isPinned == false)
                } else {
                    group.group(.and) { unpinnedBefore in
                        unpinnedBefore.filter(\.$isPinned == false)
                        unpinnedBefore.filter(\.$lastActivityAt < cursor.lastActivityAt)
                    }
                    group.group(.and) { unpinnedTieBreaker in
                        unpinnedTieBreaker.filter(\.$isPinned == false)
                        unpinnedTieBreaker.filter(\.$lastActivityAt == cursor.lastActivityAt)
                        unpinnedTieBreaker.filter(\.$id < cursor.recordID)
                    }
                }
            }
        }

        let rows = try await query
            .limit(limit + 1)
            .all()
        let hasMore = rows.count > limit
        let pageRows = Array(rows.prefix(limit))
        let items = pageRows.map(makeConversationResponse)
        let nextCursor = pageRows.last.map {
            Self.encodePageCursor(PageCursor(
                isPinned: $0.isPinned,
                pinnedAt: $0.pinnedAt,
                lastActivityAt: $0.lastActivityAt,
                recordID: $0.id ?? ConversationUserSummary.recordID(
                    ownerUserID: $0.ownerUserID,
                    conversationID: $0.conversationID
                )
            ))
        }

        let snapshotToken = try await latestToken(for: userID) ?? Self.encodeChangeToken(
            ChangeToken(updatedAt: .distantPast, recordID: "")
        )

        return IMConversationPageResponse(
            items: items,
            nextCursor: hasMore ? nextCursor : nil,
            hasMore: hasMore,
            snapshotToken: snapshotToken
        )
    }

    private func normalizedConversationKind(_ rawKind: String?) throws -> IMConversationKind? {
        guard let rawKind = rawKind?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawKind.isEmpty
        else {
            return nil
        }

        guard let kind = IMConversationKind(rawValue: rawKind) else {
            throw Abort(.badRequest, reason: "会话类型无效。")
        }

        return kind
    }

    func listConversationChanges(
        for userID: UUID,
        afterToken rawAfterToken: String,
        cursor rawCursor: String?,
        limit requestedLimit: Int?
    ) async throws -> IMConversationChangesResponse {
        let afterToken = try Self.decodeChangeToken(rawAfterToken)
        let pageCursor = try rawCursor.map(Self.decodeChangeToken)
        let limit = normalizedPageLimit(requestedLimit)

        let query = ConversationChangesLogEntry.query(on: readModelDB)
            .filter(\.$ownerUserID == userID)
            .sort(\.$updatedAt, .ascending)
            .sort(\.$id, .ascending)

        query.group(.or) { group in
            group.filter(\.$updatedAt > afterToken.updatedAt)
            group.group(.and) { tieBreaker in
                tieBreaker.filter(\.$updatedAt == afterToken.updatedAt)
                tieBreaker.filter(\.$id > afterToken.recordID)
            }
        }

        if let pageCursor {
            query.group(.or) { group in
                group.filter(\.$updatedAt > pageCursor.updatedAt)
                group.group(.and) { tieBreaker in
                    tieBreaker.filter(\.$updatedAt == pageCursor.updatedAt)
                    tieBreaker.filter(\.$id > pageCursor.recordID)
                }
            }
        }

        let rows = try await query
            .limit(limit + 1)
            .all()
        let hasMore = rows.count > limit
        let pageRows = Array(rows.prefix(limit))
        let summaryRecordIDs = pageRows
            .filter { !$0.isRemoved }
            .map(\.summaryRecordID)
        let summaries = try await ConversationUserSummary.query(on: readModelDB)
            .filter(\.$id ~~ summaryRecordIDs)
            .all()
        let summariesByRecordID: [String: ConversationUserSummary] = Dictionary(uniqueKeysWithValues: summaries.compactMap { summary in
            guard let recordID = summary.id else {
                return nil
            }
            return (recordID, summary)
        })
        let upserts = pageRows.compactMap { row -> IMConversationResponse? in
            guard !row.isRemoved, let summary = summariesByRecordID[row.summaryRecordID] else {
                return nil
            }
            return makeConversationResponse(from: summary)
        }
        let removedConversationIDs = pageRows
            .filter(\.isRemoved)
            .map(\.conversationID)
        let nextCursor = pageRows.last.map {
            Self.encodeChangeToken(ChangeToken(updatedAt: $0.updatedAt, recordID: $0.id ?? ""))
        }

        let targetToken = try await latestToken(for: userID) ?? rawAfterToken

        return IMConversationChangesResponse(
            upserts: upserts,
            removedConversationIDs: removedConversationIDs,
            nextCursor: hasMore ? nextCursor : nil,
            hasMore: hasMore,
            targetToken: targetToken
        )
    }

    private func findOrCreateSummary(
        ownerUserID: UUID,
        conversationID: UUID,
        on database: any Database
    ) async throws -> ConversationUserSummary {
        let recordID = ConversationUserSummary.recordID(ownerUserID: ownerUserID, conversationID: conversationID)
        if let existing = try await ConversationUserSummary.find(recordID, on: database) {
            return existing
        }

        return try ConversationUserSummary(
            ownerUserID: ownerUserID,
            conversationID: conversationID,
            title: nil,
            kind: IMConversationKind.group.rawValue,
            directMessagingState: nil,
            directPeerUserID: nil,
            directPeerEmail: nil,
            directPeerDisplayName: nil,
            directPeerAvatarPreset: nil,
            notice: nil,
            avatarPreset: nil,
            memberUserIDs: [],
            lastMessage: nil,
            lastReadSequence: 0,
            unreadCount: 0,
            isPinned: false,
            pinnedAt: nil,
            isMuted: false,
            lastActivityAt: .distantPast,
            updatedAt: .distantPast,
            isRemoved: false
        )
    }

    private func save(_ summary: ConversationUserSummary, on database: any Database) async throws {
        if try await ConversationUserSummary.find(summary.id, on: database) == nil {
            try await summary.create(on: database)
        } else {
            try await summary.update(on: database)
        }
    }

    func refreshDirectPeerProfiles(for userID: UUID) async throws -> [UUID: [UUID]] {
        let summaries = try await ConversationUserSummary.query(on: readModelDB)
            .filter(\.$directPeerUserID == userID)
            .all()
        guard !summaries.isEmpty else {
            return [:]
        }

        guard let user = try await User.find(userID, on: sourceDB) else {
            return [:]
        }

        var recipientUserIDsByConversationID: [UUID: [UUID]] = [:]
        for summary in summaries {
            summary.directPeerEmail = user.email
            summary.directPeerDisplayName = user.displayName
            summary.directPeerAvatarPresetEnum = user.avatarPresetEnum
            summary.updatedAt = Date()
            try await save(summary, on: readModelDB)
            try await upsertChangeLog(
                ownerUserID: summary.ownerUserID,
                conversationID: summary.conversationID,
                summaryRecordID: summary.id ?? ConversationUserSummary.recordID(
                    ownerUserID: summary.ownerUserID,
                    conversationID: summary.conversationID
                ),
                updatedAt: summary.updatedAt,
                isRemoved: summary.isRemoved,
                on: readModelDB
            )
            recipientUserIDsByConversationID[summary.conversationID, default: []].append(summary.ownerUserID)
        }

        return recipientUserIDsByConversationID.mapValues { ownerUserIDs in
            Array(Set(ownerUserIDs)).sorted { $0.uuidString < $1.uuidString }
        }
    }

    private func latestToken(for userID: UUID) async throws -> String? {
        if let token = try await ConversationReadModelToken.find(
            ConversationReadModelToken.recordID(ownerUserID: userID),
            on: readModelDB
        ) {
            return token.targetToken
        }

        guard let latest = try await ConversationChangesLogEntry.query(on: readModelDB)
            .filter(\.$ownerUserID == userID)
            .sort(\.$updatedAt, .descending)
            .sort(\.$id, .descending)
            .first()
        else {
            return nil
        }

        return Self.encodeChangeToken(ChangeToken(updatedAt: latest.updatedAt, recordID: latest.id ?? ""))
    }

    private func upsertChangeLog(
        ownerUserID: UUID,
        conversationID: UUID,
        summaryRecordID: String,
        updatedAt: Date,
        isRemoved: Bool,
        on database: any Database
    ) async throws {
        let recordID = ConversationChangesLogEntry.recordID(ownerUserID: ownerUserID, conversationID: conversationID)
        let entry = try await ConversationChangesLogEntry.find(recordID, on: database)
            ?? ConversationChangesLogEntry(
                ownerUserID: ownerUserID,
                conversationID: conversationID,
                summaryRecordID: summaryRecordID,
                updatedAt: updatedAt,
                isRemoved: isRemoved
            )
        entry.ownerUserID = ownerUserID
        entry.conversationID = conversationID
        entry.summaryRecordID = summaryRecordID
        entry.updatedAt = updatedAt
        entry.isRemoved = isRemoved

        if try await ConversationChangesLogEntry.find(recordID, on: database) == nil {
            try await entry.create(on: database)
        } else {
            try await entry.update(on: database)
        }

        let targetToken = Self.encodeChangeToken(
            ChangeToken(updatedAt: updatedAt, recordID: recordID)
        )
        let tokenRecordID = ConversationReadModelToken.recordID(ownerUserID: ownerUserID)
        let token = try await ConversationReadModelToken.find(tokenRecordID, on: database)
            ?? ConversationReadModelToken(ownerUserID: ownerUserID, targetToken: targetToken, updatedAt: updatedAt)
        token.ownerUserID = ownerUserID
        token.targetToken = targetToken
        token.updatedAt = updatedAt
        if try await ConversationReadModelToken.find(tokenRecordID, on: database) == nil {
            try await token.create(on: database)
        } else {
            try await token.update(on: database)
        }
    }

    private func normalizedPageLimit(_ requestedLimit: Int?) -> Int {
        let requested = requestedLimit ?? 50
        return max(1, min(requested, 100))
    }

    private func makeConversationResponse(from row: ConversationUserSummary) -> IMConversationResponse {
        IMConversationResponse(
            id: row.conversationID,
            title: row.title,
            kind: row.kind,
            directMessagingState: row.directMessagingState,
            directPeer: row.directPeerUserID.map { directPeerUserID in
                IMDirectPeerResponse(
                    id: directPeerUserID,
                    email: row.directPeerEmail ?? "",
                    displayName: row.directPeerDisplayName,
                    avatarPreset: row.directPeerAvatarPresetEnum
                )
            },
            notice: row.notice,
            avatarPreset: row.avatarPresetEnum,
            memberCount: row.memberCount,
            memberUserIDs: row.memberUserIDs.sorted { $0.uuidString < $1.uuidString },
            lastMessage: row.lastMessage,
            lastReadSequence: row.lastReadSequence,
            unreadCount: row.unreadCount,
            isPinned: row.isPinned,
            pinnedAt: row.pinnedAt,
            isMuted: row.isMuted,
            createdAt: nil,
            updatedAt: row.lastActivityAt
        )
    }

    private func directPeer(
        from memberships: [ConversationMember],
        currentUserID: UUID
    ) -> IMDirectPeerResponse? {
        guard let peerMembership = memberships.first(where: { $0.$user.id != currentUserID }),
              let peer = peerMembership.$user.value
        else {
            return nil
        }

        return IMDirectPeerResponse(
            id: peerMembership.$user.id,
            email: peer.email,
            displayName: peer.displayName,
            avatarPreset: peer.avatarPresetEnum
        )
    }

    private func makePreview(from message: ConversationMessage) throws -> IMMessagePreviewResponse {
        let content = try message.decodedContent()
        let derivedState = try message.decodedDerivedState()
        return IMMessagePreviewResponse(
            id: try message.requireID(),
            senderUserID: message.$sender.id,
            serverSequence: message.serverSequence,
            content: content,
            derivedState: derivedState,
            createdAt: message.createdAt
        )
    }

    private static func encodePageCursor(_ cursor: PageCursor) -> String {
        encode(cursor)
    }

    private static func decodePageCursor(_ value: String) throws -> PageCursor {
        try decode(PageCursor.self, from: value)
    }

    private static func encodeChangeToken(_ token: ChangeToken) -> String {
        encode(token)
    }

    private static func decodeChangeToken(_ value: String) throws -> ChangeToken {
        try decode(ChangeToken.self, from: value)
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(value)) ?? Data()
        return data.base64EncodedString()
    }

    private static func decode<T: Decodable>(_ type: T.Type, from value: String) throws -> T {
        guard let data = Data(base64Encoded: value) else {
            throw Abort(.badRequest, reason: "分页游标无效。")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
