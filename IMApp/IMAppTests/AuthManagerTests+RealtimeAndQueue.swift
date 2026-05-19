import Foundation
@testable import IMClientKit
import Testing
@testable import IMApp

extension AuthManagerTests {
    @Test func loginAutoConnectsIMAndLogoutDisconnectsConnection() async throws {
        let harness = IMConnectionTestHarness()
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("DELETE", "/api/auth/sessions/current"):
                return HTTPFixtures.response(statusCode: 200)
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
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
                return try Self.defaultOrUnexpectedIMResponse(for: request)
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
                return try Self.defaultOrUnexpectedIMResponse(for: request)
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
                return try Self.defaultOrUnexpectedIMResponse(for: request)
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
                return try Self.defaultOrUnexpectedIMResponse(for: request)
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
                return try Self.defaultOrUnexpectedIMResponse(for: request)
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
                return try Self.defaultOrUnexpectedIMResponse(for: request)
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


    @Test func sendIMMediaUploadsAssetThenWritesTCPPacket() async throws {
        let harness = IMConnectionTestHarness()
        let uploadID = "upload-media-1"
        let mediaTransport = MockFileTransferTransport()
        let fileTransferClient = FileTransferClient(
            baseURL: HTTPFixtures.baseURL,
            transport: mediaTransport
        )
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            case ("POST", "/api/media/uploads"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        MediaUploadSessionResponseBody(
                            uploadID: uploadID,
                            uploadPath: "/api/media/uploads/\(uploadID)/chunk",
                            completePath: "/api/media/uploads/\(uploadID)/complete",
                            expiresAt: Date().addingTimeInterval(300)
                        )
                    )
                )
            case ("POST", "/api/media/uploads/\(uploadID)/complete"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        IMMediaAsset(
                            assetID: uploadID,
                            kind: .image,
                            mimeType: "image/png",
                            byteSize: 15,
                            filename: "photo.png",
                            width: 120,
                            height: 90,
                            durationMillis: nil,
                            previewAssetID: nil
                        )
                    )
                )
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }
        let manager = makeManager(
            transport: transport,
            fileTransferClient: fileTransferClient,
            openIMConnection: {
                await harness.makeConnection()
            }
        )

        let fileURL = FileManager.default.temporaryDirectory.appending(path: "media-\(UUID().uuidString).png")
        try Data("fake-image-data".utf8).write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        await manager.login(email: Self.user.email, password: "password123")
        try await Self.waitUntil {
            await MainActor.run { manager.imConnectionStatus == .connected }
        }

        let didSend = await manager.sendIMMedia(
            fileURL: fileURL,
            kind: .image,
            mimeType: "image/png",
            width: 120,
            height: 90,
            to: "conv-local"
        )

        #expect(didSend)
        let uploadRequests = await mediaTransport.requests()
        #expect(uploadRequests.count == 1)
        #expect(uploadRequests.first?.url?.path == "/api/media/uploads/\(uploadID)/chunk")

        let messageLine = try await Self.requireRecordedLine(at: 0, from: harness)
        let messagePacket = try Self.decode(IMTCPPacketEnvelope<IMTCPMessagePayload>.self, from: messageLine)
        #expect(messagePacket.type == .message)
        #expect(messagePacket.payload.conversationID == "conv-local")
        #expect(messagePacket.payload.content == .image(
            IMMediaAsset(
                assetID: uploadID,
                kind: .image,
                mimeType: "image/png",
                byteSize: 15,
                filename: "photo.png",
                width: 120,
                height: 90,
                durationMillis: nil,
                previewAssetID: nil
            )
        ))

        try await Self.waitUntil {
            await MainActor.run {
                manager.imConversationStore.selectedConversation?.messages.first?.deliveryState == .sending
            }
        }
    }


    @Test func restoredPendingIMMediaUploadResumesAndWritesTCPPacket() async throws {
        let harness = IMConnectionTestHarness()
        let uploadID = "upload-media-recovery-1"
        let mediaTransport = MockFileTransferTransport()
        let fileTransferClient = FileTransferClient(
            baseURL: HTTPFixtures.baseURL,
            transport: mediaTransport
        )
        let conversationID = "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb"
        let sourceFileURL = FileManager.default.temporaryDirectory.appending(path: "recover-media-\(UUID().uuidString).png")
        try Data("recoverable-image-data".utf8).write(to: sourceFileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: sourceFileURL) }

        let cache = InMemoryIMConversationCache()
        await cache.seed(
            IMConversationCacheSnapshot(
                conversations: [
                    IMCachedConversationState(
                        id: conversationID,
                        title: "Recovered Media",
                        kind: .direct,
                        memberCount: 2,
                        memberUserIDs: [Self.user.id],
                        messages: [
                            IMCachedMessageState(
                                id: "media-local-1",
                                conversationID: conversationID,
                                clientMessageID: "media-local-1",
                                serverMessageID: nil,
                                senderUserID: Self.user.id,
                                serverSequence: nil,
                                content: .image(
                                    IMMediaAsset(
                                        assetID: "local-recover-asset",
                                        kind: .image,
                                        mimeType: "image/png",
                                        byteSize: 22,
                                        filename: "recover.png",
                                        width: 120,
                                        height: 90
                                    )
                                ),
                                direction: .outgoing,
                                createdAt: Date(timeIntervalSince1970: 1_700_900_000),
                                deliveryState: .uploading(message: "正在上传附件。"),
                                localTransferState: IMMessageLocalTransferState(
                                    sourceFilePath: sourceFileURL.path
                                )
                            )
                        ],
                        hasLoadedMessages: true,
                        lastMessagePreviewText: "recover.png",
                        hasMoreHistory: false,
                        latestSyncedServerSequence: nil,
                        oldestLoadedServerSequence: nil,
                        serverLastReadSequence: 0,
                        serverUnreadCount: 0,
                        updatedAt: Date(timeIntervalSince1970: 1_700_900_000)
                    )
                ],
                selectedConversationID: conversationID,
                lastSummaryRefreshAt: nil
            ),
            for: Self.user.id
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
                    body: try HTTPFixtures.jsonBody(
                        IMConversationSummaryPageResponseBody(
                            items: [
                                IMConversationSummaryResponseBody(
                                    id: UUID(uuidString: conversationID)!,
                                    title: nil,
                                    kind: IMConversationKind.direct.rawValue,
                                    memberCount: 2,
                                    memberUserIDs: [Self.user.id],
                                    lastMessage: nil,
                                    createdAt: Date(timeIntervalSince1970: 1_700_900_000),
                                    updatedAt: Date(timeIntervalSince1970: 1_700_900_000)
                                )
                            ],
                            nextCursor: nil,
                            hasMore: false,
                            snapshotToken: "token-1"
                        )
                    )
                )
            case ("GET", "/api/im/conversations/changes"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.emptyConversationChangesBody())
            case ("POST", "/api/media/uploads"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        MediaUploadSessionResponseBody(
                            uploadID: uploadID,
                            uploadPath: "/api/media/uploads/\(uploadID)/chunk",
                            completePath: "/api/media/uploads/\(uploadID)/complete",
                            expiresAt: Date().addingTimeInterval(300)
                        )
                    )
                )
            case ("POST", "/api/media/uploads/\(uploadID)/complete"):
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        IMMediaAsset(
                            assetID: uploadID,
                            kind: .image,
                            mimeType: "image/png",
                            byteSize: 22,
                            filename: "recover.png",
                            width: 120,
                            height: 90,
                            durationMillis: nil,
                            previewAssetID: nil
                        )
                    )
                )
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }
        let manager = makeManager(
            transport: transport,
            fileTransferClient: fileTransferClient,
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
        #expect(messagePacket.payload.content == .image(
            IMMediaAsset(
                assetID: uploadID,
                kind: .image,
                mimeType: "image/png",
                byteSize: 22,
                filename: "recover.png",
                width: 120,
                height: 90,
                durationMillis: nil,
                previewAssetID: nil
            )
        ))

        let uploadRequests = await mediaTransport.requests()
        #expect(uploadRequests.contains(where: { $0.url?.path == "/api/media/uploads/\(uploadID)/chunk" }))

        try await Self.waitUntil {
            await MainActor.run {
                guard let message = manager.imConversationStore.selectedConversation?.messages.first else {
                    return false
                }
                return message.deliveryState == .sending && message.localTransferState == nil
            }
        }
    }


    @Test func restoredBackgroundMediaDownloadSnapshotReattachesToCachedMessageState() async throws {
        let conversationID = "downloaded-conversation-1"
        let asset = IMMediaAsset(
            assetID: "asset-background-download-1",
            kind: .file,
            mimeType: "application/pdf",
            byteSize: 128,
            filename: "guide.pdf"
        )
        let destinationURL = FileManager.default.temporaryDirectory
            .appending(path: "im-background-download-\(UUID().uuidString).pdf")
        let cache = InMemoryIMConversationCache()
        await cache.seed(
            IMConversationCacheSnapshot(
                conversations: [
                    IMCachedConversationState(
                        id: conversationID,
                        title: "Background Download",
                        kind: .direct,
                        memberCount: 2,
                        memberUserIDs: [Self.user.id],
                        messages: [
                            IMCachedMessageState(
                                id: "download-message-1",
                                conversationID: conversationID,
                                clientMessageID: nil,
                                serverMessageID: UUID().uuidString,
                                senderUserID: Self.user.id,
                                serverSequence: 9,
                                content: .file(asset),
                                direction: .incoming,
                                createdAt: Date(timeIntervalSince1970: 1_701_000_000),
                                deliveryState: .received,
                                localDownloadState: IMMessageLocalDownloadState(
                                    destinationFilePath: destinationURL.path,
                                    status: .paused(progress: nil)
                                )
                            )
                        ],
                        hasLoadedMessages: true,
                        lastMessagePreviewText: asset.filename,
                        hasMoreHistory: false,
                        latestSyncedServerSequence: 9,
                        oldestLoadedServerSequence: 9,
                        serverLastReadSequence: 9,
                        serverUnreadCount: 0,
                        updatedAt: Date(timeIntervalSince1970: 1_701_000_010)
                    )
                ],
                selectedConversationID: conversationID,
                lastSummaryRefreshAt: Date(timeIntervalSince1970: 1_701_000_010),
                summarySyncToken: "snapshot-download",
                summaryNextCursor: nil,
                hasMoreConversationSummaries: false
            ),
            for: Self.user.id
        )
        let snapshot = BackgroundTransferSnapshot(
            sessionIdentifier: "tests.im.background.download",
            taskIdentifier: 41,
            kind: .download,
            state: .running,
            progress: FileTransferProgress(
                transferredBytes: 32,
                totalBytes: 128,
                resumedBytes: 0
            ),
            destinationURL: destinationURL
        )
        let monitor = AuthManagerBackgroundTransferMonitor(initialSnapshots: [snapshot])
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }
        let manager = makeManager(
            transport: transport,
            backgroundTransferMonitor: monitor,
            imConversationCache: IMConversationCacheHandler(cache)
        )

        await manager.login(email: Self.user.email, password: "password123")

        try await Self.waitUntil {
            await MainActor.run {
                guard
                    let message = manager.imConversationStore.conversations.first?.messages.first,
                    let localDownloadState = message.localDownloadState
                else {
                    return false
                }

                switch localDownloadState.status {
                case .downloading(let progress, let transfer):
                    return progress?.transferredBytes == 32
                        && progress?.totalBytes == 128
                        && transfer == IMMessageBackgroundTransferReference(
                            sessionIdentifier: snapshot.sessionIdentifier,
                            taskIdentifier: snapshot.taskIdentifier
                        )
                case .waitingForConnectivity, .paused, .downloaded, .failed:
                    return false
                }
            }
        }
    }


    @Test func cachedTransferSnapshotRestoresDownloadProjectionWithoutLiveBackgroundSnapshot() async throws {
        let conversationID = "downloaded-conversation-cache-only"
        let asset = IMMediaAsset(
            assetID: "asset-background-download-cache-only",
            kind: .file,
            mimeType: "application/pdf",
            byteSize: 256,
            filename: "restore.pdf"
        )
        let destinationURL = FileManager.default.temporaryDirectory
            .appending(path: "im-background-download-cached-\(UUID().uuidString).pdf")
        let transferSnapshot = IMTransferSnapshot(
            taskID: IMTransferTaskID(
                sessionIdentifier: "tests.im.cached.download",
                taskIdentifier: 52
            ),
            kind: .download,
            intent: .mediaDownload,
            state: .running(
                progress: IMMessageLocalDownloadProgressSnapshot(
                    transferredBytes: 96,
                    totalBytes: 256,
                    resumedBytes: 16
                )
            ),
            destinationURL: destinationURL
        )
        let cache = InMemoryIMConversationCache()
        await cache.seed(
            IMConversationCacheSnapshot(
                conversations: [
                    IMCachedConversationState(
                        id: conversationID,
                        title: "Cached Snapshot Download",
                        kind: .direct,
                        memberCount: 2,
                        memberUserIDs: [Self.user.id],
                        messages: [
                            IMCachedMessageState(
                                id: "download-message-cache-only",
                                conversationID: conversationID,
                                clientMessageID: nil,
                                serverMessageID: UUID().uuidString,
                                senderUserID: Self.user.id,
                                serverSequence: 12,
                                content: .file(asset),
                                direction: .incoming,
                                createdAt: Date(timeIntervalSince1970: 1_701_100_000),
                                deliveryState: .received,
                                transferTaskID: transferSnapshot.taskID,
                                localDownloadState: nil
                            )
                        ],
                        hasLoadedMessages: true,
                        lastMessagePreviewText: asset.filename,
                        hasMoreHistory: false,
                        latestSyncedServerSequence: 12,
                        oldestLoadedServerSequence: 12,
                        serverLastReadSequence: 12,
                        serverUnreadCount: 0,
                        updatedAt: Date(timeIntervalSince1970: 1_701_100_010)
                    )
                ],
                selectedConversationID: conversationID,
                lastSummaryRefreshAt: Date(timeIntervalSince1970: 1_701_100_010),
                summarySyncToken: "snapshot-download-cache-only",
                summaryNextCursor: nil,
                hasMoreConversationSummaries: false,
                transferSnapshots: [transferSnapshot]
            ),
            for: Self.user.id
        )
        let monitor = AuthManagerBackgroundTransferMonitor(initialSnapshots: [])
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
            }
        }
        let manager = makeManager(
            transport: transport,
            backgroundTransferMonitor: monitor,
            imConversationCache: IMConversationCacheHandler(cache)
        )

        await manager.login(email: Self.user.email, password: "password123")

        try await Self.waitUntil {
            await MainActor.run {
                guard
                    let message = manager.imConversationStore.conversations.first?.messages.first,
                    let localDownloadState = message.localDownloadState
                else {
                    return false
                }

                switch localDownloadState.status {
                case .downloading(let progress, let transfer):
                    return progress?.transferredBytes == 96
                        && progress?.totalBytes == 256
                        && progress?.resumedBytes == 16
                        && message.transferTaskID == transferSnapshot.taskID
                        && transfer == IMMessageBackgroundTransferReference(
                            sessionIdentifier: transferSnapshot.taskID.sessionIdentifier,
                            taskIdentifier: transferSnapshot.taskID.taskIdentifier
                        )
                case .waitingForConnectivity, .paused, .downloaded, .failed:
                    return false
                }
            }
        }
    }


    @Test func cancelQueuedIMTextMessageRemovesOfflineQueuedMessage() async throws {
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.authResponseBody())
            default:
                return try Self.defaultOrUnexpectedIMResponse(for: request)
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
                return try Self.defaultOrUnexpectedIMResponse(for: request)
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
                return try Self.defaultOrUnexpectedIMResponse(for: request)
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
                return try Self.defaultOrUnexpectedIMResponse(for: request)
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
                return try Self.defaultOrUnexpectedIMResponse(for: request)
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
                return try Self.defaultOrUnexpectedIMResponse(for: request)
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
                return try Self.defaultOrUnexpectedIMResponse(for: request)
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

}
