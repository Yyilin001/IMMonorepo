import Foundation
@testable import IMClientKit
import Testing
@testable import IMApp

private actor RestoreGate {
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

private actor IMGapSyncCounter {
    private var value = 0

    func increment() {
        value += 1
    }

    func currentValue() -> Int {
        value
    }
}

private actor IMRequestCounter {
    private var counts: [String: Int] = [:]

    func increment(_ key: String) {
        counts[key, default: 0] += 1
    }

    func count(for key: String) -> Int {
        counts[key, default: 0]
    }
}

private actor IMReadSequenceRecorder {
    private var sequences: [UInt64] = []

    func record(_ sequence: UInt64) {
        sequences.append(sequence)
    }

    func allSequences() -> [UInt64] {
        sequences
    }
}

private actor IMConversationMutationState {
    private var didMutate = false

    func markMutated() {
        didMutate = true
    }

    func isMutated() -> Bool {
        didMutate
    }
}

private actor IMSummarySequenceState {
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

private actor IMCrossDeviceConversationSummaryState {
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

private actor IMCrossDeviceConversationListState {
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
}

private actor IMCrossDeviceConversationMembersState {
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

private final class AuthManagerBackgroundTransferMonitor: BackgroundTransferMonitoring, @unchecked Sendable {
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

private actor IMConnectionTestHarness {
    private var continuation: AsyncThrowingStream<IMTCPConnectionEvent, Error>.Continuation?
    private var disconnectCount = 0
    private var sentLines: [String] = []
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
            sendLine: { line in
                try await self.record(line)
            },
            disconnectHandler: {
                await self.disconnect()
            }
        )
    }

    func yield(_ event: IMTCPConnectionEvent) {
        continuation?.yield(event)
    }

    func disconnections() -> Int {
        disconnectCount
    }

    func recordedLines() -> [String] {
        sentLines
    }

    private func disconnect() {
        disconnectCount += 1
        continuation?.finish()
        continuation = nil
    }

    private func record(_ line: String) async throws {
        if sendDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: sendDelayNanoseconds)
        }
        sendAttemptCount += 1
        if failingSendNumbers.contains(sendAttemptCount) {
            throw URLError(.notConnectedToInternet)
        }
        sentLines.append(line)
    }
}

@MainActor
struct AuthManagerTests {
    private nonisolated static let user = AuthUser(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        email: "manager@example.com"
    )

    @Test func loadSessionsMarksServerOfflineWhenConnectivityFails() async {
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/auth/sessions"):
                throw URLError(.notConnectedToInternet)
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = makeManager(transport: transport)
        await manager.login(email: Self.user.email, password: "password123")
        await manager.loadSessions()

        #expect(manager.serverStatus == .offline(message: "当前无法连接服务器。"))
        #expect(manager.currentUser?.id == Self.user.id)
    }

    @Test func restoreSessionDoesNotOverrideNewerLogin() async throws {
        let harness = IMConnectionTestHarness()
        let tokenStore = InMemoryTokenStore()
        try tokenStore.save("refresh-1", for: "refresh_token")

        let restoredUser = AuthUser(
            id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            email: "restored@example.com"
        )
        let gate = RestoreGate()
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/refresh"):
                await gate.markStarted()
                await gate.waitForResume()
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.authResponseBody(
                        user: restoredUser,
                        accessToken: "restore-access",
                        refreshToken: "restore-refresh"
                    )
                )
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.authResponseBody(
                        user: Self.user,
                        accessToken: "login-access",
                        refreshToken: "login-refresh"
                    )
                )
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: wrapWithDefaultIMResponses(transport)),
            tokenStore: tokenStore,
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: true
        )

        await gate.waitUntilStarted()
        await manager.login(email: Self.user.email, password: "password123")
        await gate.resume()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(manager.phase == .signedIn(Self.user))
        #expect(manager.currentUser?.email == Self.user.email)
    }

    @Test func loadSessionsSignsOutWhenSessionIsRevoked() async {
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/auth/sessions"):
                let body = try HTTPFixtures.jsonBody(ErrorEnvelope(reason: "当前登录已失效。"))
                return HTTPFixtures.response(statusCode: 401, body: body)
            case ("POST", "/api/auth/refresh"):
                let body = try HTTPFixtures.jsonBody(ErrorEnvelope(reason: "当前登录已失效。"))
                return HTTPFixtures.response(statusCode: 401, body: body)
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = makeManager(transport: transport)
        await manager.login(email: Self.user.email, password: "password123")
        await manager.loadSessions()

        #expect(manager.phase == .signedOut(message: "当前登录已失效。"))
        #expect(manager.serverStatus == .unknown)
        #expect(manager.currentUser == nil)
        #expect(manager.sessions.isEmpty)
    }

    @Test func reloadProfileMarksServerOfflineWhenConnectivityFails() async {
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/me"):
                throw URLError(.notConnectedToInternet)
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = makeManager(transport: transport)
        await manager.login(email: Self.user.email, password: "password123")
        await manager.reloadProfile()

        #expect(manager.serverStatus == .offline(message: "当前无法连接服务器。"))
        #expect(manager.currentUser?.id == Self.user.id)
    }

    @Test func signOutOtherDeviceClearsLocalSessionWhenForbidden() async {
        let targetSessionID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("DELETE", "/api/auth/sessions/\(targetSessionID.uuidString)"):
                let body = try HTTPFixtures.jsonBody(ErrorEnvelope(reason: "当前设备已被撤销。"))
                return HTTPFixtures.response(statusCode: 403, body: body)
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = makeManager(transport: transport)
        await manager.login(email: Self.user.email, password: "password123")
        await manager.signOut(sessionID: targetSessionID, isCurrent: false)

        #expect(manager.phase == .signedOut(message: "当前设备已被撤销。"))
        #expect(manager.serverStatus == .unknown)
        #expect(manager.currentUser == nil)
    }

    @Test func loginMarksServerOfflineWhenConnectivityFails() async {
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                throw URLError(.notConnectedToInternet)
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = makeManager(transport: transport)
        await manager.login(email: Self.user.email, password: "password123")

        #expect(manager.phase == .signedOut(message: "当前无法连接服务器。"))
        #expect(manager.serverStatus == .offline(message: "当前无法连接服务器。"))
    }

    @Test func registerMarksServerOfflineWhenConnectivityFails() async {
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/register"):
                throw URLError(.notConnectedToInternet)
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = makeManager(transport: transport)
        await manager.register(email: Self.user.email, password: "password123")

        #expect(manager.phase == .signedOut(message: "当前无法连接服务器。"))
        #expect(manager.serverStatus == .offline(message: "当前无法连接服务器。"))
    }

    @Test func recoveredBackgroundUnauthorizedFailureClearsSession() async {
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let snapshot = BackgroundTransferSnapshot(
            sessionIdentifier: "tests.background.download",
            taskIdentifier: 12,
            kind: .download,
            state: .running,
            progress: nil,
            destinationURL: FileManager.default.temporaryDirectory.appending(path: "restored.bin")
        )
        let monitor = AuthManagerBackgroundTransferMonitor(initialSnapshots: [snapshot])
        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: wrapWithDefaultIMResponses(transport)),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            backgroundTransferMonitor: monitor,
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        monitor.emit(
            BackgroundTransferSnapshot(
                sessionIdentifier: snapshot.sessionIdentifier,
                taskIdentifier: snapshot.taskIdentifier,
                kind: .download,
                state: .failed(
                    BackgroundTransferSnapshot.Failure(
                        error: APIError.unauthorized("当前登录已失效。")
                    )
                ),
                progress: nil,
                destinationURL: snapshot.destinationURL
            )
        )
        try? await Task.sleep(for: .milliseconds(50))

        #expect(manager.phase == .signedOut(message: "当前登录已失效。"))
        #expect(manager.serverStatus == .unknown)
        #expect(manager.currentUser == nil)
    }

    @Test func loginAutoConnectsIMAndLogoutDisconnectsConnection() async throws {
        let harness = IMConnectionTestHarness()
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("DELETE", "/api/auth/sessions/current"):
                return HTTPFixtures.response(statusCode: 200)
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: wrapWithDefaultIMResponses(transport)),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run { manager.imConnectionStatus == .connected }
        }

        await manager.logout()
        try await Self.waitUntil {
            await MainActor.run { manager.phase == .signedOut(message: nil) }
        }

        #expect(await harness.disconnections() == 1)
        #expect(manager.imConnectionStatus == .disconnected)
    }

    @Test func kickClearsLocalSession() async throws {
        let harness = IMConnectionTestHarness()
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: wrapWithDefaultIMResponses(transport)),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run { manager.imConnectionStatus == .connected }
        }

        await harness.yield(
            .kick(IMTCPKickPayload(reason: .sessionRevoked, message: "当前登录已失效。"))
        )
        try await Self.waitUntil {
            await MainActor.run { manager.phase == .signedOut(message: "当前登录已失效。") }
        }

        #expect(manager.currentUser == nil)
        #expect(manager.imConnectionStatus == .disconnected)
    }

    @Test func incomingMessageUpdatesConversationStoreAndSendsDeliveryAck() async throws {
        let harness = IMConnectionTestHarness()
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: wrapWithDefaultIMResponses(transport)),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run { manager.imConnectionStatus == .connected }
        }

        let requestID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        await harness.yield(
            .message(
                requestID: requestID,
                payload: IMTCPMessagePayload(
                    clientMessageID: nil,
                    messageID: "srv-msg-1",
                    conversationID: "conv-42",
                    senderUserID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    serverSequence: 99,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_000_999),
                    kind: "text",
                    body: ["text": "hello from server"]
                )
            )
        )

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.count == 1
            }
        }

        let conversation = manager.imConversationStore.selectedConversation
        #expect(conversation?.id == "conv-42")
        #expect(conversation?.messages.first?.text == "hello from server")
        #expect(conversation?.messages.first?.direction == .incoming)
        #expect(conversation?.messages.first?.serverSequence == 99)
        #expect(conversation?.messages.first?.createdAt == Date(timeIntervalSince1970: 1_700_000_999))

        let ackLine = try await Self.requireRecordedLine(at: 0, from: harness)
        let ackPacket = try Self.decode(IMTCPPacketEnvelope<IMTCPAckPayload>.self, from: ackLine)
        #expect(ackPacket.type == .ack)
        #expect(ackPacket.requestID == requestID)
        #expect(ackPacket.payload.messageID == "srv-msg-1")
        #expect(ackPacket.payload.conversationID == "conv-42")
        #expect(ackPacket.payload.status == "received")
    }

    @Test func incomingMessagesThrottleMarkReadToHighestSequence() async throws {
        let harness = IMConnectionTestHarness()
        let readRecorder = IMReadSequenceRecorder()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationsBody())
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read"):
                let payload = try JSONDecoder().decode(
                    IMConversationReadRequestBody.self,
                    from: request.httpBody ?? Data()
                )
                await readRecorder.record(payload.readSequence)
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        IMConversationReadResponseBody(
                            conversationID: conversationID,
                            lastReadSequence: Int(payload.readSequence),
                            unreadCount: 0
                        )
                    )
                )
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run { manager.imConnectionStatus == .connected }
        }

        await harness.yield(
            .message(
                requestID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                payload: IMTCPMessagePayload(
                    clientMessageID: nil,
                    messageID: "srv-msg-1",
                    conversationID: conversationID.uuidString,
                    senderUserID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    serverSequence: 99,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_000_999),
                    kind: "text",
                    body: ["text": "hello from server 1"]
                )
            )
        )
        await harness.yield(
            .message(
                requestID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                payload: IMTCPMessagePayload(
                    clientMessageID: nil,
                    messageID: "srv-msg-2",
                    conversationID: conversationID.uuidString,
                    senderUserID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    serverSequence: 100,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_001_000),
                    kind: "text",
                    body: ["text": "hello from server 2"]
                )
            )
        )

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.count == 2
            }
        }
        try await Self.waitUntil {
            await readRecorder.allSequences() == [100]
        }

        #expect(await readRecorder.allSequences() == [100])
    }

    @Test func sendIMTextWritesTCPPacketAndAckMarksMessageSent() async throws {
        let harness = IMConnectionTestHarness()
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            }
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run { manager.imConnectionStatus == .connected }
        }

        let didSend = await manager.sendIMText("hello client", to: "conv-local")
        #expect(didSend)

        let messageLine = try await Self.requireRecordedLine(at: 0, from: harness)
        let messagePacket = try Self.decode(IMTCPPacketEnvelope<IMTCPMessagePayload>.self, from: messageLine)
        #expect(messagePacket.type == .message)
        #expect(messagePacket.payload.conversationID == "conv-local")
        #expect(messagePacket.payload.senderUserID == nil)
        #expect(messagePacket.payload.serverSequence == nil)
        #expect(messagePacket.payload.serverTimestamp == nil)
        #expect(messagePacket.payload.body["text"] == "hello client")

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.first?.deliveryState == .sending
            }
        }

        await harness.yield(
            .ack(
                requestID: messagePacket.requestID,
                payload: IMTCPAckPayload(
                    messageID: "srv-msg-9001",
                    conversationID: "conv-local",
                    status: "accepted"
                )
            )
        )

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.first?.deliveryState == .sent
            }
        }

        await harness.yield(
            .message(
                requestID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                payload: IMTCPMessagePayload(
                    clientMessageID: messagePacket.payload.clientMessageID,
                    messageID: "srv-msg-9001",
                    conversationID: "conv-local",
                    senderUserID: Self.user.id,
                    serverSequence: 100,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_001_000),
                    kind: "text",
                    body: ["text": "hello client"]
                )
            )
        )

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.count == 1
                    && manager.imConversationStore.selectedConversation?.messages.first?.serverSequence == 100
            }
        }

        let sentMessage = manager.imConversationStore.selectedConversation?.messages.first
        #expect(sentMessage?.direction == .outgoing)
        #expect(sentMessage?.serverMessageID == "srv-msg-9001")
        #expect(sentMessage?.serverSequence == 100)
        #expect(sentMessage?.createdAt == Date(timeIntervalSince1970: 1_700_001_000))
    }

    @Test func sendIMTextQueuesWhenTCPConnectionIsUnavailable() async throws {
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                throw URLError(.notConnectedToInternet)
            }
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                if case .signedIn = manager.phase {
                    return true
                }
                return false
            }
        }

        let didSend = await manager.sendIMText("queued while offline", to: "conv-local")

        #expect(didSend)
        let message = try #require(manager.imConversationStore.selectedConversation?.messages.first)
        #expect(message.text == "queued while offline")
        #expect(message.deliveryState == .queued(message: "等待 IM 长连接恢复后发送。"))
    }

    @Test func sendIMTextSendFailureLeavesMessageUnknown() async throws {
        let harness = IMConnectionTestHarness(failingSendNumbers: [1])
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            }
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run { manager.imConnectionStatus == .connected }
        }

        let didSend = await manager.sendIMText("lost ack", to: "conv-local")

        #expect(!didSend)
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.first?.deliveryState
                    == .unknown(message: "发送状态未确认，请重试。")
            }
        }
        let message = try #require(manager.imConversationStore.selectedConversation?.messages.first)
        #expect(manager.imConversationStore.isRetryableFailure(message))
        #expect(manager.imConversationStore.queueSummary(for: "conv-local").retryableIssueCount == 1)
    }

    @Test func cancelQueuedIMTextMessageRemovesOfflineQueuedMessage() async throws {
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                throw URLError(.notConnectedToInternet)
            }
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                if case .signedIn = manager.phase {
                    return true
                }
                return false
            }
        }

        let didSend = await manager.sendIMText("cancel me", to: "conv-local")
        let message = try #require(manager.imConversationStore.selectedConversation?.messages.first)
        let didCancel = manager.cancelQueuedIMTextMessage(localMessageID: message.id, in: "conv-local")

        #expect(didSend)
        #expect(didCancel)
        #expect(manager.imConversationStore.selectedConversation?.messages.isEmpty == true)
        #expect(!manager.imConversationStore.queueSummary(for: "conv-local").hasPendingWork)
    }

    @Test func loginFlushesRestoredQueuedMessagesAfterGapSync() async throws {
        let harness = IMConnectionTestHarness()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString
        let cache = InMemoryIMConversationCache()
        await cache.seed(
            IMConversationCacheSnapshot(
                conversations: [
                    IMCachedConversationState(
                        id: conversationIDString,
                        title: "缓存会话",
                        kind: .direct,
                        memberCount: 2,
                        memberUserIDs: [Self.user.id],
                        messages: [
                            IMCachedMessageState(
                                id: "queued-client-1",
                                conversationID: conversationIDString,
                                clientMessageID: "queued-client-1",
                                serverMessageID: nil,
                                senderUserID: Self.user.id,
                                serverSequence: nil,
                                kind: "text",
                                text: "恢复后发送",
                                direction: .outgoing,
                                createdAt: Date(timeIntervalSince1970: 1_700_100_000),
                                deliveryState: .queued(message: "等待 IM 长连接恢复后发送。")
                            )
                        ],
                        hasLoadedMessages: true,
                        lastMessagePreviewText: "恢复后发送",
                        hasMoreHistory: false,
                        latestSyncedServerSequence: nil,
                        oldestLoadedServerSequence: nil,
                        serverLastReadSequence: 0,
                        serverUnreadCount: 0,
                        updatedAt: Date(timeIntervalSince1970: 1_700_100_000)
                    )
                ],
                selectedConversationID: conversationIDString,
                lastSummaryRefreshAt: nil
            ),
            for: Self.user.id
        )

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        [
                            IMConversationSummaryResponseBody(
                                id: conversationID,
                                title: "服务端会话",
                                kind: IMConversationKind.direct.rawValue,
                                memberCount: 2,
                                memberUserIDs: [Self.user.id],
                                lastMessage: nil,
                                createdAt: Date(timeIntervalSince1970: 1_700_090_000),
                                updatedAt: Date(timeIntervalSince1970: 1_700_100_000)
                            )
                        ]
                    )
                )
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            imConversationCache: IMConversationCacheHandler(cache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")

        let messageLine = try await Self.requireRecordedLine(at: 0, from: harness)
        let messagePacket = try Self.decode(IMTCPPacketEnvelope<IMTCPMessagePayload>.self, from: messageLine)
        #expect(messagePacket.type == .message)
        #expect(messagePacket.payload.conversationID == conversationIDString)
        #expect(messagePacket.payload.clientMessageID == "queued-client-1")
        #expect(messagePacket.payload.body["text"] == "恢复后发送")
    }

    @Test func queuedFlushPublishesProgressAndClearsWhenFinished() async throws {
        let harness = IMConnectionTestHarness(sendDelayNanoseconds: 200_000_000)
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString
        let cache = InMemoryIMConversationCache()
        await cache.seed(
            IMConversationCacheSnapshot(
                conversations: [
                    IMCachedConversationState(
                        id: conversationIDString,
                        title: "缓存会话",
                        kind: .direct,
                        memberCount: 2,
                        memberUserIDs: [Self.user.id],
                        messages: [
                            IMCachedMessageState(
                                id: "queued-client-1",
                                conversationID: conversationIDString,
                                clientMessageID: "queued-client-1",
                                serverMessageID: nil,
                                senderUserID: Self.user.id,
                                serverSequence: nil,
                                kind: "text",
                                text: "恢复后发送",
                                direction: .outgoing,
                                createdAt: Date(timeIntervalSince1970: 1_700_100_000),
                                deliveryState: .queued(message: "等待 IM 长连接恢复后发送。")
                            )
                        ],
                        hasLoadedMessages: true,
                        lastMessagePreviewText: "恢复后发送",
                        hasMoreHistory: false,
                        latestSyncedServerSequence: nil,
                        oldestLoadedServerSequence: nil,
                        serverLastReadSequence: 0,
                        serverUnreadCount: 0,
                        updatedAt: Date(timeIntervalSince1970: 1_700_100_000)
                    )
                ],
                selectedConversationID: conversationIDString,
                lastSummaryRefreshAt: nil
            ),
            for: Self.user.id
        )

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        [
                            IMConversationSummaryResponseBody(
                                id: conversationID,
                                title: "服务端会话",
                                kind: IMConversationKind.direct.rawValue,
                                memberCount: 2,
                                memberUserIDs: [Self.user.id],
                                lastMessage: nil,
                                createdAt: Date(timeIntervalSince1970: 1_700_090_000),
                                updatedAt: Date(timeIntervalSince1970: 1_700_100_000)
                            )
                        ]
                    )
                )
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            imConversationCache: IMConversationCacheHandler(cache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")

        try await Self.waitUntil {
            await MainActor.run {
                manager.isFlushingQueuedIMTextMessages
            }
        }
        _ = try await Self.requireRecordedLine(at: 0, from: harness)
        try await Self.waitUntil {
            await MainActor.run {
                !manager.isFlushingQueuedIMTextMessages
            }
        }
    }

    @Test func queuedFlushFailureMakesInFlightUnknownAndLeavesUnsentQueued() async throws {
        let harness = IMConnectionTestHarness(failingSendNumbers: [1])
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString
        let cache = InMemoryIMConversationCache()
        await cache.seed(
            IMConversationCacheSnapshot(
                conversations: [
                    IMCachedConversationState(
                        id: conversationIDString,
                        title: "缓存会话",
                        kind: .direct,
                        memberCount: 2,
                        memberUserIDs: [Self.user.id],
                        messages: [
                            IMCachedMessageState(
                                id: "queued-client-1",
                                conversationID: conversationIDString,
                                clientMessageID: "queued-client-1",
                                serverMessageID: nil,
                                senderUserID: Self.user.id,
                                serverSequence: nil,
                                kind: "text",
                                text: "第一条",
                                direction: .outgoing,
                                createdAt: Date(timeIntervalSince1970: 1_700_100_000),
                                deliveryState: .queued(message: "等待 IM 长连接恢复后发送。")
                            ),
                            IMCachedMessageState(
                                id: "queued-client-2",
                                conversationID: conversationIDString,
                                clientMessageID: "queued-client-2",
                                serverMessageID: nil,
                                senderUserID: Self.user.id,
                                serverSequence: nil,
                                kind: "text",
                                text: "第二条",
                                direction: .outgoing,
                                createdAt: Date(timeIntervalSince1970: 1_700_100_001),
                                deliveryState: .queued(message: "等待 IM 长连接恢复后发送。")
                            )
                        ],
                        hasLoadedMessages: true,
                        lastMessagePreviewText: "第二条",
                        hasMoreHistory: false,
                        latestSyncedServerSequence: nil,
                        oldestLoadedServerSequence: nil,
                        serverLastReadSequence: 0,
                        serverUnreadCount: 0,
                        updatedAt: Date(timeIntervalSince1970: 1_700_100_001)
                    )
                ],
                selectedConversationID: conversationIDString,
                lastSummaryRefreshAt: nil
            ),
            for: Self.user.id
        )

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        [
                            IMConversationSummaryResponseBody(
                                id: conversationID,
                                title: "服务端会话",
                                kind: IMConversationKind.direct.rawValue,
                                memberCount: 2,
                                memberUserIDs: [Self.user.id],
                                lastMessage: nil,
                                createdAt: Date(timeIntervalSince1970: 1_700_090_000),
                                updatedAt: Date(timeIntervalSince1970: 1_700_100_000)
                            )
                        ]
                    )
                )
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            imConversationCache: IMConversationCacheHandler(cache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.map(\.deliveryState) == [
                    .unknown(message: "发送状态未确认，请重试。"),
                    .queued(message: "等待 IM 长连接恢复后发送。")
                ]
            }
        }
        let summary = manager.imConversationStore.queueSummary(for: conversationIDString)
        #expect(summary.queuedCount == 1)
        #expect(summary.retryableIssueCount == 1)
    }

    @Test func queuedFlushContinuesAcrossMultipleBatchesUntilQueueIsDrained() async throws {
        let harness = IMConnectionTestHarness(sendDelayNanoseconds: 100_000_000)
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString
        let cache = InMemoryIMConversationCache()
        await cache.seed(
            Self.queuedConversationCacheSnapshot(
                conversationID: conversationIDString,
                messageCount: 25
            ),
            for: Self.user.id
        )

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        [
                            IMConversationSummaryResponseBody(
                                id: conversationID,
                                title: "服务端会话",
                                kind: IMConversationKind.direct.rawValue,
                                memberCount: 2,
                                memberUserIDs: [Self.user.id],
                                lastMessage: nil,
                                createdAt: Date(timeIntervalSince1970: 1_700_090_000),
                                updatedAt: Date(timeIntervalSince1970: 1_700_100_000)
                            )
                        ]
                    )
                )
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            imConversationCache: IMConversationCacheHandler(cache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")

        try await Self.waitUntil {
            let lineCount = await harness.recordedLines().count
            return await MainActor.run {
                lineCount >= 20 && lineCount < 25
                    && manager.isFlushingQueuedIMTextMessages
                    && manager.imConnectionStatus == .connected
            }
        }

        try await Self.waitUntil {
            let lineCount = await harness.recordedLines().count
            return await MainActor.run {
                lineCount == 25 && !manager.isFlushingQueuedIMTextMessages
            }
        }

        let summary = manager.imConversationStore.queueSummary(for: conversationIDString)
        #expect(summary.queuedCount == 0)
        #expect(summary.sendingCount == 25)
        #expect(await harness.recordedLines().count == 25)
    }

    @Test func queuedFlushFailureInLaterBatchStopsBackfillAndLeavesRemainingQueued() async throws {
        let harness = IMConnectionTestHarness(failingSendNumbers: [22])
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString
        let cache = InMemoryIMConversationCache()
        await cache.seed(
            Self.queuedConversationCacheSnapshot(
                conversationID: conversationIDString,
                messageCount: 25
            ),
            for: Self.user.id
        )

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        [
                            IMConversationSummaryResponseBody(
                                id: conversationID,
                                title: "服务端会话",
                                kind: IMConversationKind.direct.rawValue,
                                memberCount: 2,
                                memberUserIDs: [Self.user.id],
                                lastMessage: nil,
                                createdAt: Date(timeIntervalSince1970: 1_700_090_000),
                                updatedAt: Date(timeIntervalSince1970: 1_700_100_000)
                            )
                        ]
                    )
                )
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            imConversationCache: IMConversationCacheHandler(cache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")

        try await Self.waitUntil {
            let lineCount = await harness.recordedLines().count
            let messages = await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages ?? []
            }
            let queuedCount = messages.filter {
                if case .queued = $0.deliveryState {
                    return true
                }
                return false
            }.count
            let unknownCount = messages.filter {
                if case .unknown = $0.deliveryState {
                    return true
                }
                return false
            }.count
            return await MainActor.run {
                lineCount == 21
                    && queuedCount == 3
                    && unknownCount == 22
                    && !manager.isFlushingQueuedIMTextMessages
                    && {
                        if case .failed = manager.imConnectionStatus {
                            return true
                        }
                        return false
                    }()
            }
        }

        let summary = manager.imConversationStore.queueSummary(for: conversationIDString)
        #expect(summary.queuedCount == 3)
        #expect(summary.retryableIssueCount == 22)
        #expect(await harness.recordedLines().count == 21)
    }

    @Test func logoutCancelsQueuedFlushBackfillAndPreventsLateMutation() async throws {
        let harness = IMConnectionTestHarness(sendDelayNanoseconds: 200_000_000)
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString
        let cache = InMemoryIMConversationCache()
        await cache.seed(
            Self.queuedConversationCacheSnapshot(
                conversationID: conversationIDString,
                messageCount: 25
            ),
            for: Self.user.id
        )

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("DELETE", "/api/auth/sessions/current"):
                return HTTPFixtures.response(statusCode: 200)
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        [
                            IMConversationSummaryResponseBody(
                                id: conversationID,
                                title: "服务端会话",
                                kind: IMConversationKind.direct.rawValue,
                                memberCount: 2,
                                memberUserIDs: [Self.user.id],
                                lastMessage: nil,
                                createdAt: Date(timeIntervalSince1970: 1_700_090_000),
                                updatedAt: Date(timeIntervalSince1970: 1_700_100_000)
                            )
                        ]
                    )
                )
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            imConversationCache: IMConversationCacheHandler(cache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        _ = try await Self.requireRecordedLine(at: 0, from: harness)

        let recordedLineCountBeforeLogout = await harness.recordedLines().count
        await manager.logout()
        try await Task.sleep(for: .milliseconds(300))

        #expect(manager.phase == .signedOut(message: nil))
        #expect(manager.imConversationStore.conversations.isEmpty)
        #expect(!manager.isFlushingQueuedIMTextMessages)
        #expect(await harness.recordedLines().count == recordedLineCountBeforeLogout)
    }

    @Test func contactEventsUpdateRequestsAndContactsInRealtime() async throws {
        let harness = IMConnectionTestHarness()
        let peer = AuthUser(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            email: "peer@example.com"
        )
        let requestID = UUID(uuidString: "aaaaaaaa-aaaa-bbbb-cccc-dddddddddddd")!
        let pendingRequest = ContactRequestResponseBody(
            id: requestID,
            requester: peer,
            addressee: Self.user,
            status: .pending,
            message: "hi",
            requesterRemark: "me",
            addresseeRemark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_200_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_200_000),
            respondedAt: nil
        )
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            }
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run { manager.imConnectionStatus == .connected }
        }

        await harness.yield(
            .contactEvent(
                requestID: nil,
                payload: IMTCPContactEventPayload(
                    eventType: .friendRequestCreated,
                    request: pendingRequest,
                    contact: nil,
                    contactUserID: nil,
                    actorUserID: peer.id,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_200_001)
                )
            )
        )

        try await Self.waitUntil {
            await MainActor.run {
                manager.incomingContactRequests.map(\.id) == [requestID]
            }
        }

        let contact = ContactResponseBody(
            id: peer.id,
            email: peer.email,
            remark: "Peer",
            createdAt: Date(timeIntervalSince1970: 1_700_200_002)
        )
        await harness.yield(
            .contactEvent(
                requestID: nil,
                payload: IMTCPContactEventPayload(
                    eventType: .friendRequestAccepted,
                    request: ContactRequestResponseBody(
                        id: requestID,
                        requester: peer,
                        addressee: Self.user,
                        status: .accepted,
                        message: "hi",
                        requesterRemark: "me",
                        addresseeRemark: "Peer",
                        createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                        updatedAt: Date(timeIntervalSince1970: 1_700_200_002),
                        respondedAt: Date(timeIntervalSince1970: 1_700_200_002)
                    ),
                    contact: contact,
                    contactUserID: nil,
                    actorUserID: Self.user.id,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_200_002)
                )
            )
        )

        try await Self.waitUntil {
            await MainActor.run {
                manager.incomingContactRequests.isEmpty && manager.contacts.map(\.id) == [peer.id]
            }
        }

        await harness.yield(
            .contactEvent(
                requestID: nil,
                payload: IMTCPContactEventPayload(
                    eventType: .contactRemoved,
                    request: nil,
                    contact: nil,
                    contactUserID: peer.id,
                    actorUserID: peer.id,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_200_003)
                )
            )
        )

        try await Self.waitUntil {
            await MainActor.run { manager.contacts.isEmpty }
        }
    }

    @Test func imConnectionSyncsContactStateAfterConnection() async throws {
        let harness = IMConnectionTestHarness()
        let requestCounter = IMRequestCounter()
        let peer = AuthUser(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            email: "peer@example.com"
        )
        let contact = ContactResponseBody(
            id: peer.id,
            email: peer.email,
            remark: "Peer",
            createdAt: Date(timeIntervalSince1970: 1_700_210_000)
        )
        let pendingRequest = ContactRequestResponseBody(
            id: UUID(uuidString: "aaaaaaaa-2222-bbbb-cccc-dddddddddddd")!,
            requester: peer,
            addressee: Self.user,
            status: .pending,
            message: "hi",
            requesterRemark: nil,
            addresseeRemark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_210_001),
            updatedAt: Date(timeIntervalSince1970: 1_700_210_001),
            respondedAt: nil
        )
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationsBody())
            case ("GET", "/api/contacts"):
                await requestCounter.increment("contacts")
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([contact]))
            case ("GET", "/api/contact-requests"):
                await requestCounter.increment("contactRequests")
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([pendingRequest]))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")

        try await Self.waitUntil {
            await MainActor.run {
                manager.contacts.map(\.id) == [peer.id]
                    && manager.incomingContactRequests.map(\.id) == [pendingRequest.id]
                    && manager.pendingIncomingContactRequestCount == 1
            }
        }
        try await Self.waitUntil {
            let contactCount = await requestCounter.count(for: "contacts")
            let contactRequestCount = await requestCounter.count(for: "contactRequests")
            return contactCount >= 2 && contactRequestCount >= 2
        }
    }

    @Test func completeContactEventDoesNotTriggerHTTPCorrection() async throws {
        let harness = IMConnectionTestHarness()
        let requestCounter = IMRequestCounter()
        let peer = AuthUser(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            email: "peer@example.com"
        )
        let requestID = UUID(uuidString: "aaaaaaaa-3333-bbbb-cccc-dddddddddddd")!
        let pendingRequest = ContactRequestResponseBody(
            id: requestID,
            requester: peer,
            addressee: Self.user,
            status: .pending,
            message: nil,
            requesterRemark: nil,
            addresseeRemark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_220_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_220_000),
            respondedAt: nil
        )
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationsBody())
            case ("GET", "/api/contacts"):
                await requestCounter.increment("contacts")
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                await requestCounter.increment("contactRequests")
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            let contactCount = await requestCounter.count(for: "contacts")
            let contactRequestCount = await requestCounter.count(for: "contactRequests")
            return contactCount >= 2 && contactRequestCount >= 2
        }
        let contactCount = await requestCounter.count(for: "contacts")
        let contactRequestCount = await requestCounter.count(for: "contactRequests")

        await harness.yield(
            .contactEvent(
                requestID: nil,
                payload: IMTCPContactEventPayload(
                    eventType: .friendRequestCreated,
                    request: pendingRequest,
                    contact: nil,
                    contactUserID: nil,
                    actorUserID: peer.id,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_220_001)
                )
            )
        )

        try await Self.waitUntil {
            await MainActor.run {
                manager.incomingContactRequests.map(\.id) == [requestID]
                    && manager.pendingIncomingContactRequestCount == 1
            }
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(await requestCounter.count(for: "contacts") == contactCount)
        #expect(await requestCounter.count(for: "contactRequests") == contactRequestCount)
    }

    @Test func acceptContactRequestMovesPendingIntoResolvedHistoryAndPersistsSnapshot() async throws {
        let harness = IMConnectionTestHarness()
        let contactCache = InMemoryContactStateCache()
        let peer = AuthUser(
            id: UUID(uuidString: "abababab-1111-2222-3333-444444444444")!,
            email: "peer@example.com"
        )
        let requestID = UUID(uuidString: "cdcdcdcd-1111-2222-3333-444444444444")!
        let pendingRequest = ContactRequestResponseBody(
            id: requestID,
            requester: peer,
            addressee: Self.user,
            status: .pending,
            message: "hi",
            requesterRemark: nil,
            addresseeRemark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_225_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_225_000),
            respondedAt: nil
        )
        let contact = ContactResponseBody(
            id: peer.id,
            email: peer.email,
            remark: "好友",
            createdAt: Date(timeIntervalSince1970: 1_700_225_010)
        )
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationsBody())
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([contact]))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([pendingRequest]))
            case ("POST", "/api/contact-requests/\(requestID.uuidString)/accept"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody(contact))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            contactStateCache: ContactStateCacheHandler(contactCache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.incomingContactRequests.map(\.id) == [requestID]
            }
        }

        let didAccept = await manager.acceptContactRequest(id: requestID, remark: "peer")

        #expect(didAccept)
        #expect(manager.acceptingRequestIDs.isEmpty)
        try await Self.waitUntil {
            await MainActor.run {
                manager.incomingContactRequests.isEmpty
                    && manager.recentResolvedContactRequests.map(\.id) == [requestID]
                    && manager.recentResolvedContactRequests.first?.status == .accepted
                    && manager.contacts.map(\.id) == [peer.id]
            }
        }
        try await Self.waitUntil {
            let snapshot = await contactCache.latestSnapshot(for: Self.user.id)
            return snapshot?.resolvedRequests.map(\.id) == [requestID]
                && snapshot?.resolvedRequests.first?.status == .accepted
        }
    }

    @Test func cancelContactRequestMovesOutgoingPendingIntoResolvedHistory() async throws {
        let harness = IMConnectionTestHarness()
        let contactCache = InMemoryContactStateCache()
        let peer = AuthUser(
            id: UUID(uuidString: "abababab-5555-2222-3333-444444444444")!,
            email: "peer@example.com"
        )
        let requestID = UUID(uuidString: "cdcdcdcd-5555-2222-3333-444444444444")!
        let outgoingRequest = ContactRequestResponseBody(
            id: requestID,
            requester: Self.user,
            addressee: peer,
            status: .pending,
            message: "hello",
            requesterRemark: nil,
            addresseeRemark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_225_100),
            updatedAt: Date(timeIntervalSince1970: 1_700_225_100),
            respondedAt: nil
        )
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationsBody())
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([outgoingRequest]))
            case ("POST", "/api/contact-requests/\(requestID.uuidString)/cancel"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        ContactRequestResponseBody(
                            id: requestID,
                            requester: Self.user,
                            addressee: peer,
                            status: .cancelled,
                            message: "hello",
                            requesterRemark: nil,
                            addresseeRemark: nil,
                            createdAt: outgoingRequest.createdAt,
                            updatedAt: Date(timeIntervalSince1970: 1_700_225_110),
                            respondedAt: Date(timeIntervalSince1970: 1_700_225_110)
                        )
                    )
                )
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            contactStateCache: ContactStateCacheHandler(contactCache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.outgoingContactRequests.map(\.id) == [requestID]
            }
        }

        let didCancel = await manager.cancelContactRequest(id: requestID)

        #expect(didCancel)
        #expect(manager.cancellingRequestIDs.isEmpty)
        try await Self.waitUntil {
            await MainActor.run {
                manager.outgoingContactRequests.isEmpty
                    && manager.recentResolvedContactRequests.map(\.id) == [requestID]
                    && manager.recentResolvedContactRequests.first?.status == .cancelled
            }
        }
        try await Self.waitUntil {
            let snapshot = await contactCache.latestSnapshot(for: Self.user.id)
            return snapshot?.resolvedRequests.map(\.id) == [requestID]
                && snapshot?.resolvedRequests.first?.status == .cancelled
        }
    }

    @Test func incompleteContactEventTriggersHTTPCorrectionWithoutClearingCurrentState() async throws {
        let harness = IMConnectionTestHarness()
        let requestCounter = IMRequestCounter()
        let contactCache = InMemoryContactStateCache()
        let peer = AuthUser(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            email: "peer@example.com"
        )
        let contact = ContactResponseBody(
            id: peer.id,
            email: peer.email,
            remark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_230_000)
        )
        let pendingRequest = ContactRequestResponseBody(
            id: UUID(uuidString: "aaaaaaaa-4444-bbbb-cccc-dddddddddddd")!,
            requester: peer,
            addressee: Self.user,
            status: .pending,
            message: nil,
            requesterRemark: nil,
            addresseeRemark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_230_001),
            updatedAt: Date(timeIntervalSince1970: 1_700_230_001),
            respondedAt: nil
        )
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationsBody())
            case ("GET", "/api/contacts"):
                await requestCounter.increment("contacts")
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([contact]))
            case ("GET", "/api/contact-requests"):
                await requestCounter.increment("contactRequests")
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([pendingRequest]))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            contactStateCache: ContactStateCacheHandler(contactCache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.contacts.map(\.id) == [peer.id]
                    && manager.incomingContactRequests.map(\.id) == [pendingRequest.id]
            }
        }
        try await Self.waitUntil {
            let contactCount = await requestCounter.count(for: "contacts")
            let contactRequestCount = await requestCounter.count(for: "contactRequests")
            return contactCount >= 2 && contactRequestCount >= 2
        }
        let contactCount = await requestCounter.count(for: "contacts")
        let contactRequestCount = await requestCounter.count(for: "contactRequests")
        try await Self.waitUntil {
            let snapshot = await contactCache.latestSnapshot(for: Self.user.id)
            return snapshot?.contacts.map(\.id) == [peer.id]
                && snapshot?.incomingRequests.map(\.id) == [pendingRequest.id]
        }
        let saveCount = await contactCache.saveCount(for: Self.user.id)

        await harness.yield(
            .contactEvent(
                requestID: nil,
                payload: IMTCPContactEventPayload(
                    eventType: .contactRemoved,
                    request: nil,
                    contact: nil,
                    contactUserID: nil,
                    actorUserID: peer.id,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_230_002)
                )
            )
        )

        #expect(manager.contacts.map(\.id) == [peer.id])
        try await Self.waitUntil {
            let latestContactCount = await requestCounter.count(for: "contacts")
            let latestContactRequestCount = await requestCounter.count(for: "contactRequests")
            return latestContactCount > contactCount && latestContactRequestCount > contactRequestCount
        }
        #expect(manager.contacts.map(\.id) == [peer.id])
        #expect(manager.incomingContactRequests.map(\.id) == [pendingRequest.id])
        #expect(await contactCache.saveCount(for: Self.user.id) == saveCount)
    }

    @Test func loginRestoresContactCacheBeforeNetworkOverrides() async throws {
        let harness = IMConnectionTestHarness()
        let restoreGate = RestoreGate()
        let contactCache = InMemoryContactStateCache()
        let cachedPeer = AuthUser(
            id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
            email: "cached@example.com"
        )
        let networkPeer = AuthUser(
            id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            email: "network@example.com"
        )
        let cachedRequest = ContactRequestResponseBody(
            id: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
            requester: cachedPeer,
            addressee: Self.user,
            status: .pending,
            message: "cached",
            requesterRemark: nil,
            addresseeRemark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_240_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_240_000),
            respondedAt: nil
        )
        let networkRequest = ContactRequestResponseBody(
            id: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
            requester: networkPeer,
            addressee: Self.user,
            status: .pending,
            message: "network",
            requesterRemark: nil,
            addresseeRemark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_240_100),
            updatedAt: Date(timeIntervalSince1970: 1_700_240_100),
            respondedAt: nil
        )
        await contactCache.seed(
            ContactStateCacheSnapshot(
                contacts: [
                    CachedContactState(
                        id: cachedPeer.id,
                        email: cachedPeer.email,
                        remark: "缓存联系人",
                        createdAt: Date(timeIntervalSince1970: 1_700_239_999)
                    )
                ],
                incomingRequests: [CachedContactRequestState(cachedRequest)],
                outgoingRequests: [],
                resolvedRequests: [],
                lastRefreshAt: Date(timeIntervalSince1970: 1_700_240_000),
                lastSeenIncomingContactRequestAt: cachedRequest.createdAt
            ),
            for: Self.user.id
        )

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationsBody())
            case ("GET", "/api/contacts"):
                await restoreGate.markStarted()
                await restoreGate.waitForResume()
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody([
                        ContactResponseBody(
                            id: networkPeer.id,
                            email: networkPeer.email,
                            remark: "网络联系人",
                            createdAt: Date(timeIntervalSince1970: 1_700_240_100)
                        )
                    ])
                )
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody([networkRequest])
                )
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            contactStateCache: ContactStateCacheHandler(contactCache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        await restoreGate.waitUntilStarted()

        #expect(manager.contacts.map(\.id) == [cachedPeer.id])
        #expect(manager.incomingContactRequests.map(\.id) == [cachedRequest.id])
        #expect(manager.pendingIncomingContactRequestCount == 1)
        #expect(manager.unseenIncomingContactRequestCount == 0)
        #expect(manager.hasUnreadIncomingContactRequests == false)

        await restoreGate.resume()

        try await Self.waitUntil {
            await MainActor.run {
                manager.contacts.map(\.id) == [networkPeer.id]
                    && manager.incomingContactRequests.map(\.id) == [networkRequest.id]
                    && manager.pendingIncomingContactRequestCount == 1
                    && manager.unseenIncomingContactRequestCount == 1
            }
        }
    }

    @Test func contactEventPersistsPendingRequestForColdStartReplay() async throws {
        let harness = IMConnectionTestHarness()
        let contactCache = InMemoryContactStateCache()
        let peer = AuthUser(
            id: UUID(uuidString: "aaaaaaaa-5555-bbbb-cccc-dddddddddddd")!,
            email: "peer@example.com"
        )
        let pendingRequest = ContactRequestResponseBody(
            id: UUID(uuidString: "bbbbbbbb-5555-bbbb-cccc-dddddddddddd")!,
            requester: peer,
            addressee: Self.user,
            status: .pending,
            message: "hi",
            requesterRemark: nil,
            addresseeRemark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_250_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_250_000),
            respondedAt: nil
        )
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationsBody())
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            contactStateCache: ContactStateCacheHandler(contactCache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.contacts.isEmpty && manager.incomingContactRequests.isEmpty
            }
        }

        await harness.yield(
            .contactEvent(
                requestID: nil,
                payload: IMTCPContactEventPayload(
                    eventType: .friendRequestCreated,
                    request: pendingRequest,
                    contact: nil,
                    contactUserID: nil,
                    actorUserID: peer.id,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_250_001)
                )
            )
        )

        try await Self.waitUntil {
            await MainActor.run {
                manager.incomingContactRequests.map(\.id) == [pendingRequest.id]
                    && manager.unseenIncomingContactRequestCount == 1
            }
        }
        try await Self.waitUntil {
            let snapshot = await contactCache.latestSnapshot(for: Self.user.id)
            return snapshot?.incomingRequests.map(\.id) == [pendingRequest.id]
        }
    }

    @Test func markIncomingContactRequestsSeenClearsUnreadAndPersistsSeenTimestamp() async throws {
        let harness = IMConnectionTestHarness()
        let contactCache = InMemoryContactStateCache()
        let peer = AuthUser(
            id: UUID(uuidString: "aaaaaaaa-9999-bbbb-cccc-dddddddddddd")!,
            email: "peer@example.com"
        )
        let pendingRequest = ContactRequestResponseBody(
            id: UUID(uuidString: "bbbbbbbb-9999-bbbb-cccc-dddddddddddd")!,
            requester: peer,
            addressee: Self.user,
            status: .pending,
            message: nil,
            requesterRemark: nil,
            addresseeRemark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_290_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_290_000),
            respondedAt: nil
        )
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationsBody())
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([pendingRequest]))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            contactStateCache: ContactStateCacheHandler(contactCache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")

        try await Self.waitUntil {
            await MainActor.run {
                manager.incomingContactRequests.map(\.id) == [pendingRequest.id]
                    && manager.unseenIncomingContactRequestCount == 1
                    && manager.hasUnreadIncomingContactRequests
            }
        }

        await MainActor.run {
            manager.markIncomingContactRequestsSeen()
        }

        #expect(manager.unseenIncomingContactRequestCount == 0)
        #expect(manager.hasUnreadIncomingContactRequests == false)
        try await Self.waitUntil {
            let snapshot = await contactCache.latestSnapshot(for: Self.user.id)
            return snapshot?.lastSeenIncomingContactRequestAt == pendingRequest.createdAt
        }
    }

    @Test func frozenDirectConversationShowsUnavailableUntilPeerLoads() async throws {
        let harness = IMConnectionTestHarness()
        let membersGate = RestoreGate()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let peerID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(
                        conversationID: conversationID,
                        kind: .direct,
                        directMessagingState: IMDirectMessagingState.frozenAfterUnfriend.rawValue,
                        memberUserIDs: [Self.user.id, peerID]
                    )
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members"):
                await membersGate.markStarted()
                await membersGate.waitForResume()
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationMembersBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        await membersGate.waitUntilStarted()
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversationID == conversationID.uuidString
            }
        }

        let unavailable = manager.directPeerRelationshipPresentation(for: conversationID.uuidString)
        #expect(unavailable?.state == .unavailable)
        #expect(unavailable?.message == "正在加载对方信息…")

        await membersGate.resume()

        try await Self.waitUntil {
            await MainActor.run {
                manager.directPeerRelationshipPresentation(for: conversationID.uuidString)?.state == .none
            }
        }
    }

    @Test func sendDirectConversationFriendRequestMovesFrozenConversationToOutgoingPending() async throws {
        let harness = IMConnectionTestHarness()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let peer = AuthUser(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            email: "peer@example.com"
        )
        let requestID = UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(
                        conversationID: conversationID,
                        kind: .direct,
                        directMessagingState: IMDirectMessagingState.frozenAfterUnfriend.rawValue,
                        memberUserIDs: [Self.user.id, peer.id],
                        directPeer: IMDirectPeerResponseBody(id: peer.id, email: peer.email)
                    )
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationMembersBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            case ("POST", "/api/contact-requests"):
                let body = try JSONDecoder().decode(
                    ContactRequestCreateRequestBody.self,
                    from: request.httpBody ?? Data()
                )
                #expect(body.email == peer.email)
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        ContactRequestResponseBody(
                            id: requestID,
                            requester: Self.user,
                            addressee: peer,
                            status: .pending,
                            message: body.message,
                            requesterRemark: body.remark,
                            addresseeRemark: nil,
                            createdAt: Date(timeIntervalSince1970: 1_700_260_000),
                            updatedAt: Date(timeIntervalSince1970: 1_700_260_000),
                            respondedAt: nil
                        )
                    )
                )
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.directPeerRelationshipPresentation(for: conversationID.uuidString)?.state == .none
            }
        }

        let didSend = await manager.sendDirectConversationFriendRequest(conversationID: conversationID.uuidString)

        #expect(didSend)
        #expect(manager.contactRequestActionMessage == nil)
        #expect(manager.directConversationRelationshipActionMessage(for: conversationID.uuidString) == "好友申请已发送。")
        #expect(manager.directPeerRelationshipPresentation(for: conversationID.uuidString)?.state == .outgoingPending)
    }

    @Test func acceptDirectConversationFriendRequestMovesFrozenConversationToFriendState() async throws {
        let harness = IMConnectionTestHarness()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let peer = AuthUser(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            email: "peer@example.com"
        )
        let requestID = UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!
        let contact = ContactResponseBody(
            id: peer.id,
            email: peer.email,
            remark: "好友",
            createdAt: Date(timeIntervalSince1970: 1_700_260_100)
        )
        let incomingRequest = ContactRequestResponseBody(
            id: requestID,
            requester: peer,
            addressee: Self.user,
            status: .pending,
            message: "add me",
            requesterRemark: nil,
            addresseeRemark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_260_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_260_000),
            respondedAt: nil
        )
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([incomingRequest]))
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(
                        conversationID: conversationID,
                        kind: .direct,
                        directMessagingState: IMDirectMessagingState.frozenAfterUnfriend.rawValue,
                        memberUserIDs: [Self.user.id, peer.id],
                        directPeer: IMDirectPeerResponseBody(id: peer.id, email: peer.email)
                    )
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationMembersBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            case ("POST", "/api/contact-requests/\(requestID.uuidString)/accept"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody(contact))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.directPeerRelationshipPresentation(for: conversationID.uuidString)?.state == .incomingPending
            }
        }

        let didAccept = await manager.acceptDirectConversationFriendRequest(conversationID: conversationID.uuidString)

        #expect(didAccept)
        #expect(manager.contactRequestActionMessage == nil)
        #expect(manager.directConversationRelationshipActionMessage(for: conversationID.uuidString) == "已添加好友。")
        try await Self.waitUntil {
            await MainActor.run {
                manager.contacts.map(\.id) == [peer.id]
                    && manager.directPeerRelationshipPresentation(for: conversationID.uuidString)?.state == .friend
            }
        }
    }

    @Test func directConversationIdentityPresentationPrefersContactRemarkOverPeerEmail() async throws {
        let harness = IMConnectionTestHarness()
        let conversationID = UUID(uuidString: "99999999-1111-2222-3333-bbbbbbbbbbbb")!
        let peer = AuthUser(
            id: UUID(uuidString: "88888888-4444-4444-4444-444444444444")!,
            email: "peer@example.com"
        )
        let contact = ContactResponseBody(
            id: peer.id,
            email: peer.email,
            remark: "备注好友",
            createdAt: Date(timeIntervalSince1970: 1_700_261_000)
        )
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([contact]))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(
                        conversationID: conversationID,
                        kind: .direct,
                        memberUserIDs: [Self.user.id, peer.id],
                        directPeer: IMDirectPeerResponseBody(id: peer.id, email: peer.email)
                    )
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.conversations.map { $0.id } == [conversationID.uuidString]
            }
        }

        let identity = manager.conversationIdentityPresentation(for: conversationID.uuidString)
        #expect(identity?.title == "备注好友")
        #expect(identity?.detailSummary == peer.email)
        #expect(identity?.rowSecondaryLabel == peer.email)
    }

    @Test func directConversationIdentityPresentationFallsBackToPeerEmailWithoutContactRemark() async throws {
        let harness = IMConnectionTestHarness()
        let conversationID = UUID(uuidString: "77777777-1111-2222-3333-bbbbbbbbbbbb")!
        let peer = AuthUser(
            id: UUID(uuidString: "66666666-4444-4444-4444-444444444444")!,
            email: "peer@example.com"
        )
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(
                        conversationID: conversationID,
                        kind: .direct,
                        memberUserIDs: [Self.user.id, peer.id],
                        directPeer: IMDirectPeerResponseBody(id: peer.id, email: peer.email)
                    )
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.conversations.map { $0.id } == [conversationID.uuidString]
            }
        }

        let identity = manager.conversationIdentityPresentation(for: conversationID.uuidString)
        #expect(identity?.title == peer.email)
        #expect(identity?.detailSummary == peer.email)
        #expect(identity?.rowSecondaryLabel == nil)
    }

    @Test func seenIncomingRequestsStayReadAfterCorrectionUntilNewerRequestArrives() async throws {
        let harness = IMConnectionTestHarness()
        let requestCounter = IMRequestCounter()
        let contactCache = InMemoryContactStateCache()
        let peer = AuthUser(
            id: UUID(uuidString: "aaaaaaaa-abcd-bbbb-cccc-dddddddddddd")!,
            email: "peer@example.com"
        )
        let oldRequest = ContactRequestResponseBody(
            id: UUID(uuidString: "bbbbbbbb-abcd-bbbb-cccc-dddddddddddd")!,
            requester: peer,
            addressee: Self.user,
            status: .pending,
            message: nil,
            requesterRemark: nil,
            addresseeRemark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_300_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_300_000),
            respondedAt: nil
        )
        let newRequest = ContactRequestResponseBody(
            id: UUID(uuidString: "cccccccc-abcd-bbbb-cccc-dddddddddddd")!,
            requester: peer,
            addressee: Self.user,
            status: .pending,
            message: "new",
            requesterRemark: nil,
            addresseeRemark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_300_100),
            updatedAt: Date(timeIntervalSince1970: 1_700_300_100),
            respondedAt: nil
        )
        await contactCache.seed(
            ContactStateCacheSnapshot(
                contacts: [],
                incomingRequests: [CachedContactRequestState(oldRequest)],
                outgoingRequests: [],
                resolvedRequests: [],
                lastRefreshAt: Date(timeIntervalSince1970: 1_700_300_010),
                lastSeenIncomingContactRequestAt: oldRequest.createdAt
            ),
            for: Self.user.id
        )
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationsBody())
            case ("GET", "/api/contacts"):
                await requestCounter.increment("contacts")
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                await requestCounter.increment("contactRequests")
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([oldRequest]))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            contactStateCache: ContactStateCacheHandler(contactCache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.incomingContactRequests.map(\.id) == [oldRequest.id]
                    && manager.unseenIncomingContactRequestCount == 0
            }
        }
        let baselineCorrectionCount = await requestCounter.count(for: "contactRequests")

        await harness.yield(
            .contactEvent(
                requestID: nil,
                payload: IMTCPContactEventPayload(
                    eventType: .contactRemoved,
                    request: nil,
                    contact: nil,
                    contactUserID: nil,
                    actorUserID: peer.id,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_300_050)
                )
            )
        )

        try await Self.waitUntil {
            let latestCorrectionCount = await requestCounter.count(for: "contactRequests")
            return latestCorrectionCount > baselineCorrectionCount
        }
        #expect(manager.unseenIncomingContactRequestCount == 0)

        await harness.yield(
            .contactEvent(
                requestID: nil,
                payload: IMTCPContactEventPayload(
                    eventType: .friendRequestCreated,
                    request: newRequest,
                    contact: nil,
                    contactUserID: nil,
                    actorUserID: peer.id,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_300_101)
                )
            )
        )

        try await Self.waitUntil {
            await MainActor.run {
                manager.incomingContactRequests.map(\.id) == [newRequest.id, oldRequest.id]
                    && manager.unseenIncomingContactRequestCount == 1
            }
        }
    }

    @Test func contactRemovedEventUpdatesPersistedContactSnapshot() async throws {
        let harness = IMConnectionTestHarness()
        let contactCache = InMemoryContactStateCache()
        let peer = AuthUser(
            id: UUID(uuidString: "aaaaaaaa-6666-bbbb-cccc-dddddddddddd")!,
            email: "peer@example.com"
        )
        let contact = ContactResponseBody(
            id: peer.id,
            email: peer.email,
            remark: "旧联系人",
            createdAt: Date(timeIntervalSince1970: 1_700_260_000)
        )
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationsBody())
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([contact]))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            contactStateCache: ContactStateCacheHandler(contactCache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run { manager.contacts.map(\.id) == [peer.id] }
        }
        try await Self.waitUntil {
            let snapshot = await contactCache.latestSnapshot(for: Self.user.id)
            return snapshot?.contacts.map(\.id) == [peer.id]
        }

        await harness.yield(
            .contactEvent(
                requestID: nil,
                payload: IMTCPContactEventPayload(
                    eventType: .contactRemoved,
                    request: nil,
                    contact: nil,
                    contactUserID: peer.id,
                    actorUserID: peer.id,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_260_100)
                )
            )
        )

        try await Self.waitUntil {
            await MainActor.run { manager.contacts.isEmpty }
        }
        try await Self.waitUntil {
            let snapshot = await contactCache.latestSnapshot(for: Self.user.id)
            return snapshot?.contacts.isEmpty == true
        }
    }

    @Test func contactCacheRestoreFailureFallsBackToNetworkStartup() async throws {
        let harness = IMConnectionTestHarness()
        let peer = AuthUser(
            id: UUID(uuidString: "aaaaaaaa-7777-bbbb-cccc-dddddddddddd")!,
            email: "peer@example.com"
        )
        let pendingRequest = ContactRequestResponseBody(
            id: UUID(uuidString: "bbbbbbbb-7777-bbbb-cccc-dddddddddddd")!,
            requester: peer,
            addressee: Self.user,
            status: .pending,
            message: nil,
            requesterRemark: nil,
            addresseeRemark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_270_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_270_000),
            respondedAt: nil
        )
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationsBody())
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody([
                        ContactResponseBody(
                            id: peer.id,
                            email: peer.email,
                            remark: nil,
                            createdAt: Date(timeIntervalSince1970: 1_700_270_000)
                        )
                    ])
                )
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([pendingRequest]))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            contactStateCache: ContactStateCacheHandler(FailingLoadContactStateCache()),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")

        try await Self.waitUntil {
            await MainActor.run {
                manager.contacts.map(\.id) == [peer.id]
                    && manager.incomingContactRequests.map(\.id) == [pendingRequest.id]
                    && manager.pendingIncomingContactRequestCount == 1
            }
        }
    }

    @Test func logoutClearsCurrentUsersContactCache() async throws {
        let harness = IMConnectionTestHarness()
        let contactCache = InMemoryContactStateCache()
        let peer = AuthUser(
            id: UUID(uuidString: "aaaaaaaa-8888-bbbb-cccc-dddddddddddd")!,
            email: "peer@example.com"
        )
        let pendingRequest = ContactRequestResponseBody(
            id: UUID(uuidString: "bbbbbbbb-8888-bbbb-cccc-dddddddddddd")!,
            requester: peer,
            addressee: Self.user,
            status: .pending,
            message: nil,
            requesterRemark: nil,
            addresseeRemark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_280_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_280_000),
            respondedAt: nil
        )
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("POST", "/api/auth/logout"):
                return HTTPFixtures.response(statusCode: 204)
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationsBody())
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody([
                        ContactResponseBody(
                            id: peer.id,
                            email: peer.email,
                            remark: nil,
                            createdAt: Date(timeIntervalSince1970: 1_700_280_000)
                        )
                    ])
                )
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([pendingRequest]))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }
        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            contactStateCache: ContactStateCacheHandler(contactCache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            let snapshot = await contactCache.latestSnapshot(for: Self.user.id)
            return snapshot?.contacts.map(\.id) == [peer.id]
                && snapshot?.incomingRequests.map(\.id) == [pendingRequest.id]
        }

        await manager.logout()

        #expect(await contactCache.latestSnapshot(for: Self.user.id) == nil)
    }

    @Test func loginLoadsServerConversationListAndHistory() async throws {
        let harness = IMConnectionTestHarness()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(conversationID: conversationID)
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationMembersBody()
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesBody(conversationID: conversationID)
                )
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(for: request)
                )
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.id == conversationID.uuidString
                    && manager.imConversationStore.selectedConversation?.messages.count == 1
            }
        }

        let conversation = manager.imConversationStore.selectedConversation
        #expect(conversation?.title == "服务端会话")
        #expect(conversation?.members.map(\.email) == ["manager@example.com", "peer@example.com"])
        #expect(conversation?.messages.first?.text == "来自历史接口")
    }

    @Test func loginLoadsOnlyFirstConversationSummaryPageDuringBootstrap() async throws {
        let harness = IMConnectionTestHarness()
        let firstConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let secondConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                let cursor = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "cursor" })?
                    .value
                #expect(cursor == nil)
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationSummaryPageBody(
                        items: [
                            Self.imConversationSummary(
                                id: firstConversationID,
                                latestServerSequence: 2,
                                updatedAt: Date(timeIntervalSince1970: 1_700_001_100),
                                title: "第一页会话"
                            )
                        ],
                        nextCursor: "cursor-page-2",
                        hasMore: true,
                        snapshotToken: "snapshot-page-1"
                    )
                )
            case ("GET", "/api/im/conversations/\(firstConversationID.uuidString)/members"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationMembersBody()
                )
            case ("GET", "/api/im/conversations/\(firstConversationID.uuidString)/messages"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesBody(conversationID: firstConversationID)
                )
            case ("POST", "/api/im/conversations/\(firstConversationID.uuidString)/read"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(for: request)
                )
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.id == firstConversationID.uuidString
                    && manager.imConversationStore.selectedConversation?.messages.count == 1
            }
        }

        let requests = await transport.requests()
        let summaryRequests = requests.filter { $0.url?.path == "/api/im/conversations" }

        #expect(summaryRequests.count == 1)
        #expect(requests.contains(where: { $0.url?.path == "/api/im/conversations/changes" }) == false)
        #expect(manager.imConversationStore.conversations.map(\.id) == [firstConversationID.uuidString])
        #expect(manager.imConversationStore.conversationSummaryNextCursor == "cursor-page-2")
        #expect(manager.imConversationStore.hasMoreConversationSummaries == true)
        #expect(manager.imConversationStore.conversations.contains(where: { $0.id == secondConversationID.uuidString }) == false)
    }

    @Test func loadMoreIMConversationSummariesAppendsNextPageAfterAnchorAppears() async throws {
        let harness = IMConnectionTestHarness()
        let firstConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let secondConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!
        let thirdConversationID = UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                let components = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)
                let cursor = components?.queryItems?.first(where: { $0.name == "cursor" })?.value

                if cursor == nil {
                    return HTTPFixtures.response(
                        statusCode: 200,
                        body: try Self.imConversationSummaryPageBody(
                            items: [
                                Self.imConversationSummary(
                                    id: firstConversationID,
                                    latestServerSequence: 3,
                                    updatedAt: Date(timeIntervalSince1970: 1_700_001_200),
                                    title: "第一页顶部"
                                ),
                                Self.imConversationSummary(
                                    id: secondConversationID,
                                    latestServerSequence: 2,
                                    updatedAt: Date(timeIntervalSince1970: 1_700_001_100),
                                    title: "第一页底部"
                                )
                            ],
                            nextCursor: "cursor-page-2",
                            hasMore: true,
                            snapshotToken: "snapshot-page-1"
                        )
                    )
                }

                if cursor == "cursor-page-2" {
                    return HTTPFixtures.response(
                        statusCode: 200,
                        body: try Self.imConversationSummaryPageBody(
                            items: [
                                Self.imConversationSummary(
                                    id: thirdConversationID,
                                    latestServerSequence: 1,
                                    updatedAt: Date(timeIntervalSince1970: 1_700_001_000),
                                    title: "第二页"
                                )
                            ],
                            nextCursor: nil,
                            hasMore: false,
                            snapshotToken: "snapshot-page-1"
                        )
                    )
                }

                Issue.record("收到未预期分页游标：\(cursor ?? "nil")")
                return HTTPFixtures.response(statusCode: 500)
            case ("GET", "/api/im/conversations/\(firstConversationID.uuidString)/members"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationMembersBody()
                )
            case ("GET", "/api/im/conversations/\(firstConversationID.uuidString)/messages"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesBody(conversationID: firstConversationID)
                )
            case ("POST", "/api/im/conversations/\(firstConversationID.uuidString)/read"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(for: request)
                )
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.conversations.map(\.id) == [
                    firstConversationID.uuidString,
                    secondConversationID.uuidString
                ]
            }
        }

        await manager.loadMoreIMConversationSummariesIfNeeded(anchorConversationID: firstConversationID.uuidString)
        var summaryRequests = await transport.requests().filter { $0.url?.path == "/api/im/conversations" }
        #expect(summaryRequests.count == 1)

        await manager.loadMoreIMConversationSummariesIfNeeded(
            anchorConversationID: manager.imConversationStore.conversationSummaryPaginationAnchorID
        )

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.conversations.map(\.id) == [
                    firstConversationID.uuidString,
                    secondConversationID.uuidString,
                    thirdConversationID.uuidString
                ]
            }
        }

        summaryRequests = await transport.requests().filter { $0.url?.path == "/api/im/conversations" }
        let secondRequestCursor = summaryRequests
            .dropFirst()
            .compactMap { request in
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "cursor" })?
                    .value
            }
            .first

        #expect(summaryRequests.count == 2)
        #expect(secondRequestCursor == "cursor-page-2")
        #expect(manager.imConversationStore.conversationSummaryNextCursor == nil)
        #expect(manager.imConversationStore.hasMoreConversationSummaries == false)
        #expect(manager.imConversationStore.conversationSummaryPaginationAnchorID == thirdConversationID.uuidString)
    }

    @Test func conversationPreferencesUpdatedOnAnotherDeviceConvergeViaSummaryChanges() async throws {
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let summaryState = IMCrossDeviceConversationSummaryState(
            summary: Self.imConversationSummary(
                id: conversationID,
                latestServerSequence: 3,
                updatedAt: Date(timeIntervalSince1970: 1_700_600_100),
                title: "跨端偏好"
            )
        )
        let requestCounter = IMRequestCounter()
        let loginCounter = IMRequestCounter()
        let transport = MockHTTPTransport { request in
            let path = request.url?.path
            switch (request.httpMethod, path) {
            case ("POST", "/api/auth/login"):
                await loginCounter.increment("login")
                let loginIndex = await loginCounter.count(for: "login")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.authResponseBody(
                        user: Self.user,
                        accessToken: "access-\(loginIndex)",
                        refreshToken: "refresh-\(loginIndex)"
                    )
                )
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await summaryState.pageResponse())
                )
            case ("GET", "/api/im/conversations/changes"):
                await requestCounter.increment("changes")
                let afterToken = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "afterToken" })?
                    .value
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await summaryState.changesResponse(afterToken: afterToken))
                )
            case ("PATCH", "/api/im/conversations/\(conversationID.uuidString)/preferences"):
                let payload = try JSONDecoder().decode(
                    IMConversationPreferencesUpdateRequestBody.self,
                    from: request.httpBody ?? Data()
                )
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        await summaryState.updatePreferences(
                            isPinned: payload.isPinned,
                            isMuted: payload.isMuted
                        )
                    )
                )
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationReadBody(for: request))
            case ("GET", let path) where path?.hasPrefix("/api/im/conversations/") == true && path?.hasSuffix("/members") == true:
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", let path) where path?.hasPrefix("/api/im/conversations/") == true && path?.hasSuffix("/messages/since") == true:
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            case ("GET", let path) where path?.hasPrefix("/api/im/conversations/") == true && path?.hasSuffix("/messages") == true:
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesBody())
            case ("POST", let path) where path?.hasPrefix("/api/im/conversations/") == true && path?.hasSuffix("/read") == true:
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationReadBody(for: request))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let firstManager = makeManager(
            transport: transport,
            openIMConnection: nil,
            wrapDefaultIMResponses: false
        )
        let secondManager = makeManager(
            transport: transport,
            openIMConnection: nil,
            wrapDefaultIMResponses: false
        )

        await firstManager.login(email: Self.user.email, password: "password123")
        await secondManager.login(email: Self.user.email, password: "password123")

        #expect(secondManager.imConversationStore.conversations.first?.isPinned == false)
        #expect(secondManager.imConversationStore.conversations.first?.isMuted == false)

        let didUpdate = await firstManager.updateIMConversationPreferences(
            conversationID.uuidString,
            isPinned: true,
            isMuted: true
        )
        #expect(didUpdate)

        try await Task.sleep(for: .seconds(5.2))
        await secondManager.refreshIMConversationSummaryReadModelIfNeeded()

        #expect(await requestCounter.count(for: "changes") >= 1)
        #expect(secondManager.imConversationStore.conversations.first?.isPinned == true)
        #expect(secondManager.imConversationStore.conversations.first?.isMuted == true)
        #expect(secondManager.imConversationStore.totalUnreadCount == 0)
    }

    @Test func conversationMetadataUpdatedOnAnotherDeviceRefreshesSelectedConversation() async throws {
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let summaryState = IMCrossDeviceConversationSummaryState(
            summary: Self.imConversationSummary(
                id: conversationID,
                latestServerSequence: 2,
                updatedAt: Date(timeIntervalSince1970: 1_700_600_200),
                title: "旧群资料"
            )
        )
        let requestCounter = IMRequestCounter()
        let loginCounter = IMRequestCounter()
        let transport = MockHTTPTransport { request in
            let path = request.url?.path
            switch (request.httpMethod, path) {
            case ("POST", "/api/auth/login"):
                await loginCounter.increment("login")
                let loginIndex = await loginCounter.count(for: "login")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.authResponseBody(
                        user: Self.user,
                        accessToken: "access-meta-\(loginIndex)",
                        refreshToken: "refresh-meta-\(loginIndex)"
                    )
                )
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await summaryState.pageResponse())
                )
            case ("GET", "/api/im/conversations/changes"):
                await requestCounter.increment("changes")
                let afterToken = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "afterToken" })?
                    .value
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await summaryState.changesResponse(afterToken: afterToken))
                )
            case ("PATCH", "/api/im/conversations/\(conversationID.uuidString)/metadata"):
                let payload = try JSONDecoder().decode(
                    IMConversationMetadataUpdateRequestBody.self,
                    from: request.httpBody ?? Data()
                )
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        await summaryState.updateMetadata(
                            title: payload.title,
                            notice: payload.notice,
                            avatarPreset: payload.avatarPreset
                        )
                    )
                )
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationReadBody(for: request))
            case ("GET", let path) where path?.hasPrefix("/api/im/conversations/") == true && path?.hasSuffix("/members") == true:
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", let path) where path?.hasPrefix("/api/im/conversations/") == true && path?.hasSuffix("/messages/since") == true:
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            case ("GET", let path) where path?.hasPrefix("/api/im/conversations/") == true && path?.hasSuffix("/messages") == true:
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesBody())
            case ("POST", let path) where path?.hasPrefix("/api/im/conversations/") == true && path?.hasSuffix("/read") == true:
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationReadBody(for: request))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let firstManager = makeManager(
            transport: transport,
            openIMConnection: nil,
            wrapDefaultIMResponses: false
        )
        let secondManager = makeManager(
            transport: transport,
            openIMConnection: nil,
            wrapDefaultIMResponses: false
        )

        await firstManager.login(email: Self.user.email, password: "password123")
        await secondManager.login(email: Self.user.email, password: "password123")

        let didUpdate = await firstManager.updateIMConversationMetadata(
            conversationID.uuidString,
            title: "新群资料",
            notice: "新的群公告",
            avatarPreset: .forest
        )
        #expect(didUpdate)

        try await Task.sleep(for: .seconds(5.2))
        await secondManager.refreshIMConversationSummaryReadModelIfNeeded()

        #expect(await requestCounter.count(for: "changes") >= 1)
        #expect(secondManager.imConversationStore.selectedConversation?.title == "新群资料")
        #expect(secondManager.imConversationStore.selectedConversation?.notice == "新的群公告")
        #expect(secondManager.imConversationStore.selectedConversation?.avatarPreset == .forest)
    }

    @Test func conversationRemovedForSelfOnAnotherDeviceFallsBackSelectionViaSummaryChanges() async throws {
        let removedConversationID = UUID(uuidString: "aaaaaaaa-7777-8888-9999-bbbbbbbbbbbb")!
        let fallbackConversationID = UUID(uuidString: "bbbbbbbb-7777-8888-9999-cccccccccccc")!
        let state = IMCrossDeviceConversationListState(
            conversations: [
                IMConversationSummaryResponseBody(
                    id: removedConversationID,
                    title: "将被移除的群聊",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 2,
                    memberUserIDs: [Self.user.id],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: UUID(uuidString: "11111111-7777-8888-9999-aaaaaaaaaaaa")!,
                        senderUserID: Self.user.id,
                        serverSequence: 1,
                        content: .text("当前选中的会话"),
                        createdAt: Date(timeIntervalSince1970: 1_700_900_000)
                    ),
                    lastReadSequence: 1,
                    unreadCount: 0,
                    createdAt: Date(timeIntervalSince1970: 1_700_899_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_900_000)
                ),
                IMConversationSummaryResponseBody(
                    id: fallbackConversationID,
                    title: "回退会话",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 2,
                    memberUserIDs: [Self.user.id],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: UUID(uuidString: "22222222-7777-8888-9999-aaaaaaaaaaaa")!,
                        senderUserID: Self.user.id,
                        serverSequence: 1,
                        content: .text("备用摘要"),
                        createdAt: Date(timeIntervalSince1970: 1_700_899_900)
                    ),
                    lastReadSequence: 1,
                    unreadCount: 0,
                    createdAt: Date(timeIntervalSince1970: 1_700_898_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_899_900)
                )
            ],
            messagesByConversationID: [
                removedConversationID: [
                    IMConversationMessageResponseBody(
                        id: UUID(uuidString: "11111111-7777-8888-9999-aaaaaaaaaaaa")!,
                        conversationID: removedConversationID,
                        senderUserID: Self.user.id,
                        clientMessageID: nil,
                        serverSequence: 1,
                        content: .text("当前选中的会话"),
                        createdAt: Date(timeIntervalSince1970: 1_700_900_000)
                    )
                ]
            ]
        )
        let requestCounter = IMRequestCounter()
        let loginCounter = IMRequestCounter()

        let transport = MockHTTPTransport { request in
            let path = request.url?.path
            switch (request.httpMethod, path) {
            case ("POST", "/api/auth/login"):
                await loginCounter.increment("login")
                let loginIndex = await loginCounter.count(for: "login")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.authResponseBody(
                        user: Self.user,
                        accessToken: "access-remove-\(loginIndex)",
                        refreshToken: "refresh-remove-\(loginIndex)"
                    )
                )
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.pageResponse())
                )
            case ("GET", "/api/im/conversations/changes"):
                await requestCounter.increment("changes")
                let afterToken = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "afterToken" })?
                    .value
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.changesResponse(afterToken: afterToken))
                )
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            case ("GET", "/api/im/conversations/\(removedConversationID.uuidString)/members"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", "/api/im/conversations/\(removedConversationID.uuidString)/messages"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.messagesResponse(for: removedConversationID))
                )
            case ("GET", let path?) where path.hasPrefix("/api/im/conversations/") && path.hasSuffix("/messages/since"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            case ("POST", let path?) where path.hasPrefix("/api/im/conversations/") && path.hasSuffix("/read"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationReadBody(for: request))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = makeManager(
            transport: transport,
            openIMConnection: nil,
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversationID == removedConversationID.uuidString
                    && manager.imConversationStore.conversations.count == 2
                    && manager.imConversationStore.selectedConversation?.title == "将被移除的群聊"
            }
        }

        await state.removeConversation(id: removedConversationID)

        try await Task.sleep(for: .seconds(5.2))
        await manager.refreshIMConversationSummaryReadModelIfNeeded()

        #expect(await requestCounter.count(for: "changes") >= 1)
        #expect(manager.imConversationStore.conversations.map(\.id) == [fallbackConversationID.uuidString])
        #expect(manager.imConversationStore.selectedConversationID == fallbackConversationID.uuidString)
        #expect(manager.imConversationStore.selectedConversation?.title == "回退会话")
    }

    @Test func removedConversationWithCachedHistoryDoesNotReappearAfterRefreshAndReconnectGapSync() async throws {
        let harness = IMConnectionTestHarness()
        let removedConversationID = UUID(uuidString: "aaaaaaaa-6666-7777-8888-bbbbbbbbbbbb")!
        let fallbackConversationID = UUID(uuidString: "bbbbbbbb-6666-7777-8888-cccccccccccc")!
        let removedConversationIDString = removedConversationID.uuidString
        let fallbackConversationIDString = fallbackConversationID.uuidString
        let cache = InMemoryIMConversationCache()
        await cache.seed(
            IMConversationCacheSnapshot(
                conversations: [
                    IMCachedConversationState(
                        id: removedConversationIDString,
                        title: "缓存中的旧群聊",
                        kind: .group,
                        memberCount: 2,
                        memberUserIDs: [Self.user.id],
                        messages: [
                            IMCachedMessageState(
                                id: "removed-cached-1",
                                conversationID: removedConversationIDString,
                                clientMessageID: nil,
                                serverMessageID: "removed-server-1",
                                senderUserID: Self.user.id,
                                serverSequence: 1,
                                kind: "text",
                                text: "缓存旧历史 1",
                                direction: .incoming,
                                createdAt: Date(timeIntervalSince1970: 1_700_920_000),
                                deliveryState: .sent
                            ),
                            IMCachedMessageState(
                                id: "removed-cached-2",
                                conversationID: removedConversationIDString,
                                clientMessageID: nil,
                                serverMessageID: "removed-server-2",
                                senderUserID: Self.user.id,
                                serverSequence: 2,
                                kind: "text",
                                text: "缓存旧历史 2",
                                direction: .incoming,
                                createdAt: Date(timeIntervalSince1970: 1_700_920_010),
                                deliveryState: .sent
                            )
                        ],
                        hasLoadedMessages: true,
                        lastMessagePreviewText: "缓存旧历史 2",
                        hasMoreHistory: false,
                        latestSyncedServerSequence: 2,
                        oldestLoadedServerSequence: 1,
                        serverLastReadSequence: 2,
                        serverUnreadCount: 0,
                        updatedAt: Date(timeIntervalSince1970: 1_700_920_010)
                    ),
                    IMCachedConversationState(
                        id: fallbackConversationIDString,
                        title: "缓存中的回退会话",
                        kind: .group,
                        memberCount: 2,
                        memberUserIDs: [Self.user.id],
                        messages: [
                            IMCachedMessageState(
                                id: "fallback-cached-1",
                                conversationID: fallbackConversationIDString,
                                clientMessageID: nil,
                                serverMessageID: "fallback-server-1",
                                senderUserID: Self.user.id,
                                serverSequence: 1,
                                kind: "text",
                                text: "回退历史 1",
                                direction: .incoming,
                                createdAt: Date(timeIntervalSince1970: 1_700_920_020),
                                deliveryState: .sent
                            )
                        ],
                        hasLoadedMessages: true,
                        lastMessagePreviewText: "回退历史 1",
                        hasMoreHistory: true,
                        latestSyncedServerSequence: 1,
                        oldestLoadedServerSequence: 1,
                        serverLastReadSequence: 1,
                        serverUnreadCount: 0,
                        updatedAt: Date(timeIntervalSince1970: 1_700_920_020)
                    )
                ],
                selectedConversationID: removedConversationIDString,
                lastSummaryRefreshAt: Date(timeIntervalSince1970: 1_700_920_030)
            ),
            for: Self.user.id
        )

        let state = IMCrossDeviceConversationListState(
            conversations: [
                IMConversationSummaryResponseBody(
                    id: removedConversationID,
                    title: "服务端旧群聊",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 2,
                    memberUserIDs: [Self.user.id],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: UUID(uuidString: "11111111-6666-7777-8888-aaaaaaaaaaaa")!,
                        senderUserID: Self.user.id,
                        serverSequence: 2,
                        content: .text("缓存旧历史 2"),
                        createdAt: Date(timeIntervalSince1970: 1_700_920_010)
                    ),
                    lastReadSequence: 2,
                    unreadCount: 0,
                    createdAt: Date(timeIntervalSince1970: 1_700_919_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_920_010)
                ),
                IMConversationSummaryResponseBody(
                    id: fallbackConversationID,
                    title: "服务端回退会话",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 2,
                    memberUserIDs: [Self.user.id],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: UUID(uuidString: "22222222-6666-7777-8888-aaaaaaaaaaaa")!,
                        senderUserID: Self.user.id,
                        serverSequence: 2,
                        content: .text("回退历史 2"),
                        createdAt: Date(timeIntervalSince1970: 1_700_920_040)
                    ),
                    lastReadSequence: 1,
                    unreadCount: 1,
                    createdAt: Date(timeIntervalSince1970: 1_700_919_100),
                    updatedAt: Date(timeIntervalSince1970: 1_700_920_040)
                )
            ],
            messagesByConversationID: [
                removedConversationID: [
                    IMConversationMessageResponseBody(
                        id: UUID(uuidString: "11111111-6666-7777-8888-aaaaaaaaaaaa")!,
                        conversationID: removedConversationID,
                        senderUserID: Self.user.id,
                        clientMessageID: nil,
                        serverSequence: 2,
                        content: .text("缓存旧历史 2"),
                        createdAt: Date(timeIntervalSince1970: 1_700_920_010)
                    )
                ],
                fallbackConversationID: [
                    IMConversationMessageResponseBody(
                        id: UUID(uuidString: "33333333-6666-7777-8888-aaaaaaaaaaaa")!,
                        conversationID: fallbackConversationID,
                        senderUserID: Self.user.id,
                        clientMessageID: nil,
                        serverSequence: 1,
                        content: .text("回退历史 1"),
                        createdAt: Date(timeIntervalSince1970: 1_700_920_020)
                    ),
                    IMConversationMessageResponseBody(
                        id: UUID(uuidString: "22222222-6666-7777-8888-aaaaaaaaaaaa")!,
                        conversationID: fallbackConversationID,
                        senderUserID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                        clientMessageID: nil,
                        serverSequence: 2,
                        content: .text("回退历史 2"),
                        createdAt: Date(timeIntervalSince1970: 1_700_920_040)
                    )
                ]
            ]
        )
        let requestCounter = IMRequestCounter()
        let loginCounter = IMRequestCounter()

        let transport = MockHTTPTransport { request in
            let path = request.url?.path
            let query = request.url?.query
            switch (request.httpMethod, path, query) {
            case ("POST", "/api/auth/login", _):
                await loginCounter.increment("login")
                let loginIndex = await loginCounter.count(for: "login")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.authResponseBody(
                        user: Self.user,
                        accessToken: "access-removed-cache-\(loginIndex)",
                        refreshToken: "refresh-removed-cache-\(loginIndex)"
                    )
                )
            case ("GET", "/api/im/conversations", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.pageResponse())
                )
            case ("GET", "/api/im/conversations/changes", _):
                await requestCounter.increment("changes")
                let afterToken = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "afterToken" })?
                    .value
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.changesResponse(afterToken: afterToken))
                )
            case ("GET", "/api/contacts", _):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests", _):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            case ("GET", "/api/im/conversations/\(removedConversationIDString)/members", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", "/api/im/conversations/\(fallbackConversationIDString)/members", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", "/api/im/conversations/\(removedConversationIDString)/messages", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.messagesResponse(for: removedConversationID))
                )
            case ("GET", "/api/im/conversations/\(fallbackConversationIDString)/messages", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.messagesResponse(for: fallbackConversationID))
                )
            case ("GET", "/api/im/conversations/\(removedConversationIDString)/messages/since", _):
                await requestCounter.increment("removedGapSync")
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            case ("GET", "/api/im/conversations/\(fallbackConversationIDString)/messages/since", _):
                await requestCounter.increment("fallbackGapSync")
                let afterSequence = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "afterSequence" })?
                    .value
                    .flatMap(UInt64.init)
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        await state.messagesSinceResponse(for: fallbackConversationID, afterSequence: afterSequence)
                    )
                )
            case ("POST", "/api/im/conversations/\(removedConversationIDString)/read", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationReadBody(for: request))
            case ("POST", "/api/im/conversations/\(fallbackConversationIDString)/read", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationReadBody(for: request))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            imConversationCache: IMConversationCacheHandler(cache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversationID == removedConversationIDString
                    && manager.imConversationStore.selectedConversation?.messages.map(\.text) == ["缓存旧历史 1", "缓存旧历史 2"]
                    && manager.imConnectionStatus == .connected
            }
        }

        await state.removeConversation(id: removedConversationID)

        try await Task.sleep(for: .seconds(5.2))
        await manager.refreshIMConversationSummaryReadModelIfNeeded()

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversationID == fallbackConversationIDString
                    && manager.imConversationStore.conversations.map(\.id) == [fallbackConversationIDString]
                    && manager.imConversationStore.selectedConversation?.messages.map(\.text) == ["回退历史 1"]
            }
        }

        let removedGapRequestsBeforeReconnect = await requestCounter.count(for: "removedGapSync")
        let fallbackGapRequestsBeforeReconnect = await requestCounter.count(for: "fallbackGapSync")
        await manager.reconnectIMConnection()

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversationID == fallbackConversationIDString
                    && manager.imConversationStore.conversations.map(\.id) == [fallbackConversationIDString]
                    && manager.imConversationStore.selectedConversation?.messages.map(\.text) == ["回退历史 1", "回退历史 2"]
                    && manager.imConversationStore.selectedConversation?.lastMessagePreview == "回退历史 2"
                    && manager.imConversationStore.selectedConversation?.serverUnreadCount == 1
            }
        }

        #expect(await requestCounter.count(for: "changes") >= 1)
        #expect(await requestCounter.count(for: "removedGapSync") == removedGapRequestsBeforeReconnect)
        #expect(await requestCounter.count(for: "fallbackGapSync") > fallbackGapRequestsBeforeReconnect)
    }

    @Test func conversationMemberRoleUpdatedOnAnotherDeviceConvergesSummaryAndMembersAfterRefreshAndOpen() async throws {
        let conversationID = UUID(uuidString: "aaaaaaaa-8888-9999-0000-bbbbbbbbbbbb")!
        let peerUserID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let roleUpdatedMessageID = UUID(uuidString: "11111111-8888-9999-0000-aaaaaaaaaaaa")!
        let summaryState = IMCrossDeviceConversationSummaryState(
            summary: IMConversationSummaryResponseBody(
                id: conversationID,
                title: "群角色同步",
                kind: IMConversationKind.group.rawValue,
                memberCount: 2,
                memberUserIDs: [Self.user.id, peerUserID],
                lastMessage: IMMessagePreviewResponseBody(
                    id: UUID(uuidString: "22222222-8888-9999-0000-aaaaaaaaaaaa")!,
                    senderUserID: Self.user.id,
                    serverSequence: 1,
                    content: .system(.legacyText("manager@example.com 创建了群聊")),
                    createdAt: Date(timeIntervalSince1970: 1_700_910_000)
                ),
                lastReadSequence: 1,
                unreadCount: 0,
                createdAt: Date(timeIntervalSince1970: 1_700_909_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_910_000)
            )
        )
        let membersState = IMCrossDeviceConversationMembersState(
            membersByConversationID: [
                conversationID: [
                    IMConversationMemberResponseBody(id: Self.user.id, email: Self.user.email, role: .owner),
                    IMConversationMemberResponseBody(id: peerUserID, email: "peer@example.com", role: .member)
                ]
            ]
        )
        let requestCounter = IMRequestCounter()
        let loginCounter = IMRequestCounter()

        let transport = MockHTTPTransport { request in
            let path = request.url?.path
            switch (request.httpMethod, path) {
            case ("POST", "/api/auth/login"):
                await loginCounter.increment("login")
                let loginIndex = await loginCounter.count(for: "login")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.authResponseBody(
                        user: Self.user,
                        accessToken: "access-role-\(loginIndex)",
                        refreshToken: "refresh-role-\(loginIndex)"
                    )
                )
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await summaryState.pageResponse())
                )
            case ("GET", "/api/im/conversations/changes"):
                await requestCounter.increment("changes")
                let afterToken = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "afterToken" })?
                    .value
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await summaryState.changesResponse(afterToken: afterToken))
                )
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members"):
                await requestCounter.increment("members")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await membersState.membersResponse(for: conversationID))
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationReadBody(for: request))
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/members/\(peerUserID.uuidString)/role"):
                let payload = try JSONDecoder().decode(
                    IMConversationMemberRoleUpdateRequestBody.self,
                    from: request.httpBody ?? Data()
                )
                #expect(payload.role == .admin)
                await membersState.updateRole(in: conversationID, memberUserID: peerUserID, role: .admin)
                await summaryState.appendMessage(
                    IMConversationMessageResponseBody(
                        id: roleUpdatedMessageID,
                        conversationID: conversationID,
                        senderUserID: Self.user.id,
                        clientMessageID: nil,
                        serverSequence: 2,
                        content: .system(
                            IMSystemEvent(
                                type: .roleUpdated,
                                actorUserID: Self.user.id,
                                actorEmail: Self.user.email,
                                targetUserID: peerUserID,
                                targetEmail: "peer@example.com",
                                previousRole: .member,
                                newRole: .admin
                            )
                        ),
                        createdAt: Date(timeIntervalSince1970: 1_700_910_100)
                    ),
                    unreadCount: 1,
                    lastReadSequence: 1
                )
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await summaryState.currentSummary())
                )
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let firstManager = makeManager(
            transport: transport,
            openIMConnection: nil,
            wrapDefaultIMResponses: false
        )
        let secondManager = makeManager(
            transport: transport,
            openIMConnection: nil,
            wrapDefaultIMResponses: false
        )

        await firstManager.login(email: Self.user.email, password: "password123")
        await secondManager.login(email: Self.user.email, password: "password123")
        await secondManager.openIMConversation(conversationID.uuidString)

        try await Self.waitUntil {
            await MainActor.run {
                secondManager.imConversationStore.selectedConversation?.members.first(where: { $0.id == peerUserID })?.role == .member
            }
        }

        let didUpdateRole = await firstManager.updateIMConversationMemberRole(
            memberUserID: peerUserID,
            role: .admin,
            in: conversationID.uuidString
        )
        #expect(didUpdateRole)

        try await Task.sleep(for: .seconds(5.2))
        await secondManager.refreshIMConversationSummaryReadModelIfNeeded()
        await secondManager.openIMConversation(conversationID.uuidString)

        try await Self.waitUntil {
            await MainActor.run {
                secondManager.imConversationStore.selectedConversation?.lastMessagePreview == "manager@example.com 将 peer@example.com 设为管理员"
                    && secondManager.imConversationStore.selectedConversation?.serverUnreadCount == 1
                    && secondManager.imConversationStore.selectedConversation?.members.first(where: { $0.id == peerUserID })?.role == .admin
            }
        }

        #expect(await requestCounter.count(for: "changes") >= 1)
        #expect(await requestCounter.count(for: "members") >= 2)
    }

    @Test func conversationDraftRemainsLocalAcrossDevices() async throws {
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let cache = InMemoryIMConversationCache()
        await cache.seed(
            IMConversationCacheSnapshot(
                conversations: [
                    IMCachedConversationState(
                        id: conversationID.uuidString,
                        title: "本地草稿",
                        kind: .group,
                        memberCount: 2,
                        memberUserIDs: [Self.user.id],
                        messages: [],
                        hasLoadedMessages: false,
                        lastMessagePreviewText: "",
                        hasMoreHistory: false,
                        latestSyncedServerSequence: nil,
                        oldestLoadedServerSequence: nil,
                        serverLastReadSequence: 0,
                        serverUnreadCount: 0,
                        draftText: "只在本地的草稿",
                        draftUpdatedAt: Date(timeIntervalSince1970: 1_700_600_300),
                        updatedAt: Date(timeIntervalSince1970: 1_700_600_300)
                    )
                ],
                selectedConversationID: conversationID.uuidString,
                lastSummaryRefreshAt: nil
            ),
            for: Self.user.id
        )

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(conversationID: conversationID)
                )
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationReadBody(for: request))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let firstManager = makeManager(
            transport: transport,
            openIMConnection: nil,
            imConversationCache: IMConversationCacheHandler(cache),
            wrapDefaultIMResponses: false
        )
        let secondManager = makeManager(
            transport: transport,
            openIMConnection: nil,
            wrapDefaultIMResponses: false
        )

        await firstManager.login(email: Self.user.email, password: "password123")
        await secondManager.login(email: Self.user.email, password: "password123")

        #expect(firstManager.imConversationStore.draftText(for: conversationID.uuidString) == "只在本地的草稿")
        #expect(secondManager.imConversationStore.draftText(for: conversationID.uuidString).isEmpty)
    }

    @Test func recalledMessageOnAnotherDeviceConvergesViaSummaryChangesEvenWhenHistoryIsLoaded() async throws {
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let recalledMessageID = UUID(uuidString: "99999999-1111-2222-3333-aaaaaaaaaaaa")!
        let summaryState = IMCrossDeviceConversationSummaryState(
            summary: IMConversationSummaryResponseBody(
                id: conversationID,
                title: "待撤回消息",
                kind: IMConversationKind.group.rawValue,
                memberCount: 1,
                memberUserIDs: [Self.user.id],
                lastMessage: IMMessagePreviewResponseBody(
                    id: recalledMessageID,
                    senderUserID: Self.user.id,
                    serverSequence: 1,
                    kind: "text",
                    body: ["text": "待撤回消息"],
                    createdAt: Date(timeIntervalSince1970: 1_700_600_350)
                ),
                lastReadSequence: 0,
                unreadCount: 0,
                createdAt: Date(timeIntervalSince1970: 1_700_600_300),
                updatedAt: Date(timeIntervalSince1970: 1_700_600_350)
            )
        )
        let requestCounter = IMRequestCounter()
        let loginCounter = IMRequestCounter()
        let transport = MockHTTPTransport { request in
            let path = request.url?.path
            switch (request.httpMethod, path) {
            case ("POST", "/api/auth/login"):
                await loginCounter.increment("login")
                let loginIndex = await loginCounter.count(for: "login")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.authResponseBody(
                        user: Self.user,
                        accessToken: "access-recall-\(loginIndex)",
                        refreshToken: "refresh-recall-\(loginIndex)"
                    )
                )
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await summaryState.pageResponse())
                )
            case ("GET", "/api/im/conversations/changes"):
                await requestCounter.increment("changes")
                let afterToken = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "afterToken" })?
                    .value
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await summaryState.changesResponse(afterToken: afterToken))
                )
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/messages/\(recalledMessageID.uuidString)/recall"):
                let response = await summaryState.recallLatestMessage(senderUserID: Self.user.id)
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(try #require(response))
                )
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        [
                            IMConversationMessageResponseBody(
                                id: recalledMessageID,
                                conversationID: conversationID,
                                senderUserID: Self.user.id,
                                clientMessageID: nil,
                                serverSequence: 1,
                                kind: "text",
                                body: ["text": "待撤回消息"],
                                createdAt: Date(timeIntervalSince1970: 1_700_600_350)
                            )
                        ]
                    )
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationReadBody(for: request))
            case ("GET", let path) where path?.hasPrefix("/api/im/conversations/") == true && path?.hasSuffix("/members") == true:
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", let path) where path?.hasPrefix("/api/im/conversations/") == true && path?.hasSuffix("/messages/since") == true:
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            case ("GET", let path) where path?.hasPrefix("/api/im/conversations/") == true && path?.hasSuffix("/messages") == true:
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesBody())
            case ("POST", let path) where path?.hasPrefix("/api/im/conversations/") == true && path?.hasSuffix("/read") == true:
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationReadBody(for: request))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let firstManager = makeManager(
            transport: transport,
            openIMConnection: nil,
            wrapDefaultIMResponses: false
        )
        let secondManager = makeManager(
            transport: transport,
            openIMConnection: nil,
            wrapDefaultIMResponses: false
        )

        await firstManager.login(email: Self.user.email, password: "password123")
        await secondManager.login(email: Self.user.email, password: "password123")
        await secondManager.openIMConversation(conversationID.uuidString)

        try await Self.waitUntil {
            await MainActor.run {
                secondManager.imConversationStore.selectedConversation?.messages.last?.text == "待撤回消息"
            }
        }

        let changesBeforeRecall = await requestCounter.count(for: "changes")
        let didRecall = await firstManager.recallIMMessage(
            messageID: recalledMessageID.uuidString,
            in: conversationID.uuidString
        )
        #expect(didRecall)

        try await Self.waitUntil {
            await MainActor.run {
                firstManager.imConversationStore.selectedConversation?.lastMessagePreview == "撤回了一条消息"
            }
        }

        #expect(await requestCounter.count(for: "changes") > changesBeforeRecall)

        try await Task.sleep(for: .seconds(5.2))
        await secondManager.refreshIMConversationSummaryReadModelIfNeeded()

        #expect(secondManager.imConversationStore.selectedConversation?.lastMessagePreview == "撤回了一条消息")
    }

    @Test func recalledReadChangesAndGapSyncConvergeAcrossDevices() async throws {
        let secondHarness = IMConnectionTestHarness()
        let requestCounter = IMRequestCounter()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let historicalMessageID = UUID(uuidString: "11111111-1111-2222-3333-aaaaaaaaaaaa")!
        let recalledGapMessageID = UUID(uuidString: "22222222-1111-2222-3333-aaaaaaaaaaaa")!
        let initialMessages = [
            IMConversationMessageResponseBody(
                id: historicalMessageID,
                conversationID: conversationID,
                senderUserID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                clientMessageID: nil,
                serverSequence: 1,
                kind: "text",
                body: ["text": "历史中的旧消息"],
                createdAt: Date(timeIntervalSince1970: 1_700_610_000)
            )
        ]
        let summaryState = IMCrossDeviceConversationSummaryState(
            summary: IMConversationSummaryResponseBody(
                id: conversationID,
                title: "撤回+已读+补洞",
                kind: IMConversationKind.group.rawValue,
                memberCount: 1,
                memberUserIDs: [Self.user.id],
                lastMessage: IMMessagePreviewResponseBody(
                    id: historicalMessageID,
                    senderUserID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    serverSequence: 1,
                    kind: "text",
                    body: ["text": "历史中的旧消息"],
                    createdAt: Date(timeIntervalSince1970: 1_700_610_000)
                ),
                lastReadSequence: 1,
                unreadCount: 0,
                createdAt: Date(timeIntervalSince1970: 1_700_609_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_610_000)
            ),
            messages: initialMessages
        )
        let transport = MockHTTPTransport { request in
            let path = request.url?.path
            let query = request.url?.query
            switch (request.httpMethod, path, query) {
            case ("POST", "/api/auth/login", _):
                await requestCounter.increment("login")
                let loginIndex = await requestCounter.count(for: "login")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.authResponseBody(
                        user: Self.user,
                        accessToken: "access-combo-\(loginIndex)",
                        refreshToken: "refresh-combo-\(loginIndex)"
                    )
                )
            case ("GET", "/api/im/conversations", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await summaryState.pageResponse())
                )
            case ("GET", "/api/im/conversations/changes", _):
                await requestCounter.increment("changes")
                let afterToken = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "afterToken" })?
                    .value
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await summaryState.changesResponse(afterToken: afterToken))
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await summaryState.messagesResponse())
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since", _):
                await requestCounter.increment("gapSync")
                let afterSequence = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "afterSequence" })?
                    .value
                    .flatMap(UInt64.init)
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await summaryState.messagesSinceResponse(afterSequence: afterSequence))
                )
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read", _):
                await requestCounter.increment("markRead")
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationReadBody(for: request))
            case ("GET", "/api/contacts", _):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests", _):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let firstManager = makeManager(
            transport: transport,
            openIMConnection: nil,
            wrapDefaultIMResponses: false
        )
        let secondManager = makeManager(
            transport: transport,
            openIMConnection: {
                await secondHarness.makeConnection()
            },
            wrapDefaultIMResponses: false
        )

        await firstManager.login(email: Self.user.email, password: "password123")
        await secondManager.login(email: Self.user.email, password: "password123")

        try await Self.waitUntil {
            await MainActor.run {
                secondManager.imConversationStore.selectedConversation?.messages.map(\.text) == ["历史中的旧消息"]
                    && secondManager.imConnectionStatus == .connected
            }
        }

        await summaryState.appendMessage(
            IMConversationMessageResponseBody(
                id: recalledGapMessageID,
                conversationID: conversationID,
                senderUserID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                clientMessageID: nil,
                serverSequence: 2,
                kind: "text",
                body: ["text": "稍后会被撤回"],
                createdAt: Date(timeIntervalSince1970: 1_700_610_100)
            ),
            unreadCount: 1,
            lastReadSequence: 1
        )
        _ = await summaryState.recallLatestMessage(
            senderUserID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        )
        _ = await summaryState.updateReadState(lastReadSequence: 2, unreadCount: 0)

        try await Task.sleep(for: .seconds(5.2))
        await secondManager.refreshIMConversationSummaryReadModelIfNeeded()

        #expect(await requestCounter.count(for: "changes") >= 1)
        #expect(secondManager.imConversationStore.selectedConversation?.lastMessagePreview == "撤回了一条消息")
        #expect(secondManager.imConversationStore.selectedConversation?.serverLastReadSequence == 2)
        #expect(secondManager.imConversationStore.selectedConversation?.unreadCount == 0)

        let gapRequestsBeforeReconnect = await requestCounter.count(for: "gapSync")
        await secondManager.reconnectIMConnection()

        try await Self.waitUntil {
            await MainActor.run {
                let selectedConversation = secondManager.imConversationStore.selectedConversation
                return selectedConversation?.lastMessagePreview == "撤回了一条消息"
                    && selectedConversation?.serverLastReadSequence == 2
                    && selectedConversation?.unreadCount == 0
                    && selectedConversation?.messages.count == 2
                    && selectedConversation?.messages.last?.content == .recalled
            }
        }

        #expect(await requestCounter.count(for: "gapSync") > gapRequestsBeforeReconnect)
        #expect(secondManager.imConversationStore.selectedConversation?.localUnreadDelta == 0)
        #expect(secondManager.imConversationStore.selectedConversation?.messages.map(\.text) == [
            "历史中的旧消息",
            "撤回了一条消息"
        ])
    }

    @Test func backgroundRealtimeUnreadDeltaConvergesAfterCrossDeviceReadRecallAndGapSync() async throws {
        let harness = IMConnectionTestHarness()
        let requestCounter = IMRequestCounter()
        let selectedConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let backgroundConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!
        let backgroundHistoryMessageID = UUID(uuidString: "33333333-1111-2222-3333-aaaaaaaaaaaa")!
        let backgroundRealtimeMessageID = UUID(uuidString: "44444444-1111-2222-3333-aaaaaaaaaaaa")!
        let backgroundRecalledMessageID = UUID(uuidString: "55555555-1111-2222-3333-aaaaaaaaaaaa")!
        let peerUserID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

        let state = IMCrossDeviceConversationListState(
            conversations: [
                IMConversationSummaryResponseBody(
                    id: selectedConversationID,
                    title: "当前会话",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 1,
                    memberUserIDs: [Self.user.id],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: UUID(uuidString: "66666666-1111-2222-3333-aaaaaaaaaaaa")!,
                        senderUserID: Self.user.id,
                        serverSequence: 1,
                        kind: "text",
                        body: ["text": "当前会话消息"],
                        createdAt: Date(timeIntervalSince1970: 1_700_820_000)
                    ),
                    lastReadSequence: 1,
                    unreadCount: 0,
                    createdAt: Date(timeIntervalSince1970: 1_700_819_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_820_000)
                ),
                IMConversationSummaryResponseBody(
                    id: backgroundConversationID,
                    title: "后台会话",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 1,
                    memberUserIDs: [Self.user.id],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: backgroundHistoryMessageID,
                        senderUserID: peerUserID,
                        serverSequence: 1,
                        kind: "text",
                        body: ["text": "后台历史消息"],
                        createdAt: Date(timeIntervalSince1970: 1_700_820_100)
                    ),
                    lastReadSequence: 1,
                    unreadCount: 0,
                    createdAt: Date(timeIntervalSince1970: 1_700_819_100),
                    updatedAt: Date(timeIntervalSince1970: 1_700_820_100)
                )
            ],
            messagesByConversationID: [
                selectedConversationID: [
                    IMConversationMessageResponseBody(
                        id: UUID(uuidString: "66666666-1111-2222-3333-aaaaaaaaaaaa")!,
                        conversationID: selectedConversationID,
                        senderUserID: Self.user.id,
                        clientMessageID: nil,
                        serverSequence: 1,
                        kind: "text",
                        body: ["text": "当前会话消息"],
                        createdAt: Date(timeIntervalSince1970: 1_700_820_000)
                    )
                ],
                backgroundConversationID: [
                    IMConversationMessageResponseBody(
                        id: backgroundHistoryMessageID,
                        conversationID: backgroundConversationID,
                        senderUserID: peerUserID,
                        clientMessageID: nil,
                        serverSequence: 1,
                        kind: "text",
                        body: ["text": "后台历史消息"],
                        createdAt: Date(timeIntervalSince1970: 1_700_820_100)
                    )
                ]
            ]
        )

        let transport = MockHTTPTransport { request in
            let path = request.url?.path
            let query = request.url?.query
            switch (request.httpMethod, path, query) {
            case ("POST", "/api/auth/login", _):
                await requestCounter.increment("login")
                let loginIndex = await requestCounter.count(for: "login")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.authResponseBody(
                        user: Self.user,
                        accessToken: "access-background-\(loginIndex)",
                        refreshToken: "refresh-background-\(loginIndex)"
                    )
                )
            case ("GET", "/api/im/conversations", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.pageResponse())
                )
            case ("GET", "/api/im/conversations/changes", _):
                await requestCounter.increment("changes")
                let afterToken = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "afterToken" })?
                    .value
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.changesResponse(afterToken: afterToken))
                )
            case ("GET", let path?, _) where path.hasPrefix("/api/im/conversations/") && path.hasSuffix("/members"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", "/api/im/conversations/\(selectedConversationID.uuidString)/messages", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.messagesResponse(for: selectedConversationID))
                )
            case ("GET", "/api/im/conversations/\(backgroundConversationID.uuidString)/messages", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.messagesResponse(for: backgroundConversationID))
                )
            case ("GET", "/api/im/conversations/\(selectedConversationID.uuidString)/messages/since", _):
                await requestCounter.increment("gapSyncSelected")
                let afterSequence = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "afterSequence" })?
                    .value
                    .flatMap(UInt64.init)
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.messagesSinceResponse(for: selectedConversationID, afterSequence: afterSequence))
                )
            case ("GET", "/api/im/conversations/\(backgroundConversationID.uuidString)/messages/since", _):
                await requestCounter.increment("gapSyncBackground")
                let afterSequence = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "afterSequence" })?
                    .value
                    .flatMap(UInt64.init)
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.messagesSinceResponse(for: backgroundConversationID, afterSequence: afterSequence))
                )
            case ("POST", let path?, _) where path.hasPrefix("/api/im/conversations/") && path.hasSuffix("/read"):
                await requestCounter.increment("markRead")
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationReadBody(for: request))
            case ("GET", "/api/contacts", _):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests", _):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversationID == selectedConversationID.uuidString
                    && manager.imConnectionStatus == .connected
                    && manager.imConversationStore.conversations.count == 2
            }
        }

        await harness.yield(
            .message(
                requestID: UUID(uuidString: "77777777-1111-2222-3333-aaaaaaaaaaaa"),
                payload: IMTCPMessagePayload(
                    clientMessageID: nil,
                    messageID: backgroundRealtimeMessageID.uuidString,
                    conversationID: backgroundConversationID.uuidString,
                    senderUserID: peerUserID,
                    serverSequence: 2,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_820_200),
                    kind: "text",
                    body: ["text": "后台实时未读"]
                )
            )
        )

        try await Self.waitUntil {
            await MainActor.run {
                guard let backgroundConversation = manager.imConversationStore.conversations.first(where: {
                    $0.id == backgroundConversationID.uuidString
                }) else {
                    return false
                }

                return backgroundConversation.localUnreadDelta == 1
                    && backgroundConversation.unreadCount == 1
                    && manager.imConversationStore.totalUnreadCount == 1
            }
        }

        await state.appendMessage(
            IMConversationMessageResponseBody(
                id: backgroundRecalledMessageID,
                conversationID: backgroundConversationID,
                senderUserID: peerUserID,
                clientMessageID: nil,
                serverSequence: 3,
                kind: "text",
                body: ["text": "稍后被另一端撤回"],
                createdAt: Date(timeIntervalSince1970: 1_700_820_300)
            ),
            unreadCount: 2,
            lastReadSequence: 1
        )
        _ = await state.recallLatestMessage(
            in: backgroundConversationID,
            senderUserID: peerUserID
        )
        await state.updateReadState(
            for: backgroundConversationID,
            lastReadSequence: 3,
            unreadCount: 0
        )

        try await Task.sleep(for: .seconds(5.2))
        await manager.refreshIMConversationSummaryReadModelIfNeeded()

        #expect(await requestCounter.count(for: "changes") >= 1)
        #expect(manager.imConversationStore.selectedConversationID == selectedConversationID.uuidString)

        let backgroundAfterChanges = manager.imConversationStore.conversations.first {
            $0.id == backgroundConversationID.uuidString
        }
        #expect(backgroundAfterChanges?.lastMessagePreview == "撤回了一条消息")
        #expect(backgroundAfterChanges?.serverLastReadSequence == 3)
        #expect(backgroundAfterChanges?.serverUnreadCount == 0)
        #expect(backgroundAfterChanges?.localUnreadDelta == 0)
        #expect(backgroundAfterChanges?.unreadCount == 0)
        #expect(manager.imConversationStore.totalUnreadCount == 0)

        let gapRequestsBeforeReconnect = await requestCounter.count(for: "gapSyncBackground")
        await manager.reconnectIMConnection()

        try await Self.waitUntil {
            await MainActor.run {
                guard let backgroundConversation = manager.imConversationStore.conversations.first(where: {
                    $0.id == backgroundConversationID.uuidString
                }) else {
                    return false
                }

                return backgroundConversation.lastMessagePreview == "撤回了一条消息"
                    && backgroundConversation.serverLastReadSequence == 3
                    && backgroundConversation.localUnreadDelta == 0
                    && backgroundConversation.unreadCount == 0
                    && backgroundConversation.messages.last?.content == .recalled
                    && backgroundConversation.messages.map(\.text) == [
                        "后台实时未读",
                        "撤回了一条消息"
                    ]
            }
        }

        #expect(await requestCounter.count(for: "gapSyncBackground") > gapRequestsBeforeReconnect)
        #expect(manager.imConversationStore.selectedConversationID == selectedConversationID.uuidString)
        #expect(manager.imConversationStore.totalUnreadCount == 0)
    }

    @Test func backgroundReplyReferenceConvergesAfterCrossDeviceRecallReadAndGapSync() async throws {
        let harness = IMConnectionTestHarness()
        let requestCounter = IMRequestCounter()
        let selectedConversationID = UUID(uuidString: "aaaaaaaa-2222-3333-4444-bbbbbbbbbbbb")!
        let backgroundConversationID = UUID(uuidString: "bbbbbbbb-2222-3333-4444-cccccccccccc")!
        let selectedMessageID = UUID(uuidString: "11111111-2222-3333-4444-aaaaaaaaaaaa")!
        let backgroundBaselineMessageID = UUID(uuidString: "22222222-2222-3333-4444-aaaaaaaaaaaa")!
        let backgroundTargetMessageID = UUID(uuidString: "33333333-2222-3333-4444-aaaaaaaaaaaa")!
        let backgroundReplyMessageID = UUID(uuidString: "44444444-2222-3333-4444-aaaaaaaaaaaa")!
        let peerUserID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

        let state = IMCrossDeviceConversationListState(
            conversations: [
                IMConversationSummaryResponseBody(
                    id: selectedConversationID,
                    title: "当前会话",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 1,
                    memberUserIDs: [Self.user.id],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: selectedMessageID,
                        senderUserID: Self.user.id,
                        serverSequence: 1,
                        content: .text("当前会话消息"),
                        createdAt: Date(timeIntervalSince1970: 1_700_830_000)
                    ),
                    lastReadSequence: 1,
                    unreadCount: 0,
                    createdAt: Date(timeIntervalSince1970: 1_700_829_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_830_000)
                ),
                IMConversationSummaryResponseBody(
                    id: backgroundConversationID,
                    title: "后台引用会话",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 1,
                    memberUserIDs: [Self.user.id],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: backgroundBaselineMessageID,
                        senderUserID: peerUserID,
                        serverSequence: 1,
                        content: .text("后台已加载基线"),
                        createdAt: Date(timeIntervalSince1970: 1_700_830_100)
                    ),
                    lastReadSequence: 1,
                    unreadCount: 0,
                    createdAt: Date(timeIntervalSince1970: 1_700_829_100),
                    updatedAt: Date(timeIntervalSince1970: 1_700_830_100)
                )
            ],
            messagesByConversationID: [
                selectedConversationID: [
                    IMConversationMessageResponseBody(
                        id: selectedMessageID,
                        conversationID: selectedConversationID,
                        senderUserID: Self.user.id,
                        clientMessageID: nil,
                        serverSequence: 1,
                        content: .text("当前会话消息"),
                        createdAt: Date(timeIntervalSince1970: 1_700_830_000)
                    )
                ],
                backgroundConversationID: [
                    IMConversationMessageResponseBody(
                        id: backgroundBaselineMessageID,
                        conversationID: backgroundConversationID,
                        senderUserID: peerUserID,
                        clientMessageID: nil,
                        serverSequence: 1,
                        content: .text("后台已加载基线"),
                        createdAt: Date(timeIntervalSince1970: 1_700_830_100)
                    )
                ]
            ]
        )

        let transport = MockHTTPTransport { request in
            let path = request.url?.path
            let query = request.url?.query
            switch (request.httpMethod, path, query) {
            case ("POST", "/api/auth/login", _):
                await requestCounter.increment("login")
                let loginIndex = await requestCounter.count(for: "login")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.authResponseBody(
                        user: Self.user,
                        accessToken: "access-background-reply-\(loginIndex)",
                        refreshToken: "refresh-background-reply-\(loginIndex)"
                    )
                )
            case ("GET", "/api/im/conversations", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.pageResponse())
                )
            case ("GET", "/api/im/conversations/changes", _):
                await requestCounter.increment("changes")
                let afterToken = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "afterToken" })?
                    .value
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.changesResponse(afterToken: afterToken))
                )
            case ("GET", let path?, _) where path.hasPrefix("/api/im/conversations/") && path.hasSuffix("/members"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", "/api/im/conversations/\(selectedConversationID.uuidString)/messages", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.messagesResponse(for: selectedConversationID))
                )
            case ("GET", "/api/im/conversations/\(backgroundConversationID.uuidString)/messages", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.messagesResponse(for: backgroundConversationID))
                )
            case ("GET", "/api/im/conversations/\(selectedConversationID.uuidString)/messages/since", _):
                await requestCounter.increment("gapSyncSelected")
                let afterSequence = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "afterSequence" })?
                    .value
                    .flatMap(UInt64.init)
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.messagesSinceResponse(for: selectedConversationID, afterSequence: afterSequence))
                )
            case ("GET", "/api/im/conversations/\(backgroundConversationID.uuidString)/messages/since", _):
                await requestCounter.increment("gapSyncBackground")
                let afterSequence = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "afterSequence" })?
                    .value
                    .flatMap(UInt64.init)
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.messagesSinceResponse(for: backgroundConversationID, afterSequence: afterSequence))
                )
            case ("POST", let path?, _) where path.hasPrefix("/api/im/conversations/") && path.hasSuffix("/read"):
                await requestCounter.increment("markRead")
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationReadBody(for: request))
            case ("GET", "/api/contacts", _):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests", _):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversationID == selectedConversationID.uuidString
                    && manager.imConnectionStatus == .connected
                    && manager.imConversationStore.conversations.count == 2
            }
        }

        await MainActor.run {
            manager.imConversationStore.replaceMessages(
                in: backgroundConversationID.uuidString,
                messages: [
                    IMConversationMessageResponseBody(
                        id: backgroundBaselineMessageID,
                        conversationID: backgroundConversationID,
                        senderUserID: peerUserID,
                        clientMessageID: nil,
                        serverSequence: 1,
                        content: .text("后台已加载基线"),
                        createdAt: Date(timeIntervalSince1970: 1_700_830_100)
                    )
                ],
                currentUserID: Self.user.id
            )
        }

        #expect(manager.imConversationStore.selectedConversationID == selectedConversationID.uuidString)
        #expect(manager.imConversationStore.conversations.first(where: {
            $0.id == backgroundConversationID.uuidString
        })?.messages.map(\.text) == ["后台已加载基线"])

        await state.appendMessage(
            IMConversationMessageResponseBody(
                id: backgroundTargetMessageID,
                conversationID: backgroundConversationID,
                senderUserID: peerUserID,
                clientMessageID: nil,
                serverSequence: 2,
                content: .text("稍后会被撤回的引用目标"),
                createdAt: Date(timeIntervalSince1970: 1_700_830_200)
            ),
            unreadCount: 1,
            lastReadSequence: 1
        )
        await state.appendMessage(
            IMConversationMessageResponseBody(
                id: backgroundReplyMessageID,
                conversationID: backgroundConversationID,
                senderUserID: peerUserID,
                clientMessageID: nil,
                serverSequence: 3,
                content: .reply(
                    reference: IMReplyReference(
                        messageID: backgroundTargetMessageID.uuidString,
                        senderUserID: peerUserID,
                        previewText: "稍后会被撤回的引用目标"
                    ),
                    text: "后台 reply 正文"
                ),
                createdAt: Date(timeIntervalSince1970: 1_700_830_300)
            ),
            unreadCount: 2,
            lastReadSequence: 1
        )
        _ = await state.recallMessage(
            id: backgroundTargetMessageID,
            in: backgroundConversationID,
            senderUserID: peerUserID
        )
        await state.updateReadState(
            for: backgroundConversationID,
            lastReadSequence: 3,
            unreadCount: 0
        )

        try await Task.sleep(for: .seconds(5.2))
        await manager.refreshIMConversationSummaryReadModelIfNeeded()

        #expect(await requestCounter.count(for: "changes") >= 1)
        let backgroundAfterChanges = try #require(
            manager.imConversationStore.conversations.first(where: {
                $0.id == backgroundConversationID.uuidString
            })
        )
        #expect(backgroundAfterChanges.lastMessagePreview == "后台 reply 正文")
        #expect(backgroundAfterChanges.serverLastReadSequence == 3)
        #expect(backgroundAfterChanges.unreadCount == 0)
        #expect(backgroundAfterChanges.localUnreadDelta == 0)
        #expect(backgroundAfterChanges.messages.map(\.text) == ["后台已加载基线"])

        let gapRequestsBeforeReconnect = await requestCounter.count(for: "gapSyncBackground")
        await manager.reconnectIMConnection()

        try await Self.waitUntil {
            await MainActor.run {
                guard let backgroundConversation = manager.imConversationStore.conversations.first(where: {
                    $0.id == backgroundConversationID.uuidString
                }) else {
                    return false
                }

                guard let replyMessage = backgroundConversation.messages.last else {
                    return false
                }

                return manager.imConversationStore.selectedConversationID == selectedConversationID.uuidString
                    && backgroundConversation.serverLastReadSequence == 3
                    && backgroundConversation.unreadCount == 0
                    && backgroundConversation.localUnreadDelta == 0
                    && backgroundConversation.messages.count == 3
                    && replyMessage.resolvedReplyReference(in: backgroundConversation.messages) == IMReplyReferenceResolution(
                        state: .recalled,
                        text: "原消息已撤回"
                    )
            }
        }

        let backgroundAfterGapSync = try #require(
            manager.imConversationStore.conversations.first(where: {
                $0.id == backgroundConversationID.uuidString
            })
        )
        let replyAfterGapSync = try #require(backgroundAfterGapSync.messages.last)
        #expect(await requestCounter.count(for: "gapSyncBackground") > gapRequestsBeforeReconnect)
        #expect(backgroundAfterGapSync.messages.map(\.text) == [
            "后台已加载基线",
            "撤回了一条消息",
            "后台 reply 正文"
        ])
        #expect(backgroundAfterGapSync.lastMessagePreview == "后台 reply 正文")
        #expect(replyAfterGapSync.resolvedReplyReference(in: backgroundAfterGapSync.messages) == IMReplyReferenceResolution(
            state: .recalled,
            text: "原消息已撤回"
        ))
        #expect(manager.imConversationStore.selectedConversationID == selectedConversationID.uuidString)
        #expect(manager.imConversationStore.totalUnreadCount == 0)
    }

    @Test func backgroundReplyReferenceLoadsOlderPagesAfterOpenThenStaysConsistentThroughChangesAndGapSync() async throws {
        let harness = IMConnectionTestHarness()
        let requestCounter = IMRequestCounter()
        let selectedConversationID = UUID(uuidString: "aaaaaaaa-3333-4444-5555-bbbbbbbbbbbb")!
        let backgroundConversationID = UUID(uuidString: "bbbbbbbb-3333-4444-5555-cccccccccccc")!
        let selectedMessageID = UUID(uuidString: "11111111-3333-4444-5555-aaaaaaaaaaaa")!
        let backgroundReplyMessageID = UUID(uuidString: "22222222-3333-4444-5555-aaaaaaaaaaaa")!
        let backgroundIntermediateMessageID = UUID(uuidString: "33333333-3333-4444-5555-aaaaaaaaaaaa")!
        let backgroundTargetMessageID = UUID(uuidString: "44444444-3333-4444-5555-aaaaaaaaaaaa")!
        let backgroundGapMessageID = UUID(uuidString: "55555555-3333-4444-5555-aaaaaaaaaaaa")!
        let peerUserID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let cache = InMemoryIMConversationCache()

        await cache.seed(
            IMConversationCacheSnapshot(
                conversations: [
                    IMCachedConversationState(
                        id: selectedConversationID.uuidString,
                        title: "当前会话",
                        kind: .group,
                        memberCount: 1,
                        memberUserIDs: [Self.user.id],
                        messages: [
                            IMCachedMessageState(
                                id: selectedMessageID.uuidString,
                                conversationID: selectedConversationID.uuidString,
                                clientMessageID: nil,
                                serverMessageID: selectedMessageID.uuidString,
                                senderUserID: Self.user.id,
                                serverSequence: 1,
                                content: .text("当前会话消息"),
                                direction: .outgoing,
                                createdAt: Date(timeIntervalSince1970: 1_700_840_000),
                                deliveryState: .sent
                            )
                        ],
                        hasLoadedMessages: true,
                        lastMessagePreviewText: "当前会话消息",
                        hasMoreHistory: false,
                        latestSyncedServerSequence: 1,
                        oldestLoadedServerSequence: 1,
                        serverLastReadSequence: 1,
                        serverUnreadCount: 0,
                        updatedAt: Date(timeIntervalSince1970: 1_700_840_000)
                    ),
                    IMCachedConversationState(
                        id: backgroundConversationID.uuidString,
                        title: "后台补页引用会话",
                        kind: .group,
                        memberCount: 1,
                        memberUserIDs: [Self.user.id],
                        messages: [
                            IMCachedMessageState(
                                id: backgroundReplyMessageID.uuidString,
                                conversationID: backgroundConversationID.uuidString,
                                clientMessageID: nil,
                                serverMessageID: backgroundReplyMessageID.uuidString,
                                senderUserID: peerUserID,
                                serverSequence: 4,
                                content: .reply(
                                    reference: IMReplyReference(
                                        messageID: backgroundTargetMessageID.uuidString,
                                        senderUserID: peerUserID,
                                        previewText: "稍后会被撤回的引用目标"
                                    ),
                                    text: "缓存里的 reply"
                                ),
                                direction: .incoming,
                                createdAt: Date(timeIntervalSince1970: 1_700_840_400),
                                deliveryState: .received
                            )
                        ],
                        hasLoadedMessages: true,
                        lastMessagePreviewText: "缓存里的 reply",
                        hasMoreHistory: true,
                        latestSyncedServerSequence: 4,
                        oldestLoadedServerSequence: 4,
                        serverLastReadSequence: 3,
                        serverUnreadCount: 1,
                        updatedAt: Date(timeIntervalSince1970: 1_700_840_400)
                    )
                ],
                selectedConversationID: selectedConversationID.uuidString,
                lastSummaryRefreshAt: nil
            ),
            for: Self.user.id
        )

        let state = IMCrossDeviceConversationListState(
            conversations: [
                IMConversationSummaryResponseBody(
                    id: selectedConversationID,
                    title: "当前会话",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 1,
                    memberUserIDs: [Self.user.id],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: selectedMessageID,
                        senderUserID: Self.user.id,
                        serverSequence: 1,
                        content: .text("当前会话消息"),
                        createdAt: Date(timeIntervalSince1970: 1_700_840_000)
                    ),
                    lastReadSequence: 1,
                    unreadCount: 0,
                    createdAt: Date(timeIntervalSince1970: 1_700_839_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_840_000)
                ),
                IMConversationSummaryResponseBody(
                    id: backgroundConversationID,
                    title: "后台补页引用会话",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 1,
                    memberUserIDs: [Self.user.id],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: backgroundReplyMessageID,
                        senderUserID: peerUserID,
                        serverSequence: 4,
                        content: .reply(
                            reference: IMReplyReference(
                                messageID: backgroundTargetMessageID.uuidString,
                                senderUserID: peerUserID,
                                previewText: "稍后会被撤回的引用目标"
                            ),
                            text: "缓存里的 reply"
                        ),
                        createdAt: Date(timeIntervalSince1970: 1_700_840_400)
                    ),
                    lastReadSequence: 3,
                    unreadCount: 1,
                    createdAt: Date(timeIntervalSince1970: 1_700_839_100),
                    updatedAt: Date(timeIntervalSince1970: 1_700_840_400)
                )
            ],
            messagesByConversationID: [
                selectedConversationID: [
                    IMConversationMessageResponseBody(
                        id: selectedMessageID,
                        conversationID: selectedConversationID,
                        senderUserID: Self.user.id,
                        clientMessageID: nil,
                        serverSequence: 1,
                        content: .text("当前会话消息"),
                        createdAt: Date(timeIntervalSince1970: 1_700_840_000)
                    )
                ],
                backgroundConversationID: [
                    IMConversationMessageResponseBody(
                        id: backgroundTargetMessageID,
                        conversationID: backgroundConversationID,
                        senderUserID: peerUserID,
                        clientMessageID: nil,
                        serverSequence: 2,
                        content: .text("稍后会被撤回的引用目标"),
                        createdAt: Date(timeIntervalSince1970: 1_700_840_200)
                    ),
                    IMConversationMessageResponseBody(
                        id: backgroundIntermediateMessageID,
                        conversationID: backgroundConversationID,
                        senderUserID: peerUserID,
                        clientMessageID: nil,
                        serverSequence: 3,
                        content: .text("中间历史消息"),
                        createdAt: Date(timeIntervalSince1970: 1_700_840_300)
                    ),
                    IMConversationMessageResponseBody(
                        id: backgroundReplyMessageID,
                        conversationID: backgroundConversationID,
                        senderUserID: peerUserID,
                        clientMessageID: nil,
                        serverSequence: 4,
                        content: .reply(
                            reference: IMReplyReference(
                                messageID: backgroundTargetMessageID.uuidString,
                                senderUserID: peerUserID,
                                previewText: "稍后会被撤回的引用目标"
                            ),
                            text: "缓存里的 reply"
                        ),
                        createdAt: Date(timeIntervalSince1970: 1_700_840_400)
                    )
                ]
            ]
        )

        let transport = MockHTTPTransport { request in
            let path = request.url?.path
            let components = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)
            let queryItems = components?.queryItems ?? []
            let beforeSequence = queryItems.first(where: { $0.name == "beforeSequence" })?.value.flatMap(UInt64.init)
            let afterToken = queryItems.first(where: { $0.name == "afterToken" })?.value
            let afterSequence = queryItems.first(where: { $0.name == "afterSequence" })?.value.flatMap(UInt64.init)

            switch (request.httpMethod, path) {
            case ("POST", "/api/auth/login"):
                await requestCounter.increment("login")
                let loginIndex = await requestCounter.count(for: "login")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.authResponseBody(
                        user: Self.user,
                        accessToken: "access-background-open-\(loginIndex)",
                        refreshToken: "refresh-background-open-\(loginIndex)"
                    )
                )
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.pageResponse())
                )
            case ("GET", "/api/im/conversations/changes"):
                await requestCounter.increment("changes")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.changesResponse(afterToken: afterToken))
                )
            case ("GET", let path?) where path.hasPrefix("/api/im/conversations/") && path.hasSuffix("/members"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", "/api/im/conversations/\(selectedConversationID.uuidString)/messages"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.messagesResponse(for: selectedConversationID))
                )
            case ("GET", "/api/im/conversations/\(backgroundConversationID.uuidString)/messages"):
                switch beforeSequence {
                case nil:
                    await requestCounter.increment("messagesBackgroundUnexpected")
                    return HTTPFixtures.response(
                        statusCode: 200,
                        body: try HTTPFixtures.jsonBody(await state.messagesResponse(for: backgroundConversationID))
                    )
                case 4:
                    await requestCounter.increment("loadOlderBackground")
                    return HTTPFixtures.response(
                        statusCode: 200,
                        body: try HTTPFixtures.jsonBody([
                            IMConversationMessageResponseBody(
                                id: backgroundIntermediateMessageID,
                                conversationID: backgroundConversationID,
                                senderUserID: peerUserID,
                                clientMessageID: nil,
                                serverSequence: 3,
                                content: .text("中间历史消息"),
                                createdAt: Date(timeIntervalSince1970: 1_700_840_300)
                            )
                        ])
                    )
                case 3:
                    await requestCounter.increment("loadOlderBackground")
                    return HTTPFixtures.response(
                        statusCode: 200,
                        body: try HTTPFixtures.jsonBody([
                            IMConversationMessageResponseBody(
                                id: backgroundTargetMessageID,
                                conversationID: backgroundConversationID,
                                senderUserID: peerUserID,
                                clientMessageID: nil,
                                serverSequence: 2,
                                content: .recalled,
                                createdAt: Date(timeIntervalSince1970: 1_700_840_200)
                            )
                        ])
                    )
                default:
                    Issue.record("收到未预期的历史补页 beforeSequence：\(beforeSequence.map(String.init) ?? "nil")")
                    return HTTPFixtures.response(statusCode: 500)
                }
            case ("GET", "/api/im/conversations/\(selectedConversationID.uuidString)/messages/since"):
                await requestCounter.increment("gapSyncSelected")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.messagesSinceResponse(for: selectedConversationID, afterSequence: afterSequence))
                )
            case ("GET", "/api/im/conversations/\(backgroundConversationID.uuidString)/messages/since"):
                await requestCounter.increment("gapSyncBackground")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(await state.messagesSinceResponse(for: backgroundConversationID, afterSequence: afterSequence))
                )
            case ("POST", let path?) where path.hasPrefix("/api/im/conversations/") && path.hasSuffix("/read"):
                await requestCounter.increment("markRead")
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationReadBody(for: request))
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            imConversationCache: IMConversationCacheHandler(cache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversationID == selectedConversationID.uuidString
                    && manager.imConnectionStatus == .connected
                    && manager.imConversationStore.conversations.count == 2
                    && manager.imConversationStore.conversations.first(where: {
                        $0.id == backgroundConversationID.uuidString
                    })?.messages.count == 1
            }
        }

        let backgroundBeforeRefresh = try #require(
            manager.imConversationStore.conversations.first(where: {
                $0.id == backgroundConversationID.uuidString
            })
        )
        let cachedReply = try #require(backgroundBeforeRefresh.messages.last)
        #expect(cachedReply.resolvedReplyReference(in: backgroundBeforeRefresh.messages) == IMReplyReferenceResolution(
            state: .unavailable,
            text: "稍后会被撤回的引用目标"
        ))

        _ = await state.recallMessage(
            id: backgroundTargetMessageID,
            in: backgroundConversationID,
            senderUserID: peerUserID
        )
        await state.updateReadState(
            for: backgroundConversationID,
            lastReadSequence: 4,
            unreadCount: 0
        )

        try await Task.sleep(for: .seconds(5.2))
        await manager.refreshIMConversationSummaryReadModelIfNeeded()

        let backgroundAfterChanges = try #require(
            manager.imConversationStore.conversations.first(where: {
                $0.id == backgroundConversationID.uuidString
            })
        )
        let replyAfterChanges = try #require(backgroundAfterChanges.messages.last)
        #expect(await requestCounter.count(for: "changes") >= 1)
        #expect(backgroundAfterChanges.serverLastReadSequence == 4)
        #expect(backgroundAfterChanges.unreadCount == 0)
        #expect(backgroundAfterChanges.localUnreadDelta == 0)
        #expect(replyAfterChanges.resolvedReplyReference(in: backgroundAfterChanges.messages) == IMReplyReferenceResolution(
            state: .unavailable,
            text: "稍后会被撤回的引用目标"
        ))

        await manager.openIMConversation(backgroundConversationID.uuidString)
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversationID == backgroundConversationID.uuidString
            }
        }

        await manager.loadOlderIMMessages()
        try await Self.waitUntil {
            await MainActor.run {
                let selectedConversation = manager.imConversationStore.selectedConversation
                return selectedConversation?.messages.map(\.text) == [
                    "中间历史消息",
                    "缓存里的 reply"
                ]
            }
        }

        let afterFirstPage = try #require(manager.imConversationStore.selectedConversation)
        let replyAfterFirstPage = try #require(afterFirstPage.messages.last)
        #expect(replyAfterFirstPage.resolvedReplyReference(in: afterFirstPage.messages) == IMReplyReferenceResolution(
            state: .unavailable,
            text: "稍后会被撤回的引用目标"
        ))

        await manager.loadOlderIMMessages()
        try await Self.waitUntil {
            await MainActor.run {
                let selectedConversation = manager.imConversationStore.selectedConversation
                guard let replyMessage = selectedConversation?.messages.last else {
                    return false
                }

                return selectedConversation?.messages.map(\.text) == [
                    "撤回了一条消息",
                    "中间历史消息",
                    "缓存里的 reply"
                ] && replyMessage.resolvedReplyReference(in: selectedConversation?.messages ?? []) == IMReplyReferenceResolution(
                    state: .recalled,
                    text: "原消息已撤回"
                )
            }
        }

        await state.appendMessage(
            IMConversationMessageResponseBody(
                id: backgroundGapMessageID,
                conversationID: backgroundConversationID,
                senderUserID: peerUserID,
                clientMessageID: nil,
                serverSequence: 5,
                content: .text("重连后补进的新消息"),
                createdAt: Date(timeIntervalSince1970: 1_700_840_500)
            ),
            unreadCount: 0,
            lastReadSequence: 5
        )

        try await Task.sleep(for: .seconds(5.2))
        let gapRequestsBeforeReconnect = await requestCounter.count(for: "gapSyncBackground")
        await manager.reconnectIMConnection()

        try await Self.waitUntil {
            await MainActor.run {
                guard let selectedConversation = manager.imConversationStore.selectedConversation,
                      let replyMessage = selectedConversation.messages.dropLast().last
                else {
                    return false
                }

                return manager.imConversationStore.selectedConversationID == backgroundConversationID.uuidString
                    && selectedConversation.serverLastReadSequence == 5
                    && selectedConversation.unreadCount == 0
                    && selectedConversation.localUnreadDelta == 0
                    && selectedConversation.messages.map(\.text) == [
                        "撤回了一条消息",
                        "中间历史消息",
                        "缓存里的 reply",
                        "重连后补进的新消息"
                    ]
                    && replyMessage.resolvedReplyReference(in: selectedConversation.messages) == IMReplyReferenceResolution(
                        state: .recalled,
                        text: "原消息已撤回"
                    )
            }
        }

        #expect(await requestCounter.count(for: "loadOlderBackground") == 2)
        #expect(await requestCounter.count(for: "gapSyncBackground") > gapRequestsBeforeReconnect)
        #expect(await requestCounter.count(for: "messagesBackgroundUnexpected") == 0)
    }

    @Test func addIMConversationMembersRefreshesSummaryAndMembers() async throws {
        let mutationState = IMConversationMutationState()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                let summary = IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "服务端群聊",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: await mutationState.isMutated() ? 3 : 2,
                    memberUserIDs: [Self.user.id],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_001_000)
                )
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody([summary])
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members"):
                let members = await mutationState.isMutated()
                    ? [
                        IMConversationMemberResponseBody(id: Self.user.id, email: Self.user.email),
                        IMConversationMemberResponseBody(
                            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                            email: "peer@example.com"
                        ),
                        IMConversationMemberResponseBody(
                            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                            email: "new@example.com"
                        )
                    ]
                    : [
                        IMConversationMemberResponseBody(id: Self.user.id, email: Self.user.email),
                        IMConversationMemberResponseBody(
                            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                            email: "peer@example.com"
                        )
                    ]
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(members)
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesBody())
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/members"):
                let payload = try JSONDecoder().decode(
                    IMConversationMemberUpdateRequestBody.self,
                    from: request.httpBody ?? Data()
                )
                #expect(payload.memberEmails == ["new@example.com"])
                await mutationState.markMutated()
                let updatedSummary = IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "服务端群聊",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 3,
                    memberUserIDs: [Self.user.id],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_001_100)
                )
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(updatedSummary)
                )
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.id == conversationID.uuidString
                    && manager.imConversationStore.selectedConversation?.memberCount == 2
                    && manager.imConversationStore.selectedConversation?.members.count == 2
            }
        }

        let didAdd = await manager.addIMConversationMembers(
            to: conversationID.uuidString,
            memberEmails: ["  NEW@example.com  ", "new@example.com"]
        )

        #expect(didAdd)
        #expect(manager.imConversationStore.selectedConversation?.kind == .group)
        #expect(manager.imConversationStore.selectedConversation?.memberCount == 3)
        #expect(manager.imConversationStore.selectedConversation?.members.map(\.email) == [
            "manager@example.com",
            "peer@example.com",
            "new@example.com"
        ])
    }

    @Test func leaveIMConversationRemovesCurrentConversationAndFallsBackToListSelection() async throws {
        let mutationState = IMConversationMutationState()
        let currentConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let fallbackConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                let summaries = await mutationState.isMutated()
                    ? [
                        IMConversationSummaryResponseBody(
                            id: fallbackConversationID,
                            title: "剩余会话",
                            kind: IMConversationKind.direct.rawValue,
                            memberCount: 2,
                            memberUserIDs: [Self.user.id],
                            lastMessage: nil,
                            createdAt: Date(timeIntervalSince1970: 1_700_000_100),
                            updatedAt: Date(timeIntervalSince1970: 1_700_000_200)
                        )
                    ]
                    : [
                        IMConversationSummaryResponseBody(
                            id: currentConversationID,
                            title: "当前群聊",
                            kind: IMConversationKind.group.rawValue,
                            memberCount: 3,
                            memberUserIDs: [Self.user.id],
                            lastMessage: nil,
                            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                            updatedAt: Date(timeIntervalSince1970: 1_700_001_000)
                        ),
                        IMConversationSummaryResponseBody(
                            id: fallbackConversationID,
                            title: "剩余会话",
                            kind: IMConversationKind.direct.rawValue,
                            memberCount: 2,
                            memberUserIDs: [Self.user.id],
                            lastMessage: nil,
                            createdAt: Date(timeIntervalSince1970: 1_700_000_100),
                            updatedAt: Date(timeIntervalSince1970: 1_700_000_200)
                        )
                    ]
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(summaries)
                )
            case ("GET", "/api/im/conversations/\(currentConversationID.uuidString)/members"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", "/api/im/conversations/\(currentConversationID.uuidString)/messages"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesBody())
            case ("POST", "/api/im/conversations/\(currentConversationID.uuidString)/leave"):
                await mutationState.markMutated()
                return HTTPFixtures.response(statusCode: 200, body: Data())
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversationID == currentConversationID.uuidString
                    && manager.imConversationStore.conversations.count == 2
            }
        }

        let didLeave = await manager.leaveIMConversation(currentConversationID.uuidString)

        #expect(didLeave)
        #expect(manager.imConversationStore.conversations.count == 1)
        #expect(manager.imConversationStore.conversations.first?.id == fallbackConversationID.uuidString)
        #expect(manager.imConversationStore.selectedConversationID == fallbackConversationID.uuidString)
    }

    @Test func conversationRemovedForSelfEventRemovesCurrentSelectionWithoutSummaryRefresh() async throws {
        let harness = IMConnectionTestHarness()
        let requestCounter = IMRequestCounter()
        let currentConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let fallbackConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path, request.url?.query) {
            case ("POST", "/api/auth/login", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations", _):
                await requestCounter.increment("conversations")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        [
                            IMConversationSummaryResponseBody(
                                id: currentConversationID,
                                title: "Current",
                                memberUserIDs: [Self.user.id],
                                lastMessage: nil,
                                createdAt: Date(timeIntervalSince1970: 1_700_200_001),
                                updatedAt: Date(timeIntervalSince1970: 1_700_300_001)
                            ),
                            IMConversationSummaryResponseBody(
                                id: fallbackConversationID,
                                title: "Fallback",
                                memberUserIDs: [Self.user.id],
                                lastMessage: nil,
                                createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                                updatedAt: Date(timeIntervalSince1970: 1_700_300_000)
                            )
                        ]
                    )
                )
            case ("GET", "/api/im/conversations/\(currentConversationID.uuidString)/members", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationMembersBody())
            case ("GET", "/api/im/conversations/\(currentConversationID.uuidString)/messages", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesBody(conversationID: currentConversationID)
                )
            case ("POST", "/api/im/conversations/\(currentConversationID.uuidString)/read", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(for: request)
                )
            case ("GET", "/api/im/conversations/\(currentConversationID.uuidString)/messages/since", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversationID == currentConversationID.uuidString
                    && manager.imConnectionStatus == .connected
            }
        }

        let initialConversationRequests = await requestCounter.count(for: "conversations")
        await harness.yield(
            .conversationEvent(
                requestID: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
                payload: IMTCPConversationEventPayload(
                    eventType: .conversationRemovedForSelf,
                    conversation: IMConversationSummaryResponseBody(
                        id: currentConversationID,
                        title: "Current",
                        memberUserIDs: [Self.user.id],
                        lastMessage: nil,
                        createdAt: Date(timeIntervalSince1970: 1_700_200_001),
                        updatedAt: Date(timeIntervalSince1970: 1_700_300_001)
                    ),
                    actorUserID: Self.user.id,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_400_000)
                )
            )
        )

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversationID == fallbackConversationID.uuidString
                    && manager.imConversationStore.conversations.count == 1
            }
        }

        #expect(await requestCounter.count(for: "conversations") == initialConversationRequests)
        #expect(manager.imConversationStore.conversations.first?.id == fallbackConversationID.uuidString)
    }

    @Test func reconnectIMConnectionSyncsConversationGap() async throws {
        let harness = IMConnectionTestHarness()
        let gapCounter = IMGapSyncCounter()
        let summarySequenceState = IMSummarySequenceState()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path, request.url?.query) {
            case ("POST", "/api/auth/login", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(
                        conversationID: conversationID,
                        latestServerSequence: await summarySequenceState.currentLatestServerSequence()
                    )
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationMembersBody()
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesBody(conversationID: conversationID)
                )
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(for: request)
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since", "afterSequence=1&limit=100"):
                await gapCounter.increment()
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesSinceBody(conversationID: conversationID)
                )
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        await summarySequenceState.setLatestServerSequence(1)
        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.count == 1
                    && manager.imConnectionStatus == .connected
            }
        }

        await summarySequenceState.setLatestServerSequence(2)
        await manager.reconnectIMConnection()
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.count == 2
                    && manager.imConversationStore.selectedConversation?.messages.last?.text == "来自补洞接口"
                    && manager.imConnectionStatus == .connected
            }
        }

        #expect(await gapCounter.currentValue() >= 1)
    }

    @Test func openIMConversationSyncsGapForLoadedConversation() async throws {
        let harness = IMConnectionTestHarness()
        let gapCounter = IMGapSyncCounter()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path, request.url?.query) {
            case ("POST", "/api/auth/login", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(conversationID: conversationID)
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationMembersBody()
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesBody(conversationID: conversationID)
                )
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(for: request)
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since", "afterSequence=1&limit=100"):
                await gapCounter.increment()
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesSinceBody(conversationID: conversationID)
                )
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.count == 1
            }
        }

        await manager.openIMConversation(conversationID.uuidString)
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.count == 2
                    && manager.imConversationStore.selectedConversation?.messages.last?.text == "来自补洞接口"
            }
        }

        #expect(await gapCounter.currentValue() >= 1)
    }

    @Test func gapSyncFailureDoesNotClearLoadedMessages() async throws {
        let harness = IMConnectionTestHarness()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path, request.url?.query) {
            case ("POST", "/api/auth/login", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(conversationID: conversationID)
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationMembersBody()
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesBody(conversationID: conversationID)
                )
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(for: request)
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since", "afterSequence=1&limit=100"):
                throw URLError(.timedOut)
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.count == 1
            }
        }

        await manager.openIMConversation(conversationID.uuidString)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(manager.phase == .signedIn(Self.user))
        #expect(manager.currentUser?.id == Self.user.id)
        #expect(manager.imConversationStore.selectedConversation?.messages.count == 1)
        #expect(manager.imConversationStore.selectedConversation?.messages.first?.text == "来自历史接口")
        #expect(manager.imConversationStore.statusMessage == "请求超时，请稍后重试。")
        #expect(manager.serverStatus == .offline(message: "请求超时，请稍后重试。"))
    }

    @Test func reconnectIMConnectionLoopsGapSyncUntilFullyCaughtUp() async throws {
        let harness = IMConnectionTestHarness()
        let gapCounter = IMGapSyncCounter()
        let summarySequenceState = IMSummarySequenceState()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path, request.url?.query) {
            case ("POST", "/api/auth/login", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(
                        conversationID: conversationID,
                        latestServerSequence: await summarySequenceState.currentLatestServerSequence()
                    )
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationMembersBody()
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesBody(conversationID: conversationID)
                )
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(for: request)
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since", "afterSequence=1&limit=100"):
                await gapCounter.increment()
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesSincePageBody(
                        conversationID: conversationID,
                        messages: [
                            IMConversationMessageResponseBody(
                                id: UUID(uuidString: "ffffffff-1111-2222-3333-eeeeeeeeeeee")!,
                                conversationID: conversationID,
                                senderUserID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                                clientMessageID: "client-gap-2",
                                serverSequence: 2,
                                kind: "text",
                                body: ["text": "gap-2"],
                                createdAt: Date(timeIntervalSince1970: 1_700_001_100)
                            )
                        ],
                        hasMore: true,
                        nextAfterSequence: 2
                    )
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since", "afterSequence=2&limit=100"):
                await gapCounter.increment()
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesSincePageBody(
                        conversationID: conversationID,
                        messages: [
                            IMConversationMessageResponseBody(
                                id: UUID(uuidString: "aaaaaaaa-9999-2222-3333-eeeeeeeeeeee")!,
                                conversationID: conversationID,
                                senderUserID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                                clientMessageID: "client-gap-3",
                                serverSequence: 3,
                                kind: "text",
                                body: ["text": "gap-3"],
                                createdAt: Date(timeIntervalSince1970: 1_700_001_200)
                            )
                        ],
                        hasMore: false,
                        nextAfterSequence: 3
                    )
                )
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        await summarySequenceState.setLatestServerSequence(1)
        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.map(\.text) == ["来自历史接口"]
                    && manager.imConnectionStatus == .connected
            }
        }
        await summarySequenceState.setLatestServerSequence(3)
        await manager.reconnectIMConnection()
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.map(\.text) == ["来自历史接口", "gap-2", "gap-3"]
            }
        }

        #expect(await gapCounter.currentValue() >= 2)
        #expect(manager.imConversationStore.selectedConversation?.messages.map(\.serverSequence) == [1, 2, 3])
    }

    @Test func reconnectIMConnectionSkipsGapSyncWhenSummarySequenceIsNotAhead() async throws {
        let harness = IMConnectionTestHarness()
        let requestCounter = IMRequestCounter()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path, request.url?.query) {
            case ("POST", "/api/auth/login", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations", _):
                await requestCounter.increment("conversations")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(conversationID: conversationID)
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members", _):
                await requestCounter.increment("members")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationMembersBody()
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages", _):
                await requestCounter.increment("messages")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesBody(conversationID: conversationID)
                )
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read", _):
                await requestCounter.increment("markRead")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(for: request)
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since", "afterSequence=1&limit=100"):
                await requestCounter.increment("messagesSince")
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.emptyMessagesSinceBody()
                )
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.count == 1
                    && manager.imConnectionStatus == .connected
            }
        }
        try await Self.waitUntil {
            await requestCounter.count(for: "markRead") >= 1
        }

        let initialConversationRequests = await requestCounter.count(for: "conversations")
        let initialMemberRequests = await requestCounter.count(for: "members")
        let initialMessageRequests = await requestCounter.count(for: "messages")
        let initialMarkReadRequests = await requestCounter.count(for: "markRead")

        await manager.reconnectIMConnection()
        try await Self.waitUntil {
            let isConnected = await MainActor.run { manager.imConnectionStatus == .connected }
            let didRefreshSummaries = await requestCounter.count(for: "conversations") > initialConversationRequests
            return isConnected && didRefreshSummaries
        }

        #expect(await requestCounter.count(for: "messagesSince") == 0)
        #expect(await requestCounter.count(for: "markRead") == initialMarkReadRequests)
        #expect(await requestCounter.count(for: "members") == initialMemberRequests)
        #expect(await requestCounter.count(for: "messages") == initialMessageRequests)
    }

    @Test func loginGapSyncContinuesBackgroundBackfillBeyondSingleBatchBudget() async throws {
        let harness = IMConnectionTestHarness()
        let gate = RestoreGate()
        let requestCounter = IMRequestCounter()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(
                        conversationID: conversationID,
                        latestServerSequence: 12
                    )
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationMembersBody()
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesBody(conversationID: conversationID)
                )
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(for: request)
                )
            case ("GET", "/api/contacts"):
                await requestCounter.increment("contacts")
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                await requestCounter.increment("contactRequests")
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since"):
                guard let afterSequence = Self.afterSequence(from: request) else {
                    Issue.record("缺少 afterSequence 查询参数")
                    return HTTPFixtures.response(statusCode: 500)
                }

                switch afterSequence {
                case 1...10:
                    let nextSequence = afterSequence + 1
                    return HTTPFixtures.response(
                        statusCode: 200,
                        body: try Self.imMessagesSincePageBody(
                            conversationID: conversationID,
                            messages: [Self.gapMessage(conversationID: conversationID, serverSequence: nextSequence)],
                            hasMore: true,
                            nextAfterSequence: nextSequence
                        )
                    )
                case 11:
                    await gate.markStarted()
                    await gate.waitForResume()
                    return HTTPFixtures.response(
                        statusCode: 200,
                        body: try Self.imMessagesSincePageBody(
                            conversationID: conversationID,
                            messages: [Self.gapMessage(conversationID: conversationID, serverSequence: 12)],
                            hasMore: false,
                            nextAfterSequence: 12
                        )
                    )
                default:
                    Issue.record("收到未预期 afterSequence: \(afterSequence)")
                    return HTTPFixtures.response(statusCode: 500)
                }
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        await gate.waitUntilStarted()
        try await Self.waitUntil {
            let contactsLoaded = await requestCounter.count(for: "contacts") > 0
            return await MainActor.run {
                contactsLoaded
                    && manager.imConnectionStatus == .connected
                    && manager.imConversationStore.selectedConversation?.messages.map(\.serverSequence) == Array(1...11).map(UInt64.init)
            }
        }

        await gate.resume()
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.map(\.serverSequence) == Array(1...12).map(UInt64.init)
            }
        }
    }

    @Test func loginGapSyncAdvancesSelectedConversationReadSequenceBatchByBatch() async throws {
        let harness = IMConnectionTestHarness()
        let gate = RestoreGate()
        let readRecorder = IMReadSequenceRecorder()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(
                        conversationID: conversationID,
                        latestServerSequence: 12
                    )
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationMembersBody()
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesBody(conversationID: conversationID)
                )
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read"):
                let payload = try JSONDecoder().decode(
                    IMConversationReadRequestBody.self,
                    from: request.httpBody ?? Data()
                )
                await readRecorder.record(payload.readSequence)
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(
                        conversationID: conversationID,
                        lastReadSequence: Int(payload.readSequence)
                    )
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since"):
                guard let afterSequence = Self.afterSequence(from: request) else {
                    Issue.record("缺少 afterSequence 查询参数")
                    return HTTPFixtures.response(statusCode: 500)
                }

                switch afterSequence {
                case 1...10:
                    let nextSequence = afterSequence + 1
                    return HTTPFixtures.response(
                        statusCode: 200,
                        body: try Self.imMessagesSincePageBody(
                            conversationID: conversationID,
                            messages: [Self.gapMessage(conversationID: conversationID, serverSequence: nextSequence)],
                            hasMore: true,
                            nextAfterSequence: nextSequence
                        )
                    )
                case 11:
                    await gate.markStarted()
                    await gate.waitForResume()
                    return HTTPFixtures.response(
                        statusCode: 200,
                        body: try Self.imMessagesSincePageBody(
                            conversationID: conversationID,
                            messages: [Self.gapMessage(conversationID: conversationID, serverSequence: 12)],
                            hasMore: false,
                            nextAfterSequence: 12
                        )
                    )
                default:
                    Issue.record("收到未预期 afterSequence: \(afterSequence)")
                    return HTTPFixtures.response(statusCode: 500)
                }
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            }
        )

        await manager.login(email: Self.user.email, password: "password123")
        await gate.waitUntilStarted()
        try await Self.waitUntil {
            let sequences = await readRecorder.allSequences()
            return await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.count == 11
                    && sequences.contains(11)
                    && sequences.last == 11
            }
        }

        await gate.resume()
        try await Self.waitUntil {
            let sequences = await readRecorder.allSequences()
            return await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.count == 12
                    && sequences.contains(11)
                    && sequences.last == 12
            }
        }
    }

    @Test func backgroundGapSyncFailureKeepsMergedMessagesAndMarksServerOffline() async throws {
        let harness = IMConnectionTestHarness()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(
                        conversationID: conversationID,
                        latestServerSequence: 12
                    )
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationMembersBody()
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesBody(conversationID: conversationID)
                )
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(for: request)
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since"):
                guard let afterSequence = Self.afterSequence(from: request) else {
                    Issue.record("缺少 afterSequence 查询参数")
                    return HTTPFixtures.response(statusCode: 500)
                }

                switch afterSequence {
                case 1...10:
                    let nextSequence = afterSequence + 1
                    return HTTPFixtures.response(
                        statusCode: 200,
                        body: try Self.imMessagesSincePageBody(
                            conversationID: conversationID,
                            messages: [Self.gapMessage(conversationID: conversationID, serverSequence: nextSequence)],
                            hasMore: true,
                            nextAfterSequence: nextSequence
                        )
                    )
                case 11:
                    throw URLError(.timedOut)
                default:
                    Issue.record("收到未预期 afterSequence: \(afterSequence)")
                    return HTTPFixtures.response(statusCode: 500)
                }
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            }
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.map(\.serverSequence) == Array(1...11).map(UInt64.init)
                    && manager.imConversationStore.statusMessage == "请求超时，请稍后重试。"
                    && manager.serverStatus == .offline(message: "请求超时，请稍后重试。")
            }
        }
    }

    @Test func logoutCancelsBackgroundGapSyncAndPreventsLateMutation() async throws {
        let harness = IMConnectionTestHarness()
        let gate = RestoreGate()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("DELETE", "/api/auth/sessions/current"):
                return HTTPFixtures.response(statusCode: 200)
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationsBody(
                        conversationID: conversationID,
                        latestServerSequence: 12
                    )
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationMembersBody()
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imMessagesBody(conversationID: conversationID)
                )
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(for: request)
                )
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/messages/since"):
                guard let afterSequence = Self.afterSequence(from: request) else {
                    Issue.record("缺少 afterSequence 查询参数")
                    return HTTPFixtures.response(statusCode: 500)
                }

                switch afterSequence {
                case 1...10:
                    let nextSequence = afterSequence + 1
                    return HTTPFixtures.response(
                        statusCode: 200,
                        body: try Self.imMessagesSincePageBody(
                            conversationID: conversationID,
                            messages: [Self.gapMessage(conversationID: conversationID, serverSequence: nextSequence)],
                            hasMore: true,
                            nextAfterSequence: nextSequence
                        )
                    )
                case 11:
                    await gate.markStarted()
                    await gate.waitForResume()
                    return HTTPFixtures.response(
                        statusCode: 200,
                        body: try Self.imMessagesSincePageBody(
                            conversationID: conversationID,
                            messages: [Self.gapMessage(conversationID: conversationID, serverSequence: 12)],
                            hasMore: false,
                            nextAfterSequence: 12
                        )
                    )
                default:
                    Issue.record("收到未预期 afterSequence: \(afterSequence)")
                    return HTTPFixtures.response(statusCode: 500)
                }
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            }
        )

        await manager.login(email: Self.user.email, password: "password123")
        await gate.waitUntilStarted()
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.count == 11
            }
        }

        await manager.logout()
        #expect(manager.phase == .signedOut(message: nil))
        #expect(manager.imConversationStore.conversations.isEmpty)

        await gate.resume()
        try await Task.sleep(for: .milliseconds(50))

        #expect(manager.phase == .signedOut(message: nil))
        #expect(manager.imConversationStore.conversations.isEmpty)
    }

    @Test func loginBootstrapAppliesServerUnreadCountToBackgroundConversationSummary() async throws {
        let harness = IMConnectionTestHarness()
        let selectedConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let backgroundConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path, request.url?.query) {
            case ("POST", "/api/auth/login", _):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        [
                            IMConversationSummaryResponseBody(
                                id: selectedConversationID,
                                title: "selected",
                                memberUserIDs: [Self.user.id],
                                lastMessage: IMMessagePreviewResponseBody(
                                    id: UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!,
                                    senderUserID: Self.user.id,
                                    serverSequence: 1,
                                    kind: "text",
                                    body: ["text": "selected preview"],
                                    createdAt: Date(timeIntervalSince1970: 1_700_001_000)
                                ),
                                lastReadSequence: 1,
                                unreadCount: 0,
                                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                updatedAt: Date(timeIntervalSince1970: 1_700_001_600)
                            ),
                            IMConversationSummaryResponseBody(
                                id: backgroundConversationID,
                                title: "background",
                                memberUserIDs: [Self.user.id],
                                lastMessage: IMMessagePreviewResponseBody(
                                    id: UUID(uuidString: "dddddddd-1111-2222-3333-eeeeeeeeeeee")!,
                                    senderUserID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                                    serverSequence: 8,
                                    kind: "text",
                                    body: ["text": "background preview"],
                                    createdAt: Date(timeIntervalSince1970: 1_700_001_500)
                                ),
                                lastReadSequence: 5,
                                unreadCount: 3,
                                createdAt: Date(timeIntervalSince1970: 1_700_000_500),
                                updatedAt: Date(timeIntervalSince1970: 1_700_001_500)
                            )
                        ]
                    )
                )
            case ("GET", "/api/im/conversations/\(selectedConversationID.uuidString)/members", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.emptyMembersBody()
                )
            case ("GET", "/api/im/conversations/\(selectedConversationID.uuidString)/messages", _):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.emptyMessagesBody()
                )
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = AuthManager(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: {
                await harness.makeConnection()
            },
            shouldRestoreSession: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.conversations.count == 2
                    && manager.imConversationStore.conversations.first(where: { $0.id == backgroundConversationID.uuidString })?.serverUnreadCount == 3
            }
        }

        let backgroundConversation = manager.imConversationStore.conversations.first {
            $0.id == backgroundConversationID.uuidString
        }
        #expect(backgroundConversation?.serverLastReadSequence == 5)
        #expect(backgroundConversation?.serverUnreadCount == 3)
        #expect(backgroundConversation?.unreadCount == 3)
    }

    @Test func loginRestoresCachedConversationBeforeNetworkRefreshAndThenAppliesServerSummary() async throws {
        let harness = IMConnectionTestHarness()
        let gate = RestoreGate()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString
        let cache = InMemoryIMConversationCache()

        await cache.seed(
            IMConversationCacheSnapshot(
                conversations: [
                    IMCachedConversationState(
                        id: conversationIDString,
                        title: "缓存会话",
                        kind: .group,
                        memberCount: 2,
                        memberUserIDs: [Self.user.id],
                        messages: [
                            IMCachedMessageState(
                                id: "cached-message-1",
                                conversationID: conversationIDString,
                                clientMessageID: "cached-client-1",
                                serverMessageID: "cached-server-1",
                                senderUserID: Self.user.id,
                                serverSequence: 7,
                                kind: "text",
                                text: "来自缓存",
                                direction: .outgoing,
                                createdAt: Date(timeIntervalSince1970: 1_700_100_000),
                                deliveryState: .sent
                            )
                        ],
                        hasLoadedMessages: true,
                        lastMessagePreviewText: "来自缓存",
                        hasMoreHistory: true,
                        latestSyncedServerSequence: 7,
                        oldestLoadedServerSequence: 7,
                        serverLastReadSequence: 7,
                        serverUnreadCount: 0,
                        updatedAt: Date(timeIntervalSince1970: 1_700_100_000)
                    )
                ],
                selectedConversationID: conversationIDString,
                lastSummaryRefreshAt: Date(timeIntervalSince1970: 1_700_100_100)
            ),
            for: Self.user.id
        )

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                await gate.markStarted()
                await gate.waitForResume()
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        [
                            IMConversationSummaryResponseBody(
                                id: conversationID,
                                title: "服务端会话",
                                kind: IMConversationKind.direct.rawValue,
                                memberCount: 3,
                                memberUserIDs: [Self.user.id],
                                lastMessage: IMMessagePreviewResponseBody(
                                    id: UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!,
                                    senderUserID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                                    serverSequence: 8,
                                    kind: "text",
                                    body: ["text": "服务端预览"],
                                    createdAt: Date(timeIntervalSince1970: 1_700_100_200)
                                ),
                                lastReadSequence: 7,
                                unreadCount: 1,
                                createdAt: Date(timeIntervalSince1970: 1_700_090_000),
                                updatedAt: Date(timeIntervalSince1970: 1_700_100_200)
                            )
                        ]
                    )
                )
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            imConversationCache: IMConversationCacheHandler(cache),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")
        await gate.waitUntilStarted()
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.title == "缓存会话"
                    && manager.imConversationStore.selectedConversation?.messages.map { $0.text } == ["来自缓存"]
                    && manager.imConversationStore.latestLoadedServerSequence(for: conversationIDString) == 7
            }
        }

        await gate.resume()
        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.title == "服务端会话"
                    && manager.imConversationStore.selectedConversation?.kind == .direct
                    && manager.imConversationStore.selectedConversation?.memberCount == 3
                    && manager.imConversationStore.selectedConversation?.serverUnreadCount == 1
            }
        }

        #expect(manager.imConversationStore.selectedConversationID == conversationIDString)
        #expect(manager.imConversationStore.selectedConversation?.messages.map { $0.text } == ["来自缓存"])
        #expect(manager.imConversationStore.hasLoadedMessages(for: conversationIDString))
        #expect(manager.imConversationStore.latestLoadedServerSequence(for: conversationIDString) == 7)
        #expect(manager.imConversationStore.oldestLoadedServerSequence(for: conversationIDString) == 7)
    }

    @Test func loginContinuesWithNetworkBootstrapWhenConversationCacheLoadFails() async throws {
        let harness = IMConnectionTestHarness()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        [
                            IMConversationSummaryResponseBody(
                                id: conversationID,
                                title: "网络会话",
                                kind: IMConversationKind.group.rawValue,
                                memberCount: 2,
                                memberUserIDs: [Self.user.id],
                                lastMessage: nil,
                                createdAt: Date(timeIntervalSince1970: 1_700_090_000),
                                updatedAt: Date(timeIntervalSince1970: 1_700_100_000)
                            )
                        ]
                    )
                )
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let manager = makeManager(
            transport: transport,
            openIMConnection: {
                await harness.makeConnection()
            },
            imConversationCache: IMConversationCacheHandler(FailingLoadIMConversationCache()),
            wrapDefaultIMResponses: false
        )

        await manager.login(email: Self.user.email, password: "password123")

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.title == "网络会话"
                    && manager.imConversationStore.selectedConversationID == conversationID.uuidString
            }
        }

        #expect(manager.imConversationStore.conversations.count == 1)
    }

    private func makeManager(
        transport: MockHTTPTransport,
        openIMConnection: (@Sendable () async throws -> IMTCPConnection)? = nil,
        imConversationCache: IMConversationCacheHandler = IMConversationCacheHandler(NoopIMConversationCache()),
        contactStateCache: ContactStateCacheHandler = ContactStateCacheHandler(NoopContactStateCache()),
        wrapDefaultIMResponses: Bool = true
    ) -> AuthManager {
        return AuthManager(
            httpClient: HTTPClient(
                baseURL: HTTPFixtures.baseURL,
                transport: wrapDefaultIMResponses ? wrapWithDefaultIMResponses(transport) : transport
            ),
            tokenStore: InMemoryTokenStore(),
            userCache: InMemoryUserSessionCache(),
            openIMConnection: openIMConnection,
            imConversationCache: imConversationCache,
            contactStateCache: contactStateCache,
            shouldRestoreSession: false
        )
    }

    private func wrapWithDefaultIMResponses(_ transport: MockHTTPTransport) -> MockHTTPTransport {
        MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/contacts"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactResponseBody]()))
            case ("GET", "/api/contact-requests"):
                return HTTPFixtures.response(statusCode: 200, body: try HTTPFixtures.jsonBody([ContactRequestResponseBody]()))
            case ("GET", "/api/im/conversations"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationsBody())
            case ("GET", "/api/im/conversations/changes"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationChangesBody())
            case ("GET", let path) where path?.hasPrefix("/api/im/conversations/") == true && path?.hasSuffix("/members") == true:
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMembersBody())
            case ("GET", let path) where path?.hasPrefix("/api/im/conversations/") == true && path?.hasSuffix("/messages/since") == true:
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesSinceBody())
            case ("GET", let path) where path?.hasPrefix("/api/im/conversations/") == true && path?.hasSuffix("/messages") == true:
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyMessagesBody())
            case ("POST", let path) where path?.hasPrefix("/api/im/conversations/") == true && path?.hasSuffix("/read") == true:
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.imConversationReadBody(for: request)
                )
            default:
                return try await transport.send(request)
            }
        }
    }

    private nonisolated static func authResponseBody() throws -> Data {
        try authResponseBody(
            user: user,
            accessToken: "access-1",
            refreshToken: "refresh-1"
        )
    }

    private nonisolated static func authResponseBody(
        user: AuthUser,
        accessToken: String,
        refreshToken: String
    ) throws -> Data {
        try HTTPFixtures.jsonBody(
            AuthResponseBody(
                accessToken: accessToken,
                expiresIn: 600,
                refreshToken: refreshToken,
                refreshExpiresIn: 30 * 24 * 60 * 60,
                user: user
            )
        )
    }

    private nonisolated static func emptyConversationsBody() throws -> Data {
        try HTTPFixtures.jsonBody(
            IMConversationSummaryPageResponseBody(
                items: [],
                nextCursor: nil,
                hasMore: false,
                snapshotToken: "snapshot-empty"
            )
        )
    }

    private nonisolated static func emptyMessagesBody() throws -> Data {
        try HTTPFixtures.jsonBody([IMConversationMessageResponseBody]())
    }

    private nonisolated static func emptyConversationChangesBody() throws -> Data {
        try HTTPFixtures.jsonBody(
            IMConversationSummaryChangesResponseBody(
                upserts: [],
                removedConversationIDs: [],
                nextCursor: nil,
                hasMore: false,
                targetToken: "snapshot-empty"
            )
        )
    }

    private nonisolated static func emptyMessagesSinceBody() throws -> Data {
        try HTTPFixtures.jsonBody(
            IMConversationMessagesSinceResponseBody(
                messages: [],
                hasMore: false,
                nextAfterSequence: nil
            )
        )
    }

    private nonisolated static func emptyMembersBody() throws -> Data {
        try HTTPFixtures.jsonBody([IMConversationMemberResponseBody]())
    }

    private nonisolated static func imConversationReadBody(
        conversationID: UUID,
        lastReadSequence: Int,
        unreadCount: Int = 0
    ) throws -> Data {
        try HTTPFixtures.jsonBody(
            IMConversationReadResponseBody(
                conversationID: conversationID,
                lastReadSequence: lastReadSequence,
                unreadCount: unreadCount
            )
        )
    }

    private nonisolated static func imConversationReadBody(for request: URLRequest) throws -> Data {
        guard let path = request.url?.path else {
            throw URLError(.badURL)
        }

        let components = path.split(separator: "/")
        guard
            let conversationsIndex = components.firstIndex(of: "conversations"),
            components.indices.contains(components.index(after: conversationsIndex)),
            let conversationID = UUID(uuidString: String(components[components.index(after: conversationsIndex)]))
        else {
            throw URLError(.badURL)
        }

        let payload = try JSONDecoder().decode(
            IMConversationReadRequestBody.self,
            from: request.httpBody ?? Data()
        )
        return try imConversationReadBody(
            conversationID: conversationID,
            lastReadSequence: Int(payload.readSequence)
        )
    }

    private nonisolated static func imConversationsBody(
        conversationID: UUID,
        latestServerSequence: Int = 1,
        kind: IMConversationKind = .group,
        directMessagingState: String? = nil,
        memberUserIDs: [UUID] = [user.id],
        directPeer: IMDirectPeerResponseBody? = nil
    ) throws -> Data {
        try HTTPFixtures.jsonBody(
            IMConversationSummaryPageResponseBody(
                items: [
                    IMConversationSummaryResponseBody(
                        id: conversationID,
                        title: "服务端会话",
                        kind: kind.rawValue,
                        directMessagingState: directMessagingState,
                        directPeer: directPeer,
                        memberUserIDs: memberUserIDs,
                        lastMessage: IMMessagePreviewResponseBody(
                            id: UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!,
                            senderUserID: user.id,
                            serverSequence: latestServerSequence,
                            kind: "text",
                            body: ["text": latestServerSequence == 1 ? "来自历史接口" : "服务端摘要更新"],
                            createdAt: Date(timeIntervalSince1970: 1_700_001_000 + Double(latestServerSequence - 1))
                        ),
                        lastReadSequence: 0,
                        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                        updatedAt: Date(timeIntervalSince1970: 1_700_001_000 + Double(latestServerSequence - 1))
                    )
                ],
                nextCursor: nil,
                hasMore: false,
                snapshotToken: "snapshot-\(conversationID.uuidString.lowercased())"
            )
        )
    }

    private nonisolated static func imConversationSummaryPageBody(
        items: [IMConversationSummaryResponseBody],
        nextCursor: String?,
        hasMore: Bool,
        snapshotToken: String
    ) throws -> Data {
        try HTTPFixtures.jsonBody(
            IMConversationSummaryPageResponseBody(
                items: items,
                nextCursor: nextCursor,
                hasMore: hasMore,
                snapshotToken: snapshotToken
            )
        )
    }

    private nonisolated static func imConversationSummary(
        id: UUID,
        latestServerSequence: Int,
        updatedAt: Date,
        title: String,
        kind: IMConversationKind = .group
    ) -> IMConversationSummaryResponseBody {
        IMConversationSummaryResponseBody(
            id: id,
            title: title,
            kind: kind.rawValue,
            memberUserIDs: [user.id],
            lastMessage: IMMessagePreviewResponseBody(
                id: UUID(),
                senderUserID: user.id,
                serverSequence: latestServerSequence,
                kind: "text",
                body: ["text": title],
                createdAt: updatedAt
            ),
            lastReadSequence: 0,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: updatedAt
        )
    }

    private nonisolated static func imMessagesBody(conversationID: UUID) throws -> Data {
        try HTTPFixtures.jsonBody(
            [
                IMConversationMessageResponseBody(
                    id: UUID(uuidString: "dddddddd-1111-2222-3333-eeeeeeeeeeee")!,
                    conversationID: conversationID,
                    senderUserID: user.id,
                    clientMessageID: "client-history-1",
                    serverSequence: 1,
                    kind: "text",
                    body: ["text": "来自历史接口"],
                    createdAt: Date(timeIntervalSince1970: 1_700_001_000)
                )
            ]
        )
    }

    private nonisolated static func imMessagesSinceBody(conversationID: UUID) throws -> Data {
        try imMessagesSincePageBody(
            conversationID: conversationID,
            messages: [
                IMConversationMessageResponseBody(
                    id: UUID(uuidString: "ffffffff-1111-2222-3333-eeeeeeeeeeee")!,
                    conversationID: conversationID,
                    senderUserID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    clientMessageID: "client-gap-2",
                    serverSequence: 2,
                    kind: "text",
                    body: ["text": "来自补洞接口"],
                    createdAt: Date(timeIntervalSince1970: 1_700_001_100)
                )
            ],
            hasMore: false,
            nextAfterSequence: 2
        )
    }

    private nonisolated static func gapMessage(
        conversationID: UUID,
        serverSequence: Int
    ) -> IMConversationMessageResponseBody {
        IMConversationMessageResponseBody(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", serverSequence)) ?? UUID(),
            conversationID: conversationID,
            senderUserID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            clientMessageID: "client-gap-\(serverSequence)",
            serverSequence: serverSequence,
            kind: "text",
            body: ["text": "gap-\(serverSequence)"],
            createdAt: Date(timeIntervalSince1970: 1_700_001_000 + Double(serverSequence))
        )
    }

    private nonisolated static func imMessagesSincePageBody(
        conversationID: UUID,
        messages: [IMConversationMessageResponseBody],
        hasMore: Bool,
        nextAfterSequence: Int?
    ) throws -> Data {
        _ = conversationID
        return try HTTPFixtures.jsonBody(
            IMConversationMessagesSinceResponseBody(
                messages: messages,
                hasMore: hasMore,
                nextAfterSequence: nextAfterSequence
            )
        )
    }

    private nonisolated static func afterSequence(from request: URLRequest) -> Int? {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return nil
        }

        return components.queryItems?
            .first(where: { $0.name == "afterSequence" })?
            .value
            .flatMap(Int.init)
    }

    private nonisolated static func queuedConversationCacheSnapshot(
        conversationID: String,
        messageCount: Int
    ) -> IMConversationCacheSnapshot {
        let queuedMessages = (0..<messageCount).map { index in
            IMCachedMessageState(
                id: "queued-client-\(index + 1)",
                conversationID: conversationID,
                clientMessageID: "queued-client-\(index + 1)",
                serverMessageID: nil,
                senderUserID: user.id,
                serverSequence: nil,
                kind: "text",
                text: "排队消息-\(index + 1)",
                direction: .outgoing,
                createdAt: Date(timeIntervalSince1970: 1_700_100_000 + Double(index)),
                deliveryState: .queued(message: "等待 IM 长连接恢复后发送。")
            )
        }

        return IMConversationCacheSnapshot(
            conversations: [
                IMCachedConversationState(
                    id: conversationID,
                    title: "缓存会话",
                    kind: .direct,
                    memberCount: 2,
                    memberUserIDs: [user.id],
                    messages: queuedMessages,
                    hasLoadedMessages: true,
                    lastMessagePreviewText: queuedMessages.last?.text ?? "",
                    hasMoreHistory: false,
                    latestSyncedServerSequence: nil,
                    oldestLoadedServerSequence: nil,
                    serverLastReadSequence: 0,
                    serverUnreadCount: 0,
                    updatedAt: queuedMessages.last?.createdAt ?? Date(timeIntervalSince1970: 1_700_100_000)
                )
            ],
            selectedConversationID: conversationID,
            lastSummaryRefreshAt: nil
        )
    }

    private nonisolated static func imConversationMembersBody() throws -> Data {
        try HTTPFixtures.jsonBody(
            [
                IMConversationMemberResponseBody(
                    id: user.id,
                    email: user.email
                ),
                IMConversationMemberResponseBody(
                    id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    email: "peer@example.com"
                )
            ]
        )
    }

    private nonisolated static func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<100 {
            if await predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        Issue.record("等待状态变化超时。")
        throw IMTCPClientError.connectionClosed
    }

    private nonisolated static func requireRecordedLine(
        at index: Int,
        from harness: IMConnectionTestHarness
    ) async throws -> String {
        for _ in 0..<50 {
            let lines = await harness.recordedLines()
            if lines.indices.contains(index) {
                return lines[index]
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        Issue.record("等待第 \(index) 条 IM 发送数据超时。")
        throw IMTCPClientError.connectionClosed
    }

    private nonisolated static func decode<T: Decodable>(_ type: T.Type, from line: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(line.utf8))
    }
}
