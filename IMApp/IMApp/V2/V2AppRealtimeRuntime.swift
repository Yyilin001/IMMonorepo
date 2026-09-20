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

/// 群已读回执读取能力。
///
/// 回执详情只在用户显式操作之后才去获取，刻意不保存在常规时间线投影中。
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

/// 面向界面的消息撤回边界。
///
/// 实现必须在尝试传输之前先把操作持久化，使连接中断不会导致意图丢失。
protocol V2MessageWithdrawing: Sendable {
    func withdraw(messageID: String, in roomID: String, expectedMessageRevision: UInt64) async throws -> V2MessageWithdrawalOutcome
}

enum V2MessageReactionOutcome: Equatable, Sendable {
    case accepted
    case queuedForRetry
    case rejected(code: String)
}

/// 面向界面的消息表情边界。
///
/// 持久化命令被确认之后，可见表情集合仍以消息投影为权威。
protocol V2MessageReactionChanging: Sendable {
    func changeReaction(messageID: String, in roomID: String, reaction: String, action: V2MessageReactionAction) async throws -> V2MessageReactionOutcome
}

enum V2MessageEditOutcome: Equatable, Sendable {
    case accepted
    case queuedForRetry
    case rejected(code: String)
}

/// 面向界面的消息编辑边界。
///
/// 调用方从自己的持久化投影中取得修订号；作者身份与冲突判定仍以服务端为权威。
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

/// 面向界面的会话展示状态变更边界。
///
/// 这是私有用户维度状态；重连之后，权威来源仍是服务端投影，而不是列表上的乐观改动。
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
    case queued
    case rejected(code: String)
}

/// 面向界面的消息转发边界。
///
/// 界面为每条来源提交房间、消息与修订引用；真正的重试记录保存在发件箱中，
/// 因此离开选择目标页面也不会丢失转发工作。
protocol V2MessageForwarding: Sendable {
    func forward(sources: [V2ForwardMessageReference], targetRoomIDs: [String]) async throws -> V2MessageForwardingOutcome
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

/// 为当前登录用户与目标用户打开确定性私聊房间的边界。
///
/// 开房在服务端是幂等的，因此传输中断后可以安全重试；该边界不涉及任何消息内容。
protocol V2DirectConversationOpening: Sendable {
    func openConversation(with publicIdentity: V2PublicIdentity) async throws -> String
}

/// 在实时协议收到不透明用户标识之前先解析显式公开账号名的能力。
///
/// 这样可以让 UUID 不出现在任何面向产品的输入字段中。
protocol V2ConversationPublicIdentityResolving: Sendable {
    func resolve(handle: String) async throws -> V2PublicIdentity
}

extension V2HTTPPublicIdentityDirectory: V2ConversationPublicIdentityResolving {}

enum V2GroupConversationCreationOutcome: Equatable, Sendable {
    case created(roomID: String)
    /// 操作已持久化保存但尚未完成。
    ///
    /// 界面会保留该标识，使用户显式取消时能够命中同一条持久化记录。
    case queuedForRetry(operationID: String)
    case rejected(code: String)
}

enum V2GroupConversationCancellationOutcome: Equatable, Sendable {
    case cancelled
    case queuedForRetry
    case finalizationAlreadyStarted
}

/// 界面重建后从本地发件箱恢复的建群状态。
///
/// 它只暴露产品层状态，不暴露传输或数据库细节。
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
    /// 仅用于后续已认证成员命令的不透明标识；界面必须改为渲染下方的公开字段。
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

/// 面向界面的用户拉黑名单边界。
///
/// 命令在传输之前先持久化；收到的社交投影仍是权威来源。
protocol V2UserBlockChanging: Sendable {
    func changeBlock(targetUserID: String, action: V2UserBlockAction) async throws -> V2UserBlockChangeOutcome
}

enum V2RelationshipChangeOutcome: Equatable, Sendable {
    case accepted
    case queuedForRetry
    case rejected(code: String)
}

/// 面向界面的好友关系变更边界。
///
/// 可见关系状态仍由同步投影驱动；该边界只负责保存并尝试执行用户的持久化意图。
protocol V2RelationshipChanging: Sendable {
    func changeRelationship(targetUserID: String, action: V2RelationshipAction) async throws -> V2RelationshipChangeOutcome
}

enum V2GroupModerationOutcome: Equatable, Sendable {
    case accepted
    case queuedForRetry
    case rejected(code: String)
}

/// 面向界面的群成员禁言边界。
///
/// 两类审核动作都有各自独立的持久化操作与审计记录，
/// 绝不能借用普通成员变更路径来执行。
protocol V2GroupMemberMuting: Sendable {
    func muteMember(roomID: String, targetUserID: String, muteUntil: Date, reasonCode: V2ModerationReasonCode) async throws -> V2GroupModerationOutcome
}

protocol V2ModeratedGroupMemberRemoving: Sendable {
    func removeMemberByModerator(roomID: String, targetUserID: String, reasonCode: V2ModerationReasonCode) async throws -> V2GroupModerationOutcome
}

/// 面向界面的消息发送实现。
///
/// 它在尝试传输之前先持久化命令，因此前台连接失败会转化为持久化重试，
/// 而不是丢失界面意图。
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
        try Task.checkCancellation()
        let command = try await outbox.enqueueMessage(roomID: .init(roomID), text: text, media: media, mentions: mentions, entities: entities, replyTo: replyTo)
        do {
            switch try await outbox.flushOnce() {
            case .accepted(let identifier) where identifier == command.clientMessageID:
                return .accepted
            case .rejected(let identifier, let code) where identifier == command.clientMessageID:
                return .rejected(code: code)
            case .accepted, .rejected, .retryScheduled, .idle:
                return .queuedForRetry
            }
        } catch is CancellationError {
            // Runtime suspension cancels its flush owner independently from
            // this caller. The command was durably enqueued above.
            try Task.checkCancellation()
            return .queuedForRetry
        }
    }
}

