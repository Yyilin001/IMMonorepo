import Foundation
import IMV2ClientKit
import IMV2Core

enum V2ConversationSendOutcome: Equatable, Sendable {
    case accepted
    case queuedForRetry
    case rejected(code: String)
}

protocol V2ConversationSending: Sendable {
    func send(text: String, media: [V2MediaReference], in roomID: String) async throws -> V2ConversationSendOutcome
}

extension V2ConversationSending {
    func send(text: String, in roomID: String) async throws -> V2ConversationSendOutcome {
        try await send(text: text, media: [], in: roomID)
    }
}

enum V2MessageWithdrawalOutcome: Equatable, Sendable {
    case accepted
    case queuedForRetry
    case rejected(code: String)
}

/// UI-facing withdrawal boundary. Its implementation must make the operation
/// durable before attempting transport so a connection loss cannot drop intent.
protocol V2MessageWithdrawing: Sendable {
    func withdraw(messageID: String, in roomID: String, expectedMessageRevision: UInt64) async throws -> V2MessageWithdrawalOutcome
}

enum V2MessageReactionOutcome: Equatable, Sendable {
    case accepted
    case queuedForRetry
    case rejected(code: String)
}

/// UI-facing reaction boundary. The message projection remains authoritative
/// for the visible reaction set after the durable command is acknowledged.
protocol V2MessageReactionChanging: Sendable {
    func changeReaction(messageID: String, in roomID: String, reaction: String, action: V2MessageReactionAction) async throws -> V2MessageReactionOutcome
}

enum V2MessageEditOutcome: Equatable, Sendable {
    case accepted
    case queuedForRetry
    case rejected(code: String)
}

/// UI-facing edit boundary. The caller supplies the revision from its durable
/// projection; the server remains authoritative for authorship and conflicts.
protocol V2MessageEditing: Sendable {
    func edit(messageID: String, in roomID: String, expectedMessageRevision: UInt64, text: String) async throws -> V2MessageEditOutcome
}

enum V2ReadReceiptReportOutcome: Equatable, Sendable {
    case recorded
    case alreadyRecorded
    case queuedForRetry
    case rejected(code: String)
}

protocol V2ConversationReadReporting: Sendable {
    func recordReadThrough(roomID: String, roomSequence: UInt64) async throws -> V2ReadReceiptReportOutcome
}

/// Opens the deterministic direct room for the signed-in user and a target
/// user. Opening is idempotent on the server, so it is safe to retry after a
/// transport interruption; no message content is at risk at this boundary.
protocol V2DirectConversationOpening: Sendable {
    func openConversation(with targetUserID: String) async throws -> String
}

/// Resolves an explicit public handle before the realtime protocol receives an
/// opaque user ID. This keeps UUIDs out of all product-facing entry fields.
protocol V2ConversationPublicIdentityResolving: Sendable {
    func resolve(handle: String) async throws -> V2PublicIdentity
}

extension V2HTTPPublicIdentityDirectory: V2ConversationPublicIdentityResolving {}

enum V2GroupConversationCreationOutcome: Equatable, Sendable {
    case created(roomID: String)
    case queuedForRetry
    case rejected(code: String)
}

protocol V2GroupConversationCreating: Sendable {
    func createConversation(title: String, initialMemberUserIDs: [String]) async throws -> V2GroupConversationCreationOutcome
}

struct V2GroupMemberItem: Equatable, Identifiable, Sendable {
    let id: String
    let role: String
}

struct V2GroupMemberPage: Equatable, Sendable {
    let membershipRevision: UInt64
    let actorRole: String
    let members: [V2GroupMemberItem]
    let nextCursor: String?
}

protocol V2GroupMemberDirectoryReading: Sendable {
    func members(in roomID: String, cursor: String?) async throws -> V2GroupMemberPage
}

enum V2GroupMembershipChangeOutcome: Equatable, Sendable {
    case accepted
    case queuedForRetry
    case rejected(code: String)
}

protocol V2GroupMembershipChanging: Sendable {
    func changeMembership(roomID: String, targetUserID: String, action: V2RoomMembershipAction, expectedMembershipRevision: UInt64) async throws -> V2GroupMembershipChangeOutcome
}

enum V2StrangerMessagePreferenceUpdateOutcome: Equatable, Sendable {
    case accepted
    case queuedForRetry
    case rejected(code: String)
}

protocol V2StrangerMessagePreferenceUpdating: Sendable {
    func update(allowsStrangerMessages: Bool) async throws -> V2StrangerMessagePreferenceUpdateOutcome
}

