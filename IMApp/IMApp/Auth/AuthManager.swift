import Combine
import Foundation
import IMClientKit
import SwiftUI
import UIKit

enum DirectPeerRelationshipState: Equatable {
    case friend
    case none
    case outgoingPending
    case incomingPending
    case resolving
    case unavailable
}

struct DirectPeerRelationshipPresentation: Equatable {
    let state: DirectPeerRelationshipState
    let message: String
    let peerUserID: UUID?
    let peerEmail: String?
    let requestID: UUID?
}

struct IMConversationIdentityPresentation: Equatable {
    let title: String
    let detailSummary: String
    let rowSecondaryLabel: String?
}

@MainActor
final class AuthManager: ObservableObject {
    private enum IMHistoryPage {
        static let refreshDebounceNanoseconds: UInt64 = 400_000_000
        static let cachePersistDebounceNanoseconds: UInt64 = 300_000_000
        static let resolvedContactRequestHistoryLimit = 50
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

    let appRootStore: AppRootStore
    let sessionStore: AppSessionStore
    let contactStore: ContactStore

    var phase: Phase {
        get { sessionStore.phase }
        set { sessionStore.phase = newValue }
    }

    var isBusy: Bool {
        get { sessionStore.isBusy }
        set { sessionStore.isBusy = newValue }
    }

    var sessions: [SessionSnapshot] {
        get { sessionStore.sessions }
        set { sessionStore.sessions = newValue }
    }

    var isLoadingSessions: Bool {
        get { sessionStore.isLoadingSessions }
        set { sessionStore.isLoadingSessions = newValue }
    }

    var sessionsMessage: String? {
        get { sessionStore.sessionsMessage }
        set { sessionStore.sessionsMessage = newValue }
    }

    var contacts: [ContactResponseBody] {
        get { contactStore.contacts }
        set { contactStore.contacts = newValue }
    }

    var isLoadingContacts: Bool {
        get { contactStore.isLoadingContacts }
        set { contactStore.isLoadingContacts = newValue }
    }

    var contactsMessage: String? {
        get { contactStore.contactsMessage }
        set { contactStore.contactsMessage = newValue }
    }

    var contactRequests: [ContactRequestResponseBody] {
        get { contactStore.contactRequests }
        set { contactStore.contactRequests = newValue }
    }

    var unseenIncomingContactRequestCount: Int {
        get { contactStore.unseenIncomingContactRequestCount }
        set { contactStore.unseenIncomingContactRequestCount = newValue }
    }

    var isLoadingContactRequests: Bool {
        get { contactStore.isLoadingContactRequests }
        set { contactStore.isLoadingContactRequests = newValue }
    }

    var contactRequestsLoadMessage: String? {
        get { contactStore.contactRequestsLoadMessage }
        set { contactStore.contactRequestsLoadMessage = newValue }
    }

    var contactRequestActionMessage: String? {
        get { contactStore.contactRequestActionMessage }
        set { contactStore.contactRequestActionMessage = newValue }
    }

    var isUpdatingProfile: Bool {
        get { sessionStore.isUpdatingProfile }
        set { sessionStore.isUpdatingProfile = newValue }
    }

    var profileMessage: String? {
        get { sessionStore.profileMessage }
        set { sessionStore.profileMessage = newValue }
    }

    var acceptingRequestIDs: Set<UUID> {
        get { contactStore.acceptingRequestIDs }
        set { contactStore.acceptingRequestIDs = newValue }
    }

    var decliningRequestIDs: Set<UUID> {
        get { contactStore.decliningRequestIDs }
        set { contactStore.decliningRequestIDs = newValue }
    }

    var cancellingRequestIDs: Set<UUID> {
        get { contactStore.cancellingRequestIDs }
        set { contactStore.cancellingRequestIDs = newValue }
    }

    var directConversationRelationshipActionMessages: [String: String] {
        get { contactStore.directConversationRelationshipActionMessages }
        set { contactStore.directConversationRelationshipActionMessages = newValue }
    }

    var sendingDirectConversationFriendRequestConversationIDs: Set<String> {
        get { contactStore.sendingDirectConversationFriendRequestConversationIDs }
        set { contactStore.sendingDirectConversationFriendRequestConversationIDs = newValue }
    }

    var blockedUsers: [UserBlockResponseBody] {
        get { contactStore.blockedUsers }
        set { contactStore.blockedUsers = newValue }
    }

    var isLoadingBlockedUsers: Bool {
        get { contactStore.isLoadingBlockedUsers }
        set { contactStore.isLoadingBlockedUsers = newValue }
    }

    var blockedUserIDs: Set<UUID> {
        Set(blockedUsers.map(\.blockedUserID))
    }

    var serverStatus: ServerStatus {
        get { sessionStore.serverStatus }
        set { sessionStore.serverStatus = newValue }
    }

    @Published private(set) var imConnectionStatus: IMConnectionStatus = .disconnected
    @Published private(set) var isFlushingQueuedIMTextMessages = false

    var incomingContactRequests: [ContactRequestResponseBody] {
        incomingPendingContactRequests
    }

    var outgoingContactRequests: [ContactRequestResponseBody] {
        outgoingPendingContactRequests
    }

    var incomingPendingContactRequests: [ContactRequestResponseBody] {
        contactStore.incomingPendingContactRequests(
            currentUserID: currentUser?.id,
            sort: sessionFacade.sortPendingNewestFirst
        )
    }

    var outgoingPendingContactRequests: [ContactRequestResponseBody] {
        contactStore.outgoingPendingContactRequests(
            currentUserID: currentUser?.id,
            sort: sessionFacade.sortPendingNewestFirst
        )
    }

