import Foundation
import Testing
@testable import IMClientKit

private actor RequestCounter {
    var refreshCount = 0

    func incrementRefresh() {
        refreshCount += 1
    }

    func currentRefreshCount() -> Int {
        refreshCount
    }
}

private actor RefreshGate {
    private var hasStarted = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var resumeContinuation: CheckedContinuation<Void, Never>?

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
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private struct ProgressUploadResponse: Codable, Equatable, Sendable, APIResponseBody {
    let message: String
}

private struct FileAPIUploadResponse: Codable, Equatable, Sendable, APIResponseBody {
    let message: String
}

private struct AuthorizedProgressUploadEndpointForSessionTests: AuthorizedUploadEndpoint {
    typealias Response = ProgressUploadResponse

    let baseRequestSpec = HTTPRequestSpec(path: "upload", method: .post)
    let uploadBody: UploadBody
}

struct SessionClientTests {
    private static let userID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let userEmail = "tester@example.com"

    @Test func refreshIsDeduplicatedAcrossConcurrentFetches() async throws {
        let tokenStore = InMemoryTokenStore()
        let userCache = InMemoryUserSessionCache()
        try tokenStore.save("refresh-1", for: "refresh_token")

        let counter = RequestCounter()
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/refresh"):
                await counter.incrementRefresh()
                let body = try Self.authResponseBody(accessToken: "access-2", refreshToken: "refresh-2")
                return HTTPFixtures.response(statusCode: 200, body: body)
            case ("GET", "/api/me"):
                let body = try Self.userBody()
                return HTTPFixtures.response(statusCode: 200, body: body)
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let httpClient = HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport)
        let client = SessionClient(
            httpClient: httpClient,
            tokenStore: tokenStore,
            userCache: userCache
        )

        async let first = client.fetchMe()
        async let second = client.fetchMe()

        let resolvedFirst = try await first
        let resolvedSecond = try await second

        let resolvedFirstID = await MainActor.run { resolvedFirst.id }
        let resolvedFirstEmail = await MainActor.run { resolvedFirst.email }
        let resolvedSecondID = await MainActor.run { resolvedSecond.id }
        let resolvedSecondEmail = await MainActor.run { resolvedSecond.email }
        #expect(resolvedFirstID == Self.userID)
        #expect(resolvedFirstEmail == Self.userEmail)
        #expect(resolvedSecondID == Self.userID)
        #expect(resolvedSecondEmail == Self.userEmail)
        #expect(await counter.currentRefreshCount() == 1)
        #expect(try tokenStore.readString(for: "refresh_token") == "refresh-2")
    }

    @Test func retriesProtectedRequestAfterUnauthorizedRefreshesToken() async throws {
        let tokenStore = InMemoryTokenStore()
        let userCache = InMemoryUserSessionCache()
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path, request.value(forHTTPHeaderField: "Authorization")) {
            case ("POST", "/api/auth/login", _):
                let body = try Self.authResponseBody(accessToken: "stale-token", refreshToken: "refresh-1")
                return HTTPFixtures.response(statusCode: 200, body: body)
            case ("GET", "/api/me", "Bearer stale-token"):
                let body = try HTTPFixtures.jsonBody(ErrorEnvelope(reason: "访问令牌已过期。"))
                return HTTPFixtures.response(statusCode: 401, body: body)
            case ("POST", "/api/auth/refresh", _):
                let body = try Self.authResponseBody(accessToken: "fresh-token", refreshToken: "refresh-2")
                return HTTPFixtures.response(statusCode: 200, body: body)
            case ("GET", "/api/me", "Bearer fresh-token"):
                let body = try Self.userBody()
                return HTTPFixtures.response(statusCode: 200, body: body)
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let httpClient = HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport)
        let client = SessionClient(
            httpClient: httpClient,
            tokenStore: tokenStore,
            userCache: userCache
        )

        let noDevice: DeviceMetadataPayload? = nil
        _ = try await client.login(email: Self.userEmail, password: "password123", device: noDevice)
        let fetchedUser = try await client.fetchMe()

        let fetchedUserID = await MainActor.run { fetchedUser.id }
        let fetchedUserEmail = await MainActor.run { fetchedUser.email }
        #expect(fetchedUserID == Self.userID)
        #expect(fetchedUserEmail == Self.userEmail)

        let requests = await transport.requests()
        let authorizations = requests
            .filter { $0.url?.path == "/api/me" }
            .compactMap { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(authorizations == ["Bearer stale-token", "Bearer fresh-token"])
        #expect(try tokenStore.readString(for: "refresh_token") == "refresh-2")
    }

    @Test func retriesAuthorizedUploadWithProgressAfterUnauthorizedRefreshesToken() async throws {
        let tokenStore = InMemoryTokenStore()
        let userCache = InMemoryUserSessionCache()

        let httpTransport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                let body = try Self.authResponseBody(accessToken: "stale-token", refreshToken: "refresh-1")
                return HTTPFixtures.response(statusCode: 200, body: body)
            case ("POST", "/api/auth/refresh"):
                let body = try Self.authResponseBody(accessToken: "fresh-token", refreshToken: "refresh-2")
                return HTTPFixtures.response(statusCode: 200, body: body)
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let uploadFileURL = FileManager.default.temporaryDirectory.appending(path: "session-upload-\(UUID().uuidString).txt")
        try Data("payload".utf8).write(to: uploadFileURL)
        defer { try? FileManager.default.removeItem(at: uploadFileURL) }

        let successBody = try HTTPFixtures.jsonBody(ProgressUploadResponse(message: "uploaded"))
        let unauthorizedBody = try HTTPFixtures.jsonBody(ErrorEnvelope(reason: "访问令牌已过期。"))
        let fileTransport = MockFileTransferTransport(
            uploadFileProgressHandler: { request, fileURL in
                #expect(fileURL == uploadFileURL)

                switch request.value(forHTTPHeaderField: "Authorization") {
                case "Bearer stale-token":
                    return AsyncThrowingStream { continuation in
                        continuation.yield(.progress(transferredBytes: 3, totalBytes: 7))
                        let response = HTTPURLResponse(
                            url: HTTPFixtures.baseURL,
                            statusCode: 401,
                            httpVersion: nil,
                            headerFields: nil
                        )!
                        continuation.yield(.completed(unauthorizedBody, response))
                        continuation.finish()
                    }
                case "Bearer fresh-token":
                    return AsyncThrowingStream { continuation in
                        continuation.yield(.progress(transferredBytes: 7, totalBytes: 7))
                        let response = HTTPURLResponse(
                            url: HTTPFixtures.baseURL,
                            statusCode: 200,
                            httpVersion: nil,
                            headerFields: nil
                        )!
                        continuation.yield(.completed(successBody, response))
                        continuation.finish()
                    }
                default:
                    return AsyncThrowingStream { continuation in
                        continuation.finish(throwing: APIError.unauthorized("缺少访问令牌，请重新登录。"))
                    }
                }
            }
        )

        let client = SessionClient(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: httpTransport),
            fileTransferClient: FileTransferClient(baseURL: HTTPFixtures.baseURL, transport: fileTransport),
            tokenStore: tokenStore,
            userCache: userCache
        )

        let noDevice: DeviceMetadataPayload? = nil
        _ = try await client.login(email: Self.userEmail, password: "password123", device: noDevice)

        let operation = try await client.uploadWithProgress(
            AuthorizedProgressUploadEndpointForSessionTests(
                uploadBody: .file(uploadFileURL, contentType: "text/plain")
            )
        )

        var progressSnapshots: [Int64] = []
        var completion: ProgressUploadResponse?
        for try await event in operation.events {
            switch event {
            case .progress(let progress):
                progressSnapshots.append(progress.transferredBytes)
            case .completed(let response):
                completion = response
            }
        }

        #expect(progressSnapshots == [3, 7])
        #expect(completion == ProgressUploadResponse(message: "uploaded"))
        #expect(try tokenStore.readString(for: "refresh_token") == "refresh-2")

        let requests = await fileTransport.requests()
        let authorizations = requests.compactMap { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(authorizations == ["Bearer stale-token", "Bearer fresh-token"])
    }

    @Test func downloadMediaAssetWithProgressUsesAuthorizedMediaEndpoint() async throws {
        let tokenStore = InMemoryTokenStore()
        let userCache = InMemoryUserSessionCache()
        let assetID = "asset-download-1"

        let httpTransport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                let body = try Self.authResponseBody(accessToken: "access-1", refreshToken: "refresh-1")
                return HTTPFixtures.response(statusCode: 200, body: body)
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let expectedData = Data("media-download".utf8)
        let fileTransport = MockFileTransferTransport(
            streamDownloadHandler: { request in
                #expect(request.url?.path == "/api/media/assets/\(assetID)")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")

                return (
                    HTTPByteStream(
                        bytes: AsyncThrowingStream { continuation in
                            for byte in expectedData {
                                continuation.yield(byte)
                            }
                            continuation.finish()
                        }
                    ),
                    HTTPURLResponse(
                        url: HTTPFixtures.baseURL.appending(path: "api/media/assets/\(assetID)"),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: [
                            "Content-Length": String(expectedData.count),
                            "ETag": "\"asset-download-v1\""
                        ]
                    )!
                )
            }
        )

        let client = SessionClient(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: httpTransport),
            fileTransferClient: FileTransferClient(baseURL: HTTPFixtures.baseURL, transport: fileTransport),
            tokenStore: tokenStore,
            userCache: userCache
        )

        let noDevice: DeviceMetadataPayload? = nil
        _ = try await client.login(email: Self.userEmail, password: "password123", device: noDevice)

        let destinationURL = FileManager.default.temporaryDirectory.appending(path: "media-download-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destinationURL) }

        let operation = try await client.downloadMediaAssetWithProgress(
            assetID: assetID,
            to: destinationURL
        )

        var completedURL: URL?
        for try await event in operation.events {
            if case .completed(let url) = event {
                completedURL = url
            }
        }

        #expect(completedURL == destinationURL)
        #expect(try Data(contentsOf: destinationURL) == expectedData)
    }

    @Test func fileAPIHonorsExplicitNeverRetryPolicyForAuthorizedUpload() async throws {
        let tokenStore = InMemoryTokenStore()
        let userCache = InMemoryUserSessionCache()

        let httpTransport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/login"):
                let body = try Self.authResponseBody(accessToken: "stale-token", refreshToken: "refresh-1")
                return HTTPFixtures.response(statusCode: 200, body: body)
            case ("POST", "/api/auth/refresh"):
                Issue.record("显式 never retry 时不应触发 refresh。")
                return HTTPFixtures.response(statusCode: 500)
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let unauthorizedBody = try HTTPFixtures.jsonBody(ErrorEnvelope(reason: "访问令牌已过期。"))
        let fileTransport = MockFileTransferTransport(
            uploadFileHandler: { request, _ in
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer stale-token")
                return HTTPFixtures.response(statusCode: 401, body: unauthorizedBody)
            }
        )

        let client = SessionClient(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: httpTransport),
            fileTransferClient: FileTransferClient(baseURL: HTTPFixtures.baseURL, transport: fileTransport),
            tokenStore: tokenStore,
            userCache: userCache
        )

        let noDevice: DeviceMetadataPayload? = nil
        _ = try await client.login(email: Self.userEmail, password: "password123", device: noDevice)

        let fileURL = FileManager.default.temporaryDirectory.appending(path: "file-api-never-\(UUID().uuidString).txt")
        try Data("payload".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let fileAPI = FileAPI(sessionClient: client)

        do {
            _ = try await fileAPI.upload(
                FileUploadRequest<FileAPIUploadResponse>(
                    path: "upload",
                    uploadBody: .file(fileURL, contentType: "text/plain"),
                    retryPolicy: .never
                )
            )
            Issue.record("预期抛出 unauthorized。")
        } catch let error as APIError {
            if case .unauthorized(let reason) = error {
                #expect(reason == "访问令牌已过期。")
            } else {
                Issue.record("收到错误类型不正确：\(error.localizedDescription)")
            }
        }

        let requests = await fileTransport.requests()
        let authorizations = requests.compactMap { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(authorizations == ["Bearer stale-token"])
        #expect(try tokenStore.readString(for: "refresh_token") == "refresh-1")
    }

    @Test func restoreSessionKeepsCachedUserWhenOffline() async throws {
        let result = await makeRestoreResult { _ in
            throw URLError(.notConnectedToInternet)
        }

        await assertSignedInOffline(result)
    }

    @Test func restoreSessionKeepsCachedUserWhenRateLimited() async throws {
        let result = await makeRestoreResult { _ in
            let body = try HTTPFixtures.jsonBody(ErrorEnvelope(reason: "请求过于频繁。"))
            return HTTPFixtures.response(
                statusCode: 429,
                headers: ["Retry-After": "30"],
                body: body
            )
        }

        await assertSignedInOffline(result)
    }

    @Test func restoreSessionKeepsCachedUserOnServerError() async throws {
        let result = await makeRestoreResult { _ in
            let body = try HTTPFixtures.jsonBody(ErrorEnvelope(reason: "服务器暂时繁忙。"))
            return HTTPFixtures.response(statusCode: 500, body: body)
        }

        await assertSignedInOffline(result)
    }

    @Test func restoreSessionSignsOutWhenForbidden() async throws {
        let result = await makeRestoreResult { _ in
            let body = try HTTPFixtures.jsonBody(ErrorEnvelope(reason: "当前设备已被撤销。"))
            return HTTPFixtures.response(statusCode: 403, body: body)
        }

        assertSignedOut(result)
    }

    @Test func restoreSessionSignsOutWhenValidationFails() async throws {
        let result = await makeRestoreResult { _ in
            let body = try HTTPFixtures.jsonBody(ErrorEnvelope(reason: "刷新请求参数无效。"))
            return HTTPFixtures.response(statusCode: 422, body: body)
        }

        assertSignedOut(result)
    }

    @Test func clearSessionPreventsInflightRefreshFromPersisting() async throws {
        let tokenStore = InMemoryTokenStore()
        let userCache = InMemoryUserSessionCache()
        try tokenStore.save("refresh-1", for: "refresh_token")
        userCache.save(AuthUser(id: Self.userID, email: Self.userEmail))

        let gate = RefreshGate()
        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/refresh"):
                await gate.markStarted()
                await gate.waitForResume()
                let body = try Self.authResponseBody(accessToken: "access-2", refreshToken: "refresh-2")
                return HTTPFixtures.response(statusCode: 200, body: body)
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let client = SessionClient(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: tokenStore,
            userCache: userCache
        )

        let fetchTask = Task {
            do {
                _ = try await client.fetchMe()
                Issue.record("清理 session 后，过期 refresh 不应让 fetchMe 成功。")
            } catch let error as APIError {
                if case .unauthorized(let reason) = error {
                    #expect(reason == "缺少访问令牌，请重新登录。")
                } else {
                    Issue.record("收到错误类型不正确：\(error.localizedDescription)")
                }
            } catch {
                Issue.record("收到未预期错误：\(error.localizedDescription)")
            }
        }

        await gate.waitUntilStarted()
        await client.clearSession()
        await gate.resume()
        await fetchTask.value

        #expect(try tokenStore.readString(for: "refresh_token") == nil)
        #expect(userCache.readUser() == nil)
    }

    @Test func fetchIMConversationsUsesAuthorizedEndpoint() async throws {
        let tokenStore = InMemoryTokenStore()
        let userCache = InMemoryUserSessionCache()

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path, request.value(forHTTPHeaderField: "Authorization")) {
            case ("POST", "/api/auth/login", _):
                let body = try Self.authResponseBody(accessToken: "access-1", refreshToken: "refresh-1")
                return HTTPFixtures.response(statusCode: 200, body: body)
            case ("GET", "/api/im/conversations", "Bearer access-1"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationsBody())
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let client = SessionClient(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: tokenStore,
            userCache: userCache
        )

        let noDevice: DeviceMetadataPayload? = nil
        _ = try await client.login(email: Self.userEmail, password: "password123", device: noDevice)
        let conversations = try await client.fetchIMConversations()

        #expect(conversations.count == 1)
        #expect(conversations[0].title == "Demo Chat")
        #expect(conversations[0].kind == IMConversationKind.group.rawValue)
        #expect(conversations[0].memberCount == 3)
        #expect(conversations[0].lastReadSequence == 7)
        #expect(conversations[0].unreadCount == 2)
        #expect(conversations[0].lastMessage?.body["text"] == "hello")
    }

    @Test func fetchIMConversationSummaryChangesUsesAuthorizedEndpoint() async throws {
        let tokenStore = InMemoryTokenStore()
        let userCache = InMemoryUserSessionCache()

        let transport = MockHTTPTransport { request in
            switch (
                request.httpMethod,
                request.url?.path,
                request.url?.query,
                request.value(forHTTPHeaderField: "Authorization")
            ) {
            case ("POST", "/api/auth/login", _, _):
                let body = try Self.authResponseBody(accessToken: "access-1", refreshToken: "refresh-1")
                return HTTPFixtures.response(statusCode: 200, body: body)
            case (
                "GET",
                "/api/im/conversations/changes",
                "afterToken=token-1&cursor=cursor-1&limit=25",
                "Bearer access-1"
            ):
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationChangesBody())
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let client = SessionClient(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: tokenStore,
            userCache: userCache
        )

        let noDevice: DeviceMetadataPayload? = nil
        _ = try await client.login(email: Self.userEmail, password: "password123", device: noDevice)
        let changes = try await client.fetchIMConversationSummaryChanges(
            afterToken: "token-1",
            cursor: "cursor-1",
            limit: 25
        )

        #expect(changes.upserts.count == 1)
        #expect(changes.upserts[0].title == "Demo Chat")
        #expect(changes.removedConversationIDs == [UUID(uuidString: "ffffffff-1111-2222-3333-eeeeeeeeeeee")!])
        #expect(changes.nextCursor == "cursor-2")
        #expect(changes.hasMore == true)
        #expect(changes.targetToken == "token-2")
    }

    @Test func createIMConversationUsesAuthorizedEndpoint() async throws {
        let tokenStore = InMemoryTokenStore()
        let userCache = InMemoryUserSessionCache()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path, request.value(forHTTPHeaderField: "Authorization")) {
            case ("POST", "/api/auth/login", _):
                let body = try Self.authResponseBody(accessToken: "access-1", refreshToken: "refresh-1")
                return HTTPFixtures.response(statusCode: 200, body: body)
            case ("POST", "/api/im/conversations", "Bearer access-1"):
                #expect(
                    request.value(forHTTPHeaderField: "Accept")
                        == "application/vnd.im.conversation-command-receipt+json"
                )
                let body = request.httpBody ?? Data()
                let payload = try JSONDecoder().decode(IMConversationCreateRequestBody.self, from: body)
                #expect(payload.kind == IMConversationKind.group.rawValue)
                #expect(payload.title == "Demo Chat")
                #expect(payload.memberEmails == ["peer@example.com"])
                return HTTPFixtures.response(
                    statusCode: 202,
                    body: try HTTPFixtures.jsonBody(
                        IMConversationCommandReceiptBody(
                            conversationID: conversationID,
                            eventID: UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd"),
                            eventType: "membership_added",
                            acceptedAt: Date(timeIntervalSince1970: 1_700_000_000),
                            membershipRevision: Date(timeIntervalSince1970: 1_700_000_000),
                            didMutate: true,
                            projectionPending: true
                        )
                    )
                )
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let client = SessionClient(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: tokenStore,
            userCache: userCache
        )

        let noDevice: DeviceMetadataPayload? = nil
        _ = try await client.login(email: Self.userEmail, password: "password123", device: noDevice)
        let receipt = try await client.createIMConversation(
            kind: .group,
            title: "Demo Chat",
            memberEmails: ["peer@example.com"]
        )

        #expect(receipt.conversationID == conversationID)
        #expect(receipt.eventID == UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd"))
        #expect(receipt.eventType == "membership_added")
        #expect(receipt.didMutate)
        #expect(receipt.projectionPending)
    }

    @Test func addIMConversationMembersUsesAuthorizedEndpoint() async throws {
        let tokenStore = InMemoryTokenStore()
        let userCache = InMemoryUserSessionCache()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path, request.value(forHTTPHeaderField: "Authorization")) {
            case ("POST", "/api/auth/login", _):
                let body = try Self.authResponseBody(accessToken: "access-1", refreshToken: "refresh-1")
                return HTTPFixtures.response(statusCode: 200, body: body)
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/members", "Bearer access-1"):
                #expect(
                    request.value(forHTTPHeaderField: "Accept")
                        == "application/vnd.im.conversation-command-receipt+json"
                )
                let body = request.httpBody ?? Data()
                let payload = try JSONDecoder().decode(IMConversationMemberUpdateRequestBody.self, from: body)
                #expect(payload.memberEmails == ["peer@example.com", "new@example.com"])
                return HTTPFixtures.response(
                    statusCode: 202,
                    body: try HTTPFixtures.jsonBody(
                        IMConversationCommandReceiptBody(
                            conversationID: conversationID,
                            eventID: UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd"),
                            eventType: "membership_added",
                            acceptedAt: Date(timeIntervalSince1970: 1_700_000_000),
                            membershipRevision: Date(timeIntervalSince1970: 1_700_000_000),
                            didMutate: true,
                            projectionPending: true
                        )
                    )
                )
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let client = SessionClient(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: tokenStore,
            userCache: userCache
        )

        let noDevice: DeviceMetadataPayload? = nil
        _ = try await client.login(email: Self.userEmail, password: "password123", device: noDevice)
        let receipt = try await client.addIMConversationMembers(
            conversationID: conversationID.uuidString,
            memberEmails: ["peer@example.com", "new@example.com"]
        )

        #expect(receipt.conversationID == conversationID)
        #expect(receipt.eventType == "membership_added")
        #expect(receipt.projectionPending)
    }

    @Test func leaveIMConversationUsesAuthorizedEndpoint() async throws {
        let tokenStore = InMemoryTokenStore()
        let userCache = InMemoryUserSessionCache()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path, request.value(forHTTPHeaderField: "Authorization")) {
            case ("POST", "/api/auth/login", _):
                let body = try Self.authResponseBody(accessToken: "access-1", refreshToken: "refresh-1")
                return HTTPFixtures.response(statusCode: 200, body: body)
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/leave", "Bearer access-1"):
                #expect(
                    request.value(forHTTPHeaderField: "Accept")
                        == "application/vnd.im.conversation-command-receipt+json"
                )
                return HTTPFixtures.response(
                    statusCode: 202,
                    body: try HTTPFixtures.jsonBody(
                        IMConversationCommandReceiptBody(
                            conversationID: conversationID,
                            eventID: UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd"),
                            eventType: "membership_removed",
                            acceptedAt: Date(timeIntervalSince1970: 1_700_000_000),
                            membershipRevision: Date(timeIntervalSince1970: 1_700_000_000),
                            didMutate: true,
                            projectionPending: true
                        )
                    )
                )
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let client = SessionClient(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: tokenStore,
            userCache: userCache
        )

        let noDevice: DeviceMetadataPayload? = nil
        _ = try await client.login(email: Self.userEmail, password: "password123", device: noDevice)
        _ = try await client.leaveIMConversation(conversationID: conversationID.uuidString)
    }

    @Test func joinIMGroupInviteUsesCommandReceiptEndpoint() async throws {
        let tokenStore = InMemoryTokenStore()
        let userCache = InMemoryUserSessionCache()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let inviteToken = "group-invite-token"

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path, request.value(forHTTPHeaderField: "Authorization")) {
            case ("POST", "/api/auth/login", _):
                let body = try Self.authResponseBody(accessToken: "access-1", refreshToken: "refresh-1")
                return HTTPFixtures.response(statusCode: 200, body: body)
            case ("POST", "/api/im/invites/\(inviteToken)/join", "Bearer access-1"):
                #expect(
                    request.value(forHTTPHeaderField: "Accept")
                        == "application/vnd.im.conversation-command-receipt+json"
                )
                return HTTPFixtures.response(
                    statusCode: 202,
                    body: try HTTPFixtures.jsonBody(
                        IMConversationCommandReceiptBody(
                            conversationID: conversationID,
                            eventID: UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd"),
                            eventType: "membership_added",
                            acceptedAt: Date(timeIntervalSince1970: 1_700_000_000),
                            membershipRevision: Date(timeIntervalSince1970: 1_700_000_000),
                            didMutate: true,
                            projectionPending: true
                        )
                    )
                )
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let client = SessionClient(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: tokenStore,
            userCache: userCache
        )
        let noDevice: DeviceMetadataPayload? = nil
        _ = try await client.login(email: Self.userEmail, password: "password123", device: noDevice)
        let receipt = try await client.joinIMGroupInvite(token: inviteToken)

        #expect(receipt.conversationID == conversationID)
        #expect(receipt.eventType == "membership_added")
        #expect(receipt.projectionPending)
    }

    @Test func fetchContactRequestsUsesAuthorizedEndpoint() async throws {
        let tokenStore = InMemoryTokenStore()
        let userCache = InMemoryUserSessionCache()

        let transport = MockHTTPTransport { request in
            switch (
                request.httpMethod,
                request.url?.path,
                request.url?.query,
                request.value(forHTTPHeaderField: "Authorization")
            ) {
            case ("POST", "/api/auth/login", _, _):
                let body = try Self.authResponseBody(accessToken: "access-1", refreshToken: "refresh-1")
                return HTTPFixtures.response(statusCode: 200, body: body)
            case ("GET", "/api/contact-requests", "box=all", "Bearer access-1"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.contactRequestsBody())
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let client = SessionClient(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: tokenStore,
            userCache: userCache
        )

        let noDevice: DeviceMetadataPayload? = nil
        _ = try await client.login(email: Self.userEmail, password: "password123", device: noDevice)
        let requests = try await client.fetchContactRequests(box: .all)

        #expect(requests.count == 1)
        #expect(requests[0].status == .pending)
        #expect(requests[0].requester.email == Self.userEmail)
        #expect(requests[0].addressee.email == "peer@example.com")
    }

    @Test func contactRequestMutationsUseAuthorizedEndpoints() async throws {
        let tokenStore = InMemoryTokenStore()
        let userCache = InMemoryUserSessionCache()
        let requestID = UUID(uuidString: "dddddddd-1111-2222-3333-eeeeeeeeeeee")!

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path, request.value(forHTTPHeaderField: "Authorization")) {
            case ("POST", "/api/auth/login", _):
                let body = try Self.authResponseBody(accessToken: "access-1", refreshToken: "refresh-1")
                return HTTPFixtures.response(statusCode: 200, body: body)
            case ("POST", "/api/contact-requests", "Bearer access-1"):
                let body = request.httpBody ?? Data()
                let payload = try JSONDecoder().decode(ContactRequestCreateRequestBody.self, from: body)
                #expect(payload.email == "peer@example.com")
                #expect(payload.message == "hello")
                #expect(payload.remark == "peer")
                return HTTPFixtures.response(statusCode: 200, body: try Self.contactRequestBody(id: requestID))
            case ("POST", "/api/contact-requests/\(requestID.uuidString)/accept", "Bearer access-1"):
                let body = request.httpBody ?? Data()
                let payload = try JSONDecoder().decode(ContactRequestAcceptRequestBody.self, from: body)
                #expect(payload.remark == "accepted peer")
                return HTTPFixtures.response(statusCode: 200, body: try Self.contactBody())
            case ("POST", "/api/contact-requests/\(requestID.uuidString)/decline", "Bearer access-1"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.contactRequestBody(id: requestID, status: .declined))
            case ("POST", "/api/contact-requests/\(requestID.uuidString)/cancel", "Bearer access-1"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.contactRequestBody(id: requestID, status: .cancelled))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let client = SessionClient(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: tokenStore,
            userCache: userCache
        )

        let noDevice: DeviceMetadataPayload? = nil
        _ = try await client.login(email: Self.userEmail, password: "password123", device: noDevice)

        let sent = try await client.sendContactRequest(email: "peer@example.com", message: "hello", remark: "peer")
        #expect(sent.id == requestID)

        let acceptedContact = try await client.acceptContactRequest(id: requestID, remark: "accepted peer")
        #expect(acceptedContact.email == "peer@example.com")

        let declined = try await client.declineContactRequest(id: requestID)
        #expect(declined.status == ContactRequestStatus.declined)

        let cancelled = try await client.cancelContactRequest(id: requestID)
        #expect(cancelled.status == ContactRequestStatus.cancelled)
    }

    @Test func fetchIMConversationMembersUsesAuthorizedEndpoint() async throws {
        let tokenStore = InMemoryTokenStore()
        let userCache = InMemoryUserSessionCache()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path, request.value(forHTTPHeaderField: "Authorization")) {
            case ("POST", "/api/auth/login", _):
                let body = try Self.authResponseBody(accessToken: "access-1", refreshToken: "refresh-1")
                return HTTPFixtures.response(statusCode: 200, body: body)
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/members", "Bearer access-1"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.imConversationMembersBody())
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let client = SessionClient(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: tokenStore,
            userCache: userCache
        )

        let noDevice: DeviceMetadataPayload? = nil
        _ = try await client.login(email: Self.userEmail, password: "password123", device: noDevice)
        let members = try await client.fetchIMConversationMembers(conversationID: conversationID.uuidString)

        #expect(members.items.map(\.email) == ["peer@example.com", Self.userEmail])
        #expect(members.total == 2)
        #expect(members.nextCursor == nil)
    }

    @Test func fetchIMTimelineUsesConversationTimelineEndpoint() async throws {
        let tokenStore = InMemoryTokenStore()
        let userCache = InMemoryUserSessionCache()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!

        let transport = MockHTTPTransport { request in
            switch (request.httpMethod, request.url?.path, request.value(forHTTPHeaderField: "Authorization")) {
            case ("POST", "/api/auth/login", _):
                let body = try Self.authResponseBody(accessToken: "access-1", refreshToken: "refresh-1")
                return HTTPFixtures.response(statusCode: 200, body: body)
            case ("GET", "/api/im/conversations/\(conversationID.uuidString)/timeline", "Bearer access-1"):
                return HTTPFixtures.response(statusCode: 200, body: try Self.imTimelineBody(conversationID: conversationID))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let client = SessionClient(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: tokenStore,
            userCache: userCache
        )

        let noDevice: DeviceMetadataPayload? = nil
        _ = try await client.login(email: Self.userEmail, password: "password123", device: noDevice)
        let response = try await client.fetchIMTimeline(conversationID: conversationID.uuidString)
        let messages = response.items.compactMap(\.message)

        #expect(messages.count == 2)
        #expect(messages.map(\.serverSequence) == [1, 2])
        #expect(messages.map(\.clientMessageID) == ["client-history-1", "client-history-2"])
        #expect(messages.map { $0.body["text"] } == ["first", "second"])
    }

    @Test func fetchIMTimelinePaginationUsesQueryItems() async throws {
        let tokenStore = InMemoryTokenStore()
        let userCache = InMemoryUserSessionCache()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!

        let transport = MockHTTPTransport { request in
            switch (
                request.httpMethod,
                request.url?.path,
                request.url?.query,
                request.value(forHTTPHeaderField: "Authorization")
            ) {
            case ("POST", "/api/auth/login", _, _):
                let body = try Self.authResponseBody(accessToken: "access-1", refreshToken: "refresh-1")
                return HTTPFixtures.response(statusCode: 200, body: body)
            case (
                "GET",
                "/api/im/conversations/\(conversationID.uuidString)/timeline",
                "beforeSequence=3&limit=2",
                "Bearer access-1"
            ):
                return HTTPFixtures.response(statusCode: 200, body: try Self.imTimelineBody(conversationID: conversationID))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let client = SessionClient(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: tokenStore,
            userCache: userCache
        )

        let noDevice: DeviceMetadataPayload? = nil
        _ = try await client.login(email: Self.userEmail, password: "password123", device: noDevice)
        let response = try await client.fetchIMTimeline(
            conversationID: conversationID.uuidString,
            beforeSequence: 3,
            limit: 2
        )
        let messages = response.items.compactMap(\.message)

        #expect(messages.count == 2)
        #expect(messages.map(\.serverSequence) == [1, 2])
    }

    @Test func fetchIMTimelineSinceUsesIncrementalEndpoint() async throws {
        let tokenStore = InMemoryTokenStore()
        let userCache = InMemoryUserSessionCache()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!

        let transport = MockHTTPTransport { request in
            switch (
                request.httpMethod,
                request.url?.path,
                request.url?.query,
                request.value(forHTTPHeaderField: "Authorization")
            ) {
            case ("POST", "/api/auth/login", _, _):
                let body = try Self.authResponseBody(accessToken: "access-1", refreshToken: "refresh-1")
                return HTTPFixtures.response(statusCode: 200, body: body)
            case (
                "GET",
                "/api/im/conversations/\(conversationID.uuidString)/timeline/since",
                "afterSequence=2&limit=50",
                "Bearer access-1"
            ):
                return HTTPFixtures.response(statusCode: 200, body: try Self.imTimelineBody(conversationID: conversationID))
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let client = SessionClient(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: tokenStore,
            userCache: userCache
        )

        let noDevice: DeviceMetadataPayload? = nil
        _ = try await client.login(email: Self.userEmail, password: "password123", device: noDevice)
        let response = try await client.fetchIMTimelineSince(
            conversationID: conversationID.uuidString,
            afterSequence: 2,
            limit: 50
        )
        let messages = response.items.compactMap(\.message)

        #expect(messages.count == 2)
        #expect(messages.map(\.serverSequence) == [1, 2])
        #expect(messages.map(\.clientMessageID) == ["client-history-1", "client-history-2"])
        #expect(response.hasMore == false)
        #expect(response.nextAfterSequence == 2)
    }

    @Test func markIMConversationReadUsesAuthorizedEndpoint() async throws {
        let tokenStore = InMemoryTokenStore()
        let userCache = InMemoryUserSessionCache()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!

        let transport = MockHTTPTransport { request in
            switch (
                request.httpMethod,
                request.url?.path,
                request.value(forHTTPHeaderField: "Authorization")
            ) {
            case ("POST", "/api/auth/login", _):
                let body = try Self.authResponseBody(accessToken: "access-1", refreshToken: "refresh-1")
                return HTTPFixtures.response(statusCode: 200, body: body)
            case ("POST", "/api/im/conversations/\(conversationID.uuidString)/read", "Bearer access-1"):
                let body = request.httpBody ?? Data()
                let payload = try JSONDecoder().decode(IMConversationReadRequestBody.self, from: body)
                #expect(payload.readSequence == 9)
                return HTTPFixtures.response(
                    statusCode: 200,
                    body: try HTTPFixtures.jsonBody(
                        IMConversationReadResponseBody(
                            conversationID: conversationID,
                            lastReadSequence: 9,
                            unreadCount: 0
                        )
                    )
                )
            default:
                Issue.record("收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
                return HTTPFixtures.response(statusCode: 500)
            }
        }

        let client = SessionClient(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: tokenStore,
            userCache: userCache
        )

        let noDevice: DeviceMetadataPayload? = nil
        _ = try await client.login(email: Self.userEmail, password: "password123", device: noDevice)
        let response = try await client.markIMConversationRead(
            conversationID: conversationID.uuidString,
            readSequence: 9
        )
        #expect(response.conversationID == conversationID)
        #expect(response.lastReadSequence == 9)
        #expect(response.unreadCount == 0)
    }

    private func makeRestoreResult(
        refreshHandler: @escaping MockHTTPTransport.Handler
    ) async -> SessionClient.RestoreResult {
        let tokenStore = InMemoryTokenStore()
        let userCache = InMemoryUserSessionCache()
        try? tokenStore.save("refresh-1", for: "refresh_token")
        let cachedUser = await MainActor.run { AuthUser(id: Self.userID, email: Self.userEmail) }
        userCache.save(cachedUser)

        let transport = MockHTTPTransport { request in
            if request.httpMethod == "POST", request.url?.path == "/api/auth/refresh" {
                return try await refreshHandler(request)
            }

            Issue.record("restoreSession 期间收到未预期请求：\(request.httpMethod ?? "-") \(request.url?.absoluteString ?? "-")")
            return HTTPFixtures.response(statusCode: 500)
        }

        let client = SessionClient(
            httpClient: HTTPClient(baseURL: HTTPFixtures.baseURL, transport: transport),
            tokenStore: tokenStore,
            userCache: userCache
        )

        return await client.restoreSession()
    }

    private func assertSignedInOffline(_ result: SessionClient.RestoreResult) async {
        switch result {
        case .signedInOffline(let restoredUser, let message):
            let restoredUserID = await MainActor.run { restoredUser.id }
            let restoredUserEmail = await MainActor.run { restoredUser.email }
            #expect(restoredUserID == Self.userID)
            #expect(restoredUserEmail == Self.userEmail)
            #expect(!message.isEmpty)
        default:
            Issue.record("预期为 signedInOffline，实际得到其他状态。")
        }
    }

    private func assertSignedOut(_ result: SessionClient.RestoreResult) {
        guard case .signedOut = result else {
            Issue.record("预期为 signedOut，实际得到其他状态。")
            return
        }
    }

    private static func userBody() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "id": userID.uuidString,
                "email": userEmail
            ]
        )
    }

    private static func authResponseBody(accessToken: String, refreshToken: String) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "accessToken": accessToken,
                "expiresIn": 600,
                "refreshToken": refreshToken,
                "refreshExpiresIn": 30 * 24 * 60 * 60,
                "user": [
                    "id": userID.uuidString,
                    "email": userEmail
                ]
            ]
        )
    }

    private static func imConversationsBody() throws -> Data {
        try HTTPFixtures.jsonBody(
            IMConversationSummaryPageResponseBody(
                items: [
                    imConversation(
                        id: UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
                    )
                ],
                nextCursor: nil,
                hasMore: false,
                snapshotToken: "token-1"
            )
        )
    }

    private static func imConversationBody(conversationID: UUID) throws -> Data {
        try HTTPFixtures.jsonBody(imConversation(id: conversationID))
    }

    private static func imConversationChangesBody() throws -> Data {
        try HTTPFixtures.jsonBody(
            IMConversationSummaryChangesResponseBody(
                upserts: [
                    imConversation(id: UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!)
                ],
                removedConversationIDs: [UUID(uuidString: "ffffffff-1111-2222-3333-eeeeeeeeeeee")!],
                nextCursor: "cursor-2",
                hasMore: true,
                targetToken: "token-2"
            )
        )
    }

    private static func imTimelineBody(conversationID: UUID) throws -> Data {
        try HTTPFixtures.jsonBody(
            IMConversationTimelineResponseBody(
                items: [
                    IMTimelineItemResponseBody(
                        type: .message,
                        timelineSequence: 1,
                        message: IMConversationMessageResponseBody(
                            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                            conversationID: conversationID,
                            senderUserID: userID,
                            clientMessageID: "client-history-1",
                            serverSequence: 1,
                            timelineSequence: 1,
                            kind: "rich_text",
                            body: ["text": "first"],
                            createdAt: Date(timeIntervalSince1970: 1_700_200_000)
                        ),
                        notice: nil
                    ),
                    IMTimelineItemResponseBody(
                        type: .message,
                        timelineSequence: 2,
                        message: IMConversationMessageResponseBody(
                            id: UUID(uuidString: "66666666-7777-8888-9999-aaaaaaaaaaaa")!,
                            conversationID: conversationID,
                            senderUserID: userID,
                            clientMessageID: "client-history-2",
                            serverSequence: 2,
                            timelineSequence: 2,
                            kind: "rich_text",
                            body: ["text": "second"],
                            createdAt: Date(timeIntervalSince1970: 1_700_200_100)
                        ),
                        notice: nil
                    )
                ],
                hasMore: false,
                nextAfterSequence: 2
            )
        )
    }

    private static func imConversationMembersBody() throws -> Data {
        try HTTPFixtures.jsonBody(
            IMConversationMemberPageResponseBody(
                items: [
                    IMConversationMemberResponseBody(
                        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                        email: "peer@example.com"
                    ),
                    IMConversationMemberResponseBody(
                        id: userID,
                        email: userEmail
                    )
                ],
                nextCursor: nil,
                total: 2,
                limit: 50
            )
        )
    }

    private static func contactRequestsBody() throws -> Data {
        try HTTPFixtures.jsonBody(
            [
                contactRequest(id: UUID(uuidString: "dddddddd-1111-2222-3333-eeeeeeeeeeee")!)
            ]
        )
    }

    private static func contactRequestBody(
        id: UUID,
        status: ContactRequestStatus = .pending
    ) throws -> Data {
        try HTTPFixtures.jsonBody(contactRequest(id: id, status: status))
    }

    private static func contactBody() throws -> Data {
        try HTTPFixtures.jsonBody(
            ContactResponseBody(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                email: "peer@example.com",
                remark: "accepted peer",
                createdAt: Date(timeIntervalSince1970: 1_700_200_000)
            )
        )
    }

    private static func contactRequest(
        id: UUID,
        status: ContactRequestStatus = .pending
    ) -> ContactRequestResponseBody {
        ContactRequestResponseBody(
            id: id,
            requester: AuthUser(id: userID, email: userEmail),
            addressee: AuthUser(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                email: "peer@example.com"
            ),
            status: status,
            message: "hello",
            requesterRemark: "peer",
            addresseeRemark: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_200_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_200_000),
            respondedAt: nil
        )
    }

    private static func imConversation(id: UUID) -> IMConversationSummaryResponseBody {
        IMConversationSummaryResponseBody(
            id: id,
            title: "Demo Chat",
            kind: IMConversationKind.group.rawValue,
            memberCount: 3,
            memberUserIDs: [userID],
            lastMessage: IMMessagePreviewResponseBody(
                id: UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!,
                senderUserID: userID,
                serverSequence: 2,
                kind: "rich_text",
                body: ["text": "hello"],
                createdAt: Date(timeIntervalSince1970: 1_700_200_000)
            ),
            lastReadSequence: 7,
            unreadCount: 2,
            createdAt: Date(timeIntervalSince1970: 1_700_100_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_200_000)
        )
    }
}
