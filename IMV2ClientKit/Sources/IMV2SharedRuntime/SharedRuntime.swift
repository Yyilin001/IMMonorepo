import Foundation
import Crypto
import IMV2Core
import IMV2ClientRuntime

package struct SharedConfiguration: Decodable, Sendable {
    let accountURL: String
    let gatewayHost: String
    let gatewayPort: UInt16
    let storageDirectory: String
}
package struct SharedRequest: Decodable, Sendable {
    package enum Operation: String, Decodable { case locateMessage, openListWindow, openTimelineWindow, readWindow, watchWindow, nextWindowPage, resetWindow, closeWindow, conversationState, profiles, clearProfiles, avatar, groupNickname, saveGroupNickname, moderateMemberRemoval, forwardMessage, interactionAction, searchMessages, clearMessaging, messageAction, markVisibleMessages, messageReaders, beginAttachment, appendAttachment, finishAttachment, clearResources, sendAttachment, openResource, downloadResource, previewResource, beginResourceRead, readResource, endResourceRead, transferAction, cancelAttachmentSend, restore, login, register, passwordLifecycle, deviceSessions, revokeDevice, privacy, setPrivacy, favorites, setFavorite, pinMessage, moderateMessage, activity, setTyping, closeActivity, connect, disconnect, synchronize, snapshot, close, signOut, openConversation, conversationsNext, conversationsFirst, messagesOlder, messagesLatest, pendingNext, pendingFirst, sendText, retrySend, resendUnsent, contacts, contactsNext, groupsFirst, groupsNext, lookupIdentity, clearDiscovery, socialAction, openDirect, createGroup, openGroup, groupMembersNext, groupAction, retryDirectoryWork, discardDirectoryDraft, openProfile, saveAlias, invitations, invitationsNext, previewInvite, refreshInvite, inviteAction, muteMember, openAvatarEditor, changeAvatar, avatarAction }
    package let operation: Operation
    var windowID: String?
    var limit: Int?
    var archived: Bool?
    var isPinned: Bool?
    var muteUntil: Int64?
    var data: String?
    var offset: Int64?
    var displayName: String?
    var contentType: String?
    var messageID: String?
    var replyToMessageID: String?
    var targetRoomID: String?
    var targetRoomIDs: [String]?
    var mediaID: String?
    var messageIDs: [String]?
    var image: String?
    var width: Int?
    var height: Int?
    var account: String?
    var password: String?
    var publicHandle: String?
    var newPassword: String?
    var recoveryCode: String?
    var flag1: Bool?
    var flag2: Bool?
    var roomID: String?
    var text: String?
    var intentID: String?
    var scope: String?
    var page: String?
    var targetUserID: String?
    var action: String?
    var revision: UInt64?
    var role: String?
    var members: [String]?
    var permissions: [String]?
    var mentions: [String]?
}
struct SharedConversation: Encodable, Sendable {
    let id: String; let title: String; let preview: String
    var unread: Int64 = 0
    var updatedAt: Int64?
    var isGroup = false
    var peerID: String?
    var isPinned = false
    var isArchived = false
    var muteUntil: Int64?

    static func row(_ entry: V2ClientConversationListEntry, list: V2ConversationListSnapshot) -> Self {
        .init(id: entry.roomID.rawValue, title: list.titles[entry.roomID] ?? "会话",
              preview: entry.latestVisible?.latest?.preview ?? entry.lastMessage.map { $0.isWithdrawn ? "消息已撤回" : String($0.text.prefix(160)) } ?? "",
              unread: Int64(clamping: list.unread[entry.roomID] ?? 0), updatedAt: Int64(entry.lastActivity.timeIntervalSince1970 * 1000),
              isGroup: entry.roomProfile != nil && entry.directIdentity == nil, peerID: entry.directIdentity?.publicIdentity.userID.rawValue,
              isPinned: entry.isPinned, isArchived: entry.isArchived,
              muteUntil: entry.muteUntil.map { Int64($0.timeIntervalSince1970 * 1000) })
    }
}
struct SharedFavoriteMessage: Encodable, Sendable {
    let id: String; let roomID: String; let roomTitle: String; let senderID: String
    let text: String; let createdAt: Int64?; let attachmentNames: [String]
}
struct SharedFavorites: Encodable, Sendable { let messages: [SharedFavoriteMessage]; let hasMore: Bool }
struct SharedEntity: Encodable, Sendable { let kind: String; let offset: Int; let length: Int; let url: String? }
struct SharedMessage: Encodable, Sendable {
    let id: String; let senderID: String; let text: String; let sequence: UInt64; var createdAt: Int64?
    let withdrawn: Bool; let hasMedia: Bool; let attachments: [SharedAttachment]
    let revision: UInt64; let canMutate: Bool; let readByPeer: Bool
    let replyToID: String?; let replyPreview: String?; let forwardedFromID: String?
    var isFavorited = false
    let mentionSummary: String?
    let entities: [SharedEntity]
    var roomSequence: UInt64 = 0
    var isPinned = false
}
struct SharedPendingMessage: Encodable, Sendable {
    let id: String
    let text: String
    let status: String
    var preparedAttachments: Int64?
    var totalAttachments: Int64?
    var preparationStatus: String?
    let createdAt: Int64