    var recentResolvedContactRequests: [ContactRequestResponseBody] {
        contactStore.recentResolvedContactRequests(sort: sessionFacade.sortResolvedNewestFirst)
    }

    var pendingIncomingContactRequestCount: Int {
        incomingPendingContactRequests.count
    }

    var totalPendingContactRequestCount: Int {
        incomingPendingContactRequests.count + outgoingPendingContactRequests.count
    }

    var hasUnreadIncomingContactRequests: Bool {
        unseenIncomingContactRequestCount > 0
    }

    var hasAnyContactRequests: Bool {
        !contactRequests.isEmpty
    }

    let sessionClient: SessionClient
    private let sessionFacade: SessionFacade
    private let openIMConnection: @Sendable () async throws -> IMTCPConnection
    private let backgroundTransferMonitor: any BackgroundTransferMonitoring
    private let imConversationCache: IMConversationCacheHandler
    private var storeCancellables: Set<AnyCancellable> = []
    private var restoreTask: Task<Void, Never>?
    private var restoreGeneration: UInt64 = 0
    private var imConversationListTask: Task<Void, Never>?
    private var contactStateCorrectionTask: Task<Void, Never>?
    private var imConversationCachePersistTask: Task<Void, Never>?
    private var contactStateCachePersistTask: Task<Void, Never>?
    private var lastIMConversationSummaryRefreshAt: Date?
    private var imConversationSummarySyncToken: String?
    private var latestIMConversationSummaries: [IMConversationSummaryResponseBody] = []
    private var lastContactStateRefreshAt: Date? {
        get { contactStore.lastContactStateRefreshAt }
        set { contactStore.lastContactStateRefreshAt = newValue }
    }
    var lastSeenIncomingContactRequestAt: Date? {
        get { contactStore.lastSeenIncomingContactRequestAt }
        set { contactStore.lastSeenIncomingContactRequestAt = newValue }
    }
    let probeManager: ProbeManager
    let fileTransferManager: FileTransferManager
    let imConversationStore: IMConversationStore
    lazy var conversationRuntimeController = makeConversationRuntimeController()
    lazy var conversationPresentationStore = IMConversationPresentationStore(authManager: self)
    lazy var conversationRuntimeStore = IMConversationRuntimeStore(authManager: self)

