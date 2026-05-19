import Foundation
@testable import IMClientKit
import Testing
@testable import IMApp

extension AuthManagerTests {
    @Test func aiStreamSnapshotRecoveryRetriesWithoutDroppingOtherTargets() async throws {
        let firstConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let secondConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-cccccccccccc")!
        let firstMessageID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let secondMessageID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
        let firstStreamID = "stream-first"
        let secondStreamID = "stream-second"
        let recorder = AIStreamSnapshotRequestRecorder()

        let controller = makeAIStreamRecoveryController { request in
            guard let path = request.url?.path else {
                return HTTPFixtures.response(statusCode: 500)
            }
            let attempt = await recorder.record(path)
            if path.contains(firstMessageID.uuidString), attempt == 1 {
                return HTTPFixtures.response(statusCode: 503)
            }
            if path.contains(firstMessageID.uuidString) {
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.streamSnapshotBody(
                        conversationID: firstConversationID,
                        messageID: firstMessageID,
                        streamID: firstStreamID,
                        text: "first completed"
                    )
                )
            }
            if path.contains(secondMessageID.uuidString) {
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try Self.streamSnapshotBody(
                        conversationID: secondConversationID,
                        messageID: secondMessageID,
                        streamID: secondStreamID,
                        text: "second completed"
                    )
                )
            }
            Issue.record("收到未预期 stream snapshot 请求：\(path)")
            return HTTPFixtures.response(statusCode: 500)
        }

        seedStreamingMessage(
            conversationID: firstConversationID,
            messageID: firstMessageID,
            streamID: firstStreamID,
            in: controller.imConversationStore
        )
        seedStreamingMessage(
            conversationID: secondConversationID,
            messageID: secondMessageID,
            streamID: secondStreamID,
            in: controller.imConversationStore
        )

        controller.syncActiveMessageStreamSnapshots()

        try await Self.waitUntil {
            let firstCount = await recorder.count(containing: firstMessageID.uuidString)
            let secondCount = await recorder.count(containing: secondMessageID.uuidString)
            return firstCount >= 2 && secondCount >= 1
        }

        let firstMessage = try #require(
            controller.imConversationStore.conversations
                .first { $0.id == firstConversationID.uuidString }?
                .messages
                .first { $0.id == firstMessageID.uuidString }
        )
        let secondMessage = try #require(
            controller.imConversationStore.conversations
                .first { $0.id == secondConversationID.uuidString }?
                .messages
                .first { $0.id == secondMessageID.uuidString }
        )
        #expect(firstMessage.text == "first completed")
        #expect(firstMessage.derivedState.streamState?.state == .completed)
        #expect(secondMessage.text == "second completed")
        #expect(secondMessage.derivedState.streamState?.state == .completed)
    }

    @Test func aiStreamSnapshotRecoveryClearsRetriesOnDisconnect() async throws {
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-dddddddddddd")!
        let messageID = UUID(uuidString: "33333333-4444-5555-6666-777777777777")!
        let streamID = "stream-disconnect"
        let recorder = AIStreamSnapshotRequestRecorder()
        let controller = makeAIStreamRecoveryController { request in
            guard let path = request.url?.path else {
                return HTTPFixtures.response(statusCode: 500)
            }
            _ = await recorder.record(path)
            return HTTPFixtures.response(statusCode: 503)
        }

        seedStreamingMessage(
            conversationID: conversationID,
            messageID: messageID,
            streamID: streamID,
            in: controller.imConversationStore
        )

        controller.syncActiveMessageStreamSnapshots()
        try await Self.waitUntil {
            await recorder.count(containing: messageID.uuidString) == 1
        }

        await controller.disconnect(flushCache: false)
        try await Task.sleep(for: .milliseconds(1_200))

        #expect(await recorder.count(containing: messageID.uuidString) == 1)
    }

    @MainActor
    private func makeAIStreamRecoveryController(
        handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) -> ConversationRuntimeController {
        let tokenStore = InMemoryTokenStore()
        try? tokenStore.save("access-1", for: "access_token")
        try? tokenStore.save("refresh-1", for: "refresh_token")
        let sessionClient = SessionClient(
            httpClient: HTTPClient(
                baseURL: HTTPFixtures.baseURL,
                transport: MockHTTPTransport { request in
                    if request.httpMethod == "POST", request.url?.path == "/api/auth/refresh" {
                        return HTTPFixtures.response(
                            statusCode: 200,
                            body: try Self.authResponseBody()
                        )
                    }
                    return try await handler(request)
                }
            ),
            tokenStore: tokenStore,
            userCache: InMemoryUserSessionCache()
        )
        return ConversationRuntimeController(
            sessionClient: sessionClient,
            openIMConnection: {
                throw URLError(.notConnectedToInternet)
            },
            imConversationStore: IMConversationStore(),
            currentUserProvider: { Self.user },
            isSignedInProvider: { true },
            latestConversationSummariesProvider: { [] },
            setLatestConversationSummaries: { _ in },
            conversationSummaryRefreshAtProvider: { nil },
            setConversationSummaryRefreshAt: { _ in },
            conversationSummarySyncTokenProvider: { nil },
            setConversationSummarySyncToken: { _ in },
            markServerOnline: { },
            clearSession: { _ in },
            handleIMDataRequestError: { _ in },
            syncContactStateAfterConnection: { },
            scheduleConversationCachePersist: { },
            flushConversationCache: { },
            flushContactStateCache: { },
            applyContactEvent: { _ in },
            setConnectionStatus: { _ in },
            setQueuedFlushActive: { _ in },
            backgroundTransferMonitor: AuthManagerBackgroundTransferMonitor()
        )
    }

    @MainActor
    private func seedStreamingMessage(
        conversationID: UUID,
        messageID: UUID,
        streamID: String,
        in store: IMConversationStore
    ) {
        let createdAt = Date(timeIntervalSince1970: 1_700_300_000)
        let summary = IMConversationSummaryResponseBody(
            id: conversationID,
            title: "AI \(streamID)",
            memberUserIDs: [Self.user.id],
            lastMessage: nil,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        store.applyConversationSummaryPage([summary])
        store.appendMessages(
            in: conversationID.uuidString,
            messages: [
                IMConversationMessageResponseBody(
                    id: messageID,
                    conversationID: conversationID,
                    senderUserID: Self.user.id,
                    serverSequence: 1,
                    content: .text("partial"),
                    derivedState: MessageDerivedState(
                        streamState: MessageStreamState(
                            streamID: streamID,
                            state: .streaming,
                            lastChunkIndex: 1,
                            partialText: "partial",
                            updatedAt: createdAt
                        )
                    ),
                    createdAt: createdAt
                )
            ],
            currentUserID: Self.user.id
        )
    }

    nonisolated private static func streamSnapshotBody(
        conversationID: UUID,
        messageID: UUID,
        streamID: String,
        text: String
    ) throws -> Data {
        let completedAt = Date(timeIntervalSince1970: 1_700_300_010)
        let derivedState = MessageDerivedState(
            streamState: MessageStreamState(
                streamID: streamID,
                state: .completed,
                lastChunkIndex: 9,
                partialText: text,
                updatedAt: completedAt
            )
        )
        return try HTTPFixtures.jsonBody(
            IMMessageStreamResponseBody(
                message: IMConversationMessageResponseBody(
                    id: messageID,
                    conversationID: conversationID,
                    senderUserID: Self.user.id,
                    serverSequence: 1,
                    content: .text(text),
                    derivedState: derivedState,
                    createdAt: Date(timeIntervalSince1970: 1_700_300_000)
                ),
                stream: IMTCPMessageStreamPayload(
                    streamID: streamID,
                    messageID: messageID.uuidString,
                    conversationID: conversationID.uuidString,
                    chunkIndex: 9,
                    partialTextLength: text.count,
                    state: .completed,
                    serverTimestamp: completedAt
                )
            )
        )
    }
}

private actor AIStreamSnapshotRequestRecorder {
    private var countsByPath: [String: Int] = [:]

    func record(_ path: String) -> Int {
        countsByPath[path, default: 0] += 1
        return countsByPath[path, default: 0]
    }

    func count(containing value: String) -> Int {
        countsByPath
            .filter { $0.key.contains(value) }
            .map(\.value)
            .reduce(0, +)
    }
}