/// UI-facing sender. It persists a command before attempting transport, so a
/// foreground connection failure becomes a durable retry rather than lost UI
/// intent.
actor V2OutboxConversationSender: V2ConversationSending {
    private let outbox: V2CommandOutboxEngine

    init(outbox: V2CommandOutboxEngine) {
        self.outbox = outbox
    }

    func send(text: String, media: [V2MediaReference], in roomID: String) async throws -> V2ConversationSendOutcome {
        _ = try await outbox.enqueueMessage(roomID: .init(roomID), text: text, media: media)
        switch try await outbox.flushOnce() {
        case .accepted:
            return .accepted
        case .retryScheduled, .idle:
            return .queuedForRetry
        case .rejected(_, let code):
            return .rejected(code: code)
        }
    }
}

/// Persists a withdrawal before its first network attempt. The synced message
/// projection, rather than this acknowledgement, remains authoritative for the
/// final tombstone shown by the UI.
actor V2OutboxMessageWithdrawer: V2MessageWithdrawing {
    private let outbox: V2MessageWithdrawalOutboxEngine

    init(outbox: V2MessageWithdrawalOutboxEngine) { self.outbox = outbox }

    func withdraw(messageID: String, in roomID: String, expectedMessageRevision: UInt64) async throws -> V2MessageWithdrawalOutcome {
        _ = try await outbox.enqueueWithdrawal(
            roomID: try .init(roomID),
            messageID: try .init(messageID),
            expectedMessageRevision: expectedMessageRevision
        )
        switch try await outbox.flushOnce() {
        case .acknowledged: return .accepted
        case .retryScheduled, .idle: return .queuedForRetry
        case .rejected(_, let code): return .rejected(code: code)
        }
    }
}

actor V2OutboxMessageReactionChanger: V2MessageReactionChanging {
    private let outbox: V2MessageReactionOutboxEngine

    init(outbox: V2MessageReactionOutboxEngine) { self.outbox = outbox }

    func changeReaction(messageID: String, in roomID: String, reaction: String, action: V2MessageReactionAction) async throws -> V2MessageReactionOutcome {
        _ = try await outbox.enqueueReaction(
            roomID: try .init(roomID),
            messageID: try .init(messageID),
            reaction: reaction,
            action: action
        )
        switch try await outbox.flushOnce() {
        case .acknowledged: return .accepted
        case .retryScheduled, .idle: return .queuedForRetry
        case .rejected(_, let code): return .rejected(code: code)
        }
    }
}

actor V2OutboxMessageEditor: V2MessageEditing {
    private let outbox: V2MessageEditOutboxEngine

    init(outbox: V2MessageEditOutboxEngine) { self.outbox = outbox }

    func edit(messageID: String, in roomID: String, expectedMessageRevision: UInt64, text: String) async throws -> V2MessageEditOutcome {
        _ = try await outbox.enqueueEdit(
            roomID: try .init(roomID),
            messageID: try .init(messageID),
            expectedMessageRevision: expectedMessageRevision,
            text: text
        )
        switch try await outbox.flushOnce() {
        case .acknowledged: return .accepted
        case .retryScheduled, .idle: return .queuedForRetry
        case .rejected(_, let code): return .rejected(code: code)
        }
    }
}

/// The underlying store atomically suppresses equal or older watermarks. This
/// actor can therefore be called whenever a local conversation becomes
/// visible, including after an offline restart, without producing duplicates.
actor V2OutboxConversationReadReporter: V2ConversationReadReporting {
    private let outbox: V2ReadReceiptOutboxEngine

    init(outbox: V2ReadReceiptOutboxEngine) { self.outbox = outbox }

    func recordReadThrough(roomID: String, roomSequence: UInt64) async throws -> V2ReadReceiptReportOutcome {
        guard try await outbox.enqueueReceiptIfAdvancing(roomID: .init(roomID), readThroughRoomSequence: roomSequence) != nil else {
            return .alreadyRecorded
        }
        switch try await outbox.flushOnce() {
        case .acknowledged: return .recorded
        case .retryScheduled, .idle: return .queuedForRetry
        case .rejected(_, let code): return .rejected(code: code)
        }
    }
}

actor V2RealtimeDirectConversationOpener: V2DirectConversationOpening {
    private let transport: any V2ClientDirectMessagingTransport
    private let makeUUID: @Sendable () -> UUID

    init(
        transport: any V2ClientDirectMessagingTransport,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.transport = transport
        self.makeUUID = makeUUID
    }

    func openConversation(with targetUserID: String) async throws -> String {
        let target = try UserID(targetUserID.trimmingCharacters(in: .whitespacesAndNewlines))
        let operationID = try DirectRoomOperationID(makeUUID().uuidString)
        return try await transport.openDirectRoom(operationID: operationID, targetUserID: target).roomID.rawValue
    }
}