    convenience init(
        network: NetworkEnvironment,
        imConnectionConfiguration: IMTCPClientConfiguration,
        tokenStore: KeychainStore = KeychainStore(),
        userCache: UserDefaultsSessionCache = UserDefaultsSessionCache(),
        backgroundTransferMonitor: any BackgroundTransferMonitoring = BackgroundTransferCoordinator.shared,
        imConversationCache: IMConversationCacheHandler = ClientPersistenceFactory().makeIMConversationCacheHandler(),
        contactStateCache: ContactStateCacheHandler = ClientPersistenceFactory().makeContactStateCacheHandler(),
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
                try await sessionClient.openIMConnection(configuration: imConnectionConfiguration)
            },
            backgroundTransferMonitor: backgroundTransferMonitor,
            imConversationCache: imConversationCache,
            contactStateCache: contactStateCache,
            shouldRestoreSession: shouldRestoreSession
        )
    }

    convenience init<TokenStoreType: TokenStore, UserCacheType: UserSessionCache>(
        httpClient: HTTPClient,
        fileTransferClient: FileTransferClient? = nil,
        tokenStore: TokenStoreType,
        userCache: UserCacheType,
        openIMConnection: (@Sendable () async throws -> IMTCPConnection)? = nil,
        backgroundTransferMonitor: any BackgroundTransferMonitoring = BackgroundTransferCoordinator.shared,
        imConversationCache: IMConversationCacheHandler = IMConversationCacheHandler(NoopIMConversationCache()),
        contactStateCache: ContactStateCacheHandler = ContactStateCacheHandler(NoopContactStateCache()),
        shouldRestoreSession: Bool = true
    ) {
        let sessionClient = SessionClient(
            httpClient: httpClient,
            fileTransferClient: fileTransferClient,
            tokenStore: tokenStore,
            userCache: userCache
        )
        self.init(
            sessionClient: sessionClient,
            openIMConnection: openIMConnection ?? {
                preconditionFailure("Explicit IM connection opener is required when no openIMConnection closure is provided.")
            },
            backgroundTransferMonitor: backgroundTransferMonitor,
            imConversationCache: imConversationCache,
            contactStateCache: contactStateCache,
            shouldRestoreSession: shouldRestoreSession
        )
    }

    private init(
        sessionClient: SessionClient,
        openIMConnection: @escaping @Sendable () async throws -> IMTCPConnection,
        backgroundTransferMonitor: any BackgroundTransferMonitoring,
        imConversationCache: IMConversationCacheHandler,
        contactStateCache: ContactStateCacheHandler,
        shouldRestoreSession: Bool
    ) {
        self.sessionClient = sessionClient
        let authSessionController = AuthSessionController(sessionClient: sessionClient)
        let contactsController = ContactsController(
            sessionClient: sessionClient,
            contactStateCache: contactStateCache
        )
        self.sessionFacade = SessionFacade(
            authSessionController: authSessionController,
            contactsController: contactsController
        )
        self.openIMConnection = openIMConnection
        self.backgroundTransferMonitor = backgroundTransferMonitor
        self.imConversationCache = imConversationCache
        let sessionStore = AppSessionStore()
        let contactStore = ContactStore()
        let conversationStore = IMConversationStore()
        self.sessionStore = sessionStore
        self.contactStore = contactStore
        self.imConversationStore = conversationStore
        self.appRootStore = AppRootStore(
            sessionStore: sessionStore,
            contactStore: contactStore,
            conversationStore: conversationStore
        )
        self.probeManager = ProbeManager(sessionClient: sessionClient)
        self.fileTransferManager = FileTransferManager(
            fileAPI: FileAPI(sessionClient: sessionClient),
            sessionClient: sessionClient,
            backgroundTransferMonitor: backgroundTransferMonitor
        )
        self.probeManager.delegate = self
        self.fileTransferManager.delegate = self
        bindChildStores()

        if shouldRestoreSession {
            scheduleRestoreSession()
        } else {
            phase = .signedOut(message: nil)
        }
    }

    private func bindChildStores() {
        sessionStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &storeCancellables)

        contactStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &storeCancellables)
    }

    private func makeConversationRuntimeController() -> ConversationRuntimeController {
        ConversationRuntimeController(
            sessionClient: sessionClient,
            openIMConnection: openIMConnection,
            imConversationStore: imConversationStore,
            currentUserProvider: { [weak self] in
                self?.currentUser
            },
            isSignedInProvider: { [weak self] in
                guard let self else {
                    return false
                }
                if case .signedIn = self.phase {
                    return true
                }
                return false
            },
            latestConversationSummariesProvider: { [weak self] in
                self?.latestIMConversationSummaries ?? []
            },
            setLatestConversationSummaries: { [weak self] summaries in
                self?.latestIMConversationSummaries = summaries
            },
            conversationSummaryRefreshAtProvider: { [weak self] in
                self?.lastIMConversationSummaryRefreshAt
            },
            setConversationSummaryRefreshAt: { [weak self] date in
                self?.lastIMConversationSummaryRefreshAt = date
            },
            conversationSummarySyncTokenProvider: { [weak self] in
                self?.imConversationSummarySyncToken
            },
            setConversationSummarySyncToken: { [weak self] token in
                self?.imConversationSummarySyncToken = token
            },
            markServerOnline: { [weak self] in
                self?.markServerOnline()
            },
            clearSession: { [weak self] message in
                await self?.clearSession(message: message)
            },
            handleIMDataRequestError: { [weak self] error in
                await self?.handleIMDataRequestError(error)
            },
            syncContactStateAfterConnection: { [weak self] in
                await self?.syncContactStateAfterConnection()
            },
            scheduleConversationCachePersist: { [weak self] in
                self?.scheduleIMConversationCachePersist()
            },
            flushConversationCache: { [weak self] in
                await self?.flushIMConversationCache()
            },
            flushContactStateCache: { [weak self] in
                await self?.flushContactStateCache()
            },
            applyContactEvent: { [weak self] payload in
                self?.applyContactEvent(payload)
            },
            setConnectionStatus: { [weak self] status in
                self?.imConnectionStatus = status
            },
            setQueuedFlushActive: { [weak self] isActive in
                self?.isFlushingQueuedIMTextMessages = isActive
            },
            backgroundTransferMonitor: backgroundTransferMonitor
        )
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
        await sessionFacade.logoutCurrentIgnoringFailure()
        await clearSession(message: nil)
    }

    func logoutAllSessions() async {
        invalidateRestoreSession()
        do {
            let result = try await sessionFacade.logoutAll()
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
            let user = try await sessionFacade.fetchProfile()
            markServerOnline()
            replaceSignedInUser(user)
            profileMessage = nil
        } catch {
            profileMessage = error.localizedDescription
            if await shouldPreserveSession(for: error) {
                await markServerUnavailableIfNeeded(for: error)
            } else {
                await clearSession(message: error.localizedDescription)
            }
        }
    }

    @discardableResult
    func updateProfile(
        displayName: String? = nil,
        avatarPreset: UserAvatarPreset? = nil
    ) async -> Bool {
        invalidateRestoreSession()
        isUpdatingProfile = true
        defer { isUpdatingProfile = false }

        do {
            let user = try await sessionFacade.updateProfile(
                displayName: displayName,
                avatarPreset: avatarPreset
            )
            markServerOnline()
            replaceSignedInUser(user)
            profileMessage = "资料已更新。"
            return true
        } catch {
            profileMessage = error.localizedDescription
            if await shouldPreserveSession(for: error) {
                await markServerUnavailableIfNeeded(for: error)
            } else {
                await clearSession(message: error.localizedDescription)
            }
            return false
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
            let response = try await sessionFacade.fetchSessions()
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
            let snapshot = try await sessionFacade.fetchContacts()
            guard currentUser?.id == user.id else {
                return
            }

            markServerOnline()
            contacts = snapshot.contacts
            contactsMessage = nil
            lastContactStateRefreshAt = snapshot.lastRefreshAt
            scheduleContactStateCachePersist()
        } catch {
            await handleContactRequestError(error)
        }
    }

    func addContact(email: String, remark: String? = nil) async -> Bool {
        await sendContactRequest(email: email, message: nil, remark: remark)
    }

    func reloadContactRequests() async {
        guard let user = currentUser else {
            contactRequests = []
            unseenIncomingContactRequestCount = 0
            return
        }

        isLoadingContactRequests = true
        defer { isLoadingContactRequests = false }

        do {
            let snapshot = try await sessionFacade.fetchContactRequests()
            guard currentUser?.id == user.id else {
                return
            }

            markServerOnline()
            replaceContactRequests(snapshot.requests, currentUserID: user.id)
            contactRequestsLoadMessage = nil
            lastContactStateRefreshAt = snapshot.lastRefreshAt
            scheduleContactStateCachePersist()
        } catch {
            await handleContactRequestsLoadError(error)
        }
    }

    func sendContactRequest(email: String, message: String? = nil, remark: String? = nil) async -> Bool {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedMessage = sessionFacade.normalizedRequestMessage(message)
        let normalizedRemark = sessionFacade.normalizedRemark(remark)
        guard !normalizedEmail.isEmpty else {
            contactRequestActionMessage = "好友邮箱不能为空。"
            return false
        }

        contactRequestActionMessage = nil
        do {
            let request = try await sessionFacade.sendContactRequest(
                email: normalizedEmail,
                message: normalizedMessage,
                remark: normalizedRemark
            )
            markServerOnline()
            upsertContactRequest(request)
            contactRequestActionMessage = "好友申请已发送。"
            scheduleContactStateCachePersist()
            return true
        } catch {
            await handleContactRequestsActionError(error)
            return false
        }
    }

    func acceptContactRequest(id requestID: UUID, remark: String? = nil) async -> Bool {
        guard !acceptingRequestIDs.contains(requestID) else {
            return false
        }

        acceptingRequestIDs.insert(requestID)
        contactRequestActionMessage = nil
        defer { acceptingRequestIDs.remove(requestID) }

        do {
            let contact = try await sessionFacade.acceptContactRequest(
                id: requestID,
                remark: sessionFacade.normalizedRemark(remark)
            )
            markServerOnline()
            upsertContact(contact)
            updateContactRequestStatus(
                id: requestID,
                status: .accepted,
                respondedAt: Date()
            )
            contactRequestActionMessage = "已添加好友。"
            scheduleContactStateCachePersist()
            await reloadContacts()
            return true
        } catch {
            await handleContactRequestsActionError(error)
            return false
        }
    }

    func declineContactRequest(id requestID: UUID) async -> Bool {
        guard !decliningRequestIDs.contains(requestID) else {
            return false
        }

        decliningRequestIDs.insert(requestID)
        contactRequestActionMessage = nil
        defer { decliningRequestIDs.remove(requestID) }

        do {
            _ = try await sessionFacade.declineContactRequest(id: requestID)
            markServerOnline()
            updateContactRequestStatus(
                id: requestID,
                status: .declined,
                respondedAt: Date()
            )
            contactRequestActionMessage = "已拒绝好友申请。"
            scheduleContactStateCachePersist()
            return true
        } catch {
            await handleContactRequestsActionError(error)
            return false
        }
    }

    func cancelContactRequest(id requestID: UUID) async -> Bool {
        guard !cancellingRequestIDs.contains(requestID) else {
            return false
        }

        cancellingRequestIDs.insert(requestID)
        contactRequestActionMessage = nil
        defer { cancellingRequestIDs.remove(requestID) }

        do {
            _ = try await sessionFacade.cancelContactRequest(id: requestID)
            markServerOnline()
            updateContactRequestStatus(
                id: requestID,
                status: .cancelled,
                respondedAt: Date()
            )
            contactRequestActionMessage = "好友申请已取消。"
            scheduleContactStateCachePersist()
            return true
        } catch {
            await handleContactRequestsActionError(error)
            return false
        }
    }

    func updateContactRemark(contactUserID: UUID, remark: String) async -> Bool {
        do {
            let contact = try await sessionFacade.updateContact(
                contactUserID: contactUserID,
                remark: sessionFacade.normalizedRemark(remark)
            )
            markServerOnline()
            upsertContact(contact)
            contactsMessage = "联系人备注已更新。"
            scheduleContactStateCachePersist()
            return true
        } catch {
            await handleContactRequestError(error)
            return false
        }
    }

    func deleteContact(_ contactUserID: UUID) async -> Bool {
        do {
            try await sessionFacade.deleteContact(contactUserID: contactUserID)
            markServerOnline()
            contacts.removeAll { $0.id == contactUserID }
            contactsMessage = "已删除联系人。"
            scheduleContactStateCachePersist()
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
            try await sessionFacade.logoutCurrent()
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
            try await sessionFacade.logout(sessionID: sessionID)
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
        switch await sessionFacade.restoreSession() {
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

    private func scheduleRestoreSession() {
        let generation = restoreGeneration
        restoreTask = Task { [weak self] in
            guard let self else {
                return
            }

            let result = await self.sessionFacade.restoreSession()
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
        let manager = AuthManager(
            network: AppNetworkConfiguration.preview.makeNetworkEnvironment(),
            imConnectionConfiguration: AppNetworkConfiguration.preview.makeIMTCPConfiguration(),
            shouldRestoreSession: false
        )
        manager.phase = .signedOut(message: "Preview mode")
        return manager
    }

    var currentUser: AuthUser? {
        sessionStore.currentUser
    }

    func conversationIdentityPresentation(
        for conversationID: String
    ) -> IMConversationIdentityPresentation? {
        guard let conversation = imConversationStore.conversations.first(where: { $0.id == conversationID }) else {
            return nil
        }

        return conversationIdentityPresentation(for: conversation)
    }

    func conversationIdentityPresentation(
        for conversation: IMConversation
    ) -> IMConversationIdentityPresentation {
        let fallbackTitle = normalizedConversationTitle(conversation.title, conversationID: conversation.id)

        guard conversation.kind == .direct,
              let currentUser
        else {
            let groupSummary = groupConversationSummary(for: conversation)
            return IMConversationIdentityPresentation(
                title: fallbackTitle,
                detailSummary: groupSummary,
                rowSecondaryLabel: conversation.members.isEmpty ? nil : groupSummary
            )
        }

        guard let peer = directConversationPeer(in: conversation, currentUserID: currentUser.id) else {
            let fallbackSummary = conversationStoreIsLoadingDirectPeer(for: conversation.id)
                ? "正在加载对方信息"
                : "当前还没有成员信息"
            return IMConversationIdentityPresentation(
                title: fallbackTitle,
                detailSummary: fallbackSummary,
                rowSecondaryLabel: nil
            )
        }

        let contact = contacts.first(where: { $0.id == peer.id })
        let contactTitle = contact?.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPeerEmail = peer.email.trimmingCharacters(in: .whitespacesAndNewlines)

        let title: String
        if let contactTitle, !contactTitle.isEmpty {
            title = contactTitle
        } else if !normalizedPeerEmail.isEmpty {
            title = normalizedPeerEmail
        } else {
            title = fallbackTitle
        }

        let detailSummary: String
        if !normalizedPeerEmail.isEmpty {
            detailSummary = normalizedPeerEmail
        } else {
            detailSummary = fallbackSummary(for: conversation)
        }

        let rowSecondaryLabel: String?
        if !normalizedPeerEmail.isEmpty && normalizedPeerEmail != title {
            rowSecondaryLabel = normalizedPeerEmail
        } else {
            rowSecondaryLabel = nil
        }

        return IMConversationIdentityPresentation(
            title: title,
            detailSummary: detailSummary,
            rowSecondaryLabel: rowSecondaryLabel
        )
    }

    func directPeerRelationshipPresentation(for conversationID: String) -> DirectPeerRelationshipPresentation? {
        guard let currentUser,
              let conversation = imConversationStore.conversations.first(where: { $0.id == conversationID }),
              conversation.kind == .direct,
              conversation.isDirectMessagingFrozen
        else {
            return nil
        }

        if sendingDirectConversationFriendRequestConversationIDs.contains(conversationID) {
            return DirectPeerRelationshipPresentation(
                state: .resolving,
                message: "正在发送好友申请…",
                peerUserID: nil,
                peerEmail: nil,
                requestID: nil
            )
        }

        guard let peer = directConversationPeer(in: conversation, currentUserID: currentUser.id) else {
            let message = conversationStoreIsLoadingDirectPeer(for: conversationID)
                ? "正在加载对方信息…"
                : "暂时无法识别对方信息。"
            return DirectPeerRelationshipPresentation(
                state: .unavailable,
                message: message,
                peerUserID: nil,
                peerEmail: nil,
                requestID: nil
            )
        }

        if contacts.contains(where: { $0.id == peer.id }) {
            return DirectPeerRelationshipPresentation(
                state: .friend,
                message: "好友关系已恢复，等待当前会话状态同步。",
                peerUserID: peer.id,
                peerEmail: peer.email,
                requestID: nil
            )
        }

        if let request = incomingPendingContactRequests.first(where: {
            $0.requester.id == peer.id && $0.addressee.id == currentUser.id
        }) {
            if acceptingRequestIDs.contains(request.id) || decliningRequestIDs.contains(request.id) {
                return DirectPeerRelationshipPresentation(
                    state: .resolving,
                    message: "正在处理好友申请…",
                    peerUserID: peer.id,
                    peerEmail: peer.email,
                    requestID: request.id
                )
            }

            return DirectPeerRelationshipPresentation(
                state: .incomingPending,
                message: "对方向你发来了好友申请。",
                peerUserID: peer.id,
                peerEmail: peer.email,
                requestID: request.id
            )
        }

        if let request = outgoingPendingContactRequests.first(where: {
            $0.requester.id == currentUser.id && $0.addressee.id == peer.id
        }) {
            if cancellingRequestIDs.contains(request.id) {
                return DirectPeerRelationshipPresentation(
                    state: .resolving,
                    message: "正在取消好友申请…",
                    peerUserID: peer.id,
                    peerEmail: peer.email,
                    requestID: request.id
                )
            }

            return DirectPeerRelationshipPresentation(
                state: .outgoingPending,
                message: "已发送好友申请，等待对方处理。",
                peerUserID: peer.id,
                peerEmail: peer.email,
                requestID: request.id
            )
        }

        return DirectPeerRelationshipPresentation(
            state: .none,
            message: "添加好友后可继续在当前会话发送消息。",
            peerUserID: peer.id,
            peerEmail: peer.email,
            requestID: nil
        )
    }

    func directConversationRelationshipActionMessage(for conversationID: String) -> String? {
        directConversationRelationshipActionMessages[conversationID]
    }

    func sendDirectConversationFriendRequest(conversationID: String) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return false
        }

        guard !sendingDirectConversationFriendRequestConversationIDs.contains(trimmedConversationID) else {
            return false
        }

        guard let peer = await ensureDirectConversationPeer(for: trimmedConversationID) else {
            setDirectConversationRelationshipActionMessage("暂时无法识别对方信息。", for: trimmedConversationID)
            return false
        }

        sendingDirectConversationFriendRequestConversationIDs.insert(trimmedConversationID)
        setDirectConversationRelationshipActionMessage(nil, for: trimmedConversationID)
        contactRequestActionMessage = nil
        defer {
            sendingDirectConversationFriendRequestConversationIDs.remove(trimmedConversationID)
            contactRequestActionMessage = nil
        }

        let didSend = await sendContactRequest(email: peer.email)
        let message = contactRequestActionMessage ?? (didSend ? "好友申请已发送。" : "好友申请发送失败。")
        setDirectConversationRelationshipActionMessage(message, for: trimmedConversationID)
        return didSend
    }

    func acceptDirectConversationFriendRequest(conversationID: String, remark: String? = nil) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let relationship = directPeerRelationshipPresentation(for: trimmedConversationID),
              relationship.state == .incomingPending,
              let requestID = relationship.requestID
        else {
            setDirectConversationRelationshipActionMessage("当前没有可接受的好友申请。", for: trimmedConversationID)
            return false
        }

        setDirectConversationRelationshipActionMessage(nil, for: trimmedConversationID)
        contactRequestActionMessage = nil
        let didAccept = await acceptContactRequest(id: requestID, remark: remark)
        let message = contactRequestActionMessage ?? (didAccept ? "已添加好友。" : "好友申请处理失败。")
        contactRequestActionMessage = nil
        setDirectConversationRelationshipActionMessage(message, for: trimmedConversationID)
        return didAccept
    }

    func declineDirectConversationFriendRequest(conversationID: String) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let relationship = directPeerRelationshipPresentation(for: trimmedConversationID),
              relationship.state == .incomingPending,
              let requestID = relationship.requestID
        else {
            setDirectConversationRelationshipActionMessage("当前没有可拒绝的好友申请。", for: trimmedConversationID)
            return false
        }

        setDirectConversationRelationshipActionMessage(nil, for: trimmedConversationID)
        contactRequestActionMessage = nil
        let didDecline = await declineContactRequest(id: requestID)
        let message = contactRequestActionMessage ?? (didDecline ? "已拒绝好友申请。" : "好友申请处理失败。")
        contactRequestActionMessage = nil
        setDirectConversationRelationshipActionMessage(message, for: trimmedConversationID)
        return didDecline
    }

    func cancelDirectConversationFriendRequest(conversationID: String) async -> Bool {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let relationship = directPeerRelationshipPresentation(for: trimmedConversationID),
              relationship.state == .outgoingPending,
              let requestID = relationship.requestID
        else {
            setDirectConversationRelationshipActionMessage("当前没有可取消的好友申请。", for: trimmedConversationID)
            return false
        }

        setDirectConversationRelationshipActionMessage(nil, for: trimmedConversationID)
        contactRequestActionMessage = nil
        let didCancel = await cancelContactRequest(id: requestID)
        let message = contactRequestActionMessage ?? (didCancel ? "好友申请已取消。" : "好友申请处理失败。")
        contactRequestActionMessage = nil
        setDirectConversationRelationshipActionMessage(message, for: trimmedConversationID)
        return didCancel
    }

    private func authenticate(action: AuthAction, email: String, password: String) async {
        guard !isBusy else {
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let device = Self.deviceMetadata()
            let sessionAction: SessionFacade.Action
            switch action {
            case .login:
                sessionAction = .login
            case .register:
                sessionAction = .register
            }
            let user = try await sessionFacade.authenticate(
                action: sessionAction,
                email: email,
                password: password,
                device: device
            )

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
        contactStateCorrectionTask?.cancel()
        contactStateCorrectionTask = nil
        imConversationCachePersistTask?.cancel()
        imConversationCachePersistTask = nil
        contactStateCachePersistTask?.cancel()
        contactStateCachePersistTask = nil
        lastIMConversationSummaryRefreshAt = nil
        imConversationSummarySyncToken = nil
        latestIMConversationSummaries = []
        lastContactStateRefreshAt = nil
        lastSeenIncomingContactRequestAt = nil
        await conversationRuntimeController.resetForSignedOut(flushCache: false)
        probeManager.stopAllForSignedOut()
        fileTransferManager.stopAllForSignedOut()
        await sessionFacade.clearSession()
        if let signedOutUserID {
            try? await imConversationCache.clearSnapshot(for: signedOutUserID)
            try? await sessionFacade.clearContactStateCacheSnapshot(for: signedOutUserID)
        } else {
            try? await imConversationCache.clearAll()
            try? await sessionFacade.clearAllContactStateCacheSnapshots()
        }
        imConversationStore.reset()
        sessions = []
        sessionsMessage = nil
        contacts = []
        contactsMessage = nil
        isLoadingContacts = false
        contactRequests = []
        unseenIncomingContactRequestCount = 0
        contactRequestsLoadMessage = nil
        contactRequestActionMessage = nil
        isUpdatingProfile = false
        profileMessage = nil
        directConversationRelationshipActionMessages = [:]
        isLoadingContactRequests = false
        acceptingRequestIDs = []
        decliningRequestIDs = []
        cancellingRequestIDs = []
        sendingDirectConversationFriendRequestConversationIDs = []
        blockedUsers = []
        isLoadingBlockedUsers = false
        serverStatus = .unknown
        imConnectionStatus = .disconnected
        phase = .signedOut(message: message)
    }

    private func applySignedInState(_ user: AuthUser) {
        profileMessage = nil
        replaceSignedInUser(user)
        scheduleIMConnectionIfNeeded()
        scheduleIMConversationBootstrap(for: user)
        Task { [weak self] in
            await self?.restoreContactStateCacheIfAvailable(for: user)
            await self?.reloadContacts()
            await self?.reloadContactRequests()
            await self?.loadBlockedUsers()
        }
    }

    private func replaceSignedInUser(_ user: AuthUser) {
        phase = .signedIn(user)
    }

    func scheduleIMConnectionIfNeeded() {
        conversationRuntimeController.scheduleConnectionIfNeeded()
    }

    func disconnectIMConnection(flushCache: Bool = true) async {
        await conversationRuntimeController.disconnect(flushCache: flushCache)
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

    private func restoreContactStateCacheIfAvailable(for user: AuthUser) async {
        do {
            let snapshot = try await sessionFacade.loadContactStateCacheSnapshot(for: user.id)
            guard currentUser?.id == user.id else {
                return
            }

            contacts = snapshot.contacts.map(\.contact).sorted { $0.email < $1.email }
            contactRequests = sessionFacade.normalizeRequests(
                snapshot.incomingRequests.map(\.request)
                    + snapshot.outgoingRequests.map(\.request)
                    + snapshot.resolvedRequests.map(\.request),
                currentUserID: user.id
            )
            lastContactStateRefreshAt = snapshot.lastRefreshAt
            lastSeenIncomingContactRequestAt = snapshot.lastSeenIncomingContactRequestAt
            recomputeIncomingContactRequestUnreadState()
        } catch {
            // Ignore cache restore failures and fall back to HTTP recovery.
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
            conversationRuntimeController.restoreTransferSnapshots(snapshot.transferSnapshots)
            conversationRuntimeController.resumeRecoverableMediaUploadsIfNeeded()
            conversationRuntimeController.reconcileBackgroundMediaDownloadSnapshots()
            lastIMConversationSummaryRefreshAt = snapshot.lastSummaryRefreshAt
            imConversationSummarySyncToken = snapshot.metadata.summarySyncToken
            latestIMConversationSummaries = []
        } catch {
            // Ignore cache restore failures and continue with network bootstrap.
        }
    }

    func scheduleIMConversationCachePersist() {
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

    func persistIMConversationCacheSoon() {
        scheduleIMConversationCachePersist()
    }

    func flushIMConversationCache() async {
        let task = imConversationCachePersistTask
        imConversationCachePersistTask = nil
        task?.cancel()

        guard let user = currentUser else {
            return
        }

        let snapshot = imConversationStore.makeCacheSnapshot(
            lastSummaryRefreshAt: lastIMConversationSummaryRefreshAt,
            summarySyncToken: imConversationSummarySyncToken,
            transferSnapshots: conversationRuntimeController.cachedTransferSnapshots()
        )
        try? await imConversationCache.saveSnapshot(snapshot, for: user.id)
    }

    private func markIMConversationReadUpToLatestLoadedSequence(for conversationID: String) async {
        await conversationRuntimeController.markConversationReadUpToLatestLoadedSequence(for: conversationID)
    }

    private func markIMConversationReadIfSelectedUpToLatestLoadedSequence(for conversationID: String) async {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              imConversationStore.selectedConversationID == trimmedConversationID
        else {
            return
        }

        await conversationRuntimeController.markConversationReadUpToLatestLoadedSequence(for: trimmedConversationID)
    }

    private func markIMConversationRead(
        conversationID: String,
        readSequence: UInt64,
        debounceNanoseconds: UInt64 = 250_000_000
    ) async {
        await conversationRuntimeController.markConversationRead(
            conversationID: conversationID,
            readSequence: readSequence,
            debounceNanoseconds: debounceNanoseconds
        )
    }

    private func syncContactStateAfterConnection() async {
        guard currentUser != nil else {
            return
        }

        await reloadContacts()
        await reloadContactRequests()
        await loadBlockedUsers()
    }

    private func scheduleContactStateCorrection(force: Bool = false, reason _: String? = nil) {
        contactStateCorrectionTask?.cancel()
        contactStateCorrectionTask = Task { [weak self] in
            guard let self else {
                return
            }

            if !force {
                try? await Task.sleep(nanoseconds: IMHistoryPage.refreshDebounceNanoseconds)
            }

            guard !Task.isCancelled else {
                return
            }

            await self.syncContactStateAfterConnection()
            self.contactStateCorrectionTask = nil
        }
    }

    private func setDirectConversationRelationshipActionMessage(_ message: String?, for conversationID: String) {
        if let message, !message.isEmpty {
            directConversationRelationshipActionMessages[conversationID] = message
        } else {
            directConversationRelationshipActionMessages.removeValue(forKey: conversationID)
        }
    }

    private func normalizedConversationTitle(_ title: String, conversationID: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "会话 \(conversationID.prefix(8))"
        }
        return trimmed
    }

    private func fallbackSummary(for conversation: IMConversation) -> String {
        if !conversation.members.isEmpty {
            return conversation.members.map(\.email).joined(separator: "、")
        }

        if conversation.memberCount > 0 {
            return "\(conversation.memberCount) 位成员"
        }

        if !conversation.memberUserIDs.isEmpty {
            return "\(conversation.memberUserIDs.count) 位成员"
        }

        return "当前还没有成员信息"
    }

    private func groupConversationSummary(for conversation: IMConversation) -> String {
        if !conversation.members.isEmpty {
            return conversation.members.map(\.email).joined(separator: "、")
        }

        if conversation.memberCount > 0 {
            return "成员 \(conversation.memberCount) 人"
        }

        if !conversation.memberUserIDs.isEmpty {
            return "成员 \(conversation.memberUserIDs.count) 人"
        }

        return "当前还没有成员信息"
    }

    private func directConversationPeer(
        in conversation: IMConversation,
        currentUserID: UUID
    ) -> IMDirectPeer? {
        if let directPeer = conversation.directPeer,
           directPeer.id != currentUserID {
            return directPeer
        }

        guard let member = conversation.members.first(where: { $0.id != currentUserID }) else {
            return nil
        }

        return IMDirectPeer(id: member.id, email: member.email)
    }

    private func conversationStoreIsLoadingDirectPeer(for conversationID: String) -> Bool {
        imConversationStore.isLoadingMembers && imConversationStore.selectedConversationID == conversationID
    }

    private func ensureDirectConversationPeer(for conversationID: String) async -> IMDirectPeer? {
        guard let currentUser,
              let conversation = imConversationStore.conversations.first(where: { $0.id == conversationID }),
              conversation.kind == .direct
        else {
            return nil
        }

        if let peer = directConversationPeer(in: conversation, currentUserID: currentUser.id) {
            return peer
        }

        await conversationRuntimeController.loadConversationMembers(for: conversationID)

        guard let refreshedConversation = imConversationStore.conversations.first(where: { $0.id == conversationID }) else {
            return nil
        }

        return directConversationPeer(in: refreshedConversation, currentUserID: currentUser.id)
    }

    private func upsertContact(_ contact: ContactResponseBody) {
        contactStore.upsertContact(contact)
    }

    private func applyContactEvent(_ payload: IMTCPContactEventPayload) {
        let result = contactStore.apply(
            event: payload,
            currentUserID: currentUser?.id,
            isRelevant: { request, currentUserID in
                sessionFacade.isRequestRelevant(request, to: currentUserID)
            },
            normalize: { requests, currentUserID in
                sessionFacade.normalizeRequests(requests, currentUserID: currentUserID)
            },
            sortPendingNewestFirst: { lhs, rhs in
                sessionFacade.sortPendingNewestFirst(lhs, rhs)
            }
        )

        switch result {
        case .applied:
            scheduleContactStateCachePersist()
        case .needsCorrection(let reason):
            scheduleContactStateCorrection(reason: reason)
        case .ignored:
            break
        }
    }

    private func replaceContactRequests(_ requests: [ContactRequestResponseBody], currentUserID: UUID) {
        contactStore.replaceRequests(
            requests,
            currentUserID: currentUserID,
            normalize: { requests, currentUserID in
                sessionFacade.normalizeRequests(requests, currentUserID: currentUserID)
            }
        )
        recomputeIncomingContactRequestUnreadState()
    }

    private func upsertContactRequest(_ request: ContactRequestResponseBody) {
        guard let currentUserID = currentUser?.id else {
            return
        }

        contactStore.upsertRequest(
            request,
            currentUserID: currentUserID,
            isRelevant: { request, currentUserID in
                sessionFacade.isRequestRelevant(request, to: currentUserID)
            },
            normalize: { requests, currentUserID in
                sessionFacade.normalizeRequests(requests, currentUserID: currentUserID)
            }
        )
        recomputeIncomingContactRequestUnreadState()
    }

    private func updateContactRequestStatus(
        id requestID: UUID,
        status: ContactRequestStatus,
        respondedAt: Date
    ) {
        guard let currentUserID = currentUser?.id else {
            return
        }
        contactStore.updateRequestStatus(
            id: requestID,
            status: status,
            respondedAt: respondedAt,
            currentUserID: currentUserID,
            normalize: { requests, currentUserID in
                sessionFacade.normalizeRequests(requests, currentUserID: currentUserID)
            }
        )
        recomputeIncomingContactRequestUnreadState()
    }

    func scheduleContactStateCachePersist() {
        guard currentUser != nil else {
            return
        }

        contactStateCachePersistTask?.cancel()
        contactStateCachePersistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: IMHistoryPage.cachePersistDebounceNanoseconds)
            guard !Task.isCancelled else {
                return
            }
            await self?.flushContactStateCache()
        }
    }

    func flushContactStateCache() async {
        contactStateCachePersistTask?.cancel()
        contactStateCachePersistTask = nil

        guard let user = currentUser else {
            return
        }

        do {
            try await sessionFacade.saveContactStateCacheSnapshot(
                makeContactStateCacheSnapshot(),
                for: user.id
            )
        } catch {
            // Ignore cache persistence failures and keep the in-memory state authoritative.
        }
    }

    private func makeContactStateCacheSnapshot() -> ContactStateCacheSnapshot {
        ContactStateCacheSnapshot(
            contacts: contacts.map(CachedContactState.init),
            incomingRequests: incomingPendingContactRequests.map(CachedContactRequestState.init),
            outgoingRequests: outgoingPendingContactRequests.map(CachedContactRequestState.init),
            resolvedRequests: recentResolvedContactRequests.map(CachedContactRequestState.init),
            lastRefreshAt: lastContactStateRefreshAt,
            lastSeenIncomingContactRequestAt: lastSeenIncomingContactRequestAt
        )
    }

    var latestIncomingContactRequestAt: Date? {
        incomingPendingContactRequests.compactMap(\.createdAt).max()
    }

    func recomputeIncomingContactRequestUnreadState() {
        guard let currentUserID = currentUser?.id else {
            unseenIncomingContactRequestCount = 0
            return
        }
        contactStore.recomputeIncomingUnread(
            currentUserID: currentUserID,
            sortPendingNewestFirst: { lhs, rhs in
                sessionFacade.sortPendingNewestFirst(lhs, rhs)
            }
        )
    }

    func scheduleIMConversationSummaryReadModelCorrection(force: Bool = false) {
        conversationRuntimeController.scheduleConversationSummaryReadModelCorrection(force: force)
    }

    func handleIMDataRequestError(_ error: Error) async {
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

    private func handleContactRequestsLoadError(_ error: Error) async {
        contactRequestsLoadMessage = error.localizedDescription

        if await shouldPreserveSession(for: error) {
            await markServerUnavailableIfNeeded(for: error)
        } else {
            await clearSession(message: error.localizedDescription)
        }
    }

    private func handleContactRequestsActionError(_ error: Error) async {
        contactRequestActionMessage = error.localizedDescription

        if await shouldPreserveSession(for: error) {
            await markServerUnavailableIfNeeded(for: error)
        } else {
            await clearSession(message: error.localizedDescription)
        }
    }

    private func shouldPreserveSession(for error: Error) async -> Bool {
        await sessionFacade.shouldPreserveSession(for: error)
    }

    private func markServerUnavailableIfNeeded(for error: Error) async {
        if await sessionFacade.shouldMarkServerOffline(for: error) {
            markServerOffline(error)
        }
    }

    func markServerOnline() {
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
