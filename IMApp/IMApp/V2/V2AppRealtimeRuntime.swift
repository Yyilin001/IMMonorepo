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
    func send(text: String, media: [V2MediaReference], mentions: [V2MentionTarget], in roomID: String) async throws -> V2ConversationSendOutcome
    func send(text: String, media: [V2MediaReference], mentions: [V2MentionTarget], entities: [V2MessageEntity], replyTo: V2MessageReplyReference?, in roomID: String) async throws -> V2ConversationSendOutcome
}

/// Group receipt details are fetched only after an explicit user action; they
/// are intentionally not retained in the normal timeline projection.
protocol V2GroupReadReceiptReading: Sendable {
    func readers(roomID: String, messageID: String, cursor: String?) async throws -> V2ReadReceiptReadersPage
}

enum V2LiveActivityPreferenceUpdateOutcome: Equatable, Sendable { case accepted, rejected(code: String) }
protocol V2LiveActivityPreferenceUpdating: Sendable {
    func update(allowsOnlinePresence: Bool, allowsTypingIndicators: Bool) async throws -> V2LiveActivityPreferenceUpdateOutcome
}
protocol V2LiveActivityPreferenceReading: Sendable {
    func preferences() async throws -> V2LiveActivityPreferences
}

protocol V2ConversationLiveActivityManaging: Sendable {
    func activate(roomID: String, includesPresence: Bool) async throws -> V2PresenceState?
    func deactivate(roomID: String, includesPresence: Bool) async
    func setTyping(roomID: String, isTyping: Bool) async throws
    func nextEvent() async throws -> V2LiveActivityEvent
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

enum V2ConversationCapabilityOutcome: Equatable, Sendable { case accepted, queuedForRetry, rejected(code: String) }

/// Private per-user presentation state. The server projection, not an
/// optimistic list mutation, remains the source of truth after reconnect.
protocol V2ConversationStateChanging: Sendable {
    func setState(roomID: String, isPinned: Bool, isArchived: Bool, muteUntil: Date?) async throws -> V2ConversationCapabilityOutcome
}

protocol V2MessageFavoriting: Sendable {
    func setFavorite(roomID: String, messageID: String, isFavorited: Bool) async throws -> V2ConversationCapabilityOutcome
}

protocol V2GroupMessagePinning: Sendable {
    func setPinned(roomID: String, messageID: String, isPinned: Bool) async throws -> V2ConversationCapabilityOutcome
}

enum V2MessageForwardingOutcome: Equatable, Sendable {
    case completed(succeeded: Int, failed: Int)
    case queuedForRetry
    case rejected(code: String)
}

/// The UI submits only opaque message and room IDs.  The outbox holds the
/// actual retry record, so leaving the destination picker never loses work.
protocol V2MessageForwarding: Sendable {
    func forward(sourceMessageIDs: [String], targetRoomIDs: [String]) async throws -> V2MessageForwardingOutcome
}

protocol V2GroupAnnouncementManaging: Sendable {
    func setAnnouncement(roomID: String, body: String, expectedRevision: UInt64) async throws -> V2ConversationCapabilityOutcome
}

protocol V2GroupMemberRoleChanging: Sendable {
    func setRole(roomID: String, userID: String, role: V2RoomMembershipRole, expectedMembershipRevision: UInt64) async throws -> V2ConversationCapabilityOutcome
}

protocol V2GroupRolePolicyChanging: Sendable {
    func setPolicy(roomID: String, role: V2RoomMembershipRole, permissions: Set<V2GroupPermission>, expectedRevision: UInt64) async throws -> V2ConversationCapabilityOutcome
}

/// Opens the deterministic direct room for the signed-in user and a target
/// user. Opening is idempotent on the server, so it is safe to retry after a
/// transport interruption; no message content is at risk at this boundary.
protocol V2DirectConversationOpening: Sendable {
    func openConversation(with publicIdentity: V2PublicIdentity) async throws -> String
}

/// Resolves an explicit public handle before the realtime protocol receives an
/// opaque user ID. This keeps UUIDs out of all product-facing entry fields.
protocol V2ConversationPublicIdentityResolving: Sendable {
    func resolve(handle: String) async throws -> V2PublicIdentity
}

extension V2HTTPPublicIdentityDirectory: V2ConversationPublicIdentityResolving {}

enum V2GroupConversationCreationOutcome: Equatable, Sendable {
    case created(roomID: String)
    /// The operation was durably saved but has not completed. The UI keeps
    /// this ID so an explicit cancellation reaches the same durable record.
    case queuedForRetry(operationID: String)
    case rejected(code: String)
}

enum V2GroupConversationCancellationOutcome: Equatable, Sendable {
    case cancelled
    case queuedForRetry
    case finalizationAlreadyStarted
}

/// A durable bootstrap status restored from the local outbox after the UI has
/// been recreated. It deliberately exposes product state, not transport or
/// database details.
enum V2RestoredGroupConversationCreationStatus: Equatable, Sendable {
    case queuedForRetry(operationID: String)
    case cancelling(operationID: String)
    case finalizing(operationID: String)
    case cancelled
    case rejected(code: String)
}

protocol V2GroupConversationCreating: Sendable {
    func createConversation(title: String, initialMemberUserIDs: [String]) async throws -> V2GroupConversationCreationOutcome
    func cancelConversationCreation(operationID: String) async throws -> V2GroupConversationCancellationOutcome
    func restoredCreationStatus() async throws -> V2RestoredGroupConversationCreationStatus?
}

struct V2GroupMemberItem: Equatable, Identifiable, Sendable {
    /// Opaque identifier used only for subsequent authenticated membership
    /// commands.  UI must render the public fields below instead.
    let id: String
    let role: String
    let handle: String
    let displayName: String