    static func preparing(_ intent: V2PreparingResourceSendPresentation) -> Self {
        let detail: String
        if intent.isRejected { detail = "preparationRejected" }
        else if intent.isExpired { detail = "preparationExpired" }
        else if intent.isUserPaused { detail = "preparationUserPaused" }
        else if intent.isPaused { detail = "preparationPaused" }
        else if intent.isProcessing { detail = "preparationProcessing" }
        else { detail = intent.total == 0 ? "preparationWaiting" : "preparing" }
        return .init(id: intent.id.uuidString, text: intent.text, status: intent.isExpired ? "expiredUnsubmitted" : "preparing",
                     preparedAttachments: Int64(intent.completed), totalAttachments: Int64(intent.total),
                     preparationStatus: detail, createdAt: Int64(intent.createdAt.timeIntervalSince1970 * 1000))
    }
}
struct SharedChat: Encodable, Sendable {
    let roomID: String; let messages: [SharedMessage]; let pending: [SharedPendingMessage]
    let focusMessageID: String?
    let hasOlder: Bool; let isLatest: Bool; let hasMorePending: Bool; let pendingPage: Int
}
struct SharedDeviceSession: Encodable, Sendable {
    let deviceID: String; let deviceName: String; let platform: String
    let createdAt: Int64; let lastActiveAt: Int64; let isCurrentDevice: Bool
}
struct SharedDeviceSessions: Encodable, Sendable { let sessions: [SharedDeviceSession]; let nextCursor: String? }
struct SharedPrivacy: Encodable, Sendable {
    var allowsStrangerMessages: Bool?
    var allowsUserAdd: Bool?
    var allowsDirectReadReceipts: Bool?
    var allowsGroupReadReceipts: Bool?
    var allowsOnlinePresence: Bool?
    var allowsTypingIndicators: Bool?
    var blockedUsers: [String]
}
package struct SharedSnapshot: Encodable, Sendable {
    let state: String
    let userID: String?
    let allowsStrangerMessages: Bool?
    let appliedSequence: UInt64
    let acknowledgedSequence: UInt64
    let connections: UInt64
    let conversations: [SharedConversation]
    let failure: String?
    let hasMoreConversations: Bool
    let isFirstConversationPage: Bool
    let chat: SharedChat?
    let directory: SharedDirectory?
    let resource: SharedResourceView?
    let messaging: SharedMessagingView?
    var windowID: String? = nil
    var deviceSessions: SharedDeviceSessions? = nil
    var privacy: SharedPrivacy? = nil
    var favorites: SharedFavorites? = nil
    var activity: SharedActivityView? = nil
}
package enum SharedFailure: String, Error { case invalidConfiguration, invalidInput, busy, closed, authenticationRequired, networkUnavailable, storageUnavailable, operationFailed, cancelled, accountExists, publicHandleTaken, invalidPublicHandle, invalidDisplayName, invalidPassword, invalidRecoveryCode, rateLimited }
package func sharedFailure(_ error: any Error) -> SharedFailure {
    if let error = error as? V2ReadReceiptServiceError { switch error { case .closed: return .closed; case .invalidInput: return .invalidInput } }
    if let error = error as? V2MessageServiceError { switch error { case .closed: return .closed; case .invalidInput: return .invalidInput } }
    if error is CancellationError { return .cancelled }
    if let error = error as? SharedFailure { return error }
    if let error = error as? V2ConversationServiceError {
        switch error {
        case .closed: return .closed
        case .busy, .windowLimit: return .busy
        case .invalidQuery: return .invalidInput
        }
    }
    if error is V2CredentialStoreError || error is V2InstallationBindingStoreError { return .storageUnavailable }
    if let error = error as? V2AccountAuthenticationError, error == .authenticationRejected { return .authenticationRequired }
    if error is V2AuthSessionError || error is V2ClientSessionBootstrapError { return .authenticationRequired }
    if error is V2TLSFrameConnectionError || error is URLError { return .networkUnavailable }
    return .operationFailed
}