/// 在首次网络尝试之前持久化撤回。
///
/// 界面最终展示的墓碑状态以已同步的消息投影为权威，而不是以本次确认为准。
actor V2OutboxMessageWithdrawer: V2MessageWithdrawing {
    private let outbox: V2MessageWithdrawalOutboxEngine

    init(outbox: V2MessageWithdrawalOutboxEngine) { self.outbox = outbox }

    func withdraw(messageID: String, in roomID: String, expectedMessageRevision: UInt64) async throws -> V2MessageWithdrawalOutcome {
        try Task.checkCancellation()
        let pending = try await outbox.enqueueWithdrawal(
            roomID: try .init(roomID),
            messageID: try .init(messageID),
            expectedMessageRevision: expectedMessageRevision
        )
        switch try await outbox.flushOnce() {
        case .acknowledged(let operationID) where operationID == pending.operationID: return .accepted
        case .rejected(let operationID, let code) where operationID == pending.operationID: return .rejected(code: code)
        case .acknowledged, .rejected, .retryScheduled, .idle: return .queuedForRetry
        }
    }
}

actor V2OutboxMessageReactionChanger: V2MessageReactionChanging {
    private let outbox: V2MessageReactionOutboxEngine

    init(outbox: V2MessageReactionOutboxEngine) { self.outbox = outbox }

    func changeReaction(messageID: String, in roomID: String, reaction: String, action: V2MessageReactionAction) async throws -> V2MessageReactionOutcome {
        try Task.checkCancellation()
        let pending = try await outbox.enqueueReaction(
            roomID: try .init(roomID),
            messageID: try .init(messageID),
            reaction: reaction,
            action: action
        )
        switch try await outbox.flushOnce() {
        case .acknowledged(let operationID) where operationID == pending.operationID: return .accepted
        case .rejected(let operationID, let code) where operationID == pending.operationID: return .rejected(code: code)
        case .acknowledged, .rejected, .retryScheduled, .idle: return .queuedForRetry
        }
    }
}

