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

    public func resendEmailVerification(email: String) async throws -> AuthChallengeResponseBody {
        try await coordinator.resendEmailVerification(email: email)
    }

    public func confirmEmailVerification(email: String, code: String) async throws -> AuthGenericResponseBody {
        try await coordinator.confirmEmailVerification(email: email, code: code)
    }

    public func requestPasswordReset(email: String) async throws -> AuthChallengeResponseBody {
        try await coordinator.requestPasswordReset(email: email)
    }

    public func confirmPasswordReset(email: String, code: String, newPassword: String) async throws -> AuthGenericResponseBody {
        try await coordinator.confirmPasswordReset(email: email, code: code, newPassword: newPassword)
    }

    public func restoreSession() async -> RestoreResult {
        await coordinator.restoreSession()
    }

    public func fetchMe() async throws -> AuthUser {
        let user = try await executor.execute(UserRequest.me)
        await coordinator.cacheUser(user)
        return user
    }

    public func updateMyProfile(
        displayName: String? = nil,
        avatarPreset: UserAvatarPreset? = nil
    ) async throws -> AuthUser {
        let user = try await executor.execute(
            UserRequest.updateProfile(
                displayName: displayName,
                avatarPreset: avatarPreset
            )
        )
        await coordinator.cacheUser(user)
        return user
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

    public func fetchBlocks() async throws -> [UserBlockResponseBody] {
        try await executor.execute(UserRequest.blocks)
    }

    public func blockUser(userID: UUID, reason: String? = nil) async throws -> UserBlockResponseBody {
        try await executor.execute(UserRequest.blockUser(userID: userID, reason: reason))
    }

    public func unblockUser(userID: UUID) async throws -> EmptyResponse {
        try await executor.execute(UserRequest.unblockUser(userID: userID))
    }

    public func createReport(
        targetType: String,
        targetID: String,
        conversationID: UUID? = nil,
        messageID: UUID? = nil,
        reason: String,
        detail: String? = nil
    ) async throws -> ReportResponseBody {
        try await executor.execute(
            UserRequest.createReport(
                targetType: targetType,
                targetID: targetID,
                conversationID: conversationID,
                messageID: messageID,
                reason: reason,
                detail: detail
            )
        )
    }

    public func fetchInternalReports(
        secret: String,
        status: String? = nil,
        targetType: String? = nil,
        cursor: String? = nil,
        limit: Int? = nil
    ) async throws -> ReportPageResponseBody {
        try await executor.execute(
            UserRequest.internalReports(
                secret: secret,
                status: status,
                targetType: targetType,
                cursor: cursor,
                limit: limit
            )
        )
    }

    public func updateInternalReport(
        secret: String,
        reportID: UUID,
        status: String,
        handledNote: String? = nil
    ) async throws -> ReportResponseBody {
        try await executor.execute(
            UserRequest.updateInternalReport(
                secret: secret,
                reportID: reportID,
                status: status,
                handledNote: handledNote
            )
        )
    }

    public func registerPushDeviceToken(platform: String = "ios", token: String) async throws -> PushDeviceTokenResponseBody {
        try await executor.execute(UserRequest.registerPushDeviceToken(platform: platform, token: token))
    }

    public func deletePushDeviceToken(tokenID: String) async throws -> EmptyResponse {
        try await executor.execute(UserRequest.deletePushDeviceToken(tokenID: tokenID))
    }

    public func fetchSessions() async throws -> [SessionSnapshot] {
        try await executor.execute(AuthRequest.sessions)
    }

    public func fetchIMConversationSummaries(
        cursor: String? = nil,
        limit: Int? = nil,
        kind: IMConversationKind? = nil
    ) async throws -> IMConversationSummaryPageResponseBody {
        try await executor.execute(
            IMRequest.conversations(
                cursor: cursor,
                limit: limit,
                kind: kind
            )
        )
    }

    public func fetchIMGroupConversationSummaries(
        cursor: String? = nil,
        limit: Int? = nil
    ) async throws -> IMConversationSummaryPageResponseBody {
        try await fetchIMConversationSummaries(
            cursor: cursor,
            limit: limit,
            kind: .group
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

    public struct IMDomainEventDeliveryEnvelope: Equatable, Sendable {
        public let cursor: UInt64
        public let eventID: UUID
        public let ownerAggregateSequence: UInt64
        public let eventPBBase64: String
        public let payload: IMTCPChatDomainEventPayload
    }

    public func fetchIMDomainEvents(
        after cursor: UInt64,
        limit: Int? = nil
    ) async throws -> (envelopes: [IMDomainEventDeliveryEnvelope], nextCursor: UInt64, hasMore: Bool) {
        let response = try await executor.execute(IMRequest.domainEventChanges(after: cursor, limit: limit))
        let envelopes = try response.items.map { item in
            guard item.cursor > 0, let data = Data(base64Encoded: item.eventPBBase64) else {
                throw APIError.decodingFailed("IM domain event payload is not valid base64.")
            }
            let payload = try IMTCPProtobufCodec.decodeDomainEvent(data)
            guard payload.ownerCursor == UInt64(item.cursor),
                  payload.ownerAggregateSequence == item.ownerAggregateSequence,
                  payload.eventID == item.eventID
            else {
                throw APIError.decodingFailed("IM domain event envelope metadata does not match payload metadata.")
            }
            return IMDomainEventDeliveryEnvelope(
                cursor: item.cursor,
                eventID: item.eventID,
                ownerAggregateSequence: item.ownerAggregateSequence,
                eventPBBase64: item.eventPBBase64,
                payload: payload
            )
        }
        return (envelopes, response.nextCursor, response.hasMore)
    }

    public func reportIMClientHealth(
        snapshot: IMConversationHealthSnapshot,
        reason: String,
        reportedAt: Date = Date()
    ) async throws {
        _ = try await executor.execute(
            IMRequest.reportClientHealth(
                IMClientHealthReportRequestBody(
                    snapshot: snapshot,
                    reason: reason,
                    reportedAt: reportedAt
                )
            )
        )
    }

    public func createIMConversation(
        kind: IMConversationKind,
        title: String?,
        memberEmails: [String]
    ) async throws -> IMConversationCommandReceiptBody {
        try await executor.execute(
            IMRequest.createConversation(
                kind: kind,
                title: title,
                memberEmails: memberEmails
            )
        )
    }

    public func fetchIMConversationMembers(
        conversationID: String,
        cursor: String? = nil,
        limit: Int? = nil,
        query: String? = nil
    ) async throws -> IMConversationMemberPageResponseBody {
        try await executor.execute(IMRequest.members(conversationID: conversationID, cursor: cursor, limit: limit, query: query))
    }

    public func addIMConversationMembers(
        conversationID: String,
        memberEmails: [String]
    ) async throws -> IMConversationCommandReceiptBody {
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
    ) async throws -> IMConversationCommandReceiptBody {
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
    ) async throws -> IMConversationCommandReceiptBody {
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
    ) async throws -> IMConversationCommandReceiptBody {
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
    ) async throws -> IMConversationCommandReceiptBody {
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
        avatarPreset: IMConversationAvatarPreset? = nil,
        muteAll: Bool? = nil
    ) async throws -> IMConversationCommandReceiptBody {
        try await executor.execute(
            IMRequest.updateMetadata(
                conversationID: conversationID,
                title: title,
                notice: notice,
                avatarPreset: avatarPreset,
                muteAll: muteAll
            )
        )
    }

    public func updateIMMyMemberProfile(
        conversationID: String,
        memberNickname: String?
    ) async throws -> IMConversationCommandReceiptBody {
        try await executor.execute(
            IMRequest.updateMyMemberProfile(conversationID: conversationID, memberNickname: memberNickname)
        )
    }

    public func fetchIMTimeline(
        conversationID: String,
        beforeSequence: UInt64? = nil,
        limit: Int? = nil
    ) async throws -> IMConversationTimelineResponseBody {
        try await executor.execute(
            IMRequest.timeline(
                conversationID: conversationID,
                beforeSequence: beforeSequence,
                limit: limit
            )
        )
    }

    public func fetchIMTimelineSince(
        conversationID: String,
        afterSequence: UInt64,
        targetSequence: UInt64? = nil,
        limit: Int? = nil
    ) async throws -> IMConversationTimelineResponseBody {
        try await executor.execute(
            IMRequest.timelineSince(
                conversationID: conversationID,
                afterSequence: afterSequence,
                targetSequence: targetSequence,
                limit: limit
            )
        )
    }

    public func startAIMessageStream(
        conversationID: String,
        prompt: String
    ) async throws -> IMMessageStreamResponseBody {
        try await executor.execute(
            IMRequest.startAIMessageStream(
                conversationID: conversationID,
                prompt: prompt
            )
        )
    }

    public func cancelMessageStream(
        conversationID: String,
        messageID: String
    ) async throws -> IMMessageStreamResponseBody {
        try await executor.execute(
            IMRequest.cancelMessageStream(
                conversationID: conversationID,
                messageID: messageID
            )
        )
    }

    public func fetchMessageStreamSnapshot(
        conversationID: String,
        messageID: String
    ) async throws -> IMMessageStreamResponseBody {
        try await executor.execute(
            IMRequest.messageStreamSnapshot(
                conversationID: conversationID,
                messageID: messageID
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

    public func forwardIMMessages(
        conversationID: String,
        messageIDs: [UUID],
        targetConversationIDs: [UUID]
    ) async throws -> [IMConversationMessageResponseBody] {
        try await executor.execute(
            IMRequest.forwardMessages(
                conversationID: conversationID,
                messageIDs: messageIDs,
                targetConversationIDs: targetConversationIDs
            )
        )
    }

    public func deleteIMMessagesForSelf(
        conversationID: String,
        messageIDs: [UUID]
    ) async throws -> EmptyResponse {
        try await executor.execute(
            IMRequest.deleteMessagesForSelf(
                conversationID: conversationID,
                messageIDs: messageIDs
            )
        )
    }

    public func favoriteIMMessage(
        conversationID: String,
        messageID: String
    ) async throws -> IMConversationMessageResponseBody {
        try await executor.execute(IMRequest.favoriteMessage(conversationID: conversationID, messageID: messageID))
    }

    public func unfavoriteIMMessage(
        conversationID: String,
        messageID: String
    ) async throws -> EmptyResponse {
        try await executor.execute(IMRequest.unfavoriteMessage(conversationID: conversationID, messageID: messageID))
    }

    public func fetchIMFavorites(
        conversationID: UUID? = nil,
        cursor: String? = nil,
        limit: Int? = nil
    ) async throws -> IMFavoritePageResponseBody {
        try await executor.execute(
            IMRequest.favorites(conversationID: conversationID, cursor: cursor, limit: limit)
        )
    }

    public func clearIMConversationForSelf(conversationID: String) async throws -> EmptyResponse {
        try await executor.execute(IMRequest.clearConversationForSelf(conversationID: conversationID))
    }

    public func deleteIMConversationForSelf(conversationID: String) async throws -> EmptyResponse {
        try await executor.execute(IMRequest.deleteConversationForSelf(conversationID: conversationID))
    }

    public func fetchIMConversationReceiptSummary(
        conversationID: String
    ) async throws -> IMConversationReceiptSummaryResponseBody {
        try await executor.execute(IMRequest.receiptSummary(conversationID: conversationID))
    }

    public func createIMGroupInvite(
        conversationID: String,
        expiresInSeconds: Int? = nil
    ) async throws -> IMGroupInviteResponseBody {
        try await executor.execute(
            IMRequest.createInvite(conversationID: conversationID, expiresInSeconds: expiresInSeconds)
        )
    }

    public func fetchIMGroupInvites(conversationID: String) async throws -> [IMGroupInviteResponseBody] {
        try await executor.execute(IMRequest.listInvites(conversationID: conversationID))
    }

    public func revokeIMGroupInvite(conversationID: String, token: String) async throws -> EmptyResponse {
        try await executor.execute(IMRequest.revokeInvite(conversationID: conversationID, token: token))
    }

    public func joinIMGroupInvite(token: String) async throws -> IMConversationCommandReceiptBody {
        try await executor.execute(IMRequest.joinInvite(token: token))
    }

    public func searchIMConversationMessages(
        conversationID: String,
        query: String,
        cursor: String? = nil,
        limit: Int? = nil
    ) async throws -> IMConversationMessageSearchPageResponseBody {
        try await executor.execute(
            IMRequest.searchMessages(
                conversationID: conversationID,
                query: query,
                cursor: cursor,
                limit: limit
            )
        )
    }

    public func createMediaUploadSession(
        kind: IMMediaAssetKind,
        mimeType: String,
        byteSize: Int64,
        filename: String,
        width: Int? = nil,
        height: Int? = nil,
        durationMillis: Int? = nil,
        previewAssetID: String? = nil
    ) async throws -> MediaUploadSessionResponseBody {
        try await executor.execute(
            MediaRequest.CreateUploadSession(
                payload: MediaUploadCreateRequestBody(
                    kind: kind,
                    mimeType: mimeType,
                    byteSize: byteSize,
                    filename: filename,
                    width: width,
                    height: height,
                    durationMillis: durationMillis,
                    previewAssetID: previewAssetID
                )
            )
        )
    }

    public func uploadMediaChunk(
        uploadID: String,
        uploadBody: UploadBody,
        backgroundTransfer: BackgroundTransferConfiguration? = nil
    ) async throws {
        _ = try await executor.upload(
            MediaRequest.UploadChunk(
                uploadID: uploadID,
                uploadBody: uploadBody,
                backgroundTransfer: backgroundTransfer
            )
        ) as EmptyResponse
    }

    public func completeMediaUpload(uploadID: String) async throws -> IMMediaAsset {
        try await executor.execute(MediaRequest.CompleteUpload(uploadID: uploadID))
    }

    public func downloadMediaAsset(
        assetID: String,
        to destinationURL: URL,
        backgroundTransfer: BackgroundTransferConfiguration? = nil
    ) async throws -> URL {
        try await executor.download(
            MediaRequest.DownloadAsset(
                assetID: assetID,
                backgroundTransfer: backgroundTransfer
            ),
            to: destinationURL
        )
    }

    public func downloadMediaAssetWithProgress(
        assetID: String,
        to destinationURL: URL,
        resumeIfPossible: Bool = true
    ) async throws -> FileTransferOperation<DownloadTransferEvent> {
        try await executor.downloadWithProgress(
            MediaRequest.DownloadAsset(assetID: assetID),
            to: destinationURL,
            resumeIfPossible: resumeIfPossible
        )
    }

    public func leaveIMConversation(
        conversationID: String
    ) async throws -> IMConversationCommandReceiptBody {
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
            timelineSequence: response.timelineSequence,
            content: response.content,
            derivedState: response.derivedState,
            createdAt: response.createdAt
        )
    }

    public func editIMMessage(
        conversationID: String,
        messageID: String,
        text: String
    ) async throws -> IMConversationMessageResponseBody {
        try await executor.execute(
            IMRequest.editMessage(conversationID: conversationID, messageID: messageID, body: .plain(text))
        )
    }

    public func toggleIMMessageReaction(
        conversationID: String,
        messageID: String,
        emoji: String
    ) async throws -> IMConversationMessageResponseBody {
        try await executor.execute(
            IMRequest.toggleMessageReaction(
                conversationID: conversationID,
                messageID: messageID,
                emoji: emoji
            )
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
