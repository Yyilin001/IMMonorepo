import Foundation

public actor SessionClient {
    public typealias RestoreResult = AuthSessionCoordinator.RestoreResult

    private let coordinator: AuthSessionCoordinator
    private let executor: AuthorizedRequestExecutor

    public init(
        network: NetworkEnvironment,
        tokenStore: KeychainStore = KeychainStore(),
        userCache: UserDefaultsSessionCache = UserDefaultsSessionCache()
    ) {
        self.init(
            httpClient: network.makeHTTPClient(),
            fileTransferClient: network.makeFileTransferClient(),
            streamingClient: network.makeStreamingClient(),
            tokenStore: TokenStoreHandler(tokenStore),
            userCache: UserSessionCacheHandler(userCache)
        )
    }

    public init<TokenStoreType: TokenStore, UserCacheType: UserSessionCache>(
        network: NetworkEnvironment,
        tokenStore: TokenStoreType,
        userCache: UserCacheType
    ) {
        self.init(
            httpClient: network.makeHTTPClient(),
            fileTransferClient: network.makeFileTransferClient(),
            streamingClient: network.makeStreamingClient(),
            tokenStore: TokenStoreHandler(tokenStore),
            userCache: UserSessionCacheHandler(userCache)
        )
    }

    public init(
        httpClient: HTTPClient,
        fileTransferClient: FileTransferClient? = nil,
        streamingClient: StreamingClient? = nil,
        tokenStore: KeychainStore = KeychainStore(),
        userCache: UserDefaultsSessionCache = UserDefaultsSessionCache()
    ) {
        self.init(
            httpClient: httpClient,
            fileTransferClient: fileTransferClient,
            streamingClient: streamingClient,
            tokenStore: TokenStoreHandler(tokenStore),
            userCache: UserSessionCacheHandler(userCache)
        )
    }

    public init<TokenStoreType: TokenStore, UserCacheType: UserSessionCache>(
        httpClient: HTTPClient,
        fileTransferClient: FileTransferClient? = nil,
        streamingClient: StreamingClient? = nil,
        tokenStore: TokenStoreType,
        userCache: UserCacheType
    ) {
        self.init(
            httpClient: httpClient,
            fileTransferClient: fileTransferClient,
            streamingClient: streamingClient,
            tokenStore: TokenStoreHandler(tokenStore),
            userCache: UserSessionCacheHandler(userCache)
        )
    }

    private init(
        httpClient: HTTPClient,
        fileTransferClient: FileTransferClient?,
        streamingClient: StreamingClient?,
        tokenStore: TokenStoreHandler,
        userCache: UserSessionCacheHandler
    ) {
        let resolvedFileTransferClient = fileTransferClient ?? FileTransferClient(
            baseURL: httpClient.baseURL,
            logger: httpClient.logger,
            coding: httpClient.coding
        )
        let resolvedStreamingClient = streamingClient ?? StreamingClient(
            baseURL: httpClient.baseURL,
            logger: httpClient.logger,
            coding: httpClient.coding
        )
        let coordinator = AuthSessionCoordinator(
            authAPI: AuthAPI(client: httpClient),
            tokenStore: tokenStore,
            userCache: userCache
        )

        self.coordinator = coordinator
        self.executor = AuthorizedRequestExecutor(
            httpClient: httpClient,
            fileTransferClient: resolvedFileTransferClient,
            streamingClient: resolvedStreamingClient,
            accessToken: { forceRefresh in
                try await coordinator.validAccessToken(forceRefresh: forceRefresh)
            }
        )
    }

    public func login(email: String, password: String, device: DeviceMetadataPayload?) async throws -> AuthUser {
        try await coordinator.login(email: email, password: password, device: device)
    }

    public func register(email: String, password: String, device: DeviceMetadataPayload?) async throws -> AuthUser {
        try await coordinator.register(email: email, password: password, device: device)
    }

    public func restoreSession() async -> RestoreResult {
        await coordinator.restoreSession()
    }

    public func fetchMe() async throws -> AuthUser {
        try await executor.execute(UserRequest.me)
    }

    public func fetchContacts() async throws -> [ContactResponseBody] {
        try await executor.execute(UserRequest.contacts)
    }

    public func addContact(email: String, remark: String? = nil) async throws -> ContactResponseBody {
        try await executor.execute(UserRequest.addContact(email: email, remark: remark))
    }

    public func updateContact(contactUserID: UUID, remark: String?) async throws -> ContactResponseBody {
        try await executor.execute(
            UserRequest.updateContact(contactUserID: contactUserID, remark: remark)
        )
    }

    public func deleteContact(contactUserID: UUID) async throws -> EmptyResponse {
        try await executor.execute(UserRequest.deleteContact(contactUserID: contactUserID))
    }

    public func fetchContactRequests(box: ContactRequestBox = .all) async throws -> [ContactRequestResponseBody] {
        try await executor.execute(UserRequest.contactRequests(box: box))
    }

    public func sendContactRequest(
        email: String,
        message: String? = nil,
        remark: String? = nil
    ) async throws -> ContactRequestResponseBody {
        try await executor.execute(
            UserRequest.sendContactRequest(
                email: email,
                message: message,
                remark: remark
            )
        )
    }

    public func acceptContactRequest(id requestID: UUID, remark: String? = nil) async throws -> ContactResponseBody {
        try await executor.execute(
            UserRequest.acceptContactRequest(
                id: requestID,
                remark: remark
            )
        )
    }

    public func declineContactRequest(id requestID: UUID) async throws -> ContactRequestResponseBody {
        try await executor.execute(UserRequest.declineContactRequest(id: requestID))
    }

    public func cancelContactRequest(id requestID: UUID) async throws -> ContactRequestResponseBody {
        try await executor.execute(UserRequest.cancelContactRequest(id: requestID))
    }

    public func fetchSessions() async throws -> [SessionSnapshot] {
        try await executor.execute(AuthRequest.sessions)
    }

    public func fetchIMConversationSummaries(
        cursor: String? = nil,
        limit: Int? = nil
    ) async throws -> IMConversationSummaryPageResponseBody {
        try await executor.execute(
            IMRequest.conversations(
                cursor: cursor,
                limit: limit
            )
        )
    }

    public func fetchIMConversationSummaryChanges(
        afterToken: String,
        cursor: String? = nil,
        limit: Int? = nil
    ) async throws -> IMConversationSummaryChangesResponseBody {
        try await executor.execute(
            IMRequest.conversationChanges(
                afterToken: afterToken,
                cursor: cursor,
                limit: limit
            )
        )
    }

    public func createIMConversation(
        kind: IMConversationKind,
        title: String?,
        memberEmails: [String]
    ) async throws -> IMConversationSummaryResponseBody {
        try await executor.execute(
            IMRequest.createConversation(
                kind: kind,
                title: title,
                memberEmails: memberEmails
            )
        )
    }

    public func fetchIMConversationMembers(
        conversationID: String
    ) async throws -> [IMConversationMemberResponseBody] {
        try await executor.execute(IMRequest.members(conversationID: conversationID))
    }

    public func addIMConversationMembers(
        conversationID: String,
        memberEmails: [String]
    ) async throws -> IMConversationSummaryResponseBody {
        try await executor.execute(
            IMRequest.addMembers(
                conversationID: conversationID,
                memberEmails: memberEmails
            )
        )
    }

    public func removeIMConversationMember(
        conversationID: String,
        memberUserID: UUID
    ) async throws -> IMConversationSummaryResponseBody {
        try await executor.execute(
            IMRequest.removeMember(
                conversationID: conversationID,
                memberUserID: memberUserID.uuidString
            )
        )
    }

    public func updateIMConversationMemberRole(
        conversationID: String,
        memberUserID: UUID,
        role: IMConversationMemberRole
    ) async throws -> IMConversationSummaryResponseBody {
        try await executor.execute(
            IMRequest.updateMemberRole(
                conversationID: conversationID,
                memberUserID: memberUserID.uuidString,
                role: role
            )
        )
    }

    public func updateIMConversationTitle(
        conversationID: String,
        title: String
    ) async throws -> IMConversationSummaryResponseBody {
        try await executor.execute(
            IMRequest.updateTitle(
                conversationID: conversationID,
                title: title
            )
        )
    }

    public func updateIMConversationPreferences(
        conversationID: String,
        isPinned: Bool? = nil,
        isMuted: Bool? = nil
    ) async throws -> IMConversationSummaryResponseBody {
        try await executor.execute(
            IMRequest.updatePreferences(
                conversationID: conversationID,
                isPinned: isPinned,
                isMuted: isMuted
            )
        )
    }

    public func updateIMConversationMetadata(
        conversationID: String,
        title: String? = nil,
        notice: String? = nil,
        avatarPreset: IMConversationAvatarPreset? = nil
    ) async throws -> IMConversationSummaryResponseBody {
        try await executor.execute(
            IMRequest.updateMetadata(
                conversationID: conversationID,
                title: title,
                notice: notice,
                avatarPreset: avatarPreset
            )
        )
    }

    public func fetchIMMessages(
        conversationID: String,
        beforeSequence: UInt64? = nil,
        limit: Int? = nil
    ) async throws -> [IMConversationMessageResponseBody] {
        try await executor.execute(
            IMRequest.messages(
                conversationID: conversationID,
                beforeSequence: beforeSequence,
                limit: limit
            )
        )
    }

    public func fetchIMMessagesSince(
        conversationID: String,
        afterSequence: UInt64,
        limit: Int? = nil
    ) async throws -> IMConversationMessagesSinceResponseBody {
        try await executor.execute(
            IMRequest.messagesSince(
                conversationID: conversationID,
                afterSequence: afterSequence,
                limit: limit
            )
        )
    }

    public func markIMConversationRead(
        conversationID: String,
        readSequence: UInt64
    ) async throws -> IMConversationReadResponseBody {
        try await executor.execute(
            IMRequest.markRead(
                conversationID: conversationID,
                readSequence: readSequence
            )
        )
    }

    public func leaveIMConversation(
        conversationID: String
    ) async throws -> EmptyResponse {
        try await executor.execute(IMRequest.leaveConversation(conversationID: conversationID))
    }

    public func recallIMMessage(
        conversationID: String,
        messageID: String
    ) async throws -> IMConversationMessageResponseBody {
        let response = try await executor.execute(
            IMRequest.recallMessage(conversationID: conversationID, messageID: messageID)
        )
        return IMConversationMessageResponseBody(
            id: response.id,
            conversationID: response.conversationID,
            senderUserID: response.senderUserID,
            clientMessageID: response.clientMessageID,
            serverSequence: response.serverSequence,
            content: response.content,
            createdAt: response.createdAt
        )
    }

    public func logoutCurrent() async throws -> EmptyResponse {
        try await executor.execute(AuthRequest.logoutCurrent)
    }

    public func logoutAll() async throws -> LogoutAllResponseBody {
        try await executor.execute(AuthRequest.logoutAll)
    }

    public func logout(sessionID: UUID) async throws -> EmptyResponse {
        try await executor.execute(AuthRequest.logout(sessionID))
    }

    public func upload<Request: UploadEndpoint>(_ request: Request) async throws -> Request.Response {
        try await executor.upload(request)
    }

    public func uploadWithProgress<Request: UploadEndpoint>(
        _ request: Request
    ) async throws -> FileTransferOperation<UploadTransferEvent<Request.Response>>
    where Request.Response: Sendable {
        try await executor.uploadWithProgress(request)
    }

    public func download<Request: DownloadEndpoint>(_ request: Request, to destinationURL: URL) async throws -> URL {
        try await executor.download(
            request,
            to: destinationURL
        )
    }

    public func downloadWithProgress<Request: DownloadEndpoint>(
        _ request: Request,
        to destinationURL: URL,
        resumeIfPossible: Bool = true
    ) async throws -> FileTransferOperation<DownloadTransferEvent> {
        try await executor.downloadWithProgress(
            request,
            to: destinationURL,
            resumeIfPossible: resumeIfPossible
        )
    }

    public func openStream<Request: StreamingEndpoint>(_ request: Request) async throws -> StreamingConnection {
        try await executor.openStream(request)
    }

    public func openIMConnection(
        configuration: IMTCPClientConfiguration
    ) async throws -> IMTCPConnection {
        try await openIMConnection(configuration: configuration, transport: NWIMTCPTransport())
    }

    public func openIMConnection<Transport: IMTCPTransport>(
        configuration: IMTCPClientConfiguration,
        transport: Transport
    ) async throws -> IMTCPConnection {
        let coordinator = self.coordinator
        let client = IMTCPClient(configuration: configuration, transport: transport) {
            try await coordinator.validAccessToken(forceRefresh: false)
        }
        return try await client.connect()
    }

    public func clearSession() async {
        await coordinator.clearSession()
    }

    public func shouldPreserveSession(for error: Error) async -> Bool {
        await coordinator.shouldPreserveSession(for: error)
    }

    public func shouldMarkServerOffline(for error: Error) async -> Bool {
        await coordinator.shouldMarkServerOffline(for: error)
    }
}