/// One actor owns one endpoint-scoped account session. Kotlin lifecycle calls are serialized;
/// this busy fence also rejects reentrant mutation from raw JNI callers. Snapshot reads are bounded.
package actor SharedRuntime {
    package nonisolated let ownershipKey: String
    private let base: URL
    private let endpoint: V2RealtimeEndpoint
    private let exitMarker: any SharedSecurePersistence
    private let credentialStore: any V2CredentialStore
    private let auth: V2AuthSession
    private let bootstrap: V2ClientSessionBootstrapper
    private let session: V2SharedSession
    private let registrations: V2DeviceRegistrationStore
    private let recovery: V2IssuedCredentialRecoveryStore
    private let revocationRunner: V2DeviceRevocationRunner
    private let cancellationRunner: V2DeviceRegistrationCancellationRunner
    private let http: any V2AuthHTTPTransport
    private let platform: SharedPlatform
    private var maintenance: [Task<Void, Never>] = []
    var conversationBusiness: V2ConversationService?
    private var bindingWindows: [String: SharedConversationWindowReader] = [:]
    private var store: GRDBV2LocalSyncStore?
    private var runtime: V2ClientRuntime?
    private var sync: V2SyncEngine?
    private var userID: String?
    private var state = "signedOut"
    private var connections: UInt64 = 0
    private var busy = false
    private var closed = false
    private var maintenanceFailure: SharedFailure?
    private var socialGroups: SharedSocialGroups?
    private var media: SharedMedia?
    private var messaging: SharedMessaging?
    var searchBusiness: V2SearchService?
    var receiptBusiness: V2ReadReceiptService?
    var messageBusiness: V2MessageService?
    private var sender: V2MessageSendOperationService?
    private var personalPreferences: V2PersonalPreferenceService?
    private var accountHTTP: V2SessionHTTPAuthorization?
    private var deviceSessionsClient: V2HTTPDeviceSessionClient?
    private var deviceSessions: SharedDeviceSessions?
    private var privacy: SharedPrivacy?
    private var favorites: SharedFavorites?
    private var favoriteCursor: V2ClientFavoriteMessageCursor?
    private var accountPreferences: V2AccountPreferenceService?
    private var preferencePreparation: Task<Void, Never>?
    private var messageModeration: V2MessageModerationOperationService?
    private var conversationActivity: SharedActivity?
    private var dispatcher: Task<Void, Never>?
    private var roomRecovery: V2RoomRecoveryRunner?
    private var selectedRoom: RoomID?
    private var conversationCursor: V2ClientConversationListCursor?
    private var nextConversationCursor: V2ClientConversationListCursor?
    private var focusMessage: MessageID?
    private var messageCursor: V2ClientTimelineCursor?
    private var olderMessageCursor: V2ClientTimelineCursor?
    private var pendingPage = 0
    private var hasMorePending = false

    package init(_ configuration: SharedConfiguration, platform: SharedPlatform) throws {
        self.platform = platform; self.http = platform.http
        guard let base = URL(string: configuration.accountURL), base.scheme == "https", base.host != nil,
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              base.path.isEmpty || base.path == "/", !configuration.gatewayHost.isEmpty,
              platform.isAbsolutePath(configuration.storageDirectory) else { throw SharedFailure.invalidConfiguration }
        self.base = base
        endpoint = try V2RealtimeEndpoint(host: configuration.gatewayHost, port: configuration.gatewayPort)
        let identity = base.absoluteString + "|" + configuration.gatewayHost + ":" + String(configuration.gatewayPort)
        let namespace = "shared-" + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let root = URL(fileURLWithPath: configuration.storageDirectory, isDirectory: true).appendingPathComponent(namespace, isDirectory: true)
        ownershipKey = root.standardizedFileURL.path
        exitMarker = platform.securePersistence(namespace + "-exit")
        credentialStore = platform.credentials(namespace + "-auth")
        let revocations = V2DeviceRevocationStore(persistence: platform.securePersistence(namespace + "-revoke"))
        registrations = V2DeviceRegistrationStore(persistence: platform.securePersistence(namespace + "-register"))
        recovery = V2IssuedCredentialRecoveryStore(persistence: platform.securePersistence(namespace + "-recovery"), revocations: revocations)
        auth = V2AuthSession(credentialStore: credentialStore,
            transport: try V2HTTPDeviceCredentialAuthTransport(refreshEndpoint: base.appendingPathComponent("v2/device-credentials/refresh"), transport: http),
            revocationScheduler: revocations)
        bootstrap = V2ClientSessionBootstrapper(authSession: auth,
            localStoreBootstrapper: V2LocalStoreBootstrapper(bindingStore: platform.installationBinding(namespace + "-binding")),
            databaseURL: root.appendingPathComponent("unused.sqlite"),
            accountStorageRoots: .init(persistent: root.appendingPathComponent("accounts"), cache: root.appendingPathComponent("cache")))
        session = V2SharedSession(authSession: auth, bootstrapper: bootstrap, exitIntent: SharedExitIntent(persistence: exitMarker), registrations: registrations)
        revocationRunner = V2DeviceRevocationRunner(store: revocations,
            client: try V2HTTPDeviceRevocationClient(endpoint: base.appendingPathComponent("v2/device-credentials/revoke"), transport: http))
        cancellationRunner = V2DeviceRegistrationCancellationRunner(store: registrations,
            client: try V2HTTPDeviceRegistrationCancellationClient(endpoint: base.appendingPathComponent("v2/device-credentials/cancel-registration"), transport: http))
    }

    package func execute(_ request: SharedRequest) async throws -> SharedSnapshot {
        // Avatar reads are display-only and must not take the account mutation fence:
        // a slow image fetch would otherwise delay sends, receipts and pagination.
        if request.operation == .avatar {
            guard !closed else { throw SharedFailure.closed }
            guard let socialGroups else { throw SharedFailure.authenticationRequired }
            try await socialGroups.execute(request)
            return try await snapshot()
        }
        if [.openListWindow, .openTimelineWindow, .readWindow, .watchWindow, .nextWindowPage, .resetWindow, .closeWindow].contains(request.operation) {
            return try await executeWindow(request)
        }
        if request.operation == .snapshot { return try await snapshot() }
        guard !closed else { throw SharedFailure.closed }
        guard !busy else { throw SharedFailure.busy }
        busy = true
        defer { busy = false }
        if request.operation == .restore || request.operation == .login || request.operation == .register {
            if try exitMarker.load() != nil { try await signOut() }
        }
        switch request.operation {
        case .restore:
            guard store == nil else { return try await snapshot() }
            try await recover()
            let authState = try await auth.restoreState()
            if case .unauthenticated = authState { state = "signedOut"; return try await snapshot() }
            let local = try await session.openLocallyEstablishedSession()
            store = local.store; userID = local.identity.userID.rawValue; state = "ready"
            do { try await configureConnection() }
            catch {
                // Local projections stay readable when the network or credential
                // path cannot be configured; sending remains unavailable.
                state = "offlineReadOnly"
                maintenanceFailure = sharedFailure(error)
                if conversationBusiness == nil, let localStore = store {
                    conversationBusiness = try? await session.conversations(for: localStore,
                        accountID: local.identity.userID, requiresAuthorization: false)
                }
            }
        case .login:
            guard store == nil, try await credentialStore.load() == nil else { throw SharedFailure.busy }
            guard let account = request.account, let password = request.password else { throw SharedFailure.invalidInput }
            try await recover()
            store = try await session.authenticatePassword(accountHandle: account, password: password,
                baseURL: base, metadata: platform.registrationMetadata, recovery: recovery, transport: http)
            userID = try await auth.localAccountIdentity().userID.rawValue
            state = "ready"
            try await configureConnection()
        case .deviceSessions:
            guard let client = deviceSessionsClient else { throw SharedFailure.authenticationRequired }
            let page = try await client.list(cursor: request.intentID, pageSize: 50)
            deviceSessions = SharedDeviceSessions(sessions: page.sessions.map {
                SharedDeviceSession(deviceID: $0.deviceID.rawValue, deviceName: $0.deviceName, platform: $0.platform,
                    createdAt: Int64($0.createdAt.timeIntervalSince1970 * 1000),
                    lastActiveAt: Int64($0.lastActiveAt.timeIntervalSince1970 * 1000),
                    isCurrentDevice: $0.isCurrentDevice)
            }, nextCursor: page.nextCursor)
        case .privacy:
            guard let service = accountPreferences, let store else { throw SharedFailure.authenticationRequired }
            var value = privacy ?? SharedPrivacy(blockedUsers: [])
            for kind in [V2OperationKind.strangerMessagePreference, .userAddPreference, .readReceiptPreference, .liveActivityPreference] {
                guard let snapshot = try? await service.baseline(kind: kind) else { continue }
                switch snapshot.value {
                case .strangerMessage(let permission): value.allowsStrangerMessages = permission == .allow
                case .userAdd(let permission): value.allowsUserAdd = permission == .allow
                case .readReceipt(let direct, let group):
                    value.allowsDirectReadReceipts = direct; value.allowsGroupReadReceipts = group
                case .liveActivity(let online, let typing):
                    value.allowsOnlinePresence = online; value.allowsTypingIndicators = typing
                }
            }
            value.blockedUsers = try await store.blocks().filter(\.isBlocked).map(\.targetUserID.rawValue)
            privacy = value
        case .favorites:
            guard let store else { throw SharedFailure.authenticationRequired }
            if request.action != "next" { favoriteCursor = nil }
            let page = try await store.favoritedMessages(before: favoriteCursor, limit: 50)
            favoriteCursor = page.nextCursor
            let titles = try await store.conversationTitles(for: Array(Set(page.messages.map(\.roomID))))
            var rows: [SharedFavoriteMessage] = []
            for message in page.messages {
                guard try await store.roomAllowsLocalRead(roomID: message.roomID) else { continue }
                rows.append(SharedFavoriteMessage(id: message.messageID.rawValue, roomID: message.roomID.rawValue,
                    roomTitle: titles[message.roomID] ?? "会话", senderID: message.senderUserID.rawValue,
                    text: message.isWithdrawn ? "消息已撤回" : String(message.text.prefix(160)),
                    createdAt: Int64(message.createdAt.timeIntervalSince1970 * 1000),
                    attachmentNames: message.mediaPresentations.map { $0.resourceDescriptor?.displayName.value ?? "附件" }))
            }
            favorites = SharedFavorites(messages: rows, hasMore: page.nextCursor != nil)
        case .activity:
            guard let conversationActivity, let store, let roomID = request.roomID else { throw SharedFailure.authenticationRequired }
            let room = try RoomID(roomID)
            guard try await store.roomAllowsLocalRead(roomID: room) else { throw SharedFailure.invalidInput }
            let isGroup = try await store.roomProfile(roomID: room) != nil
            try await conversationActivity.open(room: room, isGroup: isGroup)
        case .setTyping:
            guard let conversationActivity, let typing = request.flag1 else { throw SharedFailure.invalidInput }
            try await conversationActivity.setTyping(typing)
        case .closeActivity:
            await conversationActivity?.close()
        case .moderateMessage:
            guard let service = messageModeration, let roomID = request.roomID,
                  let messageID = request.messageID else { throw SharedFailure.invalidInput }
            let baseline = try await service.baseline(roomID: try RoomID(roomID), messageID: try MessageID(messageID))
            _ = try await service.enqueue(baseline: baseline, reason: try .init("ADMIN_ACTION"))
        case .pinMessage:
            guard let socialGroups, let roomID = request.roomID, let messageID = request.messageID,
                  let sequence = request.offset, let pinned = request.flag1 else { throw SharedFailure.invalidInput }
            try await socialGroups.pinMessage(roomID: roomID, messageID: messageID, roomSequence: UInt64(sequence), isPinned: pinned)
        case .setFavorite:
            guard let preferences = personalPreferences, let roomID = request.roomID,
                  let messageID = request.messageID, let favorited = request.flag1 else { throw SharedFailure.invalidInput }
            try await preferences.enqueue(.favorite(roomID: try RoomID(roomID), messageID: try MessageID(messageID), isFavorited: favorited))
            try? await preferences.runPreparation()
        case .setPrivacy:
            guard let service = accountPreferences, let kind = request.action else { throw SharedFailure.invalidInput }
            let patch: V2AccountPreferencePatch
            switch kind {
            case "strangerMessage":
                guard let flag = request.flag1 else { throw SharedFailure.invalidInput }
                patch = .strangerMessage(flag ? .allow : .deny)
            case "userAdd":
                guard let flag = request.flag1 else { throw SharedFailure.invalidInput }
                patch = .userAdd(flag ? .allow : .deny)
            case "readReceipt":
                guard request.flag1 != nil || request.flag2 != nil else { throw SharedFailure.invalidInput }
                patch = .readReceipt(direct: request.flag1, group: request.flag2)
            case "liveActivity":
                guard request.flag1 != nil || request.flag2 != nil else { throw SharedFailure.invalidInput }
                patch = .liveActivity(online: request.flag1, typing: request.flag2)
            default: throw SharedFailure.invalidInput
            }
            try await service.enqueue(patch: patch)
            var value = privacy ?? SharedPrivacy(blockedUsers: [])
            switch patch {
            case .strangerMessage(let permission): value.allowsStrangerMessages = permission == .allow
            case .userAdd(let permission): value.allowsUserAdd = permission == .allow
            case .readReceipt(let direct, let group):
                if let direct { value.allowsDirectReadReceipts = direct }
                if let group { value.allowsGroupReadReceipts = group }
            case .liveActivity(let online, let typing):
                if let online { value.allowsOnlinePresence = online }
                if let typing { value.allowsTypingIndicators = typing }
            }
            privacy = value
            try? await service.prepareNext()
        case .revokeDevice:
            guard let accountHTTP else { throw SharedFailure.authenticationRequired }
            let identity = try await auth.localAccountIdentity()
            let client = try V2HTTPRemoteDeviceRevocationClient(baseURL: base, credentials: accountHTTP, transport: accountHTTP)
            let baseline = try await client.baseline()
            guard baseline.actorUserID == identity.userID, baseline.currentDeviceID == identity.deviceID else {
                throw SharedFailure.invalidInput
            }
            let selection: V2RemoteDeviceRevocationCommand.Selection
            if request.action == "all" {
                selection = .allObservedOthers
            } else {
                guard let raw = request.targetUserID, let target = try? DeviceID(raw),
                      baseline.targetDeviceIDs.contains(target) else { throw SharedFailure.invalidInput }
                selection = .device(target)
            }
            let now = UInt64(Date().timeIntervalSince1970 * 1000)
            let deadline = min(now + 120_000, baseline.expiresAtMilliseconds)
            let command = try V2RemoteDeviceRevocationCommand(operationID: UUID(), baseline: baseline,
                selection: selection, firstSubmissionDeadlineMilliseconds: deadline)
            switch try await client.submit(command) {
            case .receipt(let receipt):
                guard case .revoked = receipt.outcome else { throw SharedFailure.operationFailed }
                deviceSessions = nil
            case .unresolved, .fingerprintConflict:
                throw SharedFailure.operationFailed
            }
        case .passwordLifecycle:
            guard let account = request.account, let action = request.action else { throw SharedFailure.invalidInput }
            let lifecycle: V2PasswordLifecycleAction
            switch action {
            case "change": lifecycle = .change
            case "recovery-code": lifecycle = .recoveryCode
            case "recover": lifecycle = .recover
            default: throw SharedFailure.invalidInput
            }
            let client = try V2PasswordLifecycleClient(baseURL: base, transport: http)
            try await client.perform(lifecycle, accountHandle: account,
                deviceID: try DeviceID(uuid: UUID()), currentPassword: request.password,
                newPassword: request.newPassword, recoveryCode: request.recoveryCode)
        case .register:
            guard store == nil, try await credentialStore.load() == nil else { throw SharedFailure.busy }
            guard let account = request.account, let password = request.password,
                  let handle = request.publicHandle, let name = request.displayName else { throw SharedFailure.invalidInput }
            try await recover()
            store = try await session.authenticatePassword(accountHandle: account, password: password,
                mode: .register, publicHandle: handle, displayName: name,
                baseURL: base, metadata: platform.registrationMetadata, recovery: recovery, transport: http)
            userID = try await auth.localAccountIdentity().userID.rawValue
            state = "ready"
            try await configureConnection()
        case .connect:
            if state == "offlineReadOnly", runtime == nil {
                do { try await configureConnection(); state = "ready" }
                catch { state = "offlineReadOnly"; throw error }
                return try await snapshot()
            }
            guard let runtime else { throw SharedFailure.authenticationRequired }
            if case .running = await runtime.currentState() { return try await snapshot() }
            state = "connecting"
            do {
                _ = try await runtime.start()
                try Task.checkCancellation()
                connections += 1; state = "connected"
            } catch { await runtime.stop(); state = "offline"; throw error }
        case .disconnect:
            await runtime?.stop(); state = store == nil ? "signedOut" : "offline"
        case .synchronize:
            guard let sync else { throw SharedFailure.authenticationRequired }
            _ = try await sync.synchronizeIncludingResets()
        case .signOut:
            try await signOut()
        case .conversationState:
            guard let store, let preferences = personalPreferences, let rawRoom = request.roomID else { throw SharedFailure.invalidInput }
            let room = try RoomID(rawRoom)
            guard try await store.roomAllowsLocalRead(roomID: room) else { throw SharedFailure.invalidInput }
            let current = try await store.conversationState(roomID: room)
            let pinned = request.isPinned ?? current?.isPinned ?? false
            let archived = request.archived ?? current?.isArchived ?? false
            let mute = request.muteUntil.map { $0 > 0 ? Date(timeIntervalSince1970: Double($0) / 1000) : nil } ?? current?.muteUntil
            try await preferences.enqueue(.conversation(roomID: room, isPinned: pinned, isArchived: archived, muteUntil: mute))
            try? await preferences.runPreparation()
        case .locateMessage:
            guard let business = conversationBusiness, let rawRoom = request.roomID, let rawID = request.messageID else { throw SharedFailure.invalidInput }
            let room = try RoomID(rawRoom), id = try MessageID(rawID)
            guard case .found(let window) = try await business.locate(in: room, messageID: id, before: 24, after: 25) else { throw SharedFailure.invalidInput }
            let chat = await renderChat(timeline: window.page, pending: nil, room: room, isLatest: false, focused: id)
            guard conversationBusiness === business else { throw SharedFailure.closed }
            return .init(state: state, userID: userID, allowsStrangerMessages: nil, appliedSequence: 0, acknowledgedSequence: 0,
                         connections: connections, conversations: [], failure: nil, hasMoreConversations: false, isFirstConversationPage: true,
                         chat: chat, directory: nil, resource: nil, messaging: nil)
        case .searchMessages:
            guard let messaging else { throw SharedFailure.authenticationRequired }; try await messaging.search(request)
        case .clearMessaging: await messaging?.clearTransient()
        case .forwardMessage, .interactionAction:
            guard let messaging, let room = selectedRoom, request.roomID == room.rawValue else { throw SharedFailure.invalidInput }
            try await messaging.interact(request, room: room)
        case .messageAction, .markVisibleMessages, .messageReaders:
            guard let messaging, let room = selectedRoom, request.roomID == room.rawValue else { throw SharedFailure.invalidInput }
            switch request.operation {
            case .messageAction: try await messaging.action(request, room: room)
            case .markVisibleMessages: try await messaging.visible(request.messageIDs ?? [], room: room)
            default: try await messaging.readers(request, room: room)
            }
        case .openConversation:
            guard let store, let id = request.roomID else { throw SharedFailure.invalidInput }
            let room = try RoomID(id)
            guard try await store.roomAllowsLocalRead(roomID: room) else { throw SharedFailure.invalidInput }
            if selectedRoom != room { await media?.clear() }
            if let id = request.messageID {
                let message = try MessageID(id)
                guard let messaging else { throw SharedFailure.authenticationRequired }
                _ = try await messaging.message(room: room, id: message); focusMessage = message
            } else { focusMessage = nil }
            selectedRoom = room; messageCursor = nil; olderMessageCursor = nil; pendingPage = 0
            await messaging?.clearTransient(); await messaging?.open(room)
            if let runtime, case .running = await runtime.currentState() { try await roomRecovery?.requestLatestVisible(roomIDs: [room]) }
        case .conversationsFirst: conversationCursor = nil
        case .conversationsNext:
            guard let nextConversationCursor else { return try await snapshot() }
            conversationCursor = nextConversationCursor
        case .messagesLatest: messageCursor = nil; focusMessage = nil
        case .messagesOlder:
            guard let olderMessageCursor else { return try await snapshot() }
            messageCursor = olderMessageCursor; focusMessage = nil
        case .pendingFirst: pendingPage = 0
        case .pendingNext: if hasMorePending { pendingPage += 1 }
        case .beginAttachment, .sendAttachment, .openResource:
            guard let media, let room = selectedRoom, request.roomID == room.rawValue else { throw SharedFailure.invalidInput }
            switch request.operation {
            case .beginAttachment: try await media.begin(request, room: room)
            case .sendAttachment: try await media.send(request, room: room); messageCursor = nil; pendingPage = 0
            default: try await media.open(request, room: room)
            }
        case .appendAttachment, .finishAttachment, .clearResources, .downloadResource, .previewResource, .beginResourceRead, .readResource, .endResourceRead, .transferAction, .cancelAttachmentSend:
            guard let media else { throw SharedFailure.authenticationRequired }
            switch request.operation {
            case .appendAttachment: try await media.append(request)
            case .finishAttachment: try await media.finish(request)
            case .clearResources: await media.clear()
            case .downloadResource: try await media.download()
            case .previewResource: try await media.imagePreview()
            case .beginResourceRead: try await media.beginRead()
            case .readResource: return try await snapshot(resourceChunk: try await media.read(request))
            case .endResourceRead: await media.endRead()
            case .transferAction: try await media.action(request)
            case .cancelAttachmentSend:
                guard let id = UUID(uuidString: request.intentID ?? "") else { throw SharedFailure.invalidInput }; try await media.cancelSend(id)
            default: break
            }
        case .sendText:
            guard let business = messageBusiness, let room = selectedRoom, request.roomID == room.rawValue,
                  let text = request.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SharedFailure.invalidInput }
            let reply = try request.replyToMessageID.map { V2MessageReplyReference(messageID: try MessageID($0)) }
            let mentions = try await socialGroups?.resolveMentions(request.mentions ?? []) ?? []
            _ = try await business.send(in: room, text: text, mentions: mentions, replyTo: reply)
            messageCursor = nil; focusMessage = nil; pendingPage = 0
        case .resendUnsent:
            guard let business = messageBusiness, let id = request.intentID.flatMap(UUID.init(uuidString:)) else { throw SharedFailure.invalidInput }
            try await business.resendUnsent(id)
        case .retrySend:
            guard let business = messageBusiness, let raw = request.intentID, let id = UUID(uuidString: raw) else { throw SharedFailure.invalidInput }
            try await business.retrySend(id)
        case .openAvatarEditor, .changeAvatar, .avatarAction, .contacts, .contactsNext, .groupsFirst, .groupsNext, .lookupIdentity, .clearDiscovery, .socialAction, .openDirect, .createGroup, .openGroup, .groupMembersNext, .groupAction, .retryDirectoryWork, .discardDirectoryDraft, .profiles, .clearProfiles, .avatar, .groupNickname, .saveGroupNickname, .moderateMemberRemoval, .pinMessage, .openProfile, .saveAlias, .invitations, .invitationsNext, .previewInvite, .refreshInvite, .inviteAction, .muteMember:
            guard let socialGroups else { throw SharedFailure.authenticationRequired }
            if request.operation == .clearDiscovery { await media?.clear(); await messaging?.clearTransient() }
            try await socialGroups.execute(request)
        case .close:
            await stopAccount()
            for task in maintenance { task.cancel() }
            for task in maintenance { await task.value }
            await session.suspendMaintenance()
            maintenance.removeAll()
            if let store { try await session.closeLocalStore(store) }
            store = nil; runtime = nil; sync = nil; closed = true; state = "closed"
        case .openListWindow, .openTimelineWindow, .readWindow, .watchWindow, .nextWindowPage, .resetWindow, .closeWindow: break
        case .snapshot: break
        }
        return try await snapshot()
    }
    private func stopAccount() async {
        let windows = Array(bindingWindows.values); bindingWindows.removeAll()
        for window in windows { await window.close() }
        await conversationBusiness?.close(); conversationBusiness = nil
        dispatcher?.cancel()
        await receiptBusiness?.close(); receiptBusiness = nil
        await searchBusiness?.stopIndexing(); searchBusiness = nil
        await messageBusiness?.close(); messageBusiness = nil
        await messaging?.close(); messaging = nil; focusMessage = nil
        await media?.close(); media = nil
        await socialGroups?.stop()
        socialGroups = nil
        await runtime?.stop()
        await dispatcher?.value
        dispatcher = nil; sender = nil; roomRecovery = nil; personalPreferences = nil
        accountHTTP = nil; deviceSessionsClient = nil; deviceSessions = nil
        favorites = nil; favoriteCursor = nil
        preferencePreparation?.cancel(); preferencePreparation = nil; accountPreferences = nil; privacy = nil
        messageModeration = nil
        await conversationActivity?.close(); conversationActivity = nil
    }
    private func signOut() async throws {
        // Intent survives cancellation/crash between revocation handoff and local deletion.
        try await session.beginSignOut()
        state = "signingOut"; userID = nil; selectedRoom = nil
        conversationCursor = nil; nextConversationCursor = nil; messageCursor = nil; olderMessageCursor = nil; pendingPage = 0; hasMorePending = false
        await stopAccount()
        if let store { try await session.closeLocalStore(store) }
        store = nil; runtime = nil; sync = nil
        try await session.completeSignOut()
        state = "signedOut"; connections = 0; maintenanceFailure = nil
    }
    private func recover() async throws {
        let record = try await credentialStore.load()
        try await registrations.recoverUnclaimed(ownedBy: record)
        try await recovery.recoverUnclaimed(ownedBy: record)
        if maintenance.isEmpty {
            maintenance = [Task { [revocationRunner, session] in
                do { try await session.runMaintenance(.deviceRevocation) { try await revocationRunner.run() } } catch is CancellationError {} catch { self.maintenanceFailure = sharedFailure(error) }
            }, Task { [cancellationRunner, session] in
                do { try await session.runMaintenance(.registrationCancellation) { try await cancellationRunner.run() } } catch is CancellationError {} catch { self.maintenanceFailure = sharedFailure(error) }
            }]
        }
    }
    private func configureConnection() async throws {
        guard let store else { return }
        let wire = V2TLSFrameConnection(connectionFactory: { [platform, endpoint] in platform.tlsConnection(endpoint) },
            frameLimits: try .init(maximumPayloadBytes: 65_536, acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)]), requestTimeout: .seconds(15))
        let coordinator = V2RealtimeSessionCoordinator(authSession: auth, connection: wire, supportedCapabilityProfiles: ["base"])
        let transport = V2ProtobufSyncTransport(wire: wire, protocolVersion: UInt8(IMV2ProtocolVersion.current),
            durableRoomProgress: { roomID in try await store.roomProgressAppliedSequence(roomID: roomID) })
        let sync = V2SyncEngine(transport: transport, store: store, capabilityProfile: "base")
        self.sync = sync
        let identity = try await auth.localAccountIdentity()
        await store.useCommandTimeAnchor(wire.serverTime)
        let sender = V2MessageSendOperationService(accountID: identity.userID, store: store,
            client: V2RoutedMessageSendOperationClient(accountID: identity.userID,
                realtime: V2ProtobufMessageSendOperationClient(transport: transport, connection: wire)))
        self.sender = sender
        let accountHTTP = V2SessionHTTPAuthorization(session: auth, epoch: await auth.currentEpoch(), transport: http)
        self.accountHTTP = accountHTTP
        deviceSessionsClient = try V2HTTPDeviceSessionClient(endpoint: base.appendingPathComponent("v2/devices"),
            credentials: accountHTTP, transport: accountHTTP)
        let business = try await session.messages(for: store, accountID: identity.userID, sends: sender,
            mutations: .init(accountID: identity.userID, store: store, client: try V2HTTPMessageMutationOperationClient(baseURL: base, credentials: accountHTTP, transport: accountHTTP)),
            forwards: .init(accountID: identity.userID, store: store, client: try V2HTTPForwardPlanOperationClient(baseURL: base, credentials: accountHTTP, transport: accountHTTP)))
        messageBusiness = business
        let installation = try await store.boundInstallationBinding().value.uuidString
        guard let scope = try await bootstrap.storageScope(for: store) else { throw SharedFailure.storageUnavailable }
        let socialGroups = try await SharedSocialGroups(storageScope: scope, installation: installation, account: identity.userID, device: identity.deviceID, store: store, transport: transport, base: base, http: accountHTTP, platform: platform)
        self.socialGroups = socialGroups
        await socialGroups.start()
        let avatars = await socialGroups.avatars
        let media = try await SharedMedia(account: identity.userID, store: store, resources: avatars.resources, uploads: avatars.transfers, base: base, http: accountHTTP, rangeTransport: platform.rangeTransport, createStagingFile: platform.createStagingFile, messages: business)
        self.media = media; await media.start()
        let search = try await session.search(for: store)
        searchBusiness = search
        let reads = try await session.readReceipts(for: store, accountID: identity.userID,
            receipts: .init(accountID: identity.userID, store: store,
                client: try V2ReadReceiptOperationAdapter(realtime: transport, baseURL: base, credentials: accountHTTP, transport: accountHTTP)), transport: transport)
        receiptBusiness = reads
        let messaging = SharedMessaging(account: identity.userID, store: store, messages: business, search: search, reads: reads)
        self.messaging = messaging; await messaging.start()
        let recovery = V2RoomRecoveryRunner(engine: V2RoomRecoveryEngine(transport: transport, latestVisible: transport,
            store: store, groupEvents: V2GroupEventSyncEngine(transport: transport, store: store),
            didPersistProgress: { room, cursor in try await transport.enqueueDeviceRoomProgress(roomID: room, appliedThrough: cursor) }),
            source: wire, personalSync: sync)
        roomRecovery = recovery
        let subscriptions = V2RoomSubscriptionCoordinator(subscriptions: transport, activity: transport,
            groupEvents: wire, activityEvents: wire,
            isAuthorized: { roomID in try await store.roomAllowsLocalRead(roomID: roomID) },
            roomCursor: { roomID in try await store.groupEventCursor(roomID: roomID) })
        let conversationActivity = SharedActivity(accountID: identity.userID, transport: transport, rooms: subscriptions)
        self.conversationActivity = conversationActivity
        let moderationClient = try V2HTTPMessageModerationClient(baseURL: base, credentials: accountHTTP, transport: accountHTTP)
        let messageModeration = V2MessageModerationOperationService(accountID: identity.userID,
            activationID: identity.deviceID.uuidValue ?? UUID(), store: store, client: moderationClient)
        self.messageModeration = messageModeration
        let accountPreferences = V2AccountPreferenceService(accountID: identity.userID, activationID: identity.deviceID.uuidValue ?? UUID(), store: store,
            client: try V2HTTPAccountPreferenceOperationClient(baseURL: base, credentials: accountHTTP, transport: accountHTTP))
        self.accountPreferences = accountPreferences
        preferencePreparation = Task { try? await accountPreferences.runPreparation() }
        let personalPreferences = V2PersonalPreferenceService(accountID: identity.userID, store: store, transport: transport,
            recovery: try V2HTTPPersonalPreferenceRecoveryClient(roomsEndpoint: base.appendingPathComponent("v2/rooms"),
                credentials: accountHTTP, transport: accountHTTP))
        self.personalPreferences = personalPreferences
        try? await personalPreferences.runPreparation()
        conversationBusiness = try await session.conversations(for: store, accountID: identity.userID,
            requestLatestVisible: { try await recovery.requestLatestVisible(roomIDs: $0) })
        runtime = V2ClientRuntime(connection: coordinator, activity: V2DefaultClientRuntimeActivity(syncEngine: sync,
            availabilitySource: wire, heartbeatSender: transport, heartbeatInterval: .seconds(2),
            afterDurableSynchronization: { await recovery.requestCatchUp() },
            roomCatchUpLoop: { try await recovery.run(userID: identity.userID) },
            policyRecoveryLoops: [
                { try await V2RolePolicyRecoveryRunner(store: store, transport: transport).run() },
                { try await transport.runDeviceRoomProgressReports() },
                { try await V2MessageSendNetworkRecoveryRunner(store: store, accountID: identity.userID) {
                    await wire.messageSendSession()?.accountID == identity.userID
                }.run() }
            ]))
        let worker = V2OperationWorkDispatcher(store: store, handlers: (await business.handlers()) + (await socialGroups.handlers()) + (await messaging.handlers()) + [
            .init(kind: .conversationPreference) { try await personalPreferences.execute($0) },
            .init(kind: .messageFavorite) { try await personalPreferences.execute($0) },
            .init(kind: .strangerMessagePreference) { try await accountPreferences.execute($0) },
            .init(kind: .userAddPreference) { try await accountPreferences.execute($0) },
            .init(kind: .readReceiptPreference) { try await accountPreferences.execute($0) },
            .init(kind: .liveActivityPreference) { try await accountPreferences.execute($0) },
            .init(kind: .moderation) { try await messageModeration.execute($0) },
        ])
        dispatcher = Task {
            do {
                // Text-only intents interrupted after freeze retain their original identities.
                for intent in try await store.preparingSendIntents(limit: 256) where intent.attachmentJobIDs.isEmpty {
                    _ = try await store.handOffSendIntent(intent.id)
                }
                try await worker.run()
            } catch is CancellationError {} catch { self.maintenanceFailure = sharedFailure(error) }
        }
    }
    private func executeWindow(_ request: SharedRequest) async throws -> SharedSnapshot {
        guard !closed, let business = conversationBusiness else { throw SharedFailure.authenticationRequired }
        let reader: SharedConversationWindowReader
        switch request.operation {
        case .openListWindow:
            reader = SharedConversationWindowReader(window: try await business.openList(isArchived: request.archived ?? false, limit: request.limit ?? 50), room: nil)
            guard conversationBusiness === business else { await reader.close(); throw SharedFailure.closed }
            bindingWindows[reader.id] = reader
        case .openTimelineWindow:
            guard let raw = request.roomID else { throw SharedFailure.invalidInput }
            let room = try RoomID(raw)
            reader = SharedConversationWindowReader(window: try await business.openTimeline(in: room, limit: request.limit ?? 50), room: room)
            guard conversationBusiness === business else { await reader.close(); throw SharedFailure.closed }
            bindingWindows[reader.id] = reader
        default:
            guard let id = request.windowID, let existing = bindingWindows[id] else { throw SharedFailure.closed }
            reader = existing
        }
        if request.operation == .closeWindow {
            bindingWindows.removeValue(forKey: reader.id); await reader.close()
            return .init(state: state, userID: userID, allowsStrangerMessages: nil, appliedSequence: 0, acknowledgedSequence: 0,
                connections: connections, conversations: [], failure: nil, hasMoreConversations: false, isFirstConversationPage: true,
                chat: nil, directory: nil, resource: nil, messaging: nil, windowID: reader.id)
        }
        let created = request.operation == .openListWindow || request.operation == .openTimelineWindow
        do {
        let content: V2ConversationWindowContent
        switch request.operation {
        case .watchWindow: content = try await reader.next()
        case .nextWindowPage: content = try await reader.window.nextPage()
        case .resetWindow: content = try await reader.window.reset()
        default: content = try await reader.window.read()
        }
        var rows: [SharedConversation] = [], chat: SharedChat?, hasMore = false
        let first = await reader.window.isFirstPage()
        switch content {
        case .conversations(let value):
            hasMore = value.page.nextCursor != nil
            rows = value.page.entries.map { .row($0, list: value) }
        case .timeline(let value):
            guard let room = reader.room else { throw SharedFailure.invalidInput }
            chat = await renderChat(timeline: value.page, pending: value.pending, room: room, isLatest: first)
        }
        try Task.checkCancellation()
        guard conversationBusiness === business, bindingWindows[reader.id] === reader else { throw SharedFailure.closed }
        return .init(state: state, userID: userID, allowsStrangerMessages: nil, appliedSequence: 0, acknowledgedSequence: 0,
            connections: connections, conversations: rows, failure: nil, hasMoreConversations: hasMore, isFirstConversationPage: first,
            chat: chat, directory: nil, resource: nil, messaging: nil, windowID: reader.id)
        } catch {
            if created { bindingWindows.removeValue(forKey: reader.id); await reader.close() }
            throw error
        }
    }

    private func renderChat(timeline: V2ClientConversationTimelinePage, pending: V2PendingResourceSendSnapshot?,
        room: RoomID, isLatest: Bool, focused: MessageID? = nil, pendingPage: Int = 0) async -> SharedChat {
            let favorites = (try? await store?.favoritedMessageIDs(in: room)) ?? []
            let pinned = (try? await store?.pinnedMessageIDs(roomID: room)) ?? []
            var replyPreviews: [MessageID: String] = [:]
            for id in Set(timeline.messages.filter { !$0.isWithdrawn }.compactMap { $0.replyTo?.messageID }) {
                if let original = try? await messaging?.message(room: room, id: id) {
                    replyPreviews[id] = original.text.isEmpty ? "[附件]" : String(original.text.prefix(160))
                }
            }
            let messages = timeline.messages.map { message -> SharedMessage in
                let attachments: [SharedAttachment] = message.isWithdrawn ? [] : message.mediaPresentations.map(SharedAttachment.init)
                let entities: [SharedEntity] = message.isWithdrawn ? [] : message.entities.map {
                    SharedEntity(kind: $0.kind.rawValue, offset: $0.offsetUTF16, length: $0.lengthUTF16,
                                 url: $0.linkURL?.absoluteString)
                }
                let reply: MessageID? = message.isWithdrawn ? nil : message.replyTo?.messageID
                let recipientRead: Bool = timeline.directReadReceipt?.isVisible == true
                    && timeline.directReadReceipt?.readerUserID.rawValue != userID
                    && (timeline.directReadReceipt?.readThroughRoomSequence ?? 0) >= message.roomSequence
                return SharedMessage(id: message.messageID.rawValue, senderID: message.senderUserID.rawValue,
                    text: message.isWithdrawn ? "" : message.text, sequence: message.timelineSequence,
                    createdAt: Int64(message.createdAt.timeIntervalSince1970 * 1000), withdrawn: message.isWithdrawn,
                    hasMedia: !message.media.isEmpty, attachments: attachments,
                    revision: message.messageRevision,
                    canMutate: message.senderUserID.rawValue == userID && !message.isWithdrawn && message.messageRevision > 0,
                    readByPeer: message.senderUserID.rawValue == userID && recipientRead,
                    replyToID: reply?.rawValue,
                    replyPreview: reply.flatMap { replyPreviews[$0] },
                    forwardedFromID: message.isWithdrawn ? nil : message.forwardedFrom?.messageID.rawValue,
                    isFavorited: favorites.contains(message.messageID),
                    mentionSummary: Self.mentionSummary(message.mentions),
                    entities: entities,
                    roomSequence: message.roomSequence,
                    isPinned: pinned.contains(message.messageID))
            }
            let pendingMessages: [SharedPendingMessage] = (pending?.preparing ?? []).map(SharedPendingMessage.preparing)
                + (pending?.submitted ?? []).map {
                    .init(id: $0.id.uuidString, text: $0.text, status: String(describing: $0.status),
                          createdAt: Int64($0.createdAt.timeIntervalSince1970 * 1000))
                }
            return SharedChat(roomID: room.rawValue, messages: messages, pending: pendingMessages,
                focusMessageID: focused?.rawValue, hasOlder: timeline.olderCursor != nil, isLatest: isLatest,
                hasMorePending: pending?.hasNext ?? false, pendingPage: pendingPage)
    }

    private static func mentionSummary(_ mentions: [V2MentionTarget]) -> String? {
        guard !mentions.isEmpty else { return nil }
        let everyone = mentions.contains(.everyone)
        let users = mentions.filter { if case .user = $0 { return true }; return false }.count
        if everyone && users > 0 { return "提及所有人及 \(users) 位成员" }
        if everyone { return "提及所有人" }
        return "提及 \(users) 位成员"
    }

    private func snapshot(resourceChunk: String? = nil) async throws -> SharedSnapshot {
        var currentState = state
        if let runtime, state == "connected", await runtime.currentState() == .stopped { currentState = "offline" }
        let cursor = try await store?.cursor()
        let list = try await conversationBusiness?.list(isArchived: false, before: conversationCursor, limit: 50)
        let page = list?.page
        nextConversationCursor = page?.nextCursor
        let rows = list.map { list in list.page.entries.map { SharedConversation.row($0, list: list) } } ?? []
        let failure = await runtime?.lastBackgroundFailure().map(sharedFailure) ?? maintenanceFailure
        let preference = try await store?.strangerMessagePreference()
        var chat: SharedChat?
        if let conversationBusiness, let room = selectedRoom {
            let value = try await conversationBusiness.timeline(in: room, before: messageCursor, limit: 50, pendingPage: pendingPage)
            var timeline = value.page
            if let focusMessage {
                if case .found(let window) = try await conversationBusiness.locate(in: room, messageID: focusMessage, before: 24, after: 25) { timeline = window.page }
                else { self.focusMessage = nil }
            }
            olderMessageCursor = timeline.olderCursor
            hasMorePending = value.pending.hasNext
            chat = await renderChat(timeline: timeline, pending: value.pending, room: room,
                isLatest: messageCursor == nil && focusMessage == nil, focused: focusMessage, pendingPage: pendingPage)
        }
        return .init(state: currentState, userID: userID, allowsStrangerMessages: preference?.allowsStrangerMessages, appliedSequence: cursor?.appliedSequence ?? 0,
            acknowledgedSequence: cursor?.serverAcknowledgedSequence ?? 0, connections: connections,
            conversations: rows, failure: failure?.rawValue,
            hasMoreConversations: page?.nextCursor != nil, isFirstConversationPage: conversationCursor == nil, chat: chat, directory: try await socialGroups?.snapshot(), resource: await media?.snapshot(chunk: resourceChunk), messaging: try await messaging?.snapshot(), deviceSessions: deviceSessions, privacy: privacy, favorites: favorites, activity: await conversationActivity?.view())
    }
}