actor V2OutboxMessageEditor: V2MessageEditing {
    private let outbox: V2MessageEditOutboxEngine

    init(outbox: V2MessageEditOutboxEngine) { self.outbox = outbox }

    func edit(messageID: String, in roomID: String, expectedMessageRevision: UInt64, text: String) async throws -> V2MessageEditOutcome {
        try Task.checkCancellation()
        let pending = try await outbox.enqueueEdit(
            roomID: try .init(roomID),
            messageID: try .init(messageID),
            expectedMessageRevision: expectedMessageRevision,
            text: text
        )
        switch try await outbox.flushOnce() {
        case .acknowledged(let operationID) where operationID == pending.operationID: return .accepted
        case .rejected(let operationID, let code) where operationID == pending.operationID: return .rejected(code: code)
        case .acknowledged, .rejected, .retryScheduled, .idle: return .queuedForRetry
        }
    }
}

/// 面向界面的已读回执上报实现。
///
/// 底层存储会原子地抑制相等或更旧的水位，因此每当本地会话变为可见时都可以调用该 actor，
/// 包括离线重启之后，也不会产生重复记录。
actor V2OutboxConversationReadReporter: V2ConversationReadReporting {
    private let outbox: V2ReadReceiptOutboxEngine

    init(outbox: V2ReadReceiptOutboxEngine) { self.outbox = outbox }

    func recordReadThrough(roomID: String, roomSequence: UInt64) async throws -> V2ReadReceiptReportOutcome {
        try Task.checkCancellation()
        guard let pending = try await outbox.enqueueReceiptIfAdvancing(roomID: .init(roomID), readThroughRoomSequence: roomSequence) else {
            return .alreadyRecorded
        }
        switch try await outbox.flushOnce() {
        case .acknowledged(let operationID) where operationID == pending.operationID: return .recorded
        case .rejected(let operationID, let code) where operationID == pending.operationID: return .rejected(code: code)
        case .acknowledged, .rejected, .retryScheduled, .idle: return .queuedForRetry
        }
    }
}

