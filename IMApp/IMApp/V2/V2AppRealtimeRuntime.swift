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

extension V2ConversationSending {
    func send(text: String, in roomID: String) async throws -> V2ConversationSendOutcome {
        try await send(text: text, media: [], in: roomID)
    }

    func send(text: String, media: [V2MediaReference], mentions: [V2MentionTarget], entities: [V2MessageEntity], replyTo: V2MessageReplyReference?, in roomID: String) async throws -> V2ConversationSendOutcome {
        guard entities.isEmpty, replyTo == nil else { throw V2RichMessageContentError.invalidEntity }
        return try await send(text: text, media: media, mentions: mentions, in: roomID)
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

extension V2GroupConversationCreating {
    func restoredCreationStatus() async throws -> V2RestoredGroupConversationCreationStatus? { nil }
}

struct V2GroupMemberItem: Equatable, Identifiable, Sendable {
    /// Opaque identifier used only for subsequent authenticated membership
    /// commands.  UI must render the public fields below instead.
    let id: String
    let role: String
    let handle: String?
    let displayName: String?

    init(id: String, role: String, handle: String? = nil, displayName: String? = nil) {
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
        switch try await outbox.flushOnce() {
        case .acknowledged(_, let roomID): return .created(roomID: roomID.rawValue)
        case .retryScheduled, .idle, .cancelled, .cancellationRefused: return .queuedForRetry(operationID: command.operationID.rawValue)
        case .rejected(_, let code): return .rejected(code: code)
        }
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
                    handle: $0.publicIdentity?.handle.rawValue,
                    displayName: $0.publicIdentity?.displayName
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
        guard let deliveryMode = try await localStore.groupDeliveryMode(roomID: parsedRoomID) else {
            return .notHybridRoom
        }
        let progress: V2GroupEventSyncProgress
        do {
            switch deliveryMode {
            case .largeGroupHybrid:
                progress = try await groupEventSync.synchronizeOnePage(roomID: parsedRoomID)
            case .standardFanout:
                progress = try await foregroundGroupPreview.synchronizeOnePage(roomID: parsedRoomID)
            }
        } catch let error as V2RealtimeTransportError {
            guard case .server(let code, _, _, _) = error, code == "FORBIDDEN" else { throw error }
            if deliveryMode == .largeGroupHybrid {
                try await localStore.deactivateHybridGroupRoom(roomID: parsedRoomID)
            }
            return .notHybridRoom
        }
        return .synchronized(appliedEventCount: progress.appliedEventCount, hasMore: progress.hasMore)
    }

    func subscribe(roomID: String) async throws -> V2ActiveHybridGroupSubscriptionOutcome {
        let parsedRoomID = try RoomID(roomID)
        guard let deliveryMode = try await localStore.groupDeliveryMode(roomID: parsedRoomID) else {
            return .notHybridRoom
        }
        do {
            let cursor: UInt64
            switch deliveryMode {
            case .largeGroupHybrid:
                cursor = try await localStore.groupEventCursor(roomID: parsedRoomID)
            case .standardFanout:
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
            if deliveryMode == .largeGroupHybrid {
                try await localStore.deactivateHybridGroupRoom(roomID: parsedRoomID)
            }
            return .notHybridRoom
        }
    }

    func nextWake() async throws -> V2ActiveHybridGroupWake {
        let wake = try await wakeSource.nextGroupEventAvailabilityHint()
        return .init(roomID: wake.roomID.rawValue, highWatermark: wake.highWatermark)
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
            directTransport: transport
        )
        let groupOutbox = V2GroupRoomCommandOutboxEngine(store: localStore, transport: transport)
        let membershipOutbox = V2MembershipCommandOutboxEngine(store: localStore, transport: transport)
        let memberMuteOutbox = V2MemberMuteOutboxEngine(store: localStore, transport: transport)
        let moderatedMemberRemovalOutbox = V2ModeratedMemberRemovalOutboxEngine(store: localStore, transport: transport)
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
                let scheduler = V2FairDurableCommandScheduler(lanes: [
                    // Safety and room-authority changes run before normal
                    // sends, but all lanes retain one-quantum fairness.
                    .init { if case .idle = try await withdrawalOutbox.flushOnce() { return false }; return true },
                    .init { if case .idle = try await moderatedMemberRemovalOutbox.flushOnce() { return false }; return true },
                    .init { if case .idle = try await memberMuteOutbox.flushOnce() { return false }; return true },
                    .init { if case .idle = try await membershipOutbox.flushOnce() { return false }; return true },
                    .init { if case .idle = try await outbox.flushOnce() { return false }; return true },
                    .init { if case .idle = try await groupOutbox.flushOnce() { return false }; return true },
                    .init { if case .idle = try await socialOutbox.flushOnce() { return false }; return true },
                    .init { if case .idle = try await editOutbox.flushOnce() { return false }; return true },
                    .init { if case .idle = try await reactionOutbox.flushOnce() { return false }; return true },
                    .init { if case .idle = try await readReceiptOutbox.flushOnce() { return false }; return true },
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
    let userBlockChanger: any V2UserBlockChanging
    let relationshipChanger: any V2RelationshipChanging
}
