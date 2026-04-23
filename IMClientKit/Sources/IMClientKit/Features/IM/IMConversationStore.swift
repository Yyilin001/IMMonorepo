import Combine
import Foundation

public enum IMConversationKind: String, Codable, Equatable, Sendable {
    case direct
    case group
}

public enum IMMessageDirection: String, Equatable, Sendable {
    case incoming
    case outgoing
}

public enum IMMessageDeliveryState: Equatable, Sendable {
    case queued(message: String)
    case sending
    case sent
    case received
    case unknown(message: String)
    case failed(message: String)
}

public struct IMConversationMessage: Identifiable, Equatable, Sendable {
    public let id: String
    public let conversationID: String
    public let clientMessageID: String?
    public var serverMessageID: String?
    public var senderUserID: UUID?
    public var serverSequence: UInt64?
    public let kind: String
    public let text: String
    public let direction: IMMessageDirection
    public var createdAt: Date
    public var deliveryState: IMMessageDeliveryState
}

public struct IMConversationMember: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let email: String
}

public struct IMConversation: Identifiable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var kind: IMConversationKind
    public var memberCount: Int
    public var memberUserIDs: [UUID]
    public var members: [IMConversationMember]
    public var messages: [IMConversationMessage]
    public var lastMessagePreviewText: String
    public var hasMoreHistory: Bool
    public var serverLastReadSequence: UInt64
    public var serverUnreadCount: Int
    public var localUnreadDelta: Int
    public var updatedAt: Date

    public var unreadCount: Int {
        max(0, serverUnreadCount + localUnreadDelta)
    }

    public var lastMessagePreview: String {
        messages.last?.text ?? lastMessagePreviewText
    }
}

public struct IMOutgoingMessageRequest: Sendable {
    public let requestID: UUID
    public let localMessageID: String
    public let payload: IMTCPMessagePayload
}

public struct IMConversationQueueSummary: Equatable, Sendable {
    public let queuedCount: Int
    public let sendingCount: Int
    public let retryableIssueCount: Int

    public var hasPendingWork: Bool {
        queuedCount > 0 || sendingCount > 0 || retryableIssueCount > 0
    }

    public init(queuedCount: Int, sendingCount: Int, retryableIssueCount: Int) {
        self.queuedCount = queuedCount
        self.sendingCount = sendingCount
        self.retryableIssueCount = retryableIssueCount
    }
}

public struct IMConversationEventApplyOutcome: Equatable, Sendable {
    public let shouldReloadMembersForConversationID: String?
}

@MainActor
public final class IMConversationStore: ObservableObject {
    @Published public private(set) var conversations: [IMConversation] = []
    @Published public private(set) var selectedConversationID: String?
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var isLoadingConversations = false
    @Published public private(set) var isLoadingMembers = false
    @Published public private(set) var isLoadingMessages = false

    private var pendingOutgoingRequestIDs: [UUID: String] = [:]
    private var loadedConversationIDs: Set<String> = []
    private var latestSyncedServerSequences: [String: UInt64] = [:]
    private var oldestLoadedServerSequences: [String: UInt64] = [:]

    public var selectedConversation: IMConversation? {
        guard let selectedConversationID else {
            return conversations.first
        }

        return conversations.first { $0.id == selectedConversationID } ?? conversations.first
    }

    public init() { }

    public var totalUnreadCount: Int {
        conversations.reduce(0) { $0 + $1.unreadCount }
    }

    public func queueSummary(for conversationID: String) -> IMConversationQueueSummary {
        let trimmedID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty,
              let conversation = conversations.first(where: { $0.id == trimmedID })
        else {
            return IMConversationQueueSummary(queuedCount: 0, sendingCount: 0, retryableIssueCount: 0)
        }

        return queueSummary(for: conversation.messages)
    }

    public func totalQueueSummary() -> IMConversationQueueSummary {
        conversations.reduce(IMConversationQueueSummary(queuedCount: 0, sendingCount: 0, retryableIssueCount: 0)) {
            let next = queueSummary(for: $1.messages)
            return IMConversationQueueSummary(
                queuedCount: $0.queuedCount + next.queuedCount,
                sendingCount: $0.sendingCount + next.sendingCount,
                retryableIssueCount: $0.retryableIssueCount + next.retryableIssueCount
            )
        }
    }

    public func reset() {
        conversations = []
        selectedConversationID = nil
        statusMessage = nil
        isLoadingConversations = false
        isLoadingMembers = false
        isLoadingMessages = false
        pendingOutgoingRequestIDs = [:]
        loadedConversationIDs = []
        latestSyncedServerSequences = [:]
        oldestLoadedServerSequences = [:]
    }

    public func openConversation(id: String) {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            statusMessage = "当前没有可用会话。"
            return
        }

