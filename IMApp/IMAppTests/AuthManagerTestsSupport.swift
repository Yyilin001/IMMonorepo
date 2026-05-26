import Foundation
@testable import IMClientKit
import Testing
@testable import IMApp

import Foundation
@testable import IMClientKit
import Testing
@testable import IMApp

actor RestoreGate {
    private var hasStarted = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var resumeContinuations: [CheckedContinuation<Void, Never>] = []
    private var isResumed = false

    func markStarted() {
        hasStarted = true
        startContinuation?.resume()
        startContinuation = nil
    }

    func waitUntilStarted() async {
        guard !hasStarted else {
            return
        }

        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func started() -> Bool {
        hasStarted
    }

    func waitForResume() async {
        guard !isResumed else {
            return
        }

        await withCheckedContinuation { continuation in
            resumeContinuations.append(continuation)
        }
    }

    func resume() {
        isResumed = true
        let continuations = resumeContinuations
        resumeContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

actor IMGapSyncCounter {
    private var value = 0

    func increment() {
        value += 1
    }

    func currentValue() -> Int {
        value
    }
}

actor IMRequestCounter {
    private var counts: [String: Int] = [:]

    func increment(_ key: String) {
        counts[key, default: 0] += 1
    }

    func count(for key: String) -> Int {
        counts[key, default: 0]
    }
}

actor IMReadSequenceRecorder {
    private var sequences: [UInt64] = []

    func record(_ sequence: UInt64) {
        sequences.append(sequence)
    }

    func allSequences() -> [UInt64] {
        sequences
    }
}

actor IMConversationMutationState {
    private var didMutate = false

    func markMutated() {
        didMutate = true
    }

    func isMutated() -> Bool {
        didMutate
    }
}

actor IMSummarySequenceState {
    private var latestServerSequence: Int

    init(latestServerSequence: Int = 1) {
        self.latestServerSequence = latestServerSequence
    }

    func setLatestServerSequence(_ sequence: Int) {
        latestServerSequence = sequence
    }

    func currentLatestServerSequence() -> Int {
        latestServerSequence
    }
}

actor IMCrossDeviceConversationSummaryState {
    private var summary: IMConversationSummaryResponseBody
    private var version: Int
    private var messages: [IMConversationMessageResponseBody]

    init(
        summary: IMConversationSummaryResponseBody,
        version: Int = 0,
        messages: [IMConversationMessageResponseBody] = []
    ) {
        self.summary = summary
        self.version = version
        self.messages = messages.sorted { lhs, rhs in
            if lhs.serverSequence != rhs.serverSequence {
                return lhs.serverSequence < rhs.serverSequence
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    func pageResponse() -> IMConversationSummaryPageResponseBody {
        IMConversationSummaryPageResponseBody(
            items: [summary],
            nextCursor: nil,
            hasMore: false,
            snapshotToken: snapshotToken
        )
    }

    func changesResponse(afterToken: String?) -> IMConversationSummaryChangesResponseBody {
        let currentToken = snapshotToken
        let upserts = afterToken == currentToken ? [] : [summary]
        return IMConversationSummaryChangesResponseBody(
            upserts: upserts,
            removedConversationIDs: [],
            nextCursor: nil,
            hasMore: false,
            targetToken: currentToken
        )
    }

    func currentSummary() -> IMConversationSummaryResponseBody {
        summary
    }

    func updatePreferences(
        isPinned: Bool?,
        isMuted: Bool?
    ) -> IMConversationSummaryResponseBody {
        version += 1
        let updatedAt = Date(timeIntervalSince1970: 1_700_700_000 + Double(version))
        summary = IMConversationSummaryResponseBody(
            id: summary.id,
            title: summary.title,
            kind: summary.kind,
            directMessagingState: summary.directMessagingState,
            directPeer: summary.directPeer,
            memberCount: summary.memberCount,
            memberUserIDs: summary.memberUserIDs,
            notice: summary.notice,
            avatarPreset: summary.avatarPreset,
            lastMessage: summary.lastMessage,
            lastReadSequence: summary.lastReadSequence,
            unreadCount: summary.unreadCount,
            isPinned: isPinned ?? summary.isPinned,
            pinnedAt: (isPinned ?? summary.isPinned) ? updatedAt : nil,
            isMuted: isMuted ?? summary.isMuted,
            createdAt: summary.createdAt,
            updatedAt: updatedAt
        )
        return summary
    }

    func updateMetadata(
        title: String?,
        notice: String?,
        avatarPreset: IMConversationAvatarPreset?
    ) -> IMConversationSummaryResponseBody {
        version += 1
        let updatedAt = Date(timeIntervalSince1970: 1_700_700_000 + Double(version))
        summary = IMConversationSummaryResponseBody(
            id: summary.id,
            title: title ?? summary.title,
            kind: summary.kind,
            directMessagingState: summary.directMessagingState,
            directPeer: summary.directPeer,
            memberCount: summary.memberCount,
            memberUserIDs: summary.memberUserIDs,
            notice: notice ?? summary.notice,
            avatarPreset: avatarPreset ?? summary.avatarPreset,
            lastMessage: summary.lastMessage,
            lastReadSequence: summary.lastReadSequence,
            unreadCount: summary.unreadCount,
            isPinned: summary.isPinned,
            pinnedAt: summary.pinnedAt,
            isMuted: summary.isMuted,
            createdAt: summary.createdAt,
            updatedAt: updatedAt
        )
        return summary
    }

    func messagesResponse() -> [IMConversationMessageResponseBody] {
        messages
    }

    func messagesSinceResponse(afterSequence: UInt64?) -> IMConversationMessagesSinceResponseBody {
        let minimumSequence = afterSequence.map(Int.init) ?? 0
        let filteredMessages = messages.filter { $0.serverSequence > minimumSequence }
        return IMConversationMessagesSinceResponseBody(
            messages: filteredMessages,
            hasMore: false,
            nextAfterSequence: filteredMessages.last?.serverSequence
        )
    }

    func appendMessage(
        _ message: IMConversationMessageResponseBody,
        unreadCount: Int,
        lastReadSequence: Int
    ) {
        version += 1
        messages.removeAll { $0.id == message.id }
        messages.append(message)
        messages.sort { lhs, rhs in
            if lhs.serverSequence != rhs.serverSequence {
                return lhs.serverSequence < rhs.serverSequence
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        summary = IMConversationSummaryResponseBody(
            id: summary.id,
            title: summary.title,
            kind: summary.kind,
            directMessagingState: summary.directMessagingState,
            directPeer: summary.directPeer,
            memberCount: summary.memberCount,
            memberUserIDs: summary.memberUserIDs,
            notice: summary.notice,
            avatarPreset: summary.avatarPreset,
            lastMessage: IMMessagePreviewResponseBody(
                id: message.id,
                senderUserID: message.senderUserID,
                serverSequence: message.serverSequence,
                content: message.content,
                createdAt: message.createdAt
            ),
            lastReadSequence: lastReadSequence,
            unreadCount: unreadCount,
            isPinned: summary.isPinned,
            pinnedAt: summary.pinnedAt,
            isMuted: summary.isMuted,
            createdAt: summary.createdAt,
            updatedAt: message.createdAt ?? Date(timeIntervalSince1970: 1_700_700_000 + Double(version))
        )
    }

    func updateReadState(
        lastReadSequence: Int,
        unreadCount: Int
    ) -> IMConversationSummaryResponseBody {
        version += 1
        let updatedAt = Date(timeIntervalSince1970: 1_700_700_000 + Double(version))
        summary = IMConversationSummaryResponseBody(
            id: summary.id,
            title: summary.title,
            kind: summary.kind,
            directMessagingState: summary.directMessagingState,
            directPeer: summary.directPeer,
            memberCount: summary.memberCount,
            memberUserIDs: summary.memberUserIDs,
            notice: summary.notice,
            avatarPreset: summary.avatarPreset,
            lastMessage: summary.lastMessage,
            lastReadSequence: lastReadSequence,
            unreadCount: unreadCount,
            isPinned: summary.isPinned,
            pinnedAt: summary.pinnedAt,
            isMuted: summary.isMuted,
            createdAt: summary.createdAt,
            updatedAt: updatedAt
        )
        return summary
    }

    func recallLatestMessage(
        senderUserID: UUID
    ) -> IMConversationMessageRecallResponseBody? {
        guard let lastMessage = summary.lastMessage else {
            return nil
        }

        version += 1
        let updatedAt = Date(timeIntervalSince1970: 1_700_700_000 + Double(version))
        if let messageIndex = messages.firstIndex(where: { $0.id == lastMessage.id }) {
            messages[messageIndex] = IMConversationMessageResponseBody(
                id: lastMessage.id,
                conversationID: summary.id,
                senderUserID: senderUserID,
                clientMessageID: messages[messageIndex].clientMessageID,
                serverSequence: lastMessage.serverSequence,
                content: .recalled,
                createdAt: lastMessage.createdAt
            )
        }
        summary = IMConversationSummaryResponseBody(
            id: summary.id,
            title: summary.title,
            kind: summary.kind,
            directMessagingState: summary.directMessagingState,
            directPeer: summary.directPeer,
            memberCount: summary.memberCount,
            memberUserIDs: summary.memberUserIDs,
            notice: summary.notice,
            avatarPreset: summary.avatarPreset,
            lastMessage: IMMessagePreviewResponseBody(
                id: lastMessage.id,
                senderUserID: senderUserID,
                serverSequence: lastMessage.serverSequence,
                content: .recalled,
                createdAt: lastMessage.createdAt
            ),
            lastReadSequence: summary.lastReadSequence,
            unreadCount: summary.unreadCount,
            isPinned: summary.isPinned,
            pinnedAt: summary.pinnedAt,
            isMuted: summary.isMuted,
            createdAt: summary.createdAt,
            updatedAt: updatedAt
        )

        return IMConversationMessageRecallResponseBody(
            id: lastMessage.id,
            conversationID: summary.id,
            senderUserID: senderUserID,
            clientMessageID: nil,
            serverSequence: lastMessage.serverSequence,
            content: .recalled,
            createdAt: lastMessage.createdAt
        )
    }

    private var snapshotToken: String {
        "snapshot-\(version)"
    }
}

actor IMCrossDeviceConversationListState {
    private var orderedConversationIDs: [UUID]
    private var summariesByID: [UUID: IMConversationSummaryResponseBody]
    private var messagesByConversationID: [UUID: [IMConversationMessageResponseBody]]
    private var removedConversationIDs: [UUID]
    private var version: Int

    init(
        conversations: [IMConversationSummaryResponseBody],
        messagesByConversationID: [UUID: [IMConversationMessageResponseBody]] = [:],
        version: Int = 0
    ) {
        self.orderedConversationIDs = conversations.map(\.id)
        self.summariesByID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
        self.messagesByConversationID = messagesByConversationID
        self.removedConversationIDs = []
        self.version = version
    }

    func pageResponse() -> IMConversationSummaryPageResponseBody {
        IMConversationSummaryPageResponseBody(
            items: orderedConversationIDs.compactMap { summariesByID[$0] },
            nextCursor: nil,
            hasMore: false,
            snapshotToken: snapshotToken
        )
    }

    func changesResponse(afterToken: String?) -> IMConversationSummaryChangesResponseBody {
        let currentToken = snapshotToken
        let shouldEmitChanges = afterToken != currentToken
        let upserts = shouldEmitChanges
            ? orderedConversationIDs.compactMap { summariesByID[$0] }
            : []
        return IMConversationSummaryChangesResponseBody(
            upserts: upserts,
            removedConversationIDs: shouldEmitChanges ? removedConversationIDs : [],
            nextCursor: nil,
            hasMore: false,
            targetToken: currentToken
        )
    }

    func upsertSummary(_ summary: IMConversationSummaryResponseBody) {
        version += 1
        summariesByID[summary.id] = summary
        removedConversationIDs.removeAll { $0 == summary.id }
        if !orderedConversationIDs.contains(summary.id) {
            orderedConversationIDs.append(summary.id)
        }
    }

    func removeConversation(id conversationID: UUID) {
        version += 1
        summariesByID.removeValue(forKey: conversationID)
        messagesByConversationID.removeValue(forKey: conversationID)
        orderedConversationIDs.removeAll { $0 == conversationID }
        if !removedConversationIDs.contains(conversationID) {
            removedConversationIDs.append(conversationID)
        }
    }

    func messagesResponse(for conversationID: UUID) -> [IMConversationMessageResponseBody] {
        messagesByConversationID[conversationID, default: []]
            .sorted { lhs, rhs in
                if lhs.serverSequence != rhs.serverSequence {
                    return lhs.serverSequence < rhs.serverSequence
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    func messagesSinceResponse(
        for conversationID: UUID,
        afterSequence: UInt64?
    ) -> IMConversationMessagesSinceResponseBody {
        let minimumSequence = afterSequence.map(Int.init) ?? 0
        let filteredMessages = messagesResponse(for: conversationID)
            .filter { $0.serverSequence > minimumSequence }
        return IMConversationMessagesSinceResponseBody(
            messages: filteredMessages,
            hasMore: false,
            nextAfterSequence: filteredMessages.last?.serverSequence
            )
    }

    func currentSummary(for conversationID: UUID) -> IMConversationSummaryResponseBody? {
        summariesByID[conversationID]
    }

    func editMessage(
        id messageID: UUID,
        in conversationID: UUID,
        text: String
    ) -> IMConversationMessageResponseBody? {
        guard var messages = messagesByConversationID[conversationID],
              let messageIndex = messages.firstIndex(where: { $0.id == messageID }),
              let summary = summariesByID[conversationID]
        else {
            return nil
        }

        let originalMessage = messages[messageIndex]
        switch originalMessage.content {
        case .richText, .reply:
            break
        case .recalled, .system, .image, .audio, .file:
            return nil
        }

        version += 1
        let editedState = IMMessageDerivedState(
            recallState: originalMessage.derivedState.recallState,
            edits: originalMessage.derivedState.edits + [
                .init(
                    editedAt: Date(timeIntervalSince1970: 1_700_800_000 + Double(version)),
                    body: .plain(text)
                )
            ],
            reactions: originalMessage.derivedState.reactions
        )
        let updatedMessage = IMConversationMessageResponseBody(
            id: originalMessage.id,
            conversationID: originalMessage.conversationID,
            senderUserID: originalMessage.senderUserID,
            clientMessageID: originalMessage.clientMessageID,
            serverSequence: originalMessage.serverSequence,
            content: originalMessage.content,
            derivedState: editedState,
            createdAt: originalMessage.createdAt
        )
        messages[messageIndex] = updatedMessage
        messages.sort { lhs, rhs in
            if lhs.serverSequence != rhs.serverSequence {
                return lhs.serverSequence < rhs.serverSequence
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        messagesByConversationID[conversationID] = messages
        summariesByID[conversationID] = updatedSummary(
            for: summary,
            using: messages.last,
            updatedAt: Date(timeIntervalSince1970: 1_700_800_000 + Double(version))
        )
        return updatedMessage
    }

    func toggleReaction(
        on messageID: UUID,
        in conversationID: UUID,
        actorUserID: UUID,
        emoji: String
    ) -> IMConversationMessageResponseBody? {
        guard var messages = messagesByConversationID[conversationID],
              let messageIndex = messages.firstIndex(where: { $0.id == messageID }),
              let summary = summariesByID[conversationID]
        else {
            return nil
        }

        let originalMessage = messages[messageIndex]
        switch originalMessage.content {
        case .richText, .reply, .image, .audio, .file:
            break
        case .recalled, .system:
            return nil
        }

        version += 1
        var reactions = originalMessage.derivedState.reactions
        if let index = reactions.firstIndex(where: { $0.emoji == emoji }) {
            var actorUserIDs = reactions[index].actorUserIDs
            if let existingIndex = actorUserIDs.firstIndex(of: actorUserID) {
                actorUserIDs.remove(at: existingIndex)
            } else {
                actorUserIDs.append(actorUserID)
                actorUserIDs.sort { $0.uuidString < $1.uuidString }
            }

            if actorUserIDs.isEmpty {
                reactions.remove(at: index)
            } else {
                reactions[index] = .init(emoji: emoji, actorUserIDs: actorUserIDs)
            }
        } else {
            reactions.append(.init(emoji: emoji, actorUserIDs: [actorUserID]))
            reactions.sort { $0.emoji < $1.emoji }
        }

        let updatedState = IMMessageDerivedState(
            recallState: originalMessage.derivedState.recallState,
            edits: originalMessage.derivedState.edits,
            reactions: reactions
        )
        let updatedMessage = IMConversationMessageResponseBody(
            id: originalMessage.id,
            conversationID: originalMessage.conversationID,
            senderUserID: originalMessage.senderUserID,
            clientMessageID: originalMessage.clientMessageID,
            serverSequence: originalMessage.serverSequence,
            content: originalMessage.content,
            derivedState: updatedState,
            createdAt: originalMessage.createdAt
        )
        messages[messageIndex] = updatedMessage
        messages.sort { lhs, rhs in
            if lhs.serverSequence != rhs.serverSequence {
                return lhs.serverSequence < rhs.serverSequence
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        messagesByConversationID[conversationID] = messages
        summariesByID[conversationID] = updatedSummary(
            for: summary,
            using: messages.last,
            updatedAt: Date(timeIntervalSince1970: 1_700_800_000 + Double(version))
        )
        return updatedMessage
    }

    func appendMessage(
        _ message: IMConversationMessageResponseBody,
        unreadCount: Int,
        lastReadSequence: Int
    ) {
        version += 1
        var messages = messagesByConversationID[message.conversationID, default: []]
        messages.removeAll { $0.id == message.id }
        messages.append(message)
        messages.sort { lhs, rhs in
            if lhs.serverSequence != rhs.serverSequence {
                return lhs.serverSequence < rhs.serverSequence
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        messagesByConversationID[message.conversationID] = messages

        guard let summary = summariesByID[message.conversationID] else {
            return
        }

        summariesByID[message.conversationID] = IMConversationSummaryResponseBody(
            id: summary.id,
            title: summary.title,
            kind: summary.kind,
            directMessagingState: summary.directMessagingState,
            directPeer: summary.directPeer,
            memberCount: summary.memberCount,
            memberUserIDs: summary.memberUserIDs,
            notice: summary.notice,
            avatarPreset: summary.avatarPreset,
            lastMessage: IMMessagePreviewResponseBody(
                id: message.id,
                senderUserID: message.senderUserID,
                serverSequence: message.serverSequence,
                content: message.content,
                createdAt: message.createdAt
            ),
            lastReadSequence: lastReadSequence,
            unreadCount: unreadCount,
            isPinned: summary.isPinned,
            pinnedAt: summary.pinnedAt,
            isMuted: summary.isMuted,
            createdAt: summary.createdAt,
            updatedAt: message.createdAt ?? Date(timeIntervalSince1970: 1_700_800_000 + Double(version))
        )
    }

    func recallLatestMessage(
        in conversationID: UUID,
        senderUserID: UUID
    ) -> IMConversationMessageRecallResponseBody? {
        guard let summary = summariesByID[conversationID],
              let lastMessage = summary.lastMessage
        else {
            return nil
        }

        version += 1
        if var messages = messagesByConversationID[conversationID],
           let messageIndex = messages.firstIndex(where: { $0.id == lastMessage.id }) {
            messages[messageIndex] = IMConversationMessageResponseBody(
                id: lastMessage.id,
                conversationID: conversationID,
                senderUserID: senderUserID,
                clientMessageID: messages[messageIndex].clientMessageID,
                serverSequence: lastMessage.serverSequence,
                content: .recalled,
                createdAt: lastMessage.createdAt
            )
            messagesByConversationID[conversationID] = messages
        }

        summariesByID[conversationID] = IMConversationSummaryResponseBody(
            id: summary.id,
            title: summary.title,
            kind: summary.kind,
            directMessagingState: summary.directMessagingState,
            directPeer: summary.directPeer,
            memberCount: summary.memberCount,
            memberUserIDs: summary.memberUserIDs,
            notice: summary.notice,
            avatarPreset: summary.avatarPreset,
            lastMessage: IMMessagePreviewResponseBody(
                id: lastMessage.id,
                senderUserID: senderUserID,
                serverSequence: lastMessage.serverSequence,
                content: .recalled,
                createdAt: lastMessage.createdAt
            ),
            lastReadSequence: summary.lastReadSequence,
            unreadCount: summary.unreadCount,
            isPinned: summary.isPinned,
            pinnedAt: summary.pinnedAt,
            isMuted: summary.isMuted,
            createdAt: summary.createdAt,
            updatedAt: Date(timeIntervalSince1970: 1_700_800_000 + Double(version))
        )

        return IMConversationMessageRecallResponseBody(
            id: lastMessage.id,
            conversationID: conversationID,
            senderUserID: senderUserID,
            clientMessageID: nil,
            serverSequence: lastMessage.serverSequence,
            content: .recalled,
            createdAt: lastMessage.createdAt
        )
    }

    func recallMessage(
        id messageID: UUID,
        in conversationID: UUID,
        senderUserID: UUID
    ) -> IMConversationMessageRecallResponseBody? {
        guard var messages = messagesByConversationID[conversationID],
              let messageIndex = messages.firstIndex(where: { $0.id == messageID }),
              let summary = summariesByID[conversationID]
        else {
            return nil
        }

        version += 1
        let originalMessage = messages[messageIndex]
        let recalledMessage = IMConversationMessageResponseBody(
            id: originalMessage.id,
            conversationID: conversationID,
            senderUserID: senderUserID,
            clientMessageID: originalMessage.clientMessageID,
            serverSequence: originalMessage.serverSequence,
            content: .recalled,
            createdAt: originalMessage.createdAt
        )
        messages[messageIndex] = recalledMessage
        messages.sort { lhs, rhs in
            if lhs.serverSequence != rhs.serverSequence {
                return lhs.serverSequence < rhs.serverSequence
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        messagesByConversationID[conversationID] = messages

        let lastMessage = messages.last
        summariesByID[conversationID] = IMConversationSummaryResponseBody(
            id: summary.id,
            title: summary.title,
            kind: summary.kind,
            directMessagingState: summary.directMessagingState,
            directPeer: summary.directPeer,
            memberCount: summary.memberCount,
            memberUserIDs: summary.memberUserIDs,
            notice: summary.notice,
            avatarPreset: summary.avatarPreset,
            lastMessage: lastMessage.map {
                IMMessagePreviewResponseBody(
                    id: $0.id,
                    senderUserID: $0.senderUserID,
                    serverSequence: $0.serverSequence,
                    content: $0.content,
                    createdAt: $0.createdAt
                )
            },
            lastReadSequence: summary.lastReadSequence,
            unreadCount: summary.unreadCount,
            isPinned: summary.isPinned,
            pinnedAt: summary.pinnedAt,
            isMuted: summary.isMuted,
            createdAt: summary.createdAt,
            updatedAt: Date(timeIntervalSince1970: 1_700_800_000 + Double(version))
        )

        return IMConversationMessageRecallResponseBody(
            id: originalMessage.id,
            conversationID: conversationID,
            senderUserID: senderUserID,
            clientMessageID: originalMessage.clientMessageID,
            serverSequence: originalMessage.serverSequence,
            content: .recalled,
            createdAt: originalMessage.createdAt
        )
    }

    func updateReadState(
        for conversationID: UUID,
        lastReadSequence: Int,
        unreadCount: Int
    ) {
        version += 1
        guard let summary = summariesByID[conversationID] else {
            return
        }

        summariesByID[conversationID] = IMConversationSummaryResponseBody(
            id: summary.id,
            title: summary.title,
            kind: summary.kind,
            directMessagingState: summary.directMessagingState,
            directPeer: summary.directPeer,
            memberCount: summary.memberCount,
            memberUserIDs: summary.memberUserIDs,
            notice: summary.notice,
            avatarPreset: summary.avatarPreset,
            lastMessage: summary.lastMessage,
            lastReadSequence: lastReadSequence,
            unreadCount: unreadCount,
            isPinned: summary.isPinned,
            pinnedAt: summary.pinnedAt,
            isMuted: summary.isMuted,
            createdAt: summary.createdAt,
            updatedAt: Date(timeIntervalSince1970: 1_700_800_000 + Double(version))
        )
    }

    private var snapshotToken: String {
        "snapshot-\(version)"
    }

    private func updatedSummary(
        for summary: IMConversationSummaryResponseBody,
        using lastMessage: IMConversationMessageResponseBody?,
        updatedAt: Date
    ) -> IMConversationSummaryResponseBody {
        IMConversationSummaryResponseBody(
            id: summary.id,
            title: summary.title,
            kind: summary.kind,
            directMessagingState: summary.directMessagingState,
            directPeer: summary.directPeer,
            memberCount: summary.memberCount,
            memberUserIDs: summary.memberUserIDs,
            notice: summary.notice,
            avatarPreset: summary.avatarPreset,
            lastMessage: lastMessage.map {
                IMMessagePreviewResponseBody(
                    id: $0.id,
                    senderUserID: $0.senderUserID,
                    serverSequence: $0.serverSequence,
                    content: $0.content,
                    derivedState: $0.derivedState,
                    createdAt: $0.createdAt
                )
            },
            lastReadSequence: summary.lastReadSequence,
            unreadCount: summary.unreadCount,
            isPinned: summary.isPinned,
            pinnedAt: summary.pinnedAt,
            isMuted: summary.isMuted,
            createdAt: summary.createdAt,
            updatedAt: updatedAt
        )
    }
}

actor IMCrossDeviceConversationMembersState {
    private var membersByConversationID: [UUID: [IMConversationMemberResponseBody]]

    init(membersByConversationID: [UUID: [IMConversationMemberResponseBody]]) {
        self.membersByConversationID = membersByConversationID
    }

    func membersResponse(for conversationID: UUID) -> [IMConversationMemberResponseBody] {
        membersByConversationID[conversationID, default: []]
    }

    func updateRole(
        in conversationID: UUID,
        memberUserID: UUID,
        role: IMConversationMemberRole
    ) {
        guard var members = membersByConversationID[conversationID],
              let memberIndex = members.firstIndex(where: { $0.id == memberUserID })
        else {
            return
        }

        members[memberIndex] = IMConversationMemberResponseBody(
            id: members[memberIndex].id,
            email: members[memberIndex].email,
            role: role
        )
        membersByConversationID[conversationID] = members
    }
}

final class AuthManagerBackgroundTransferMonitor: BackgroundTransferMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [BackgroundTransferSnapshot]
    private var continuations: [UUID: AsyncStream<BackgroundTransferSnapshot>.Continuation] = [:]

    init(initialSnapshots: [BackgroundTransferSnapshot] = []) {
        self.snapshots = initialSnapshots
    }

    func currentSnapshots() -> [BackgroundTransferSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return snapshots
    }

    func updates() -> AsyncStream<BackgroundTransferSnapshot> {
        AsyncStream { continuation in
            let identifier = UUID()
            lock.lock()
            continuations[identifier] = continuation
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.continuations.removeValue(forKey: identifier)
                self?.lock.unlock()
            }
        }
    }

    func cancelTransfer(sessionIdentifier: String, taskIdentifier: Int) async {
        removeSnapshot(sessionIdentifier: sessionIdentifier, taskIdentifier: taskIdentifier)
    }

    private func removeSnapshot(sessionIdentifier: String, taskIdentifier: Int) {
        lock.lock()
        snapshots.removeAll {
            $0.sessionIdentifier == sessionIdentifier && $0.taskIdentifier == taskIdentifier
        }
        lock.unlock()
    }

    func emit(_ snapshot: BackgroundTransferSnapshot) {
        let isActive: Bool
        switch snapshot.state {
        case .running, .waitingForConnectivity:
            isActive = true
        case .completed, .cancelled, .failed:
            isActive = false
        }

        lock.lock()
        if isActive {
            snapshots.removeAll { $0.id == snapshot.id }
            snapshots.append(snapshot)
        } else {
            snapshots.removeAll { $0.id == snapshot.id }
        }
        let currentContinuations = Array(continuations.values)
        lock.unlock()

        currentContinuations.forEach { $0.yield(snapshot) }
    }
}

actor IMConnectionTestHarness {
    private var continuation: AsyncThrowingStream<IMTCPConnectionEvent, Error>.Continuation?
    private var pendingEvents: [IMTCPConnectionEvent] = []
    private var disconnectCount = 0
    private var sentFrames: [Data] = []
    private var sendAttemptCount = 0
    private let sendDelayNanoseconds: UInt64
    private let failingSendNumbers: Set<Int>

    init(sendDelayNanoseconds: UInt64 = 0, failingSendNumbers: Set<Int> = []) {
        self.sendDelayNanoseconds = sendDelayNanoseconds
        self.failingSendNumbers = failingSendNumbers
    }

    func makeConnection() -> IMTCPConnection {
        let events = AsyncThrowingStream<IMTCPConnectionEvent, Error> { continuation in
            self.continuation = continuation
            let events = self.pendingEvents
            self.pendingEvents.removeAll()
            for event in events {
                continuation.yield(event)
            }
        }

        return IMTCPConnection(
            authentication: IMTCPAuthAcceptedPayload(
                connectionID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
                userID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                sessionID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
                heartbeatIntervalSeconds: 30,
                serverTime: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            events: events,
            sendFrame: { frame in
                try await self.record(frame)
            },
            disconnectHandler: {
                await self.disconnect()
            }
        )
    }

    func yield(_ event: IMTCPConnectionEvent) {
        if let continuation {
            continuation.yield(event)
        } else {
            pendingEvents.append(event)
        }
    }

    func disconnections() -> Int {
        disconnectCount
    }

    func recordedLines() -> [Data] {
        sentFrames
    }

    private func disconnect() {
        disconnectCount += 1
        continuation?.finish()
        continuation = nil
        pendingEvents.removeAll()
    }

    private func record(_ frame: Data) async throws {
        if sendDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: sendDelayNanoseconds)
        }
        sendAttemptCount += 1
        if failingSendNumbers.contains(sendAttemptCount) {
            throw URLError(.notConnectedToInternet)
        }
        sentFrames.append(frame)
    }
}