/// UI boundary for durable group bootstrap. It records intent before issuing
/// the command, preserving the same room-creation operation across reconnects.
actor V2OutboxGroupConversationCreator: V2GroupConversationCreating {
    private let outbox: V2GroupRoomCommandOutboxEngine

    init(outbox: V2GroupRoomCommandOutboxEngine) { self.outbox = outbox }

    func createConversation(title: String, initialMemberUserIDs: [String]) async throws -> V2GroupConversationCreationOutcome {
        let members = try initialMemberUserIDs.map { try UserID($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        _ = try await outbox.enqueueCreation(title: title, initialMemberUserIDs: members)
        switch try await outbox.flushOnce() {
        case .acknowledged(_, let roomID): return .created(roomID: roomID.rawValue)
        case .retryScheduled, .idle: return .queuedForRetry
        case .rejected(_, let code): return .rejected(code: code)
        }
    }
}

actor V2RealtimeGroupMemberDirectory: V2GroupMemberDirectoryReading {
    private let transport: any V2ClientMembershipDirectoryTransport

    init(transport: any V2ClientMembershipDirectoryTransport) { self.transport = transport }

    func members(in roomID: String, cursor: String?) async throws -> V2GroupMemberPage {
        let page = try await transport.listRoomMembers(roomID: .init(roomID), cursor: cursor, pageSize: 100)
        return .init(
            membershipRevision: page.membershipRevision,
            actorRole: Self.displayRole(page.actorRole),
            members: page.members.map { .init(id: $0.userID.rawValue, role: Self.displayRole($0.role)) },
            nextCursor: page.nextCursor
        )
    }

    private static func displayRole(_ role: V2RoomMembershipRole) -> String {
        switch role {
        case .owner: "群主"
        case .admin: "管理员"
        case .member: "成员"
        }
    }
}

/// Records a membership operation before attempting the realtime request. The
/// server remains the authorization authority; the UI merely avoids showing
/// controls it already knows cannot apply to the signed-in member role.
actor V2OutboxGroupMembershipChanger: V2GroupMembershipChanging {
    private let outbox: V2MembershipCommandOutboxEngine

    init(outbox: V2MembershipCommandOutboxEngine) { self.outbox = outbox }

    func changeMembership(roomID: String, targetUserID: String, action: V2RoomMembershipAction, expectedMembershipRevision: UInt64) async throws -> V2GroupMembershipChangeOutcome {
        _ = try await outbox.enqueueMembershipChange(
            roomID: .init(roomID),
            targetUserID: .init(targetUserID.trimmingCharacters(in: .whitespacesAndNewlines)),
            action: action,
            expectedMembershipRevision: expectedMembershipRevision
        )
        switch try await outbox.flushOnce() {
        case .acknowledged: return .accepted
        case .retryScheduled, .idle: return .queuedForRetry
        case .rejected(_, let code): return .rejected(code: code)
        }
    }
}

/// Keeps the user's receive preference in the durable social-command outbox.
/// The remote sync projection remains authoritative after another device
/// changes the setting, while this actor preserves local intent across loss.
actor V2OutboxStrangerMessagePreferenceUpdater: V2StrangerMessagePreferenceUpdating {
    private let outbox: V2SocialCommandOutboxEngine

    init(outbox: V2SocialCommandOutboxEngine) {
        self.outbox = outbox
    }

    func update(allowsStrangerMessages: Bool) async throws -> V2StrangerMessagePreferenceUpdateOutcome {
        _ = try await outbox.enqueueStrangerMessagePermission(allowsStrangerMessages ? .allow : .deny)
        switch try await outbox.flushOnce() {
        case .acknowledged:
            return .accepted
        case .retryScheduled, .idle:
            return .queuedForRetry
        case .rejected(_, let code):
            return .rejected(code: code)
        }
    }
}

struct V2AppRealtimeRuntime {
    let runtime: V2ClientRuntime
    let sender: any V2ConversationSending
    let messageWithdrawer: any V2MessageWithdrawing
    let messageReactionChanger: any V2MessageReactionChanging
    let messageEditor: any V2MessageEditing
    let readReceiptReporter: any V2ConversationReadReporting
    let attachmentUploader: any V2ConversationAttachmentUploading
    let mediaDownloader: any V2ConversationMediaDownloading
    let mediaCacheMaintenance: V2ForegroundConversationMediaDownloader

    init(
        configuration: V2AppConfiguration,
        authSession: V2AuthSession,
        localStore: GRDBV2LocalSyncStore,
        mediaCacheDirectory: URL
    ) throws {
        let frameLimits = try V2FrameLimits(
            maximumPayloadBytes: 65_536,
            acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)]
        )
        let connection = V2TLSFrameConnection(endpoint: configuration.realtimeEndpoint, frameLimits: frameLimits)
        let transport = V2ProtobufSyncTransport(
            wire: connection,
            protocolVersion: UInt8(IMV2ProtocolVersion.current)
        )
        let outbox = V2CommandOutboxEngine(store: localStore, transport: transport)
        let socialOutbox = V2SocialCommandOutboxEngine(
            store: localStore,
            socialTransport: transport,
            directTransport: transport
        )
        let groupOutbox = V2GroupRoomCommandOutboxEngine(store: localStore, transport: transport)
        let membershipOutbox = V2MembershipCommandOutboxEngine(store: localStore, transport: transport)
        let withdrawalOutbox = V2MessageWithdrawalOutboxEngine(store: localStore, transport: transport)
        let reactionOutbox = V2MessageReactionOutboxEngine(store: localStore, transport: transport)
        let editOutbox = V2MessageEditOutboxEngine(store: localStore, transport: transport)
        let readReceiptOutbox = V2ReadReceiptOutboxEngine(store: localStore, transport: transport)
        let mediaEdge = try V2HTTPMediaUploadEdgeClient(
            endpoint: configuration.mediaEdgeEndpoint,
            credentials: authSession
        )
        let mediaUploader = V2ClientMediaUploadService(
            targetResolver: mediaEdge,
            byteTransfer: V2URLSessionMediaByteTransfer(),
            completer: mediaEdge,
            statusReader: mediaEdge
        )
        let mediaDownloadResolver = try V2HTTPMediaDownloadTargetResolver(
            endpoint: configuration.mediaEdgeEndpoint,
            credentials: authSession
        )
        let mediaDownloader = V2ClientMediaDownloadService(
            targetResolver: mediaDownloadResolver,
            byteTransfer: V2URLSessionMediaByteTransfer()
        )
        let syncEngine = V2SyncEngine(transport: transport, store: localStore, capabilityProfile: "base")
        let coordinator = V2RealtimeSessionCoordinator(
            authSession: authSession,
            connection: connection,
            supportedCapabilityProfiles: ["base"]
        )
        let activity = V2DefaultClientRuntimeActivity(
            syncEngine: syncEngine,
            availabilitySource: connection,
            heartbeatSender: transport,
            heartbeatInterval: .seconds(30),
            commandOutbox: outbox,
            flushAdditionalDurableCommands: {
                for _ in 0 ..< 256 {
                    try Task.checkCancellation()
                    if case .idle = try await socialOutbox.flushOnce() { break }
                }
                for _ in 0 ..< 256 {
                    try Task.checkCancellation()
                    if case .idle = try await groupOutbox.flushOnce() { break }
                }
                for _ in 0 ..< 256 {
                    try Task.checkCancellation()
                    if case .idle = try await membershipOutbox.flushOnce() { break }
                }
                for _ in 0 ..< 256 {
                    try Task.checkCancellation()
                    if case .idle = try await withdrawalOutbox.flushOnce() { break }
                }
                for _ in 0 ..< 256 {
                    try Task.checkCancellation()
                    if case .idle = try await reactionOutbox.flushOnce() { break }
                }
                for _ in 0 ..< 256 {
                    try Task.checkCancellation()
                    if case .idle = try await editOutbox.flushOnce() { break }
                }
                for _ in 0 ..< 256 {
                    try Task.checkCancellation()
                    if case .idle = try await readReceiptOutbox.flushOnce() { break }
                }
            }
        )
        runtime = .init(connection: coordinator, activity: activity)
        sender = V2OutboxConversationSender(outbox: outbox)
        messageWithdrawer = V2OutboxMessageWithdrawer(outbox: withdrawalOutbox)
        messageReactionChanger = V2OutboxMessageReactionChanger(outbox: reactionOutbox)
        messageEditor = V2OutboxMessageEditor(outbox: editOutbox)
        readReceiptReporter = V2OutboxConversationReadReporter(outbox: readReceiptOutbox)
        attachmentUploader = V2ForegroundConversationAttachmentUploader(uploader: mediaUploader)
        let foregroundMediaDownloader = try V2ForegroundConversationMediaDownloader(
            downloader: mediaDownloader,
            directory: mediaCacheDirectory
        )
        self.mediaDownloader = foregroundMediaDownloader
        self.mediaCacheMaintenance = foregroundMediaDownloader
        directConversationOpener = V2RealtimeDirectConversationOpener(transport: transport)
        groupConversationCreator = V2OutboxGroupConversationCreator(outbox: groupOutbox)
        groupMemberDirectory = V2RealtimeGroupMemberDirectory(transport: transport)
        groupMembershipChanger = V2OutboxGroupMembershipChanger(outbox: membershipOutbox)
        strangerMessagePreferenceUpdater = V2OutboxStrangerMessagePreferenceUpdater(outbox: socialOutbox)
    }

    let directConversationOpener: any V2DirectConversationOpening
    let groupConversationCreator: any V2GroupConversationCreating
    let groupMemberDirectory: any V2GroupMemberDirectoryReading
    let groupMembershipChanger: any V2GroupMembershipChanging
    let strangerMessagePreferenceUpdater: any V2StrangerMessagePreferenceUpdating
}
