import Combine
import Foundation
import IMClientKit
import SwiftUI
import UIKit

@MainActor
final class AuthManager: ObservableObject {
    private enum IMHistoryPage {
        static let latestLimit = 40
        static let gapSyncLimit = 100
        static let gapSyncMaxIterations = 10
        static let readReportDebounceNanoseconds: UInt64 = 250_000_000
        static let refreshDebounceNanoseconds: UInt64 = 400_000_000
        static let cachePersistDebounceNanoseconds: UInt64 = 300_000_000
        static let minimumRefreshInterval: TimeInterval = 5
    }

    enum Phase: Equatable {
        case launching
        case signedOut(message: String?)
        case signedIn(AuthUser)
    }

    private enum AuthAction {
        case login
        case register
    }

    enum ServerStatus: Equatable {
        case unknown
        case online
        case offline(message: String)
    }

    enum IMConnectionStatus: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(message: String)
    }

    @Published private(set) var phase: Phase = .launching
    @Published private(set) var isBusy = false
    @Published private(set) var sessions: [SessionSnapshot] = []
    @Published private(set) var isLoadingSessions = false
    @Published private(set) var sessionsMessage: String?
    @Published private(set) var contacts: [ContactResponseBody] = []
    @Published private(set) var isLoadingContacts = false
    @Published private(set) var contactsMessage: String?
    @Published private(set) var incomingContactRequests: [ContactRequestResponseBody] = []
    @Published private(set) var outgoingContactRequests: [ContactRequestResponseBody] = []
    @Published private(set) var isLoadingContactRequests = false
    @Published private(set) var contactRequestsMessage: String?
    @Published private(set) var serverStatus: ServerStatus = .unknown
    @Published private(set) var imConnectionStatus: IMConnectionStatus = .disconnected

    private let sessionClient: SessionClient
    private let openIMConnection: @Sendable () async throws -> IMTCPConnection
    private let imConversationCache: IMConversationCacheHandler
    private var restoreTask: Task<Void, Never>?
    private var restoreGeneration: UInt64 = 0
    private var imConnection: IMTCPConnection?
    private var imConnectionConnectTask: Task<Void, Never>?
    private var imConnectionEventTask: Task<Void, Never>?
    private var imConnectionGeneration: UInt64 = 0
    private var imConversationListTask: Task<Void, Never>?
    private var imConversationMembersTask: Task<Void, Never>?
    private var imConversationMessagesTask: Task<Void, Never>?
    private var imConversationRefreshTask: Task<Void, Never>?
    private var imConversationCachePersistTask: Task<Void, Never>?
    private var imConversationReadReportTasks: [String: Task<Void, Never>] = [:]
    private var pendingIMConversationReadSequences: [String: UInt64] = [:]
    private var lastIMConversationSummaryRefreshAt: Date?
    let probeManager: ProbeManager
    let fileTransferManager: FileTransferManager
    let imConversationStore: IMConversationStore

    convenience init(
        network: NetworkEnvironment = NetworkEnvironment(),
        tokenStore: KeychainStore = KeychainStore(),
        userCache: UserDefaultsSessionCache = UserDefaultsSessionCache(),
        backgroundTransferMonitor: any BackgroundTransferMonitoring = BackgroundTransferCoordinator.shared,
        imConversationCache: IMConversationCacheHandler = SwiftDataIMConversationCache.makeDefaultHandler(),
        shouldRestoreSession: Bool = true
    ) {
        let sessionClient = SessionClient(
            network: network,
            tokenStore: tokenStore,
            userCache: userCache
        )
        self.init(
            sessionClient: sessionClient,
            openIMConnection: {
                try await sessionClient.openIMConnection()
            },
            backgroundTransferMonitor: backgroundTransferMonitor,
            imConversationCache: imConversationCache,
            shouldRestoreSession: shouldRestoreSession
        )
    }

    convenience init<TokenStoreType: TokenStore, UserCacheType: UserSessionCache>(
        httpClient: HTTPClient,
        tokenStore: TokenStoreType,
        userCache: UserCacheType,
        openIMConnection: (@Sendable () async throws -> IMTCPConnection)? = nil,
        backgroundTransferMonitor: any BackgroundTransferMonitoring = BackgroundTransferCoordinator.shared,
        imConversationCache: IMConversationCacheHandler = IMConversationCacheHandler(NoopIMConversationCache()),
        shouldRestoreSession: Bool = true
    ) {
        let sessionClient = SessionClient(
            httpClient: httpClient,
            tokenStore: tokenStore,
            userCache: userCache
        )
        self.init(
            sessionClient: sessionClient,
            openIMConnection: openIMConnection ?? {
                try await sessionClient.openIMConnection()
            },
            backgroundTransferMonitor: backgroundTransferMonitor,
            imConversationCache: imConversationCache,
            shouldRestoreSession: shouldRestoreSession
        )
    }

    private init(
        sessionClient: SessionClient,
        openIMConnection: @escaping @Sendable () async throws -> IMTCPConnection,
        backgroundTransferMonitor: any BackgroundTransferMonitoring,
        imConversationCache: IMConversationCacheHandler,
        shouldRestoreSession: Bool
    ) {
        self.sessionClient = sessionClient
        self.openIMConnection = openIMConnection
        self.imConversationCache = imConversationCache
        self.probeManager = ProbeManager(sessionClient: sessionClient)
        self.fileTransferManager = FileTransferManager(
            fileAPI: FileAPI(sessionClient: sessionClient),
            sessionClient: sessionClient,
            backgroundTransferMonitor: backgroundTransferMonitor
        )
        self.imConversationStore = IMConversationStore()
        self.probeManager.delegate = self
        self.fileTransferManager.delegate = self

        if shouldRestoreSession {
            scheduleRestoreSession()
        } else {
            phase = .signedOut(message: nil)
        }
    }

    func login(email: String, password: String) async {
        invalidateRestoreSession()
        await disconnectIMConnection()
        await authenticate(
            action: .login,
            email: email,
            password: password
        )
    }

    func register(email: String, password: String) async {
        invalidateRestoreSession()
        await disconnectIMConnection()
        await authenticate(
            action: .register,
            email: email,
            password: password
        )
    }

    func logout() async {
        invalidateRestoreSession()
        do {
            _ = try await sessionClient.logoutCurrent()
        } catch {
            // Ignore remote logout failures and clear local state anyway.
        }

        await clearSession(message: nil)
    }

    func logoutAllSessions() async {
        invalidateRestoreSession()
        do {
            let result = try await sessionClient.logoutAll()
            await clearSession(message: "已退出 \(result.revokedSessions) 台设备。")
        } catch {
            if await shouldPreserveSession(for: error) {
                await markServerUnavailableIfNeeded(for: error)
            } else {
                await clearSession(message: error.localizedDescription)
            }
        }
    }

    func reloadProfile() async {
        invalidateRestoreSession()
        do {
            let user = try await sessionClient.fetchMe()
            markServerOnline()
            applySignedInState(user)
        } catch {
            if await shouldPreserveSession(for: error) {
                await markServerUnavailableIfNeeded(for: error)
            } else {
                await clearSession(message: error.localizedDescription)
            }
        }
    }

    func loadSessions() async {
        invalidateRestoreSession()
        guard case .signedIn = phase else {
            sessions = []
            return
        }

        isLoadingSessions = true
        defer { isLoadingSessions = false }

        do {
            let response = try await sessionClient.fetchSessions()
            markServerOnline()
            sessions = response
            sessionsMessage = nil
        } catch {
            sessionsMessage = error.localizedDescription
            if await shouldPreserveSession(for: error) {
                await markServerUnavailableIfNeeded(for: error)
            } else {
                await clearSession(message: error.localizedDescription)
            }
        }
    }

    func reloadContacts() async {
        guard let user = currentUser else {
            contacts = []
            return
        }

        isLoadingContacts = true
        defer { isLoadingContacts = false }

        do {
            let response = try await sessionClient.fetchContacts()
            guard currentUser?.id == user.id else {
                return
            }

            markServerOnline()
            contacts = response.sorted { $0.email < $1.email }
            contactsMessage = nil
        } catch {
            await handleContactRequestError(error)
        }
    }

    func addContact(email: String, remark: String? = nil) async -> Bool {
        await sendContactRequest(email: email, message: nil, remark: remark)
    }

    func reloadContactRequests() async {
        guard let user = currentUser else {
            incomingContactRequests = []
            outgoingContactRequests = []
            return
        }

        isLoadingContactRequests = true
        defer { isLoadingContactRequests = false }

        do {
            let response = try await sessionClient.fetchContactRequests(box: .all)
            guard currentUser?.id == user.id else {
                return
            }

            markServerOnline()
            replaceContactRequests(response, currentUserID: user.id)
            contactRequestsMessage = nil
        } catch {
            await handleContactRequestsError(error)
        }
    }

    func sendContactRequest(email: String, message: String? = nil, remark: String? = nil) async -> Bool {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedMessage = normalizedContactRequestMessage(message)
        let normalizedRemark = normalizedContactRemark(remark)
        guard !normalizedEmail.isEmpty else {
            contactRequestsMessage = "好友邮箱不能为空。"
            return false
        }

        do {
            let request = try await sessionClient.sendContactRequest(
                email: normalizedEmail,
                message: normalizedMessage,
                remark: normalizedRemark
            )
            markServerOnline()
            upsertContactRequest(request)
            contactRequestsMessage = "好友申请已发送。"
            return true
        } catch {
            await handleContactRequestsError(error)
            return false
        }
    }

    func acceptContactRequest(id requestID: UUID, remark: String? = nil) async -> Bool {
        do {
            let contact = try await sessionClient.acceptContactRequest(
                id: requestID,
                remark: normalizedContactRemark(remark)
            )
            markServerOnline()
            upsertContact(contact)
            incomingContactRequests.removeAll { $0.id == requestID }
            contactRequestsMessage = "已添加好友。"
            await reloadContacts()
            return true
        } catch {
            await handleContactRequestsError(error)
            return false
        }
    }

    func declineContactRequest(id requestID: UUID) async -> Bool {
        do {
            _ = try await sessionClient.declineContactRequest(id: requestID)
            markServerOnline()
            incomingContactRequests.removeAll { $0.id == requestID }
            contactRequestsMessage = "已拒绝好友申请。"
            return true
        } catch {
            await handleContactRequestsError(error)
            return false
        }
    }

    func cancelContactRequest(id requestID: UUID) async -> Bool {
        do {
            _ = try await sessionClient.cancelContactRequest(id: requestID)
            markServerOnline()
            outgoingContactRequests.removeAll { $0.id == requestID }
            contactRequestsMessage = "好友申请已取消。"
            return true
        } catch {
            await handleContactRequestsError(error)
            return false
        }
    }

    func updateContactRemark(contactUserID: UUID, remark: String) async -> Bool {
        do {
            let contact = try await sessionClient.updateContact(
                contactUserID: contactUserID,
                remark: normalizedContactRemark(remark)
            )
            markServerOnline()
            upsertContact(contact)
            contactsMessage = "联系人备注已更新。"
            return true
        } catch {
            await handleContactRequestError(error)
            return false
        }
    }

    func deleteContact(_ contactUserID: UUID) async -> Bool {
        do {
            _ = try await sessionClient.deleteContact(contactUserID: contactUserID)
            markServerOnline()
            contacts.removeAll { $0.id == contactUserID }
            contactsMessage = "已删除联系人。"
            return true
        } catch {
            await handleContactRequestError(error)
            return false
        }
    }

    func signOutCurrentDevice() async {
        invalidateRestoreSession()
        guard !isBusy else {
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            _ = try await sessionClient.logoutCurrent()
            await clearSession(message: nil)
        } catch {
            if await shouldPreserveSession(for: error) {
                await markServerUnavailableIfNeeded(for: error)
            }
            sessionsMessage = error.localizedDescription
        }
    }

    func signOut(sessionID: UUID, isCurrent: Bool) async {
        invalidateRestoreSession()
        guard !isBusy else {
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            _ = try await sessionClient.logout(sessionID: sessionID)
            markServerOnline()
            if isCurrent {
                await clearSession(message: nil)
            } else {
                sessions.removeAll { $0.id == sessionID }
                sessionsMessage = "已退出指定设备。"
            }
        } catch {
            sessionsMessage = error.localizedDescription
            if await shouldPreserveSession(for: error) {
                await markServerUnavailableIfNeeded(for: error)
            } else {
                await clearSession(message: error.localizedDescription)
            }
        }
    }

    func restoreSession() async {
        switch await sessionClient.restoreSession() {
        case .signedOut:
            phase = .signedOut(message: nil)
        case .signedIn(let user):
            markServerOnline()
            sessionsMessage = nil
            applySignedInState(user)
        case .signedInOffline(let user, let message):
            applySignedInState(user)
            markServerOfflineMessage(message)
        }
    }

    func reconnectIMConnection() async {
        guard case .signedIn = phase else {
            return
        }

        await disconnectIMConnection()
        scheduleIMConnectionIfNeeded()
    }

    func reloadIMConversations(force: Bool = true) async {
        guard let user = currentUser else {
            return
        }

        let didRefresh = await reconcileIMConversationSummaryReadModel(force: force)
        guard didRefresh,
              currentUser?.id == user.id,
              let selectedConversationID = imConversationStore.selectedConversationID ?? imConversationStore.conversations.first?.id
        else {
            return
        }

        imConversationStore.openConversation(id: selectedConversationID)
        scheduleIMConversationCachePersist()
        await loadIMConversationMembers(for: selectedConversationID)
        await loadIMMessagesIfNeeded(for: selectedConversationID)
        await markIMConversationReadUpToLatestLoadedSequence(for: selectedConversationID)
    }

    func openIMConversation(_ conversationID: String) async {
        guard let user = currentUser else {
            return
        }

        imConversationStore.openConversation(id: conversationID)
        scheduleIMConversationCachePersist()
        await loadIMConversationMembers(for: conversationID)
        await loadIMMessagesIfNeeded(for: conversationID)
        let didSyncGap = await syncIMConversationGap(for: conversationID, currentUserID: user.id)
        if didSyncGap {
            await markIMConversationReadUpToLatestLoadedSequence(for: conversationID)
        }
    }

    func createIMConversation(kind: IMConversationKind, title: String, memberEmails: [String]) async -> Bool {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEmails = Array(
            Set(memberEmails.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.filter { !$0.isEmpty })
        ).sorted()

        guard !normalizedEmails.isEmpty else {
            imConversationStore.setStatusMessage("至少需要填写一个成员邮箱。")
            return false
        }

        do {
            let conversation = try await sessionClient.createIMConversation(
                kind: kind,
                title: normalizedTitle.isEmpty ? nil : normalizedTitle,
                memberEmails: normalizedEmails
            )
            markServerOnline()
            applyIMConversationSummaryReadModel([conversation])
            scheduleIMConversationCachePersist()
            await openIMConversation(conversation.id.uuidString)
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }

    func createDirectIMConversation(memberEmail: String) async -> String? {
        let normalizedEmail = memberEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedEmail.isEmpty else {
            imConversationStore.setStatusMessage("联系人邮箱不能为空。")
            return nil
        }

        do {
            let conversation = try await sessionClient.createIMConversation(
                kind: .direct,
                title: nil,
                memberEmails: [normalizedEmail]
            )
            markServerOnline()
            applyIMConversationSummaryReadModel([conversation])
            scheduleIMConversationCachePersist()
            let conversationID = conversation.id.uuidString
            await openIMConversation(conversationID)
            return conversationID
        } catch {
            await handleIMDataRequestError(error)
            return nil
        }
    }

    func addIMConversationMembers(
        to conversationID: String,
        memberEmails: [String]
    ) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEmails = Array(
            Set(memberEmails.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.filter { !$0.isEmpty })
        ).sorted()

        guard !trimmedConversationID.isEmpty else {
            imConversationStore.setStatusMessage("会话 ID 无效。")
            return false
        }

        guard !normalizedEmails.isEmpty else {
            imConversationStore.setStatusMessage("至少需要填写一个成员邮箱。")
            return false
        }

        do {
            let conversation = try await sessionClient.addIMConversationMembers(
                conversationID: trimmedConversationID,
                memberEmails: normalizedEmails
            )
            markServerOnline()
            applyIMConversationSummaryReadModel([conversation])
            await loadIMConversationMembers(for: trimmedConversationID)
            scheduleIMConversationCachePersist()
            return true
        } catch {
            scheduleIMConversationSummaryReadModelCorrection(force: true)
            await handleIMDataRequestError(error)
            return false
        }
    }

    func leaveIMConversation(_ conversationID: String) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            imConversationStore.setStatusMessage("会话 ID 无效。")
            return false
        }

        do {
            _ = try await sessionClient.leaveIMConversation(conversationID: trimmedConversationID)
            markServerOnline()
            imConversationStore.removeConversation(id: trimmedConversationID)
            scheduleIMConversationCachePersist()
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }

    func refreshIMConversationSummaryReadModelIfNeeded() async {
        _ = await reconcileIMConversationSummaryReadModel(force: false)
    }

    func loadOlderIMMessages() async {
        guard let user = currentUser,
              let conversationID = imConversationStore.selectedConversationID,
              imConversationStore.canLoadOlderMessages(for: conversationID),
              let beforeSequence = imConversationStore.oldestLoadedServerSequence(for: conversationID)
        else {
            return
        }

        await loadIMMessagesPage(
            for: conversationID,
            currentUserID: user.id,
            beforeSequence: beforeSequence,
            mergeMode: .prepend
        )
    }

    func appDidBecomeActive() async {
        guard case .signedIn = phase else {
            return
        }

        if imConnection == nil, imConnectionConnectTask == nil {
            scheduleIMConnectionIfNeeded()
        }

        await refreshIMConversationSummaryReadModelIfNeeded()
    }

    func appDidEnterBackground() async {
        await flushIMConversationCache()
    }

    func sendIMText(_ text: String, to conversationID: String) async -> Bool {
        guard case .signedIn(let user) = phase else {
            return false
        }

        guard let request = imConversationStore.prepareOutgoingText(
            text,
            conversationID: conversationID,
            senderUserID: user.id
        ) else {
            return false
        }
        scheduleIMConversationCachePersist()

        guard let connection = imConnection else {
            imConversationStore.markOutgoingFailure(
                requestID: request.requestID,
                message: "IM 长连接未建立，消息没有发送出去。"
            )
            scheduleIMConversationCachePersist()
            scheduleIMConnectionIfNeeded()
            return false
        }

        let generation = imConnectionGeneration

        do {
            try await connection.sendMessage(request.payload, requestID: request.requestID)
            return true
        } catch {
            imConversationStore.markOutgoingFailure(
                requestID: request.requestID,
                message: error.localizedDescription
            )
            scheduleIMConversationCachePersist()
            await handleIMConnectionFailure(error, generation: generation)
            return false
        }
    }

    private func scheduleRestoreSession() {
        let generation = restoreGeneration
        restoreTask = Task { [weak self] in
            guard let self else {
                return
            }

            let result = await self.sessionClient.restoreSession()
            await self.applyRestoreResult(result, generation: generation)
        }
    }

    private func invalidateRestoreSession() {
        restoreGeneration &+= 1
        restoreTask?.cancel()
        restoreTask = nil
    }

    private func applyRestoreResult(
        _ result: SessionClient.RestoreResult,
        generation: UInt64
    ) async {
        guard generation == restoreGeneration, !Task.isCancelled else {
            return
        }

        restoreTask = nil

        switch result {
        case .signedOut:
            phase = .signedOut(message: nil)
        case .signedIn(let user):
            markServerOnline()
            sessionsMessage = nil
            applySignedInState(user)
        case .signedInOffline(let user, let message):
            applySignedInState(user)
            markServerOfflineMessage(message)
        }
    }

    static var preview: AuthManager {
        let manager = AuthManager(shouldRestoreSession: false)
        manager.phase = .signedOut(message: "Preview mode")
        return manager
    }

    var currentUser: AuthUser? {
        guard case .signedIn(let user) = phase else {
            return nil
        }
        return user
    }

    private func authenticate(action: AuthAction, email: String, password: String) async {
        guard !isBusy else {
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let device = Self.deviceMetadata()
            let user: AuthUser

            switch action {
            case .login:
                user = try await sessionClient.login(email: email, password: password, device: device)
            case .register:
                user = try await sessionClient.register(email: email, password: password, device: device)
            }

            markServerOnline()
            sessionsMessage = nil
            applySignedInState(user)
        } catch {
            if await shouldPreserveSession(for: error) {
                await markServerUnavailableIfNeeded(for: error)
            }
            phase = .signedOut(message: error.localizedDescription)
        }
    }

    private func clearSession(message: String?) async {
        let signedOutUserID = currentUser?.id
        imConversationListTask?.cancel()
        imConversationListTask = nil
        imConversationMembersTask?.cancel()
        imConversationMembersTask = nil
        imConversationMessagesTask?.cancel()
        imConversationMessagesTask = nil
        imConversationRefreshTask?.cancel()
        imConversationRefreshTask = nil
        imConversationCachePersistTask?.cancel()
        imConversationCachePersistTask = nil
        for task in imConversationReadReportTasks.values {
            task.cancel()
        }
        imConversationReadReportTasks = [:]
        pendingIMConversationReadSequences = [:]
        lastIMConversationSummaryRefreshAt = nil
        await disconnectIMConnection(flushCache: false)
        probeManager.stopAllForSignedOut()
        fileTransferManager.stopAllForSignedOut()
        await sessionClient.clearSession()
        if let signedOutUserID {
            try? await imConversationCache.clearSnapshot(for: signedOutUserID)
        } else {
            try? await imConversationCache.clearAll()
        }
        imConversationStore.reset()
        sessions = []
        sessionsMessage = nil
        contacts = []
        contactsMessage = nil
        isLoadingContacts = false
        incomingContactRequests = []
        outgoingContactRequests = []
        contactRequestsMessage = nil
        isLoadingContactRequests = false
        serverStatus = .unknown
        imConnectionStatus = .disconnected
        phase = .signedOut(message: message)
    }

    private func applySignedInState(_ user: AuthUser) {
        phase = .signedIn(user)
        scheduleIMConnectionIfNeeded()
        scheduleIMConversationBootstrap(for: user)
        Task { [weak self] in
            await self?.reloadContacts()
            await self?.reloadContactRequests()
        }
    }

    private func scheduleIMConnectionIfNeeded() {
        guard case .signedIn = phase else {
            return
        }

        guard imConnection == nil, imConnectionConnectTask == nil else {
            return
        }

        let generation = imConnectionGeneration
        imConnectionStatus = .connecting
        imConnectionConnectTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let connection = try await self.openIMConnection()
                await self.applyIMConnection(connection, generation: generation)
            } catch {
                await self.handleIMConnectionFailure(error, generation: generation)
            }
        }
    }

    private func applyIMConnection(_ connection: IMTCPConnection, generation: UInt64) async {
        guard generation == imConnectionGeneration else {
            await connection.disconnect()
            return
        }

        guard case .signedIn = phase else {
            await connection.disconnect()
            return
        }

        imConnectionConnectTask = nil
        imConnection = connection
        imConnectionStatus = .connected
        startIMConnectionEventLoop(connection, generation: generation)
        await syncIMConversationGapsAfterConnection()
        scheduleIMConversationCachePersist()
    }

    private func startIMConnectionEventLoop(_ connection: IMTCPConnection, generation: UInt64) {
        imConnectionEventTask?.cancel()
        imConnectionEventTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                for try await event in connection.events {
                    await self.handleIMConnectionEvent(event, generation: generation)
                }

                await self.handleIMConnectionFailure(
                    IMTCPClientError.connectionClosed,
                    generation: generation
                )
            } catch {
                await self.handleIMConnectionFailure(error, generation: generation)
            }
        }
    }

    private func handleIMConnectionEvent(_ event: IMTCPConnectionEvent, generation: UInt64) async {
        guard generation == imConnectionGeneration else {
            return
        }

        switch event {
        case .heartbeatAck:
            return
        case .ack(let requestID, let payload):
            imConversationStore.applyOutgoingAcknowledgement(requestID: requestID, payload: payload)
            scheduleIMConversationCachePersist()
        case .message(let requestID, let payload):
            guard let currentUserID = currentUser?.id else {
                return
            }

            imConversationStore.receiveIncomingMessage(payload, currentUserID: currentUserID)
            scheduleIMConversationCachePersist()

            if let messageID = payload.messageID, let connection = imConnection {
                do {
                    try await connection.sendAcknowledgement(
                        IMTCPAckPayload(
                            messageID: messageID,
                            conversationID: payload.conversationID,
                            status: "received"
                        ),
                        requestID: requestID
                    )
                } catch {
                    await handleIMConnectionFailure(error, generation: generation)
                    return
                }
            }

            guard payload.senderUserID != currentUserID,
                  payload.conversationID == imConversationStore.selectedConversationID,
                  let readSequence = payload.serverSequence
            else {
                return
            }

            await markIMConversationRead(
                conversationID: payload.conversationID,
                readSequence: readSequence
            )
        case .conversationEvent(_, let payload):
            guard let currentUserID = currentUser?.id else {
                return
            }

            let outcome = imConversationStore.applyConversationEvent(payload, currentUserID: currentUserID)
            if let conversationID = outcome.shouldReloadMembersForConversationID,
               imConversationStore.conversations.contains(where: { $0.id == conversationID }) {
                await loadIMConversationMembers(for: conversationID)
            }
            scheduleIMConversationCachePersist()
        case .kick(let payload):
            await clearSession(message: payload.message)
        }
    }

    private func handleIMConnectionFailure(_ error: Error, generation: UInt64) async {
        guard generation == imConnectionGeneration else {
            return
        }

        imConnectionConnectTask = nil
        imConnectionEventTask = nil
        imConnection = nil

        if error is CancellationError {
            imConnectionStatus = .disconnected
            return
        }

        if let tcpError = error as? IMTCPClientError {
            switch tcpError {
            case .authRejected(_, let message):
                await clearSession(message: message)
            case .kicked(_, let message):
                await clearSession(message: message)
            case .connectionClosed:
                imConversationStore.markAllPendingMessagesFailed(message: "IM 连接已断开。")
                imConnectionStatus = .failed(message: "IM 连接已断开。")
                scheduleIMConversationCachePersist()
            default:
                imConversationStore.markAllPendingMessagesFailed(message: tcpError.localizedDescription)
                imConnectionStatus = .failed(message: tcpError.localizedDescription)
                scheduleIMConversationCachePersist()
            }
            return
        }

        imConversationStore.markAllPendingMessagesFailed(message: error.localizedDescription)
        imConnectionStatus = .failed(message: error.localizedDescription)
        scheduleIMConversationCachePersist()
    }

    private func disconnectIMConnection(flushCache: Bool = true) async {
        imConnectionGeneration &+= 1

        let connection = imConnection
        imConnection = nil

        let connectTask = imConnectionConnectTask
        imConnectionConnectTask = nil
        connectTask?.cancel()

        let eventTask = imConnectionEventTask
        imConnectionEventTask = nil
        eventTask?.cancel()

        if let connection {
            await connection.disconnect()
        }

        imConnectionStatus = .disconnected

        if flushCache {
            await flushIMConversationCache()
        }
    }

    private func scheduleIMConversationBootstrap(for user: AuthUser) {
        imConversationListTask?.cancel()
        imConversationListTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                self.imConversationListTask = nil
            }
            await self.restoreIMConversationCacheIfAvailable(for: user)
            await self.reloadIMConversations(force: true)
        }
    }

    private func restoreIMConversationCacheIfAvailable(for user: AuthUser) async {
        do {
            let snapshot = try await imConversationCache.loadSnapshot(for: user.id)
            guard currentUser?.id == user.id else {
                return
            }

            guard !snapshot.conversations.isEmpty else {
                return
            }

            imConversationStore.restoreCacheSnapshot(snapshot)
            lastIMConversationSummaryRefreshAt = snapshot.lastSummaryRefreshAt
        } catch {
            // Ignore cache restore failures and continue with network bootstrap.
        }
    }

    private func scheduleIMConversationCachePersist() {
        guard currentUser != nil else {
            return
        }

        imConversationCachePersistTask?.cancel()
        imConversationCachePersistTask = Task { [weak self] in
            guard let self else {
                return
            }

            try? await Task.sleep(nanoseconds: IMHistoryPage.cachePersistDebounceNanoseconds)

            guard !Task.isCancelled else {
                return
            }

            await self.flushIMConversationCache()
        }
    }

    private func flushIMConversationCache() async {
        let task = imConversationCachePersistTask
        imConversationCachePersistTask = nil
        task?.cancel()

        guard let user = currentUser else {
            return
        }

        let snapshot = imConversationStore.makeCacheSnapshot(
            lastSummaryRefreshAt: lastIMConversationSummaryRefreshAt
        )
        try? await imConversationCache.saveSnapshot(snapshot, for: user.id)
    }

    private func loadIMConversationMembers(for conversationID: String) async {
        guard let user = currentUser else {
            return
        }

        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        imConversationMembersTask?.cancel()
        imConversationMembersTask = Task { [weak self] in
            guard let self else {
                return
            }

            self.imConversationStore.setLoadingMembers(true)
            defer {
                self.imConversationStore.setLoadingMembers(false)
                self.imConversationMembersTask = nil
            }

            do {
                let members = try await self.sessionClient.fetchIMConversationMembers(
                    conversationID: trimmedConversationID
                )
                guard self.currentUser?.id == user.id else {
                    return
                }

                self.markServerOnline()
                self.imConversationStore.replaceMembers(
                    in: trimmedConversationID,
                    members: members
                )
                self.scheduleIMConversationCachePersist()
            } catch {
                await self.handleIMDataRequestError(error)
            }
        }

        await imConversationMembersTask?.value
    }

    private func loadIMMessagesIfNeeded(for conversationID: String, forceReload: Bool = false) async {
        guard let user = currentUser else {
            return
        }

        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        guard forceReload || !imConversationStore.hasLoadedMessages(for: trimmedConversationID) else {
            return
        }

        await loadIMMessagesPage(
            for: trimmedConversationID,
            currentUserID: user.id,
            beforeSequence: nil,
            mergeMode: .replace
        )
    }

    private func syncIMConversationGap(for conversationID: String, currentUserID: UUID) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              let latestLoadedSequence = imConversationStore.latestLoadedServerSequence(for: trimmedConversationID)
        else {
            return true
        }

        do {
            var afterSequence = latestLoadedSequence
            var iterations = 0

            while iterations < IMHistoryPage.gapSyncMaxIterations {
                let response = try await sessionClient.fetchIMMessagesSince(
                    conversationID: trimmedConversationID,
                    afterSequence: afterSequence,
                    limit: IMHistoryPage.gapSyncLimit
                )
                guard currentUser?.id == currentUserID else {
                    return false
                }

                markServerOnline()
                imConversationStore.appendMessages(
                    in: trimmedConversationID,
                    messages: response.messages,
                    currentUserID: currentUserID
                )
                scheduleIMConversationCachePersist()

                guard response.hasMore,
                      let nextAfterSequence = response.nextAfterSequence,
                      nextAfterSequence > afterSequence
                else {
                    return true
                }

                afterSequence = UInt64(nextAfterSequence)
                iterations += 1
            }
            return true
        } catch {
            await handleIMDataRequestError(error)
            return false
        }
    }

    private func syncIMConversationGapsAfterConnection() async {
        guard let user = currentUser else {
            return
        }

        guard let summaries = await fetchAndApplyIMConversationSummaries() else {
            scheduleIMConversationSummaryReadModelCorrection(force: true)
            return
        }

        let gapSyncTargets = prioritizedGapSyncTargets(
            imConversationStore.gapSyncTargets(from: summaries)
        )
        var didSyncAllGaps = true
        var didSyncSelectedConversationGap = false

        for conversationID in gapSyncTargets {
            let didSyncGap = await syncIMConversationGap(for: conversationID, currentUserID: user.id)
            didSyncAllGaps = didSyncAllGaps && didSyncGap

            if conversationID == imConversationStore.selectedConversationID {
                didSyncSelectedConversationGap = didSyncGap
            }
        }

        if didSyncSelectedConversationGap,
           let selectedConversationID = imConversationStore.selectedConversationID {
            await markIMConversationReadUpToLatestLoadedSequence(for: selectedConversationID)
        }

        if !didSyncAllGaps {
            scheduleIMConversationSummaryReadModelCorrection(force: true)
        }
    }

    private func prioritizedGapSyncTargets(_ conversationIDs: [String]) -> [String] {
        guard let selectedConversationID = imConversationStore.selectedConversationID,
              conversationIDs.contains(selectedConversationID)
        else {
            return conversationIDs
        }

        return [selectedConversationID] + conversationIDs.filter { $0 != selectedConversationID }
    }

    private func markIMConversationReadUpToLatestLoadedSequence(for conversationID: String) async {
        guard let readSequence = imConversationStore.latestLoadedServerSequence(for: conversationID) else {
            return
        }

        await markIMConversationRead(
            conversationID: conversationID,
            readSequence: readSequence,
            debounceNanoseconds: 0
        )
    }

    private func markIMConversationRead(
        conversationID: String,
        readSequence: UInt64,
        debounceNanoseconds: UInt64 = IMHistoryPage.readReportDebounceNanoseconds
    ) async {
        guard let trimmedConversationID = enqueueIMConversationReadReport(
            for: conversationID,
            readSequence: readSequence,
            debounceNanoseconds: debounceNanoseconds
        ) else {
            return
        }

        guard debounceNanoseconds == 0 else {
            return
        }

        await flushIMConversationReadReport(for: trimmedConversationID)
    }

    private func enqueueIMConversationReadReport(
        for conversationID: String,
        readSequence: UInt64,
        debounceNanoseconds: UInt64
    ) -> String? {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return nil
        }

        let currentServerReadSequence = imConversationStore.serverLastReadSequence(for: trimmedConversationID) ?? 0
        let nextReadSequence = max(
            readSequence,
            pendingIMConversationReadSequences[trimmedConversationID] ?? 0
        )
        guard nextReadSequence > currentServerReadSequence else {
            return nil
        }

        pendingIMConversationReadSequences[trimmedConversationID] = nextReadSequence
        imConversationReadReportTasks[trimmedConversationID]?.cancel()

        guard debounceNanoseconds > 0 else {
            imConversationReadReportTasks[trimmedConversationID] = nil
            return trimmedConversationID
        }

        imConversationReadReportTasks[trimmedConversationID] = Task { [weak self] in
            guard let self else {
                return
            }

            try? await Task.sleep(nanoseconds: debounceNanoseconds)

            guard !Task.isCancelled else {
                return
            }

            await self.flushIMConversationReadReport(for: trimmedConversationID)
        }

        return trimmedConversationID
    }

    private func flushIMConversationReadReport(for conversationID: String) async {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        imConversationReadReportTasks[trimmedConversationID] = nil

        guard let readSequence = pendingIMConversationReadSequences.removeValue(forKey: trimmedConversationID) else {
            return
        }

        do {
            let response = try await sessionClient.markIMConversationRead(
                conversationID: trimmedConversationID,
                readSequence: readSequence
            )
            markServerOnline()
            applyIMConversationExplicitReadResponse(response)
        } catch {
            await handleIMDataRequestError(error)
        }
    }

    private enum IMHistoryMergeMode {
        case replace
        case prepend
    }

    private func loadIMMessagesPage(
        for conversationID: String,
        currentUserID: UUID,
        beforeSequence: UInt64?,
        mergeMode: IMHistoryMergeMode
    ) async {
        imConversationMessagesTask?.cancel()
        imConversationMessagesTask = Task { [weak self] in
            guard let self else {
                return
            }

            self.imConversationStore.setLoadingMessages(true)
            defer {
                self.imConversationStore.setLoadingMessages(false)
                self.imConversationMessagesTask = nil
            }

            do {
                let messages = try await self.sessionClient.fetchIMMessages(
                    conversationID: conversationID,
                    beforeSequence: beforeSequence,
                    limit: IMHistoryPage.latestLimit
                )
                guard self.currentUser?.id == currentUserID else {
                    return
                }

                self.markServerOnline()

                switch mergeMode {
                case .replace:
                    self.imConversationStore.replaceMessages(
                        in: conversationID,
                        messages: messages,
                        currentUserID: currentUserID
                    )
                case .prepend:
                    self.imConversationStore.prependMessages(
                        in: conversationID,
                        messages: messages,
                        currentUserID: currentUserID
                    )
                }
                self.scheduleIMConversationCachePersist()
            } catch {
                await self.handleIMDataRequestError(error)
            }
        }

        await imConversationMessagesTask?.value
    }

    @discardableResult
    private func reconcileIMConversationSummaryReadModel(force: Bool = true) async -> Bool {
        if !force,
           let lastIMConversationSummaryRefreshAt,
           !imConversationStore.conversations.isEmpty,
           Date().timeIntervalSince(lastIMConversationSummaryRefreshAt) < IMHistoryPage.minimumRefreshInterval {
            return false
        }

        return await fetchAndApplyIMConversationSummaries() != nil
    }

    private func fetchAndApplyIMConversationSummaries() async -> [IMConversationSummaryResponseBody]? {
        guard let user = currentUser else {
            return nil
        }

        imConversationStore.setLoadingConversations(true)
        defer {
            imConversationStore.setLoadingConversations(false)
        }

        do {
            let conversations = try await sessionClient.fetchIMConversations()
            guard currentUser?.id == user.id else {
                return nil
            }

            markServerOnline()
            lastIMConversationSummaryRefreshAt = Date()
            applyIMConversationSummaryReadModel(conversations)
            return conversations
        } catch {
            await handleIMDataRequestError(error)
            return nil
        }
    }

    private func applyIMConversationSummaryReadModel(_ conversations: [IMConversationSummaryResponseBody]) {
        imConversationStore.replaceConversationSummaries(conversations)
        imConversationStore.applyServerSummaryReadStates(conversations)
        scheduleIMConversationCachePersist()
    }

    private func applyIMConversationExplicitReadResponse(_ response: IMConversationReadResponseBody) {
        imConversationStore.applyServerExplicitReadResponse(response)
        scheduleIMConversationCachePersist()
    }

    private func upsertContact(_ contact: ContactResponseBody) {
        if let index = contacts.firstIndex(where: { $0.id == contact.id }) {
            contacts[index] = contact
        } else {
            contacts.append(contact)
        }
        contacts.sort { $0.email < $1.email }
    }

    private func replaceContactRequests(_ requests: [ContactRequestResponseBody], currentUserID: UUID) {
        incomingContactRequests = requests
            .filter { $0.status == .pending && $0.addressee.id == currentUserID }
            .sorted(by: sortContactRequestsNewestFirst)
        outgoingContactRequests = requests
            .filter { $0.status == .pending && $0.requester.id == currentUserID }
            .sorted(by: sortContactRequestsNewestFirst)
    }

    private func upsertContactRequest(_ request: ContactRequestResponseBody) {
        guard let currentUserID = currentUser?.id else {
            return
        }

        incomingContactRequests.removeAll { $0.id == request.id }
        outgoingContactRequests.removeAll { $0.id == request.id }

        guard request.status == .pending else {
            return
        }

        if request.addressee.id == currentUserID {
            incomingContactRequests.append(request)
            incomingContactRequests.sort(by: sortContactRequestsNewestFirst)
        } else if request.requester.id == currentUserID {
            outgoingContactRequests.append(request)
            outgoingContactRequests.sort(by: sortContactRequestsNewestFirst)
        }
    }

    private func sortContactRequestsNewestFirst(
        _ lhs: ContactRequestResponseBody,
        _ rhs: ContactRequestResponseBody
    ) -> Bool {
        switch (lhs.createdAt, rhs.createdAt) {
        case let (lhsDate?, rhsDate?):
            return lhsDate > rhsDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func normalizedContactRemark(_ remark: String?) -> String? {
        let normalized = remark?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else {
            return nil
        }
        return String(normalized.prefix(64))
    }

    private func normalizedContactRequestMessage(_ message: String?) -> String? {
        let normalized = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else {
            return nil
        }
        return String(normalized.prefix(120))
    }

    private func scheduleIMConversationSummaryReadModelCorrection(force: Bool = false) {
        imConversationRefreshTask?.cancel()
        imConversationRefreshTask = Task { [weak self] in
            guard let self else {
                return
            }

            if !force {
                try? await Task.sleep(nanoseconds: IMHistoryPage.refreshDebounceNanoseconds)
            }

            guard !Task.isCancelled else {
                return
            }

            _ = await self.reconcileIMConversationSummaryReadModel(force: force)
            self.imConversationRefreshTask = nil
        }
    }

    private func handleIMDataRequestError(_ error: Error) async {
        imConversationStore.setStatusMessage(error.localizedDescription)

        if await shouldPreserveSession(for: error) {
            await markServerUnavailableIfNeeded(for: error)
        } else {
            await clearSession(message: error.localizedDescription)
        }
    }

    private func handleContactRequestError(_ error: Error) async {
        contactsMessage = error.localizedDescription

        if await shouldPreserveSession(for: error) {
            await markServerUnavailableIfNeeded(for: error)
        } else {
            await clearSession(message: error.localizedDescription)
        }
    }

    private func handleContactRequestsError(_ error: Error) async {
        contactRequestsMessage = error.localizedDescription

        if await shouldPreserveSession(for: error) {
            await markServerUnavailableIfNeeded(for: error)
        } else {
            await clearSession(message: error.localizedDescription)
        }
    }

    private func shouldPreserveSession(for error: Error) async -> Bool {
        await sessionClient.shouldPreserveSession(for: error)
    }

    private func markServerUnavailableIfNeeded(for error: Error) async {
        if await sessionClient.shouldMarkServerOffline(for: error) {
            markServerOffline(error)
        }
    }

    private func markServerOnline() {
        serverStatus = .online
    }

    private func markServerOffline(_ error: Error) {
        serverStatus = .offline(message: error.localizedDescription)
    }

    private func markServerOfflineMessage(_ message: String) {
        serverStatus = .offline(message: message)
    }

    private static func deviceMetadata() -> DeviceMetadataPayload {
        let info = Bundle.main.infoDictionary
        return DeviceMetadataPayload(
            deviceID: UIDevice.current.identifierForVendor?.uuidString,
            deviceName: UIDevice.current.model,
            platform: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            appVersion: info?["CFBundleShortVersionString"] as? String
        )
    }
}

extension AuthManager: ProbeManagerDelegate {
    func probeManagerDidFetchUser(_ user: AuthUser) {
        markServerOnline()
        applySignedInState(user)
    }

    func probeManagerDidReceiveFailure(_ failure: ProbeFailureContext) async {
        if failure.shouldPreserveSession {
            if failure.shouldMarkServerOffline {
                markServerOfflineMessage(failure.message)
            }
        } else {
            await clearSession(message: failure.message)
        }
    }
}

extension AuthManager: FileTransferManagerDelegate {
    func fileTransferManagerDidSucceed() {
        markServerOnline()
    }

    func fileTransferManagerDidReceiveFailure(_ failure: ProbeFailureContext) async {
        if failure.shouldPreserveSession {
            if failure.shouldMarkServerOffline {
                markServerOfflineMessage(failure.message)
            }
        } else {
            await clearSession(message: failure.message)
        }
    }
}