        _ = ensureConversationIndex(for: trimmedID)
        selectedConversationID = trimmedID
        statusMessage = nil
        sortConversations()
    }

    public func replaceConversationSummaries(_ responses: [IMConversationSummaryResponseBody]) {
        applyConversationSummaryContents(responses)
    }

    public func applyConversationSummaryContents(_ responses: [IMConversationSummaryResponseBody]) {
        let existingByID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
        let serverIDs = Set(responses.map { $0.id.uuidString })
        let previousSelectedConversationID = selectedConversationID

        var merged = responses.map { response in
            let conversationID = response.id.uuidString
            let existing = existingByID[conversationID]
            let previewText = existing?.messages.last?.text
                ?? response.lastMessage.map { formattedText(kind: $0.kind, body: $0.body) }
                ?? existing?.lastMessagePreviewText
                ?? "暂无消息"

            return IMConversation(
                id: conversationID,
                title: normalizedTitle(response.title, conversationID: conversationID),
                kind: IMConversationKind(rawValue: response.kind) ?? .group,
                memberCount: response.memberCount,
                memberUserIDs: response.memberUserIDs.sorted { $0.uuidString < $1.uuidString },
                members: existing?.members ?? [],
                messages: existing?.messages ?? [],
                lastMessagePreviewText: previewText,
                hasMoreHistory: existing?.hasMoreHistory ?? false,
                serverLastReadSequence: existing?.serverLastReadSequence ?? 0,
                serverUnreadCount: existing?.serverUnreadCount ?? 0,
                localUnreadDelta: existing?.localUnreadDelta ?? 0,
                updatedAt: response.updatedAt
            )
        }

        merged.append(contentsOf: conversations.filter { !serverIDs.contains($0.id) })
        conversations = merged

        if let previousSelectedConversationID,
           conversations.contains(where: { $0.id == previousSelectedConversationID }) {
            selectedConversationID = previousSelectedConversationID
        } else {
            selectedConversationID = conversations.first?.id
        }

        statusMessage = nil
        sortConversations()
    }

    public func applyConversationSummaryContent(_ response: IMConversationSummaryResponseBody) {
        upsertConversationSummaryContent(response)
    }

    public func removeConversation(id: String) {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            return
        }

        conversations.removeAll { $0.id == trimmedID }
        loadedConversationIDs.remove(trimmedID)
        latestSyncedServerSequences.removeValue(forKey: trimmedID)
        oldestLoadedServerSequences.removeValue(forKey: trimmedID)

        if selectedConversationID == trimmedID {
            selectedConversationID = conversations.first?.id
        } else if selectedConversationID != nil,
                  conversations.contains(where: { $0.id == selectedConversationID }) {
            // Preserve current selection when removing another conversation.
        } else {
            selectedConversationID = conversations.first?.id
        }
    }

    public func markConversationRead(id: String) {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == trimmedID })
        else {
            return
        }

        if let latestLoadedSequence = latestLoadedServerSequence(for: trimmedID) {
            conversations[index].serverLastReadSequence = latestLoadedSequence
        }
        resetUnreadState(for: index)
    }

    public func applyServerSummaryReadState(
        lastReadSequence: UInt64,
        unreadCount: Int,
        for conversationID: String
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == trimmedConversationID })
        else {
            return
        }

        conversations[index].serverLastReadSequence = lastReadSequence
        conversations[index].serverUnreadCount = max(0, unreadCount)
    }

    public func applyServerSummaryReadStates(_ responses: [IMConversationSummaryResponseBody]) {
        for response in responses {
            applyServerSummaryReadState(response)
        }
    }

    public func applyServerSummaryReadState(_ response: IMConversationSummaryResponseBody) {
        applyServerSummaryReadState(
            lastReadSequence: UInt64(response.lastReadSequence),
            unreadCount: response.unreadCount,
            for: response.id.uuidString
        )
    }

    public func applyServerExplicitReadResponse(_ response: IMConversationReadResponseBody) {
        applyServerReadState(
            lastReadSequence: UInt64(response.lastReadSequence),
            unreadCount: response.unreadCount,
            for: response.conversationID.uuidString
        )
    }

    public func applyServerReadState(
        lastReadSequence: UInt64,
        unreadCount: Int,
        for conversationID: String
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == trimmedConversationID })
        else {
            return
        }

        conversations[index].serverLastReadSequence = lastReadSequence
        conversations[index].serverUnreadCount = max(0, unreadCount)
        conversations[index].localUnreadDelta = 0
    }

    public func applyRealtimeUnreadIncrement(for conversationID: String) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == trimmedConversationID })
        else {
            return
        }

        guard selectedConversationID != trimmedConversationID else {
            resetUnreadState(for: index)
            return
        }

        conversations[index].localUnreadDelta += 1
    }

    public func applyServerUnreadCount(_ unreadCount: Int, for conversationID: String) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              let index = conversations.firstIndex(where: { $0.id == trimmedConversationID })
        else {
            return
        }

        conversations[index].serverUnreadCount = max(0, unreadCount)
    }

    public func applyConversationEvent(
        _ payload: IMTCPConversationEventPayload,
        currentUserID: UUID
    ) -> IMConversationEventApplyOutcome {
        let conversationID = payload.conversation.id.uuidString
        let selectedConversationIDBeforeApply = selectedConversationID

        switch payload.eventType {
        case .conversationCreated:
            applyConversationSummaryContent(payload.conversation)
            applyServerSummaryReadState(payload.conversation)
            return IMConversationEventApplyOutcome(
                shouldReloadMembersForConversationID: selectedConversationIDBeforeApply == conversationID ? conversationID : nil
            )

        case .membersAdded, .memberLeft:
            applyConversationSummaryContent(payload.conversation)
            applyServerSummaryReadState(payload.conversation)
            return IMConversationEventApplyOutcome(
                shouldReloadMembersForConversationID: selectedConversationIDBeforeApply == conversationID ? conversationID : nil
            )

        case .conversationRemovedForSelf:
            removeConversation(id: conversationID)
            return IMConversationEventApplyOutcome(shouldReloadMembersForConversationID: nil)

        case .summaryUpdated:
            applyConversationSummaryContent(payload.conversation)
            applyServerSummaryReadState(payload.conversation)
            return IMConversationEventApplyOutcome(shouldReloadMembersForConversationID: nil)
        }
    }

    public func replaceMessages(
        in conversationID: String,
        messages responses: [IMConversationMessageResponseBody],
        currentUserID: UUID
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        let index = ensureConversationIndex(for: trimmedConversationID)
        let serverMessages = makeMessages(from: responses, currentUserID: currentUserID)
        let mergedMessages = mergeMessages(
            existing: conversations[index].messages,
            serverMessages: serverMessages,
            preserveExistingServerMessages: false
        )
        conversations[index].messages = mergedMessages
        conversations[index].lastMessagePreviewText = mergedMessages.last?.text ?? conversations[index].lastMessagePreviewText
        conversations[index].updatedAt = mergedMessages.last?.createdAt ?? conversations[index].updatedAt
        conversations[index].hasMoreHistory = hasOlderHistory(in: serverMessages)
        loadedConversationIDs.insert(trimmedConversationID)
        refreshLoadedMessageCursors(
            for: trimmedConversationID,
            messages: mergedMessages
        )
        statusMessage = nil
        sortConversations()
    }

    public func appendMessages(
        in conversationID: String,
        messages responses: [IMConversationMessageResponseBody],
        currentUserID: UUID
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        let index = ensureConversationIndex(for: trimmedConversationID)
        let serverMessages = makeMessages(from: responses, currentUserID: currentUserID)
        let mergedMessages = mergeMessages(
            existing: conversations[index].messages,
            serverMessages: serverMessages,
            preserveExistingServerMessages: true
        )

        conversations[index].messages = mergedMessages
        conversations[index].lastMessagePreviewText = mergedMessages.last?.text ?? conversations[index].lastMessagePreviewText
        conversations[index].updatedAt = mergedMessages.last?.createdAt ?? conversations[index].updatedAt
        refreshLatestSyncedCursor(
            for: trimmedConversationID,
            messages: mergedMessages
        )
        statusMessage = nil
        sortConversations()
    }

    public func replaceMembers(
        in conversationID: String,
        members responses: [IMConversationMemberResponseBody]
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        let index = ensureConversationIndex(for: trimmedConversationID)
        let members = responses
            .map { IMConversationMember(id: $0.id, email: $0.email) }
            .sorted { $0.email < $1.email }

        conversations[index].members = members
        conversations[index].memberUserIDs = members.map(\.id).sorted { $0.uuidString < $1.uuidString }
        conversations[index].memberCount = members.count
        statusMessage = nil
    }

    public func prependMessages(
        in conversationID: String,
        messages responses: [IMConversationMessageResponseBody],
        currentUserID: UUID
    ) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        let index = ensureConversationIndex(for: trimmedConversationID)
        let serverMessages = makeMessages(from: responses, currentUserID: currentUserID)
        let mergedMessages = mergeMessages(
            existing: conversations[index].messages,
            serverMessages: serverMessages,
            preserveExistingServerMessages: true
        )

        conversations[index].messages = mergedMessages
        conversations[index].lastMessagePreviewText = mergedMessages.last?.text ?? conversations[index].lastMessagePreviewText
        conversations[index].updatedAt = mergedMessages.last?.createdAt ?? conversations[index].updatedAt
        conversations[index].hasMoreHistory = hasOlderHistory(in: serverMessages)
        loadedConversationIDs.insert(trimmedConversationID)
        refreshLoadedMessageCursors(
            for: trimmedConversationID,
            messages: mergedMessages
        )
        statusMessage = nil
        sortConversations()
    }

    public func prepareOutgoingText(
        _ text: String,
        conversationID: String,
        senderUserID: UUID
    ) -> IMOutgoingMessageRequest? {
        prepareOutgoingText(
            text,
            conversationID: conversationID,
            senderUserID: senderUserID,
            deliveryState: .sending,
            shouldRegisterPendingRequest: true
        )
    }

    @discardableResult
    public func queueOutgoingText(
        _ text: String,
        conversationID: String,
        senderUserID: UUID,
        message: String = "等待 IM 长连接恢复后发送。"
    ) -> Bool {
        prepareOutgoingText(
            text,
            conversationID: conversationID,
            senderUserID: senderUserID,
            deliveryState: .queued(message: message),
            shouldRegisterPendingRequest: false
        ) != nil
    }

    private func prepareOutgoingText(
        _ text: String,
        conversationID: String,
        senderUserID: UUID,
        deliveryState: IMMessageDeliveryState,
        shouldRegisterPendingRequest: Bool
    ) -> IMOutgoingMessageRequest? {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            statusMessage = "当前没有可用会话。"
            return nil
        }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            statusMessage = "消息内容不能为空。"
            return nil
        }

        let requestID = UUID()
        let clientMessageID = UUID().uuidString
        let localMessageID = clientMessageID
        let createdAt = Date()
        let index = ensureConversationIndex(for: trimmedConversationID)
        let message = IMConversationMessage(
            id: localMessageID,
            conversationID: trimmedConversationID,
            clientMessageID: clientMessageID,
            serverMessageID: nil,
            senderUserID: senderUserID,
            serverSequence: nil,
            kind: "text",
            text: trimmedText,
            direction: .outgoing,
            createdAt: createdAt,
            deliveryState: deliveryState
        )

        conversations[index].messages.append(message)
        conversations[index].lastMessagePreviewText = trimmedText
        conversations[index].updatedAt = createdAt
        resetUnreadState(for: index)
        selectedConversationID = trimmedConversationID
        if shouldRegisterPendingRequest {
            pendingOutgoingRequestIDs[requestID] = localMessageID
        }
        statusMessage = nil
        sortConversations()

        return IMOutgoingMessageRequest(
            requestID: requestID,
            localMessageID: localMessageID,
            payload: IMTCPMessagePayload(
                clientMessageID: clientMessageID,
                messageID: nil,
                conversationID: trimmedConversationID,
                senderUserID: nil,
                serverSequence: nil,
                serverTimestamp: nil,
                kind: "text",
                body: ["text": trimmedText]
            )
        )
    }

    public func retryOutgoingMessage(
        localMessageID: String,
        conversationID: String
    ) -> IMOutgoingMessageRequest? {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessageID = localMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedMessageID.isEmpty else {
            statusMessage = "消息重试失败：会话或消息无效。"
            return nil
        }

        guard let conversationIndex = conversations.firstIndex(where: { $0.id == trimmedConversationID }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == trimmedMessageID })
        else {
            statusMessage = "消息重试失败：本地消息不存在。"
            return nil
        }

        var message = conversations[conversationIndex].messages[messageIndex]
        guard message.direction == .outgoing else {
            statusMessage = "只能重试自己发送的消息。"
            return nil
        }

        guard isRetryableFailure(message) else {
            statusMessage = "该消息失败原因不可重试。"
            return nil
        }

        let clientMessageID = message.clientMessageID ?? message.id
        let requestID = UUID()
        message.deliveryState = .sending
        message.serverMessageID = nil
        message.serverSequence = nil
        conversations[conversationIndex].messages[messageIndex] = message
        pendingOutgoingRequestIDs[requestID] = message.id
        selectedConversationID = trimmedConversationID
        statusMessage = nil
        sortConversations()

        return IMOutgoingMessageRequest(
            requestID: requestID,
            localMessageID: message.id,
            payload: IMTCPMessagePayload(
                clientMessageID: clientMessageID,
                messageID: nil,
                conversationID: trimmedConversationID,
                senderUserID: nil,
                serverSequence: nil,
                serverTimestamp: nil,
                kind: message.kind,
                body: ["text": message.text]
            )
        )
    }

    @discardableResult
    public func queueRetryableOutgoingMessage(
        localMessageID: String,
        conversationID: String,
        message queueMessage: String = "等待 IM 长连接恢复后发送。"
    ) -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessageID = localMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedMessageID.isEmpty else {
            statusMessage = "消息排队失败：会话或消息无效。"
            return false
        }

        guard let conversationIndex = conversations.firstIndex(where: { $0.id == trimmedConversationID }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == trimmedMessageID })
        else {
            statusMessage = "消息排队失败：本地消息不存在。"
            return false
        }

        var message = conversations[conversationIndex].messages[messageIndex]
        guard isRetryableFailure(message) else {
            statusMessage = "该消息失败原因不可排队重试。"
            return false
        }

        pendingOutgoingRequestIDs = pendingOutgoingRequestIDs.filter { $0.value != message.id }
        message.deliveryState = .queued(message: queueMessage)
        message.serverMessageID = nil
        message.serverSequence = nil
        conversations[conversationIndex].messages[messageIndex] = message
        selectedConversationID = trimmedConversationID
        statusMessage = nil
        sortConversations()
        return true
    }

    @discardableResult
    public func cancelQueuedOutgoingMessage(
        localMessageID: String,
        conversationID: String
    ) -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMessageID = localMessageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty, !trimmedMessageID.isEmpty else {
            statusMessage = "取消发送失败：会话或消息无效。"
            return false
        }

        guard let conversationIndex = conversations.firstIndex(where: { $0.id == trimmedConversationID }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == trimmedMessageID })
        else {
            statusMessage = "取消发送失败：本地消息不存在。"
            return false
        }

        let message = conversations[conversationIndex].messages[messageIndex]
        guard message.direction == .outgoing, message.kind == "text", message.isQueued else {
            statusMessage = "只能取消尚未发送的文本消息。"
            return false
        }

        pendingOutgoingRequestIDs = pendingOutgoingRequestIDs.filter { $0.value != message.id }
        conversations[conversationIndex].messages.remove(at: messageIndex)
        refreshConversationPresentationAfterLocalMessageRemoval(at: conversationIndex)
        selectedConversationID = trimmedConversationID
        statusMessage = nil
        sortConversations()
        return true
    }

    public func queuedOutgoingMessageRequests(limit: Int) -> [IMOutgoingMessageRequest] {
        let limitedCount = max(0, limit)
        guard limitedCount > 0 else {
            return []
        }

        var queuedMessages: [(conversationID: String, message: IMConversationMessage)] = []
        for conversation in conversations {
            for message in conversation.messages
                where message.direction == .outgoing && message.kind == "text" && message.isQueued {
                queuedMessages.append((conversation.id, message))
            }
        }

        queuedMessages.sort { left, right in
            if left.message.createdAt == right.message.createdAt {
                return left.message.id < right.message.id
            }
            return left.message.createdAt < right.message.createdAt
        }

        var requests: [IMOutgoingMessageRequest] = []
        for (conversationID, queuedMessage) in queuedMessages.prefix(limitedCount) {
            guard let request = startQueuedOutgoingMessage(
                localMessageID: queuedMessage.id,
                conversationID: conversationID
            ) else {
                continue
            }
            requests.append(request)
        }

        return requests
    }

    public func markOutgoingQueued(requestID: UUID, message: String) {
        guard let localMessageID = pendingOutgoingRequestIDs.removeValue(forKey: requestID) else {
            return
        }

        mutateMessage(id: localMessageID) { item in
            item.deliveryState = .queued(message: message)
            item.serverMessageID = nil
            item.serverSequence = nil
        }
    }

    public func isRetryableFailure(_ message: IMConversationMessage) -> Bool {
        guard message.direction == .outgoing else {
            return false
        }

        switch message.deliveryState {
        case .queued, .unknown:
            return true
        case .failed(let failureMessage):
            return !Self.nonRetryableOutgoingFailureMessages.contains(failureMessage)
        case .sending, .sent, .received:
            return false
        }
    }

    private func queueSummary(for messages: [IMConversationMessage]) -> IMConversationQueueSummary {
        var queuedCount = 0
        var sendingCount = 0
        var retryableIssueCount = 0

        for message in messages where message.direction == .outgoing {
            switch message.deliveryState {
            case .queued:
                queuedCount += 1
            case .sending:
                sendingCount += 1
            case .unknown:
                retryableIssueCount += 1
            case .failed:
                if isRetryableFailure(message) {
                    retryableIssueCount += 1
                }
            case .sent, .received:
                break
            }
        }

        return IMConversationQueueSummary(
            queuedCount: queuedCount,
            sendingCount: sendingCount,
            retryableIssueCount: retryableIssueCount
        )
    }

    public func applyOutgoingAcknowledgement(requestID: UUID?, payload: IMTCPAckPayload) {
        guard let requestID, let localMessageID = pendingOutgoingRequestIDs.removeValue(forKey: requestID) else {
            return
        }

        mutateMessage(id: localMessageID) { message in
            message.serverMessageID = payload.messageID
            if payload.status == "accepted" {
                message.deliveryState = .sent
            } else {
                let failureMessage = outgoingAcknowledgementFailureMessage(for: payload.status)
                message.deliveryState = .failed(message: failureMessage)
                statusMessage = failureMessage
            }
        }
    }

    public func markOutgoingFailure(requestID: UUID, message: String) {
        guard let localMessageID = pendingOutgoingRequestIDs.removeValue(forKey: requestID) else {
            statusMessage = message
            return
        }

        mutateMessage(id: localMessageID) { item in
            item.deliveryState = .failed(message: message)
        }
        statusMessage = message
    }

    public func markAllPendingMessagesFailed(message: String) {
        let pendingMessageIDs = Array(pendingOutgoingRequestIDs.values)
        pendingOutgoingRequestIDs.removeAll()

        for localMessageID in pendingMessageIDs {
            mutateMessage(id: localMessageID) { item in
                item.deliveryState = .failed(message: message)
            }
        }

        if !pendingMessageIDs.isEmpty {
            statusMessage = message
        }
    }

    public func markAllPendingMessagesUnknown(message: String) {
        let pendingMessageIDs = Array(pendingOutgoingRequestIDs.values)
        pendingOutgoingRequestIDs.removeAll()

        for localMessageID in pendingMessageIDs {
            mutateMessage(id: localMessageID) { item in
                item.deliveryState = .unknown(message: message)
            }
        }

        if !pendingMessageIDs.isEmpty {
            statusMessage = message
        }
    }

    public func receiveIncomingMessage(_ payload: IMTCPMessagePayload, currentUserID: UUID) {
        let index = ensureConversationIndex(for: payload.conversationID)
        let stableMessageID = payload.messageID ?? payload.clientMessageID ?? UUID().uuidString
        let effectiveTimestamp = payload.serverTimestamp ?? Date()

        if payload.senderUserID == currentUserID,
           let clientMessageID = payload.clientMessageID,
           let existingIndex = conversations[index].messages.firstIndex(where: { $0.clientMessageID == clientMessageID }) {
            conversations[index].messages[existingIndex].serverMessageID = payload.messageID
            conversations[index].messages[existingIndex].serverSequence = payload.serverSequence
            conversations[index].messages[existingIndex].createdAt = effectiveTimestamp
            conversations[index].messages[existingIndex].deliveryState = .sent
            conversations[index].updatedAt = effectiveTimestamp
            conversations[index].lastMessagePreviewText = conversations[index].messages[existingIndex].text
            refreshLatestSyncedCursor(
                for: payload.conversationID,
                messages: conversations[index].messages
            )
            sortConversations()
            return
        }

        let alreadyExists = conversations[index].messages.contains {
            $0.id == stableMessageID
                || ($0.serverMessageID != nil && $0.serverMessageID == payload.messageID)
                || ($0.clientMessageID != nil && $0.clientMessageID == payload.clientMessageID)
        }
        guard !alreadyExists else {
            return
        }

        let message = IMConversationMessage(
            id: stableMessageID,
            conversationID: payload.conversationID,
            clientMessageID: payload.clientMessageID,
            serverMessageID: payload.messageID,
            senderUserID: payload.senderUserID,
            serverSequence: payload.serverSequence,
            kind: payload.kind,
            text: formattedText(kind: payload.kind, body: payload.body),
            direction: payload.senderUserID == currentUserID ? .outgoing : .incoming,
            createdAt: effectiveTimestamp,
            deliveryState: payload.senderUserID == currentUserID ? .sent : .received
        )

        conversations[index].messages.append(message)
        conversations[index].lastMessagePreviewText = message.text
        conversations[index].updatedAt = message.createdAt
        refreshLatestSyncedCursor(
            for: payload.conversationID,
            messages: conversations[index].messages
        )

        applyIncomingMessageUnreadState(for: payload.conversationID)

        statusMessage = nil
        sortConversations()
    }

    public func hasLoadedMessages(for conversationID: String) -> Bool {
        loadedConversationIDs.contains(conversationID)
    }

    public func canLoadOlderMessages(for conversationID: String) -> Bool {
        conversations.first(where: { $0.id == conversationID })?.hasMoreHistory ?? false
    }

    public func oldestLoadedServerSequence(for conversationID: String) -> UInt64? {
        if let storedSequence = oldestLoadedServerSequences[conversationID] {
            return storedSequence
        }

        guard !loadedConversationIDs.contains(conversationID) else {
            return nil
        }

        return conversations.first(where: { $0.id == conversationID })?
            .messages
            .compactMap(\.serverSequence)
            .min()
    }

    public func syncCursor(for conversationID: String) -> IMSyncCursorState? {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              conversations.contains(where: { $0.id == trimmedConversationID })
        else {
            return nil
        }

        return IMSyncCursorState(
            conversationID: trimmedConversationID,
            hasLoadedMessages: loadedConversationIDs.contains(trimmedConversationID),
            latestSyncedServerSequence: latestLoadedServerSequence(for: trimmedConversationID),
            oldestLoadedServerSequence: loadedConversationIDs.contains(trimmedConversationID)
                ? oldestLoadedServerSequence(for: trimmedConversationID)
                : nil
        )
    }

    public func setLatestSyncedServerSequence(_ sequence: UInt64?, for conversationID: String) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        latestSyncedServerSequences[trimmedConversationID] = sequence
    }

    public func setOldestLoadedServerSequence(_ sequence: UInt64?, for conversationID: String) {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        oldestLoadedServerSequences[trimmedConversationID] = sequence
    }

    public func trimCachedMessageWindow(limit: Int = IMConversationCacheSnapshot.cachedMessageLimit) {
        let effectiveLimit = max(0, limit)
        for index in conversations.indices {
            conversations[index].messages = trimmedCachedMessages(
                conversations[index].messages,
                limit: effectiveLimit
            )
            refreshLoadedMessageCursors(
                for: conversations[index].id,
                messages: conversations[index].messages
            )
        }
    }

    public func latestLoadedServerSequence(for conversationID: String) -> UInt64? {
        if let storedSequence = latestSyncedServerSequences[conversationID] {
            return storedSequence
        }

        return conversations.first(where: { $0.id == conversationID })?
            .messages
            .compactMap(\.serverSequence)
            .max()
    }

    public func gapSyncTargets(from summaries: [IMConversationSummaryResponseBody]) -> [String] {
        summaries.compactMap { summary in
            let conversationID = summary.id.uuidString
            let serverLatestSequence = UInt64(max(0, summary.lastMessage?.serverSequence ?? 0))
            guard
                let localLatestSequence = latestLoadedServerSequence(for: conversationID),
                serverLatestSequence > localLatestSequence
            else {
                return nil
            }

            return conversationID
        }
    }

    public func serverLastReadSequence(for conversationID: String) -> UInt64? {
        conversations.first(where: { $0.id == conversationID })?.serverLastReadSequence
    }

    public func setLoadingConversations(_ isLoading: Bool) {
        isLoadingConversations = isLoading
    }

    public func setLoadingMembers(_ isLoading: Bool) {
        isLoadingMembers = isLoading
    }

    public func setLoadingMessages(_ isLoading: Bool) {
        isLoadingMessages = isLoading
    }

    public func setStatusMessage(_ message: String?) {
        statusMessage = message
    }

    public func makeCacheSnapshot(lastSummaryRefreshAt: Date?) -> IMConversationCacheSnapshot {
        var cursorStates: [IMSyncCursorState] = []
        let cachedConversations = conversations.map { conversation in
            let cachedMessages = trimmedCachedMessages(
                conversation.messages,
                limit: IMConversationCacheSnapshot.cachedMessageLimit
            )
            let cachedServerSequences = cachedMessages.compactMap(\.serverSequence)
            let hasLoadedMessages = loadedConversationIDs.contains(conversation.id)
            let latestSyncedServerSequence = cachedServerSequences.max()
            let oldestLoadedServerSequence = hasLoadedMessages ? cachedServerSequences.min() : nil

            cursorStates.append(
                IMSyncCursorState(
                    conversationID: conversation.id,
                    hasLoadedMessages: hasLoadedMessages,
                    latestSyncedServerSequence: latestSyncedServerSequence,
                    oldestLoadedServerSequence: oldestLoadedServerSequence
                )
            )

            return IMCachedConversationState(
                id: conversation.id,
                title: conversation.title,
                kind: conversation.kind,
                memberCount: conversation.memberCount,
                memberUserIDs: conversation.memberUserIDs,
                messages: cachedMessages.map { message in
                    IMCachedMessageState(
                        id: message.id,
                        conversationID: message.conversationID,
                        clientMessageID: message.clientMessageID,
                        serverMessageID: message.serverMessageID,
                        senderUserID: message.senderUserID,
                        serverSequence: message.serverSequence,
                        kind: message.kind,
                        text: message.text,
                        direction: message.direction,
                        createdAt: message.createdAt,
                        deliveryState: message.deliveryState
                    )
                },
                hasLoadedMessages: hasLoadedMessages,
                lastMessagePreviewText: conversation.lastMessagePreviewText,
                hasMoreHistory: conversation.hasMoreHistory,
                latestSyncedServerSequence: latestSyncedServerSequence,
                oldestLoadedServerSequence: oldestLoadedServerSequence,
                serverLastReadSequence: conversation.serverLastReadSequence,
                serverUnreadCount: conversation.serverUnreadCount,
                updatedAt: conversation.updatedAt
            )
        }

        return IMConversationCacheSnapshot(
            metadata: IMCacheMetadataState(
                selectedConversationID: selectedConversationID,
                lastSummaryRefreshAt: lastSummaryRefreshAt
            ),
            conversations: cachedConversations,
            cursors: cursorStates
        )
    }

    public func restoreCacheSnapshot(_ snapshot: IMConversationCacheSnapshot) {
        let cursorsByConversationID = Dictionary(
            uniqueKeysWithValues: snapshot.cursors.map { ($0.conversationID, $0) }
        )

        conversations = snapshot.conversations.map { cachedConversation in
            IMConversation(
                id: cachedConversation.id,
                title: cachedConversation.title,
                kind: cachedConversation.kind,
                memberCount: cachedConversation.memberCount,
                memberUserIDs: cachedConversation.memberUserIDs,
                members: [],
                messages: cachedConversation.messages.map { cachedMessage in
                    IMConversationMessage(
                        id: cachedMessage.id,
                        conversationID: cachedMessage.conversationID,
                        clientMessageID: cachedMessage.clientMessageID,
                        serverMessageID: cachedMessage.serverMessageID,
                        senderUserID: cachedMessage.senderUserID,
                        serverSequence: cachedMessage.serverSequence,
                        kind: cachedMessage.kind,
                        text: cachedMessage.text,
                        direction: cachedMessage.direction,
                        createdAt: cachedMessage.createdAt,
                        deliveryState: Self.restoredDeliveryState(cachedMessage.deliveryState)
                    )
                },
                lastMessagePreviewText: cachedConversation.lastMessagePreviewText,
                hasMoreHistory: cachedConversation.hasMoreHistory,
                serverLastReadSequence: cachedConversation.serverLastReadSequence,
                serverUnreadCount: cachedConversation.serverUnreadCount,
                localUnreadDelta: 0,
                updatedAt: cachedConversation.updatedAt
            )
        }

        loadedConversationIDs = Set(
            snapshot.cursors
                .filter(\.hasLoadedMessages)
                .map(\.conversationID)
        )
        latestSyncedServerSequences = Dictionary(
            uniqueKeysWithValues: snapshot.conversations.compactMap { conversation in
                let cursor = cursorsByConversationID[conversation.id]
                return (cursor?.latestSyncedServerSequence ?? conversation.latestSyncedServerSequence)
                    .map { (conversation.id, $0) }
            }
        )
        oldestLoadedServerSequences = Dictionary(
            uniqueKeysWithValues: snapshot.conversations.compactMap { conversation in
                let cursor = cursorsByConversationID[conversation.id]
                return (cursor?.oldestLoadedServerSequence ?? conversation.oldestLoadedServerSequence)
                    .map { (conversation.id, $0) }
            }
        )

        if let selectedConversationID = snapshot.selectedConversationID,
           conversations.contains(where: { $0.id == selectedConversationID }) {
            self.selectedConversationID = selectedConversationID
        } else {
            selectedConversationID = conversations.first?.id
        }

        statusMessage = nil
        sortConversations()
    }

    private func ensureConversationIndex(for conversationID: String) -> Int {
        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            return index
        }

        let conversation = IMConversation(
            id: conversationID,
            title: fallbackTitle(for: conversationID),
            kind: .group,
            memberCount: 0,
            memberUserIDs: [],
            members: [],
            messages: [],
            lastMessagePreviewText: "暂无消息",
            hasMoreHistory: false,
            serverLastReadSequence: 0,
            serverUnreadCount: 0,
            localUnreadDelta: 0,
            updatedAt: .distantPast
        )
        conversations.append(conversation)
        return conversations.count - 1
    }

    private func upsertConversationSummaryContent(_ response: IMConversationSummaryResponseBody) {
        let conversationID = response.id.uuidString
        let index = ensureConversationIndex(for: conversationID)
        let previewText = response.lastMessage.map { formattedText(kind: $0.kind, body: $0.body) }
            ?? conversations[index].messages.last?.text
            ?? conversations[index].lastMessagePreviewText
        let preservedMessages = conversations[index].messages
        let preservedMembers = conversations[index].members
        let preservedHasMoreHistory = conversations[index].hasMoreHistory

        conversations[index].title = normalizedTitle(response.title, conversationID: conversationID)
        conversations[index].kind = IMConversationKind(rawValue: response.kind) ?? .group
        conversations[index].memberCount = response.memberCount
        conversations[index].memberUserIDs = response.memberUserIDs.sorted { $0.uuidString < $1.uuidString }
        conversations[index].members = preservedMembers.filter { member in
            conversations[index].memberUserIDs.contains(member.id)
        }
        conversations[index].messages = preservedMessages
        conversations[index].lastMessagePreviewText = previewText
        conversations[index].hasMoreHistory = preservedHasMoreHistory
        conversations[index].updatedAt = response.updatedAt

        statusMessage = nil
        sortConversations()
    }

    private func applyIncomingMessageUnreadState(for conversationID: String) {
        if selectedConversationID == nil {
            selectedConversationID = conversationID
        }

        applyRealtimeUnreadIncrement(for: conversationID)
    }

    private func refreshLoadedMessageCursors(
        for conversationID: String,
        messages: [IMConversationMessage]
    ) {
        let serverSequences = messages.compactMap(\.serverSequence)
        latestSyncedServerSequences[conversationID] = serverSequences.max()

        if let oldestSequence = serverSequences.min() {
            oldestLoadedServerSequences[conversationID] = oldestSequence
        } else {
            oldestLoadedServerSequences.removeValue(forKey: conversationID)
        }
    }

    private func refreshLatestSyncedCursor(
        for conversationID: String,
        messages: [IMConversationMessage]
    ) {
        guard let latestSequence = messages.compactMap(\.serverSequence).max() else {
            return
        }

        let currentLatest = latestSyncedServerSequences[conversationID] ?? 0
        latestSyncedServerSequences[conversationID] = max(currentLatest, latestSequence)
    }

    private func trimmedCachedMessages(
        _ messages: [IMConversationMessage],
        limit: Int
    ) -> [IMConversationMessage] {
        guard limit > 0, messages.count > limit else {
            return limit == 0 ? [] : messages
        }

        return Array(messages.suffix(limit))
    }

    private func resetUnreadState(for conversationIndex: Int) {
        conversations[conversationIndex].serverUnreadCount = 0
        conversations[conversationIndex].localUnreadDelta = 0
    }

    private func mutateMessage(id: String, update: (inout IMConversationMessage) -> Void) {
        for conversationIndex in conversations.indices {
            guard let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == id }) else {
                continue
            }

            update(&conversations[conversationIndex].messages[messageIndex])
            conversations[conversationIndex].updatedAt = conversations[conversationIndex].messages[messageIndex].createdAt
            conversations[conversationIndex].lastMessagePreviewText = conversations[conversationIndex].messages.last?.text
                ?? conversations[conversationIndex].lastMessagePreviewText
            sortConversations()
            return
        }
    }

    private func refreshConversationPresentationAfterLocalMessageRemoval(at conversationIndex: Int) {
        guard conversations.indices.contains(conversationIndex) else {
            return
        }

        if let latestMessage = conversations[conversationIndex].messages.last {
            conversations[conversationIndex].lastMessagePreviewText = latestMessage.text
            conversations[conversationIndex].updatedAt = latestMessage.createdAt
        } else {
            conversations[conversationIndex].lastMessagePreviewText = ""
        }
    }

    private func sortConversations() {
        conversations.sort { left, right in
            if left.updatedAt == right.updatedAt {
                return left.id < right.id
            }
            return left.updatedAt > right.updatedAt
        }
    }

    private func formattedText(kind: String, body: [String: String]) -> String {
        if let text = body["text"], !text.isEmpty {
            return text
        }

        let parts: [String] = body.keys.sorted().reduce(into: []) { partialResult, key in
            guard let value = body[key], !value.isEmpty else {
                return
            }
            partialResult.append("\(key): \(value)")
        }
        let bodyText = parts.joined(separator: ", ")

        if bodyText.isEmpty {
            return "[\(kind)]"
        }

        return bodyText
    }

    private func normalizedTitle(_ title: String?, conversationID: String) -> String {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }
        return fallbackTitle(for: conversationID)
    }

    private func makeMessages(
        from responses: [IMConversationMessageResponseBody],
        currentUserID: UUID
    ) -> [IMConversationMessage] {
        responses.map { response in
            IMConversationMessage(
                id: response.id.uuidString,
                conversationID: response.conversationID.uuidString,
                clientMessageID: response.clientMessageID,
                serverMessageID: response.id.uuidString,
                senderUserID: response.senderUserID,
                serverSequence: UInt64(response.serverSequence),
                kind: response.kind,
                text: formattedText(kind: response.kind, body: response.body),
                direction: response.senderUserID == currentUserID ? .outgoing : .incoming,
                createdAt: response.createdAt ?? .distantPast,
                deliveryState: response.senderUserID == currentUserID ? .sent : .received
            )
        }
    }

    private func mergeMessages(
        existing: [IMConversationMessage],
        serverMessages: [IMConversationMessage],
        preserveExistingServerMessages: Bool
    ) -> [IMConversationMessage] {
        var merged = preserveExistingServerMessages
            ? existing
            : existing.filter { message in
                message.serverMessageID == nil && message.serverSequence == nil
            }

        for serverMessage in serverMessages {
            if let existingIndex = merged.firstIndex(where: { Self.matches($0, serverMessage) }) {
                merged[existingIndex] = serverMessage
            } else {
                merged.append(serverMessage)
            }
        }

        return merged.sorted(by: Self.messageComparator)
    }

    private func hasOlderHistory(in serverMessages: [IMConversationMessage]) -> Bool {
        guard let oldestSequence = serverMessages.compactMap(\.serverSequence).min() else {
            return false
        }

        return oldestSequence > 1
    }

    private func fallbackTitle(for conversationID: String) -> String {
        "会话 \(conversationID.prefix(8).lowercased())"
    }

    private func outgoingAcknowledgementFailureMessage(for status: String) -> String {
        switch status {
        case "stranger_direct_message_limit_reached":
            return "你们还不是好友，对方回复前只能发送一条消息。"
        case "invalid_conversation_id":
            return "会话 ID 无效。"
        case "conversation_unavailable":
            return "会话不存在或你已不在该会话中。"
        case "unsupported_message_kind":
            return "当前只支持文本消息。"
        case "empty_text_body":
            return "消息内容不能为空。"
        case "internal_error":
            return "消息发送失败，请稍后重试。"
        default:
            return "消息发送失败：\(status)"
        }
    }

    private static func restoredDeliveryState(_ state: IMMessageDeliveryState) -> IMMessageDeliveryState {
        if case .sending = state {
            return .unknown(message: "发送状态未确认，请重试。")
        }

        return state
    }

    private func startQueuedOutgoingMessage(
        localMessageID: String,
        conversationID: String
    ) -> IMOutgoingMessageRequest? {
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == localMessageID })
        else {
            return nil
        }

        var message = conversations[conversationIndex].messages[messageIndex]
        guard message.direction == .outgoing, message.isQueued else {
            return nil
        }

        let clientMessageID = message.clientMessageID ?? message.id
        let requestID = UUID()
        message.deliveryState = .sending
        message.serverMessageID = nil
        message.serverSequence = nil
        conversations[conversationIndex].messages[messageIndex] = message
        pendingOutgoingRequestIDs[requestID] = message.id
        sortConversations()

        return IMOutgoingMessageRequest(
            requestID: requestID,
            localMessageID: message.id,
            payload: IMTCPMessagePayload(
                clientMessageID: clientMessageID,
                messageID: nil,
                conversationID: conversationID,
                senderUserID: nil,
                serverSequence: nil,
                serverTimestamp: nil,
                kind: message.kind,
                body: ["text": message.text]
            )
        )
    }

    private static let nonRetryableOutgoingFailureMessages: Set<String> = [
        "你们还不是好友，对方回复前只能发送一条消息。",
        "会话 ID 无效。",
        "会话不存在或你已不在该会话中。",
        "当前只支持文本消息。",
        "消息内容不能为空。"
    ]

    private static func matches(_ left: IMConversationMessage, _ right: IMConversationMessage) -> Bool {
        if let leftServerMessageID = left.serverMessageID,
           let rightServerMessageID = right.serverMessageID,
           leftServerMessageID == rightServerMessageID {
            return true
        }

        if let leftClientMessageID = left.clientMessageID,
           let rightClientMessageID = right.clientMessageID,
           leftClientMessageID == rightClientMessageID {
            return true
        }

        if let leftServerSequence = left.serverSequence,
           let rightServerSequence = right.serverSequence,
           leftServerSequence == rightServerSequence,
           left.conversationID == right.conversationID {
            return true
        }

        return false
    }

    private static let messageComparator: (IMConversationMessage, IMConversationMessage) -> Bool = { left, right in
        switch (left.serverSequence, right.serverSequence) {
        case let (leftSequence?, rightSequence?):
            if leftSequence == rightSequence {
                if left.createdAt == right.createdAt {
                    return left.id < right.id
                }
                return left.createdAt < right.createdAt
            }
            return leftSequence < rightSequence
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            if left.createdAt == right.createdAt {
                return left.id < right.id
            }
            return left.createdAt < right.createdAt
        }
    }
}

private extension IMConversationMessage {
    var isQueued: Bool {
        if case .queued = deliveryState {
            return true
        }

        return false
    }
}