    init(id: String, role: String, handle: String, displayName: String) {
        self.id = id
        self.role = role
        self.handle = handle
        self.displayName = displayName
    }
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

enum V2UserAddPreferenceUpdateOutcome: Equatable, Sendable {
    case accepted
    case queuedForRetry
    case rejected(code: String)
}

protocol V2UserAddPreferenceUpdating: Sendable {
    func update(allowsBeingAdded: Bool) async throws -> V2UserAddPreferenceUpdateOutcome
}

enum V2ReadReceiptPreferenceUpdateOutcome: Equatable, Sendable { case accepted, queuedForRetry, rejected(code: String) }
protocol V2ReadReceiptPreferenceUpdating: Sendable {
    func update(allowsDirectReadReceipts: Bool, allowsGroupReadReceipts: Bool) async throws -> V2ReadReceiptPreferenceUpdateOutcome
}

enum V2UserBlockChangeOutcome: Equatable, Sendable {
    case accepted
    case queuedForRetry
    case rejected(code: String)
}

/// UI-facing boundary for a user-owned block list. Commands are persisted
/// before transport; the received social projection remains authoritative.
protocol V2UserBlockChanging: Sendable {
    func changeBlock(targetUserID: String, action: V2UserBlockAction) async throws -> V2UserBlockChangeOutcome
}

enum V2RelationshipChangeOutcome: Equatable, Sendable {
    case accepted
    case queuedForRetry
    case rejected(code: String)
}

/// The visible relationship state remains sync-projection driven. This
/// boundary only preserves and attempts the user's durable intent.
protocol V2RelationshipChanging: Sendable {
    func changeRelationship(targetUserID: String, action: V2RelationshipAction) async throws -> V2RelationshipChangeOutcome
}

enum V2GroupModerationOutcome: Equatable, Sendable {
    case accepted
    case queuedForRetry
    case rejected(code: String)
}

/// Both moderation actions have an independent durable operation and audit
/// record. They must never be routed through ordinary membership mutation.
protocol V2GroupMemberMuting: Sendable {
    func muteMember(roomID: String, targetUserID: String, muteUntil: Date, reasonCode: V2ModerationReasonCode) async throws -> V2GroupModerationOutcome
}

protocol V2ModeratedGroupMemberRemoving: Sendable {
    func removeMemberByModerator(roomID: String, targetUserID: String, reasonCode: V2ModerationReasonCode) async throws -> V2GroupModerationOutcome
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
        try await send(text: text, media: media, mentions: [], in: roomID)
    }

    func send(text: String, media: [V2MediaReference], mentions: [V2MentionTarget], in roomID: String) async throws -> V2ConversationSendOutcome {
        try await send(text: text, media: media, mentions: mentions, entities: [], replyTo: nil, in: roomID)
    }