actor V2OutboxConversationStateChanger: V2ConversationStateChanging {
    private let outbox: V2ConversationCapabilitiesOutboxEngine
    init(outbox: V2ConversationCapabilitiesOutboxEngine) { self.outbox = outbox }
    func setState(roomID: String, isPinned: Bool, isArchived: Bool, muteUntil: Date?) async throws -> V2ConversationCapabilityOutcome {
        try Task.checkCancellation()
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
        try Task.checkCancellation()
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
        try Task.checkCancellation()
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

    func forward(sources: [V2ForwardMessageReference], targetRoomIDs: [String]) async throws -> V2MessageForwardingOutcome {
        try Task.checkCancellation()
        let targetIDs = try targetRoomIDs.map(RoomID.init)
        let plan = try await outbox.enqueue(sources: sources, targetRoomIDs: targetIDs)
        _ = try await outbox.flushOnce()
        // A flush completes at most one chunk and may serve an older plan.
        // Only the durable parent can establish this user's whole outcome.
        guard let current = try await outbox.plan(operationID: plan.operationID) else {
            throw V2ClientCommandError.commandConflict
        }
        switch current.state {
        case .completed:
            return .completed(succeeded: current.succeededCount, failed: current.failedCount)
        case .active:
            return .queued
        case .cancelled:
            return .rejected(code: current.terminalCode ?? "CANCELLED")
        }
    }
}

actor V2OutboxGroupAnnouncementManager: V2GroupAnnouncementManaging {
    private let outbox: V2GroupCapabilitiesOutboxEngine

    init(outbox: V2GroupCapabilitiesOutboxEngine) { self.outbox = outbox }

    func setAnnouncement(roomID: String, body: String, expectedRevision: UInt64) async throws -> V2ConversationCapabilityOutcome {
        try Task.checkCancellation()
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
        try Task.checkCancellation()
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
        try Task.checkCancellation()
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
        try await localStore.cacheDirectRoomIdentity(roomID: opened.roomID, publicIdentity: publicIdentity, roomCreatedAt: opened.createdAt)
        return opened.roomID.rawValue
    }
}

/// 持久化建群的界面边界。
///
/// 它先获取前台实时会话，使创建成功时能立刻返回房间标识；
/// 若连接无法建立，仍会记录请求并返回常规的持久化重试结果。
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
        guard let capacityClass = V2GroupCapacityPolicy().capacityClass(forInitialMemberCount: members.count + 1) else {
            return .rejected(code: "GROUP_MEMBER_LIMIT_REACHED")
        }
        let command = try await outbox.enqueueCreation(title: title, capacityClass: capacityClass, initialMemberUserIDs: members)
        // A staged creation has at least Begin and Finalize, plus one bounded
        // Append per audience page. Calling the durable engine only once made
        // a healthy foreground creation look offline after Begin succeeded.
        // Keep the immediate path finite; a network error still leaves the
        // same persisted command for the normal reconnect scheduler.
        let pageCount = (members.count + V2GroupAudienceImportLimits.maximumMembersPerAppend - 1) / V2GroupAudienceImportLimits.maximumMembersPerAppend
        let maximumForegroundFlushes = pageCount + 2
        for _ in 0..<maximumForegroundFlushes {
            switch try await outbox.flushOnce() {
            case .acknowledged(let operationID, let roomID) where operationID == command.operationID: return .created(roomID: roomID.rawValue)
            case .rejected(let operationID, let code) where operationID == command.operationID: return .rejected(code: code)
            case .retryScheduled:
                continue
            case .idle, .cancelled, .cancellationRefused, .acknowledged, .rejected:
                return .queuedForRetry(operationID: command.operationID.rawValue)
            }
        }
        return .queuedForRetry(operationID: command.operationID.rawValue)
    }

    func cancelConversationCreation(operationID: String) async throws -> V2GroupConversationCancellationOutcome {
        try Task.checkCancellation()
        let requestedID = try GroupRoomOperationID(operationID)
        try await outbox.requestCancellation(operationID: requestedID)
        switch try await outbox.flushOnce() {
        case .cancelled(let completedID) where completedID == requestedID:
            return .cancelled
        case .cancellationRefused(let completedID) where completedID == requestedID:
            return .finalizationAlreadyStarted
        case .retryScheduled, .idle, .acknowledged, .rejected, .cancelled, .cancellationRefused:
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

/// 面向界面的群成员变更实现。
///
/// 它在尝试实时请求之前记录成员操作；授权权威仍在服务端，
/// 界面只是不再展示已知对当前成员角色无效的控件。
actor V2OutboxGroupMembershipChanger: V2GroupMembershipChanging {
    private let outbox: V2MembershipCommandOutboxEngine

    init(outbox: V2MembershipCommandOutboxEngine) { self.outbox = outbox }

    func changeMembership(roomID: String, targetUserID: String, action: V2RoomMembershipAction, expectedMembershipRevision: UInt64) async throws -> V2GroupMembershipChangeOutcome {
        try Task.checkCancellation()
        let pending = try await outbox.enqueueMembershipChange(
            roomID: .init(roomID),
            targetUserID: .init(targetUserID.trimmingCharacters(in: .whitespacesAndNewlines)),
            action: action,
            expectedMembershipRevision: expectedMembershipRevision
        )
        switch try await outbox.flushOnce() {
        case .acknowledged(let operationID) where operationID == pending.operationID: return .accepted
        case .rejected(let operationID, let code) where operationID == pending.operationID: return .rejected(code: code)
        case .acknowledged, .rejected, .retryScheduled, .idle: return .queuedForRetry
        }
    }
}

actor V2OutboxGroupMemberMuter: V2GroupMemberMuting {
    private let outbox: V2MemberMuteOutboxEngine

    init(outbox: V2MemberMuteOutboxEngine) { self.outbox = outbox }

    func muteMember(roomID: String, targetUserID: String, muteUntil: Date, reasonCode: V2ModerationReasonCode) async throws -> V2GroupModerationOutcome {
        try Task.checkCancellation()
        let pending = try await outbox.enqueueMute(
            roomID: .init(roomID),
            targetUserID: .init(targetUserID),
            muteUntil: muteUntil,
            reasonCode: reasonCode
        )
        switch try await outbox.flushOnce() {
        case .acknowledged(let operationID) where operationID == pending.operationID: return .accepted
        case .rejected(let operationID, let code) where operationID == pending.operationID: return .rejected(code: code)
        case .acknowledged, .rejected, .retryScheduled, .idle: return .queuedForRetry
        }
    }
}

actor V2OutboxModeratedGroupMemberRemover: V2ModeratedGroupMemberRemoving {
    private let outbox: V2ModeratedMemberRemovalOutboxEngine

    init(outbox: V2ModeratedMemberRemovalOutboxEngine) { self.outbox = outbox }

    func removeMemberByModerator(roomID: String, targetUserID: String, reasonCode: V2ModerationReasonCode) async throws -> V2GroupModerationOutcome {
        try Task.checkCancellation()
        let pending = try await outbox.enqueueRemoval(
            roomID: .init(roomID),
            targetUserID: .init(targetUserID),
            reasonCode: reasonCode
        )
        switch try await outbox.flushOnce() {
        case .acknowledged(let operationID) where operationID == pending.operationID: return .accepted
        case .rejected(let operationID, let code) where operationID == pending.operationID: return .rejected(code: code)
        case .acknowledged, .rejected, .retryScheduled, .idle: return .queuedForRetry
        }
    }
}

/// 面向界面的陌生人消息偏好更新实现。
///
/// 它把用户接收偏好保存在持久化社交命令发件箱中。其他设备修改该设置后，
/// 远端同步投影仍是权威；该 actor 负责在连接中断时保留本地意图。
actor V2OutboxStrangerMessagePreferenceUpdater: V2StrangerMessagePreferenceUpdating {
    private let outbox: V2SocialCommandOutboxEngine

    init(outbox: V2SocialCommandOutboxEngine) {
        self.outbox = outbox
    }

    func update(allowsStrangerMessages: Bool) async throws -> V2StrangerMessagePreferenceUpdateOutcome {
        try Task.checkCancellation()
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
        try Task.checkCancellation()
        let command = try await outbox.enqueueUserAddPermission(allowsBeingAdded ? .allow : .deny)
        switch try await outbox.flushIfReady(operationID: command.operationID) {
        case nil: return .queuedForRetry
        case .acknowledged: return .accepted
        case .retryScheduled, .idle: return .queuedForRetry
        case .rejected(_, let code): return .rejected(code: code)
        }
    }
}

/// 面向界面的已读回执偏好更新实现。
///
/// 回执偏好变更是幂等协议命令；服务端仍是权威，并由其同步投影协调其他设备。
actor V2RealtimeReadReceiptPreferenceUpdater: V2ReadReceiptPreferenceUpdating {
    private let outbox: V2SocialCommandOutboxEngine
    init(outbox: V2SocialCommandOutboxEngine) { self.outbox = outbox }
    func update(allowsDirectReadReceipts: Bool, allowsGroupReadReceipts: Bool) async throws -> V2ReadReceiptPreferenceUpdateOutcome {
        try Task.checkCancellation()
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
        try Task.checkCancellation()
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
        try Task.checkCancellation()
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

/// 把活跃会话界面桥接到可复用房间日志引擎的适配器。
///
/// 它使 SwiftUI 存储无需直接访问 SQLite 或实现实时协议。
/// 混合大群持久化房间日志游标；标准群只使用独立的内存前台预览游标，
/// 其持久化投递权威仍是常规扇出。
actor V2RealtimeActiveHybridGroupSynchronizer: V2ActiveHybridGroupSynchronizing {
    private let groupEventSync: V2GroupEventSyncEngine
    private let localStore: GRDBV2LocalSyncStore
    private let subscriptionTransport: any V2ClientGroupEventSubscriptionTransport
    private let wakeSource: any V2GroupEventAvailabilityHintSource

    init(
        groupEventSync: V2GroupEventSyncEngine,
        localStore: GRDBV2LocalSyncStore,
        subscriptionTransport: any V2ClientGroupEventSubscriptionTransport,
        wakeSource: any V2GroupEventAvailabilityHintSource
    ) {
        self.groupEventSync = groupEventSync
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
            progress = try await groupEventSync.synchronizeOnePage(roomID: parsedRoomID)
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
            let cursor = try await localStore.groupEventCursor(roomID: parsedRoomID)
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
              access.isAuthorized
        else { return false }
        let cursor = try await localStore.groupEventCursor(roomID: roomID)
        if wake.highWatermark <= cursor { return true }
        let unapplied = wake.liveEvents.drop(while: { $0.roomSequence <= cursor })
        guard unapplied.first?.roomSequence == cursor + 1,
              unapplied.last?.roomSequence == wake.highWatermark
        else { return false }
        let page = try V2ClientGroupEventPage(
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
    }
}

struct V2AppRealtimeRuntime {
    let runtime: V2ClientRuntime
    let roomRecovery: V2RoomRecoveryRunner
    let backgroundSync: V2BackgroundSyncRunner
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
    let attachmentUploader: V2ForegroundConversationAttachmentUploader
    let mediaDownloader: any V2ConversationMediaDownloading
    let mediaCacheMaintenance: V2ForegroundConversationMediaDownloader
    let activeHybridGroupSynchronizer: any V2ActiveHybridGroupSynchronizing
    let roomSubscriptions: V2RoomSubscriptionCoordinator
    let profileRepository: V2ProfileRepository

    init(
        configuration: V2AppConfiguration,
        authSession: V2AuthSession,
        authEpoch: V2AuthSessionEpoch,
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
        let accountHTTP = V2SessionHTTPAuthorization(session: authSession, epoch: authEpoch)
        let mediaEdge = try V2HTTPMediaUploadEdgeClient(
            endpoint: configuration.mediaEdgeEndpoint,
            credentials: accountHTTP, transport: accountHTTP
        )
        let mediaUploader = V2ClientMediaUploadService(
            targetResolver: mediaEdge,
            byteTransfer: V2URLSessionMediaByteTransfer(),
            completer: mediaEdge,
            statusReader: mediaEdge
        )
        let mediaDownloadResolver = try V2HTTPMediaDownloadTargetResolver(
            endpoint: configuration.mediaEdgeEndpoint,
            credentials: accountHTTP, transport: accountHTTP
        )
        let mediaDownloader = V2ClientMediaDownloadService(
            targetResolver: mediaDownloadResolver,
            byteTransfer: V2URLSessionMediaByteTransfer()
        )
        let profileRepository = V2ProfileRepository(
            store: localStore,
            reader: try V2HTTPProfileViewClient(
                endpoint: configuration.endpoint("v2/profile-views/batch"),
                credentials: accountHTTP, transport: accountHTTP
            )
        )
        self.profileRepository = profileRepository
        let syncOwnership = V2SyncOperationGate()
        let syncEngine = V2SyncEngine(transport: transport, store: localStore, capabilityProfile: "base", operationGate: syncOwnership)
        let backgroundConnection = V2TLSFrameConnection(endpoint: configuration.realtimeEndpoint, frameLimits: frameLimits)
        let backgroundTransport = V2ProtobufSyncTransport(wire: backgroundConnection, protocolVersion: UInt8(IMV2ProtocolVersion.current))
        let backgroundPersonalSync = V2SyncEngine(transport: backgroundTransport, store: localStore, capabilityProfile: "base", maxRecords: 100, operationGate: syncOwnership)
        let backgroundRecovery = V2RoomRecoveryRunner(
            engine: V2RoomRecoveryEngine(transport: backgroundTransport, latestVisible: backgroundTransport, store: localStore,
                groupEvents: V2GroupEventSyncEngine(transport: backgroundTransport, store: localStore, pageSize: 100)),
            source: backgroundConnection, personalSync: backgroundPersonalSync)
        backgroundSync = V2BackgroundSyncRunner(
            connection: V2RealtimeSessionCoordinator(authSession: authSession, connection: backgroundConnection, supportedCapabilityProfiles: ["base"]),
            syncEngine: backgroundPersonalSync,
            roomSync: { pages in
                let credentials = try await authSession.realtimeCredentials()
                try await authSession.requireAuthenticatedEpoch(authEpoch)
                return try await backgroundRecovery.runBounded(userID: credentials.userID, maximumPages: pages)
            }
        )
        let groupEventSync = V2GroupEventSyncEngine(transport: transport, store: localStore)
        let activeHybridGroupSynchronizer = V2RealtimeActiveHybridGroupSynchronizer(
            groupEventSync: groupEventSync,
            localStore: localStore,
            subscriptionTransport: transport,
            wakeSource: connection
        )
        let roomSubscriptions = V2RoomSubscriptionCoordinator(
            subscriptions: transport, activity: transport,
            groupEvents: connection, activityEvents: connection,
            isAuthorized: { roomID in
                try await localStore.groupEventAccess(roomID: roomID)?.isAuthorized == true
            },
            roomCursor: { roomID in
                guard let access = try await localStore.groupEventAccess(roomID: roomID), access.isAuthorized else {
                    throw V2RealtimeTransportError.server(code: "FORBIDDEN", retryable: false, retryAfterSeconds: 0, currentRevision: nil)
                }
                return try await localStore.groupEventCursor(roomID: roomID)
            }
        )
        self.roomSubscriptions = roomSubscriptions
        let coordinator = V2RealtimeSessionCoordinator(
            authSession: authSession,
            connection: connection,
            supportedCapabilityProfiles: ["base"]
        )
        let projectionChangeNotifier = V2ProjectionChangeNotifier(localStore: localStore)
        let commandScheduler = V2FairDurableCommandScheduler(lanes: [
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
        let roomRecoveryEngine = V2RoomRecoveryEngine(transport: transport, latestVisible: transport, store: localStore, groupEvents: groupEventSync)
        let roomCatchUpWorker = V2RoomRecoveryRunner(engine: roomRecoveryEngine, source: connection, personalSync: syncEngine)
        self.roomRecovery = roomCatchUpWorker
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
            commandLifecycles: [
                commandScheduler, outbox, socialOutbox, groupOutbox, membershipOutbox, memberMuteOutbox,
                moderatedMemberRemovalOutbox, withdrawalOutbox, reactionOutbox,
                editOutbox, readReceiptOutbox, conversationCapabilitiesOutbox,
                groupCapabilitiesOutbox, forwardMessagesOutbox
            ],
            commandRetrySchedule: localStore.commandRetrySchedule(lanes: [
                .messages, .withdrawals, .edits, .reactions, .readReceipts, .membership,
                .memberMutes, .moderatedMemberRemovals, .groupCapabilities,
                .conversationCapabilities, .social, .groupCreation, .forwardPlans
            ]),
            flushAdditionalDurableCommands: {
                // This must precede lane selection: once the first-party
                // retry contract expires, no old operation may get one final
                // network attempt while the server is free to compact it.
                try await localStore.expireStalePendingCommands(
                    now: Date()
                )
                _ = try await commandScheduler.flush(maximumWorkItems: 256)
            },
            afterDurableSynchronization: {
                // Request bounded room work after priority commands; the
                // runtime-owned worker continues without blocking startup.
                await roomCatchUpWorker.requestCatchUp()
                await roomSubscriptions.authorityDidChange()
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
            roomSubscriptionLoop: { connectionID in
                guard let connectionID else { throw V2TLSFrameConnectionError.notConnected }
                try await roomSubscriptions.run(connectionID: connectionID)
            },
            roomCatchUpLoop: {
                let credentials = try await authSession.realtimeCredentials()
                try await authSession.requireAuthenticatedEpoch(authEpoch)
                try await roomCatchUpWorker.run(userID: credentials.userID)
            },
            policyRecoveryLoop: {
                // A fresh loop owner per authenticated connection prevents an
                // old cancelled read from owning the replacement session.
                try await V2RolePolicyRecoveryRunner(store: localStore, transport: transport).run()
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