    func send(text: String, media: [V2MediaReference], mentions: [V2MentionTarget], entities: [V2MessageEntity], replyTo: V2MessageReplyReference?, in roomID: String) async throws -> V2ConversationSendOutcome {
        _ = try await outbox.enqueueMessage(roomID: .init(roomID), text: text, media: media, mentions: mentions, entities: entities, replyTo: replyTo)
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

actor V2OutboxConversationStateChanger: V2ConversationStateChanging {
    private let outbox: V2ConversationCapabilitiesOutboxEngine
    init(outbox: V2ConversationCapabilitiesOutboxEngine) { self.outbox = outbox }
    func setState(roomID: String, isPinned: Bool, isArchived: Bool, muteUntil: Date?) async throws -> V2ConversationCapabilityOutcome {
        let pending = try await outbox.enqueueConversationState(roomID: .init(roomID), isPinned: isPinned, isArchived: isArchived, muteUntil: muteUntil)
        switch try await outbox.flushOnce() {
        case .conversationStateAcknowledged(let operationID) where operationID == pending.command.operationID: return .accepted
        case .conversationStateRejected(let operationID, let code) where operationID == pending.command.operationID: return .rejected(code: code)
        case .conversationStateRetryScheduled, .conversationStateAcknowledged, .conversationStateRejected, .idle: return .queuedForRetry
        case .messageFavoriteAcknowledged, .messageFavoriteRetryScheduled, .messageFavoriteRejected: return .queuedForRetry
        }
    }
}

actor V2OutboxMessageFavoriter: V2MessageFavoriting {
    private let outbox: V2ConversationCapabilitiesOutboxEngine
    init(outbox: V2ConversationCapabilitiesOutboxEngine) { self.outbox = outbox }
    func setFavorite(roomID: String, messageID: String, isFavorited: Bool) async throws -> V2ConversationCapabilityOutcome {
        let pending = try await outbox.enqueueMessageFavorite(roomID: .init(roomID), messageID: .init(messageID), isFavorited: isFavorited)
        switch try await outbox.flushOnce() {
        case .messageFavoriteAcknowledged(let operationID) where operationID == pending.command.operationID: return .accepted
        case .messageFavoriteRejected(let operationID, let code) where operationID == pending.command.operationID: return .rejected(code: code)
        case .messageFavoriteRetryScheduled, .messageFavoriteAcknowledged, .messageFavoriteRejected, .idle: return .queuedForRetry
        case .conversationStateAcknowledged, .conversationStateRetryScheduled, .conversationStateRejected: return .queuedForRetry
        }
    }
}

actor V2OutboxGroupMessagePinner: V2GroupMessagePinning {
    private let outbox: V2GroupCapabilitiesOutboxEngine
    init(outbox: V2GroupCapabilitiesOutboxEngine) { self.outbox = outbox }
    func setPinned(roomID: String, messageID: String, isPinned: Bool) async throws -> V2ConversationCapabilityOutcome {
        let pending = try await outbox.enqueuePin(roomID: .init(roomID), messageID: .init(messageID), isPinned: isPinned)
        switch try await outbox.flushOnce() {
        case .acknowledged(let operationID) where operationID == pending.operationID: return .accepted
        case .rejected(let operationID, let code) where operationID == pending.operationID: return .rejected(code: code)
        case .acknowledged, .retryScheduled, .rejected, .idle: return .queuedForRetry
        }
    }
}

actor V2OutboxMessageForwarder: V2MessageForwarding {
    private let outbox: V2BulkForwardMessagesOutboxEngine

    init(outbox: V2BulkForwardMessagesOutboxEngine) { self.outbox = outbox }

    func forward(sourceMessageIDs: [String], targetRoomIDs: [String]) async throws -> V2MessageForwardingOutcome {
        let sourceIDs = try sourceMessageIDs.map(MessageID.init)
        let targetIDs = try targetRoomIDs.map(RoomID.init)
        let plan = try await outbox.enqueue(sourceMessageIDs: sourceIDs, targetRoomIDs: targetIDs)
        switch try await outbox.flushOnce() {
        case .chunkAcknowledged(let planID, _, let results) where planID == plan.operationID:
            return .completed(
                succeeded: results.filter { $0.errorCode == nil }.count,
                failed: results.filter { $0.errorCode != nil }.count
            )
        case .chunkAcknowledged, .retryScheduled, .idle:
            return .queuedForRetry
        case .chunkRejected(let planID, _, let code) where planID == plan.operationID:
            return .rejected(code: code)
        case .chunkRejected:
            return .queuedForRetry
        }
    }
}

actor V2OutboxGroupAnnouncementManager: V2GroupAnnouncementManaging {
    private let outbox: V2GroupCapabilitiesOutboxEngine

    init(outbox: V2GroupCapabilitiesOutboxEngine) { self.outbox = outbox }

    func setAnnouncement(roomID: String, body: String, expectedRevision: UInt64) async throws -> V2ConversationCapabilityOutcome {
        let pending = try await outbox.enqueueAnnouncement(
            roomID: .init(roomID),
            body: body,
            expectedRevision: expectedRevision
        )
        switch try await outbox.flushOnce() {
        case .acknowledged(let operationID) where operationID == pending.operationID: return .accepted
        case .rejected(let operationID, let code) where operationID == pending.operationID: return .rejected(code: code)
        case .acknowledged, .retryScheduled, .rejected, .idle: return .queuedForRetry
        }
    }
}

actor V2OutboxGroupMemberRoleChanger: V2GroupMemberRoleChanging {
    private let outbox: V2GroupCapabilitiesOutboxEngine

    init(outbox: V2GroupCapabilitiesOutboxEngine) { self.outbox = outbox }

    func setRole(roomID: String, userID: String, role: V2RoomMembershipRole, expectedMembershipRevision: UInt64) async throws -> V2ConversationCapabilityOutcome {
        let pending = try await outbox.enqueueMemberRole(
            roomID: .init(roomID),
            targetUserID: .init(userID),
            role: role,
            expectedMembershipRevision: expectedMembershipRevision
        )
        switch try await outbox.flushOnce() {
        case .acknowledged(let operationID) where operationID == pending.operationID: return .accepted
        case .rejected(let operationID, let code) where operationID == pending.operationID: return .rejected(code: code)
        case .acknowledged, .retryScheduled, .rejected, .idle: return .queuedForRetry
        }
    }
}

actor V2OutboxGroupRolePolicyChanger: V2GroupRolePolicyChanging {
    private let outbox: V2GroupCapabilitiesOutboxEngine

    init(outbox: V2GroupCapabilitiesOutboxEngine) { self.outbox = outbox }

    func setPolicy(roomID: String, role: V2RoomMembershipRole, permissions: Set<V2GroupPermission>, expectedRevision: UInt64) async throws -> V2ConversationCapabilityOutcome {
        let pending = try await outbox.enqueueRolePermissions(
            roomID: .init(roomID),
            role: role,
            permissions: permissions,
            expectedRevision: expectedRevision
        )
        switch try await outbox.flushOnce() {
        case .acknowledged(let operationID) where operationID == pending.operationID: return .accepted
        case .rejected(let operationID, let code) where operationID == pending.operationID: return .rejected(code: code)
        case .acknowledged, .retryScheduled, .rejected, .idle: return .queuedForRetry
        }
    }
}

actor V2RealtimeDirectConversationOpener: V2DirectConversationOpening {
    private let transport: any V2ClientDirectMessagingTransport
    private let localStore: GRDBV2LocalSyncStore
    private let runtime: V2ClientRuntime
    private let makeUUID: @Sendable () -> UUID

    init(
        transport: any V2ClientDirectMessagingTransport,
        localStore: GRDBV2LocalSyncStore,
        runtime: V2ClientRuntime,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.transport = transport
        self.localStore = localStore
        self.runtime = runtime
        self.makeUUID = makeUUID
    }

    func openConversation(with publicIdentity: V2PublicIdentity) async throws -> String {
        // Signing in publishes the local conversation UI before its
        // foreground-start task is necessarily scheduled. Reuse (or create)
        // that one runtime attempt before issuing this non-durable request.
        _ = try await runtime.start()
        let operationID = try DirectRoomOperationID(makeUUID().uuidString)
        let opened = try await transport.openDirectRoom(operationID: operationID, targetUserID: publicIdentity.userID)
        try Task.checkCancellation()
        try await localStore.cacheDirectRoomIdentity(roomID: opened.roomID, publicIdentity: publicIdentity)
        return opened.roomID.rawValue
    }
}

/// UI boundary for durable group bootstrap. It obtains a foreground realtime
/// session first so a successful create can return its room ID immediately;
/// if that connection cannot be established, it still records the request and
/// returns the normal durable-retry outcome.
actor V2OutboxGroupConversationCreator: V2GroupConversationCreating {
    private let outbox: V2GroupRoomCommandOutboxEngine
    private let runtime: V2ClientRuntime

    init(outbox: V2GroupRoomCommandOutboxEngine, runtime: V2ClientRuntime) {
        self.outbox = outbox
        self.runtime = runtime
    }

    func createConversation(title: String, initialMemberUserIDs: [String]) async throws -> V2GroupConversationCreationOutcome {
        let members = try initialMemberUserIDs.map { try UserID($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        do {
            _ = try await runtime.start()
        } catch is CancellationError {
            throw CancellationError()
        } catch V2RealtimeSessionCoordinatorError.authenticationRequired {
            throw V2RealtimeSessionCoordinatorError.authenticationRequired
        } catch {
            // The command remains safe to retry: enqueue it below before the
            // first transport attempt rather than rejecting a user action just
            // because this foreground connection is presently unavailable.
        }
        guard let deliveryMode = V2GroupDeliveryPolicy().deliveryMode(forInitialMemberCount: members.count + 1) else {
            return .rejected(code: "GROUP_MEMBER_LIMIT_REACHED")
        }
        let command = try await outbox.enqueueCreation(title: title, deliveryMode: deliveryMode, initialMemberUserIDs: members)
        // A staged creation has at least Begin and Finalize, plus one bounded
        // Append per audience page. Calling the durable engine only once made
        // a healthy foreground creation look offline after Begin succeeded.
        // Keep the immediate path finite; a network error still leaves the
        // same persisted command for the normal reconnect scheduler.
        let pageCount = (members.count + V2GroupAudienceImportLimits.maximumMembersPerAppend - 1) / V2GroupAudienceImportLimits.maximumMembersPerAppend
        let maximumForegroundFlushes = pageCount + 2
        for _ in 0..<maximumForegroundFlushes {
            switch try await outbox.flushOnce() {
            case .acknowledged(_, let roomID): return .created(roomID: roomID.rawValue)
            case .rejected(_, let code): return .rejected(code: code)
            case .retryScheduled:
                continue
            case .idle, .cancelled, .cancellationRefused:
                return .queuedForRetry(operationID: command.operationID.rawValue)
            }
        }
        return .queuedForRetry(operationID: command.operationID.rawValue)
    }

    func cancelConversationCreation(operationID: String) async throws -> V2GroupConversationCancellationOutcome {
        try await outbox.requestCancellation(operationID: .init(operationID))
        switch try await outbox.flushOnce() {
        case .cancelled:
            return .cancelled
        case .cancellationRefused:
            return .finalizationAlreadyStarted
        case .retryScheduled, .idle, .acknowledged, .rejected:
            return .queuedForRetry
        }
    }

    func restoredCreationStatus() async throws -> V2RestoredGroupConversationCreationStatus? {
        guard let creation = try await outbox.latestCreation() else { return nil }
        switch creation.state {
        case .pending:
            return .queuedForRetry(operationID: creation.operationID.rawValue)
        case .cancelling:
            return .cancelling(operationID: creation.operationID.rawValue)
        case .finalizing:
            return .finalizing(operationID: creation.operationID.rawValue)
        case .cancelled:
            return .cancelled
        case .rejected:
            return .rejected(code: creation.terminalCode ?? "UNKNOWN")
        case .acknowledged:
            return nil
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
            members: page.members.map {
                .init(
                    id: $0.userID.rawValue,
                    role: Self.displayRole($0.role),
                    handle: $0.publicIdentity.handle.rawValue,
                    displayName: $0.publicIdentity.displayName
                )
            },
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

actor V2RealtimeGroupReadReceiptReader: V2GroupReadReceiptReading {
    private let transport: any V2ClientReadReceiptTransport

    init(transport: any V2ClientReadReceiptTransport) { self.transport = transport }

    func readers(roomID: String, messageID: String, cursor: String?) async throws -> V2ReadReceiptReadersPage {
        try await transport.listReadReceiptReaders(
            roomID: .init(roomID),
            messageID: .init(messageID),
            cursor: cursor,
            pageSize: 50
        )
    }
}

actor V2RealtimeLiveActivityPreferenceUpdater: V2LiveActivityPreferenceUpdating {
    private let transport: any V2ClientLiveActivityTransport
    init(transport: any V2ClientLiveActivityTransport) { self.transport = transport }

    func update(allowsOnlinePresence: Bool, allowsTypingIndicators: Bool) async throws -> V2LiveActivityPreferenceUpdateOutcome {
        do {
            _ = try await transport.setLiveActivityPreferences(operationID: .init(UUID().uuidString), allowsOnlinePresence: allowsOnlinePresence, allowsTypingIndicators: allowsTypingIndicators)
            return .accepted
        } catch let error as V2RealtimeTransportError {
            if case .server(let code, let retryable, _, _) = error, !retryable { return .rejected(code: code) }
            throw error
        }
    }
}

extension V2RealtimeLiveActivityPreferenceUpdater: V2LiveActivityPreferenceReading {
    func preferences() async throws -> V2LiveActivityPreferences { try await transport.liveActivityPreferences() }
}

actor V2RealtimeConversationLiveActivity: V2ConversationLiveActivityManaging {
    private let transport: any V2ClientLiveActivityTransport
    private let events: any V2LiveActivityEventSource

    init(transport: any V2ClientLiveActivityTransport, events: any V2LiveActivityEventSource) {
        self.transport = transport; self.events = events
    }

    func activate(roomID: String, includesPresence: Bool) async throws -> V2PresenceState? {
        let room = try RoomID(roomID)
        try await transport.subscribeTyping(roomID: room)
        return includesPresence ? try await transport.subscribePresence(roomID: room) : nil
    }

    func deactivate(roomID: String, includesPresence: Bool) async {
        guard let room = try? RoomID(roomID) else { return }
        try? await transport.setTyping(roomID: room, isTyping: false)
        try? await transport.unsubscribeTyping(roomID: room)
        if includesPresence { try? await transport.unsubscribePresence(roomID: room) }
    }

    func setTyping(roomID: String, isTyping: Bool) async throws { try await transport.setTyping(roomID: .init(roomID), isTyping: isTyping) }
    func nextEvent() async throws -> V2LiveActivityEvent { try await events.nextLiveActivityEvent() }
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

actor V2OutboxGroupMemberMuter: V2GroupMemberMuting {
    private let outbox: V2MemberMuteOutboxEngine

    init(outbox: V2MemberMuteOutboxEngine) { self.outbox = outbox }

    func muteMember(roomID: String, targetUserID: String, muteUntil: Date, reasonCode: V2ModerationReasonCode) async throws -> V2GroupModerationOutcome {
        _ = try await outbox.enqueueMute(
            roomID: .init(roomID),
            targetUserID: .init(targetUserID),
            muteUntil: muteUntil,
            reasonCode: reasonCode
        )
        switch try await outbox.flushOnce() {
        case .acknowledged: return .accepted
        case .retryScheduled, .idle: return .queuedForRetry
        case .rejected(_, let code): return .rejected(code: code)
        }
    }
}

actor V2OutboxModeratedGroupMemberRemover: V2ModeratedGroupMemberRemoving {
    private let outbox: V2ModeratedMemberRemovalOutboxEngine

    init(outbox: V2ModeratedMemberRemovalOutboxEngine) { self.outbox = outbox }

    func removeMemberByModerator(roomID: String, targetUserID: String, reasonCode: V2ModerationReasonCode) async throws -> V2GroupModerationOutcome {
        _ = try await outbox.enqueueRemoval(
            roomID: .init(roomID),
            targetUserID: .init(targetUserID),
            reasonCode: reasonCode
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
        let command = try await outbox.enqueueStrangerMessagePermission(allowsStrangerMessages ? .allow : .deny)
        switch try await outbox.flushIfReady(operationID: command.operationID) {
        case nil:
            return .queuedForRetry
        case .acknowledged:
            return .accepted
        case .retryScheduled, .idle:
            return .queuedForRetry
        case .rejected(_, let code):
            return .rejected(code: code)
        }
    }
}

actor V2OutboxUserAddPreferenceUpdater: V2UserAddPreferenceUpdating {
    private let outbox: V2SocialCommandOutboxEngine

    init(outbox: V2SocialCommandOutboxEngine) { self.outbox = outbox }

    func update(allowsBeingAdded: Bool) async throws -> V2UserAddPreferenceUpdateOutcome {
        let command = try await outbox.enqueueUserAddPermission(allowsBeingAdded ? .allow : .deny)
        switch try await outbox.flushIfReady(operationID: command.operationID) {
        case nil: return .queuedForRetry
        case .acknowledged: return .accepted
        case .retryScheduled, .idle: return .queuedForRetry
        case .rejected(_, let code): return .rejected(code: code)
        }
    }
}

/// Receipt preference changes are idempotent protocol commands. The server
/// remains the authority and its sync projection reconciles other devices.
actor V2RealtimeReadReceiptPreferenceUpdater: V2ReadReceiptPreferenceUpdating {
    private let outbox: V2SocialCommandOutboxEngine
    init(outbox: V2SocialCommandOutboxEngine) { self.outbox = outbox }
    func update(allowsDirectReadReceipts: Bool, allowsGroupReadReceipts: Bool) async throws -> V2ReadReceiptPreferenceUpdateOutcome {
        let command = try await outbox.enqueueReadReceiptPreferences(allowsDirect: allowsDirectReadReceipts, allowsGroup: allowsGroupReadReceipts)
        switch try await outbox.flushIfReady(operationID: command.operationID) {
        case .acknowledged: return .accepted
        case .rejected(_, let code): return .rejected(code: code)
        case .retryScheduled, .idle, nil: return .queuedForRetry
        }
    }
}

actor V2OutboxUserBlockChanger: V2UserBlockChanging {
    private let outbox: V2SocialCommandOutboxEngine

    init(outbox: V2SocialCommandOutboxEngine) {
        self.outbox = outbox
    }

    func changeBlock(targetUserID: String, action: V2UserBlockAction) async throws -> V2UserBlockChangeOutcome {
        let command = try await outbox.enqueueUserBlock(
            targetUserID: try .init(targetUserID),
            action: action
        )
        switch try await outbox.flushIfReady(operationID: command.operationID) {
        case nil:
            return .queuedForRetry
        case .acknowledged:
            return .accepted
        case .retryScheduled, .idle:
            return .queuedForRetry
        case .rejected(_, let code):
            return .rejected(code: code)
        }
    }
}

actor V2OutboxRelationshipChanger: V2RelationshipChanging {
    private let outbox: V2SocialCommandOutboxEngine

    init(outbox: V2SocialCommandOutboxEngine) {
        self.outbox = outbox
    }

    func changeRelationship(targetUserID: String, action: V2RelationshipAction) async throws -> V2RelationshipChangeOutcome {
        let command = try await outbox.enqueueRelationship(
            targetUserID: try .init(targetUserID),
            action: action
        )
        switch try await outbox.flushIfReady(operationID: command.operationID) {
        case nil:
            return .queuedForRetry
        case .acknowledged:
            return .accepted
        case .retryScheduled, .idle:
            return .queuedForRetry
        case .rejected(_, let code):
            return .rejected(code: code)
        }
    }
}

/// Bridges the active conversation UI to the reusable room-log engines without
/// letting a SwiftUI store inspect SQLite or speak the realtime protocol.
/// Hybrid groups persist a room-log cursor; standard groups use only the
/// separate in-memory foreground preview cursor and retain normal fan-out as
/// their durable delivery authority.
actor V2RealtimeActiveHybridGroupSynchronizer: V2ActiveHybridGroupSynchronizing {
    private let groupEventSync: V2GroupEventSyncEngine
    private let foregroundGroupPreview: V2ForegroundGroupEventPreviewEngine
    private let localStore: GRDBV2LocalSyncStore
    private let subscriptionTransport: any V2ClientGroupEventSubscriptionTransport
    private let wakeSource: any V2GroupEventAvailabilityHintSource

    init(
        groupEventSync: V2GroupEventSyncEngine,
        foregroundGroupPreview: V2ForegroundGroupEventPreviewEngine,
        localStore: GRDBV2LocalSyncStore,
        subscriptionTransport: any V2ClientGroupEventSubscriptionTransport,
        wakeSource: any V2GroupEventAvailabilityHintSource
    ) {
        self.groupEventSync = groupEventSync
        self.foregroundGroupPreview = foregroundGroupPreview
        self.localStore = localStore
        self.subscriptionTransport = subscriptionTransport
        self.wakeSource = wakeSource
    }

    func synchronizeOnePage(roomID: String) async throws -> V2ActiveHybridGroupSyncOutcome {
        let parsedRoomID = try RoomID(roomID)
        guard let access = try await localStore.groupEventAccess(roomID: parsedRoomID),
              access.isAuthorized
        else {
            return .notHybridRoom
        }
        let progress: V2GroupEventSyncProgress
        do {
            switch access.delivery {
            case .durableRoomLog:
                progress = try await groupEventSync.synchronizeOnePage(roomID: parsedRoomID)
            case .foregroundPreview:
                progress = try await foregroundGroupPreview.synchronizeOnePage(roomID: parsedRoomID)
            }
        } catch let error as V2RealtimeTransportError {
            guard case .server(let code, _, _, _) = error, code == "FORBIDDEN" else { throw error }
            try await localStore.markRoomEventUnauthorized(roomID: parsedRoomID)
            return .notHybridRoom
        }
        return .synchronized(appliedEventCount: progress.appliedEventCount, hasMore: progress.hasMore)
    }

    func subscribe(roomID: String) async throws -> V2ActiveHybridGroupSubscriptionOutcome {
        let parsedRoomID = try RoomID(roomID)
        guard let access = try await localStore.groupEventAccess(roomID: parsedRoomID),
              access.isAuthorized
        else {
            return .notHybridRoom
        }
        do {
            let cursor: UInt64
            switch access.delivery {
            case .durableRoomLog:
                cursor = try await localStore.groupEventCursor(roomID: parsedRoomID)
            case .foregroundPreview:
                cursor = try await foregroundGroupPreview.cursor(roomID: parsedRoomID)
            }
            let subscription = try await subscriptionTransport.subscribeToGroupEvents(
                roomID: parsedRoomID,
                afterRoomSequence: cursor
            )
            guard subscription.roomID == parsedRoomID else { throw V2RealtimeTransportError.unexpectedResponse }
            return .subscribed(highWatermark: subscription.highWatermark)
        } catch let error as V2RealtimeTransportError {
            guard case .server(let code, _, _, _) = error, code == "FORBIDDEN" else { throw error }
            try await localStore.markRoomEventUnauthorized(roomID: parsedRoomID)
            return .notHybridRoom
        }
    }

    func nextWake() async throws -> V2ActiveHybridGroupWake {
        let wake = try await wakeSource.nextGroupEventAvailabilityHint()
        return .init(
            roomID: wake.roomID.rawValue,
            highWatermark: wake.highWatermark,
            liveEvents: wake.liveEvents
        )
    }

    func applyLiveEvent(_ wake: V2ActiveHybridGroupWake) async throws -> Bool {
        guard let roomID = try? RoomID(wake.roomID),
              !wake.liveEvents.isEmpty,
              wake.liveEvents.last?.roomSequence == wake.highWatermark,
              zip(wake.liveEvents, wake.liveEvents.dropFirst()).allSatisfy({
                  $1.roomSequence == $0.roomSequence + 1
              }),
              let access = try await localStore.groupEventAccess(roomID: roomID),
              access.isAuthorized,
              access.delivery == .durableRoomLog
        else { return false }
        let cursor = try await localStore.groupEventCursor(roomID: roomID)
        if wake.highWatermark <= cursor { return true }
        let unapplied = wake.liveEvents.drop(while: { $0.roomSequence <= cursor })
        guard unapplied.first?.roomSequence == cursor + 1,
              unapplied.last?.roomSequence == wake.highWatermark
        else { return false }
        let page = V2ClientGroupEventPage(
            roomID: roomID,
            events: Array(unapplied),
            nextRoomSequence: wake.highWatermark,
            hasMore: false
        )
        _ = try await localStore.applyGroupEventPage(page)
        return true
    }

    func unsubscribe(roomID: String) async {
        guard let parsedRoomID = try? RoomID(roomID) else { return }
        try? await subscriptionTransport.unsubscribeFromGroupEvents(roomID: parsedRoomID)
        await foregroundGroupPreview.forget(roomID: parsedRoomID)
    }
}

struct V2AppRealtimeRuntime {
    let runtime: V2ClientRuntime
    let projectionChangeNotifier: V2ProjectionChangeNotifier
    let sender: any V2ConversationSending
    let messageWithdrawer: any V2MessageWithdrawing
    let messageReactionChanger: any V2MessageReactionChanging
    let messageEditor: any V2MessageEditing
    let readReceiptReporter: any V2ConversationReadReporting
    let conversationStateChanger: any V2ConversationStateChanging
    let messageFavoriter: any V2MessageFavoriting
    let groupMessagePinner: any V2GroupMessagePinning
    let messageForwarder: any V2MessageForwarding
    let groupAnnouncementManager: any V2GroupAnnouncementManaging
    let groupMemberRoleChanger: any V2GroupMemberRoleChanging
    let groupRolePolicyChanger: any V2GroupRolePolicyChanging
    let groupReadReceiptReader: any V2GroupReadReceiptReading
    let conversationLiveActivity: any V2ConversationLiveActivityManaging
    let attachmentUploader: any V2ConversationAttachmentUploading
    let mediaDownloader: any V2ConversationMediaDownloading
    let mediaCacheMaintenance: V2ForegroundConversationMediaDownloader
    let activeHybridGroupSynchronizer: any V2ActiveHybridGroupSynchronizing
    let profileRepository: V2ProfileRepository

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
            directTransport: transport,
            readReceiptTransport: transport
        )
        let groupOutbox = V2GroupRoomCommandOutboxEngine(store: localStore, transport: transport)
        let membershipOutbox = V2MembershipCommandOutboxEngine(store: localStore, transport: transport)
        let memberMuteOutbox = V2MemberMuteOutboxEngine(store: localStore, transport: transport)
        let moderatedMemberRemovalOutbox = V2ModeratedMemberRemovalOutboxEngine(store: localStore, transport: transport)
        let withdrawalOutbox = V2MessageWithdrawalOutboxEngine(store: localStore, transport: transport)
        let reactionOutbox = V2MessageReactionOutboxEngine(store: localStore, transport: transport)
        let editOutbox = V2MessageEditOutboxEngine(store: localStore, transport: transport)
        let readReceiptOutbox = V2ReadReceiptOutboxEngine(store: localStore, transport: transport)
        let conversationCapabilitiesOutbox = V2ConversationCapabilitiesOutboxEngine(store: localStore, transport: transport)
        let groupCapabilitiesOutbox = V2GroupCapabilitiesOutboxEngine(store: localStore, transport: transport)
        let forwardMessagesOutbox = V2BulkForwardMessagesOutboxEngine(store: localStore, transport: transport)
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
        let profileRepository = V2ProfileRepository(
            store: localStore,
            reader: try V2HTTPProfileViewClient(
                endpoint: configuration.endpoint("v2/profile-views/batch"),
                credentials: authSession
            )
        )
        self.profileRepository = profileRepository
        let syncEngine = V2SyncEngine(transport: transport, store: localStore, capabilityProfile: "base")
        let groupEventSync = V2GroupEventSyncEngine(transport: transport, store: localStore)
        let foregroundGroupPreview = V2ForegroundGroupEventPreviewEngine(transport: transport, store: localStore)
        let activeHybridGroupSynchronizer = V2RealtimeActiveHybridGroupSynchronizer(
            groupEventSync: groupEventSync,
            foregroundGroupPreview: foregroundGroupPreview,
            localStore: localStore,
            subscriptionTransport: transport,
            wakeSource: connection
        )
        let coordinator = V2RealtimeSessionCoordinator(
            authSession: authSession,
            connection: connection,
            supportedCapabilityProfiles: ["base"]
        )
        let projectionChangeNotifier = V2ProjectionChangeNotifier()
        let activity = V2DefaultClientRuntimeActivity(
            syncEngine: syncEngine,
            availabilitySource: connection,
            heartbeatSender: transport,
            heartbeatInterval: .seconds(30),
            // Every durable command, including ordinary sends, participates
            // in the same one-quantum scheduler. A large offline send queue
            // must not delay withdrawal or room-authority operations by 256
            // sequential requests.
            commandOutbox: nil,
            flushAdditionalDurableCommands: {
                // This must precede lane selection: once the first-party
                // retry contract expires, no old operation may get one final
                // network attempt while the server is free to compact it.
                try await localStore.expireStalePendingCommands(
                    now: Date()
                )
                let scheduler = V2FairDurableCommandScheduler(lanes: [
                    // Safety and room-authority changes run before normal
                    // sends, but all lanes retain one-quantum fairness.
                    .init { if case .idle = try await withdrawalOutbox.flushOnce() { return false }; return true },
                    .init { if case .idle = try await moderatedMemberRemovalOutbox.flushOnce() { return false }; return true },
                    .init { if case .idle = try await memberMuteOutbox.flushOnce() { return false }; return true },
                    .init { if case .idle = try await membershipOutbox.flushOnce() { return false }; return true },
                    .init { if case .idle = try await groupCapabilitiesOutbox.flushOnce() { return false }; return true },
                    // Interactive sends take precedence over deferred bulk
                    // forwarding. The latter is itself internally chunked.
                    .init { if case .idle = try await outbox.flushOnce() { return false }; return true },
                    .init { if case .idle = try await forwardMessagesOutbox.flushOnce() { return false }; return true },
                    .init { if case .idle = try await groupOutbox.flushOnce() { return false }; return true },
                    .init { if case .idle = try await socialOutbox.flushOnce() { return false }; return true },
                    .init { if case .idle = try await editOutbox.flushOnce() { return false }; return true },
                    .init { if case .idle = try await reactionOutbox.flushOnce() { return false }; return true },
                    .init { if case .idle = try await readReceiptOutbox.flushOnce() { return false }; return true },
                    .init { if case .idle = try await conversationCapabilitiesOutbox.flushOnce() { return false }; return true },
                ])
                _ = try await scheduler.flush(maximumWorkItems: 256)
            },
            afterDurableSynchronization: {
                // This runs after the priority outboxes.  It advances at most
                // a small number of persistent room cursors per activity
                // cycle; visible conversations retain their separate
                // immediate one-page path.
                _ = try await groupEventSync.synchronizeBackgroundKnownRooms(maximumPages: 12)
                // Profile invalidations are already durable at this point.
                // A transient account-edge failure must not roll back or
                // stall realtime synchronization; the next sync activity
                // coalesces the same pending rows into another bounded read.
                do {
                    _ = try await profileRepository.refreshPendingInvalidations()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Keep the invalidation row for a later authorized retry.
                }
                try await localStore.pruneTerminalCommands(
                    olderThan: Date().addingTimeInterval(-86_400)
                )
            },
            onProjectionSynchronized: {
                await projectionChangeNotifier.publish()
            }
        )
        runtime = .init(connection: coordinator, activity: activity)
        self.projectionChangeNotifier = projectionChangeNotifier
        self.activeHybridGroupSynchronizer = activeHybridGroupSynchronizer
        sender = V2OutboxConversationSender(outbox: outbox)
        messageWithdrawer = V2OutboxMessageWithdrawer(outbox: withdrawalOutbox)
        messageReactionChanger = V2OutboxMessageReactionChanger(outbox: reactionOutbox)
        messageEditor = V2OutboxMessageEditor(outbox: editOutbox)
        readReceiptReporter = V2OutboxConversationReadReporter(outbox: readReceiptOutbox)
        conversationStateChanger = V2OutboxConversationStateChanger(outbox: conversationCapabilitiesOutbox)
        messageFavoriter = V2OutboxMessageFavoriter(outbox: conversationCapabilitiesOutbox)
        groupMessagePinner = V2OutboxGroupMessagePinner(outbox: groupCapabilitiesOutbox)
        messageForwarder = V2OutboxMessageForwarder(outbox: forwardMessagesOutbox)
        groupAnnouncementManager = V2OutboxGroupAnnouncementManager(outbox: groupCapabilitiesOutbox)
        groupMemberRoleChanger = V2OutboxGroupMemberRoleChanger(outbox: groupCapabilitiesOutbox)
        groupRolePolicyChanger = V2OutboxGroupRolePolicyChanger(outbox: groupCapabilitiesOutbox)
        groupReadReceiptReader = V2RealtimeGroupReadReceiptReader(transport: transport)
        conversationLiveActivity = V2RealtimeConversationLiveActivity(transport: transport, events: connection)
        attachmentUploader = V2ForegroundConversationAttachmentUploader(uploader: mediaUploader)
        let foregroundMediaDownloader = try V2ForegroundConversationMediaDownloader(
            downloader: mediaDownloader,
            directory: mediaCacheDirectory
        )
        self.mediaDownloader = foregroundMediaDownloader
        self.mediaCacheMaintenance = foregroundMediaDownloader
        directConversationOpener = V2RealtimeDirectConversationOpener(transport: transport, localStore: localStore, runtime: runtime)
        groupConversationCreator = V2OutboxGroupConversationCreator(outbox: groupOutbox, runtime: runtime)
        groupMemberDirectory = V2RealtimeGroupMemberDirectory(transport: transport)
        groupMembershipChanger = V2OutboxGroupMembershipChanger(outbox: membershipOutbox)
        groupMemberMuter = V2OutboxGroupMemberMuter(outbox: memberMuteOutbox)
        moderatedGroupMemberRemover = V2OutboxModeratedGroupMemberRemover(outbox: moderatedMemberRemovalOutbox)
        strangerMessagePreferenceUpdater = V2OutboxStrangerMessagePreferenceUpdater(outbox: socialOutbox)
        userAddPreferenceUpdater = V2OutboxUserAddPreferenceUpdater(outbox: socialOutbox)
        readReceiptPreferenceUpdater = V2RealtimeReadReceiptPreferenceUpdater(outbox: socialOutbox)
        let liveActivityPreferenceService = V2RealtimeLiveActivityPreferenceUpdater(transport: transport)
        liveActivityPreferenceUpdater = liveActivityPreferenceService
        liveActivityPreferenceReader = liveActivityPreferenceService
        userBlockChanger = V2OutboxUserBlockChanger(outbox: socialOutbox)
        relationshipChanger = V2OutboxRelationshipChanger(outbox: socialOutbox)
    }

    let directConversationOpener: any V2DirectConversationOpening
    let groupConversationCreator: any V2GroupConversationCreating
    let groupMemberDirectory: any V2GroupMemberDirectoryReading
    let groupMembershipChanger: any V2GroupMembershipChanging
    let groupMemberMuter: any V2GroupMemberMuting
    let moderatedGroupMemberRemover: any V2ModeratedGroupMemberRemoving
    let strangerMessagePreferenceUpdater: any V2StrangerMessagePreferenceUpdating
    let userAddPreferenceUpdater: any V2UserAddPreferenceUpdating
    let readReceiptPreferenceUpdater: any V2ReadReceiptPreferenceUpdating
    let liveActivityPreferenceUpdater: any V2LiveActivityPreferenceUpdating
    let liveActivityPreferenceReader: any V2LiveActivityPreferenceReading
    let userBlockChanger: any V2UserBlockChanging
    let relationshipChanger: any V2RelationshipChanging
}
