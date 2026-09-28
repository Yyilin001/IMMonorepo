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

enum V2LiveActivityPreferenceUpdateOutcome: Equatable, Sendable { case accepted, queuedForRetry, rejected(code: String) }
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
protocol V2MessageReactionManaging:Sendable {
    func reactionUpdates(roomID:String) async throws -> AsyncThrowingStream<[V2MessageReactionPending],any Error>
    func resumeReactionConfirmation(intentID:UUID) async throws
}
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
protocol V2MessageMutationManaging: Sendable {
    func mutationUpdates(roomID:String) async throws -> AsyncThrowingStream<[V2MessageMutationSnapshot],any Error>
    func resumeMutationConfirmation(workID:UUID) async throws
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

protocol V2ConversationReadSyncManaging: V2ConversationReadReporting {
    func readSyncUpdates(roomID: String) async throws -> AsyncThrowingStream<V2ReadReceiptTrackingSnapshot, any Error>
    func resumeReadConfirmation(roomID: String) async throws
    func archiveUnavailableRead(workID: UUID) async throws
    func restoreReadArchive(workID: UUID) async throws
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
    func pinBaseline(roomID:String,messageID:String) async throws -> V2PinnedMessageBaseline
    func setPinned(roomID: String, messageID: String, isPinned: Bool, expectedRoomSequence:UInt64) async throws -> V2ConversationCapabilityOutcome
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
/// 请求先持久化；尚未取得原操作的成功回执时返回待处理状态。
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
    case needsConfirmation(operationID:String)
    case expired
    case created(roomID:String)
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
    /// 目录只提供命令目标；名称与头像通过当前房间展示许可获取。
    let id: String
    let role: String

    init(id: String, role: String) {
        self.id = id
        self.role = role
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
    func membershipConfirmation(roomID:String,action:V2RoomMembershipAction,expectedMembershipRevision:UInt64) throws -> V2MembershipConfirmationWindow
    func changeMembership(targetUserID:String,confirmation:V2MembershipConfirmationWindow) async throws -> V2GroupMembershipChangeOutcome
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
protocol V2MemberAdministrationManaging:Sendable {
    func administrationUpdates(roomID:RoomID) async -> AsyncThrowingStream<[V2MemberAdministrationPending],any Error>
    func resumeAdministration(id:UUID) async throws
    func reconfirmAdministration(id:UUID,revision:UInt64) async throws
    func discardAdministration(id:UUID) async throws
}

protocol V2GroupMemberMuting: Sendable {
    func muteMember(roomID: String, targetUserID: String, muteUntil: Date, reasonCode: V2ModerationReasonCode, expectedMembershipRevision: UInt64) async throws -> V2GroupModerationOutcome
}

protocol V2ModeratedGroupMemberRemoving: Sendable {
    func removeMemberByModerator(roomID: String, targetUserID: String, reasonCode: V2ModerationReasonCode, expectedMembershipRevision: UInt64) async throws -> V2GroupModerationOutcome
}

/// 面向界面的消息发送实现。
///
/// 它在尝试传输之前先持久化命令，因此前台连接失败会转化为持久化重试，
/// 而不是丢失界面意图。
actor V2OperationConversationSender: V2ConversationSending {
    private let service: V2MessageSendOperationService
    init(service:V2MessageSendOperationService) { self.service=service }
    func send(text:String,media:[V2MediaReference],in roomID:String) async throws -> V2ConversationSendOutcome {
        try await send(text:text,media:media,mentions:[],entities:[],replyTo:nil,in:roomID)
    }
    func send(text:String,media:[V2MediaReference],mentions:[V2MentionTarget],in roomID:String) async throws -> V2ConversationSendOutcome {
        try await send(text:text,media:media,mentions:mentions,entities:[],replyTo:nil,in:roomID)
    }
    func send(text:String,media:[V2MediaReference],mentions:[V2MentionTarget],entities:[V2MessageEntity],replyTo:V2MessageReplyReference?,in roomID:String) async throws -> V2ConversationSendOutcome {
        try Task.checkCancellation()
        // Attachment sends enter via durable consumer intents with explicit Ready dependencies.
        guard media.isEmpty else { throw V2OperationWorkError.dependencyUnavailable }
        _ = try await service.enqueueMessage(roomID:.init(roomID),text:text,mentions:mentions,entities:entities,replyTo:replyTo)
        return .queuedForRetry
    }
}

/// 在首次网络尝试之前持久化撤回。
///
/// 界面最终展示的墓碑状态以已同步的消息投影为权威，而不是以本次确认为准。
actor V2OperationMessageWithdrawer: V2MessageWithdrawing {
    private let service: V2MessageMutationOperationService
    init(service: V2MessageMutationOperationService) { self.service=service }
    func withdraw(messageID:String,in roomID:String,expectedMessageRevision:UInt64) async throws -> V2MessageWithdrawalOutcome {
        try Task.checkCancellation()
        _ = try await service.enqueueWithdrawal(roomID:.init(roomID),messageID:.init(messageID),expectedRevision:expectedMessageRevision)
        return .queuedForRetry
    }
}

actor V2OperationMessageReactionChanger: V2MessageReactionChanging,V2MessageReactionManaging {
    private let service:V2MessageReactionOperationService
    init(service:V2MessageReactionOperationService) { self.service=service }
    func reactionUpdates(roomID:String) async throws -> AsyncThrowingStream<[V2MessageReactionPending],any Error> { await service.updates(roomID:try .init(roomID)) }
    func resumeReactionConfirmation(intentID:UUID) async throws { try await service.resumeConfirmation(intentID:intentID) }
    func changeReaction(messageID:String,in roomID:String,reaction:String,action:V2MessageReactionAction) async throws -> V2MessageReactionOutcome {
        _ = try await service.enqueue(roomID:.init(roomID),messageID:.init(messageID),reaction:reaction,targetState:action == .add ? .present : .absent)
        return .queuedForRetry
    }
}

actor V2OperationMessageEditor: V2MessageEditing, V2MessageMutationManaging {
    private let service: V2MessageMutationOperationService
    init(service: V2MessageMutationOperationService) { self.service=service }
    func mutationUpdates(roomID:String) async throws -> AsyncThrowingStream<[V2MessageMutationSnapshot],any Error> {
        await service.updates(roomID:try .init(roomID))
    }
    func resumeMutationConfirmation(workID:UUID) async throws { try await service.resumeConfirmation(workID:workID) }
    func edit(messageID:String,in roomID:String,expectedMessageRevision:UInt64,text:String) async throws -> V2MessageEditOutcome {
        try Task.checkCancellation()
        _ = try await service.enqueueEdit(roomID:.init(roomID),messageID:.init(messageID),expectedRevision:expectedMessageRevision,text:text)
        return .queuedForRetry
    }
}

/// 面向界面的已读回执上报实现。
///
/// 底层存储会原子地抑制相等或更旧的水位，因此每当本地会话变为可见时都可以调用该 actor，
/// 包括离线重启之后，也不会产生重复记录。
actor V2OperationConversationReadReporter: V2ConversationReadSyncManaging {
    private let service: V2ReadReceiptOperationService
    init(service: V2ReadReceiptOperationService) { self.service = service }
    func readSyncUpdates(roomID: String) async throws -> AsyncThrowingStream<V2ReadReceiptTrackingSnapshot, any Error> {
        await service.statusUpdates(roomID:try .init(roomID))
    }
    func resumeReadConfirmation(roomID: String) async throws {
        try await service.resumeConfirmation(roomID:.init(roomID))
    }
    func archiveUnavailableRead(workID: UUID) async throws {
        try await service.archiveUnavailable(workID: workID)
    }
    func restoreReadArchive(workID: UUID) async throws {
        try await service.restoreArchive(workID: workID)
    }
    func recordReadThrough(roomID: String, roomSequence: UInt64) async throws -> V2ReadReceiptReportOutcome {
        try Task.checkCancellation()
        return try await service.enqueue(roomID:.init(roomID),readThrough:roomSequence) ? .queuedForRetry : .alreadyRecorded
    }
}

actor V2OutboxConversationStateChanger: V2ConversationStateChanging, V2PersonalPreferenceManaging {
    private let service: V2PersonalPreferenceService
    init(service: V2PersonalPreferenceService) { self.service = service }
    func preferenceUpdates(limit: Int) async -> AsyncThrowingStream<[V2PersonalPreferencePending], any Error> { await service.pendingUpdates(limit: limit) }
    func desiredPreferenceTarget(_ fallback: V2PersonalPreferenceTarget) async throws -> V2PersonalPreferenceTarget { try await service.desiredTarget(fallback: fallback) }
    func resumePreference(_ id: UUID) async throws { try await service.resumeConfirmation(intentID: id) }
    func discardPreference(_ id: UUID) async throws { try await service.discard(intentID: id) }

    func setState(roomID: String, isPinned: Bool, isArchived: Bool, muteUntil: Date?) async throws -> V2ConversationCapabilityOutcome {
        try Task.checkCancellation()
        try await service.enqueue(.conversation(roomID: .init(roomID), isPinned: isPinned, isArchived: isArchived, muteUntil: muteUntil))
        return .queuedForRetry
    }
}

actor V2OutboxMessageFavoriter: V2MessageFavoriting, V2PersonalPreferenceManaging {
    private let service: V2PersonalPreferenceService
    init(service: V2PersonalPreferenceService) { self.service = service }
    func preferenceUpdates(limit: Int) async -> AsyncThrowingStream<[V2PersonalPreferencePending], any Error> { await service.pendingUpdates(limit: limit) }
    func desiredPreferenceTarget(_ fallback: V2PersonalPreferenceTarget) async throws -> V2PersonalPreferenceTarget { try await service.desiredTarget(fallback: fallback) }
    func resumePreference(_ id: UUID) async throws { try await service.resumeConfirmation(intentID: id) }
    func discardPreference(_ id: UUID) async throws { try await service.discard(intentID: id) }

    func setFavorite(roomID: String, messageID: String, isFavorited: Bool) async throws -> V2ConversationCapabilityOutcome {
        try Task.checkCancellation()
        try await service.enqueue(.favorite(roomID: .init(roomID), messageID: .init(messageID), isFavorited: isFavorited))
        return .queuedForRetry
    }
}

protocol V2GroupCapabilityManaging:Sendable {
    var service:V2GroupCapabilityOperationService { get }
}

struct V2OperationGroupMessagePinner: V2GroupMessagePinning, V2GroupCapabilityManaging {
    let service:V2GroupCapabilityOperationService
    func pinBaseline(roomID:String,messageID:String) async throws -> V2PinnedMessageBaseline {
        try await service.pinBaseline(roomID:.init(roomID),messageID:.init(messageID))
    }
    func setPinned(roomID:String,messageID:String,isPinned:Bool,expectedRoomSequence:UInt64) async throws -> V2ConversationCapabilityOutcome {
        let confirmation=try service.confirmationWindow(roomID:.init(roomID),action:.pin(messageID:.init(messageID),isPinned:isPinned,expectedRoomSequence:expectedRoomSequence))
        try await service.enqueue(confirmation:confirmation)
        return .queuedForRetry
    }
}

protocol V2ForwardPlanManaging: V2MessageForwarding {
    func updates(sourceRoomID:RoomID) async -> AsyncThrowingStream<[V2ForwardPlanSnapshot],any Error>
    func resumeConfirmation(workID:UUID) async throws
    func cancelRemaining(workID:UUID) async throws
}
actor V2OperationMessageForwarder: V2ForwardPlanManaging {
    private let service:V2ForwardPlanOperationService
    init(service:V2ForwardPlanOperationService) { self.service=service }
    func forward(sources:[V2ForwardMessageReference],targetRoomIDs:[String]) async throws -> V2MessageForwardingOutcome {
        _ = try await service.enqueue(sources:sources,targetRoomIDs:targetRoomIDs.map(RoomID.init))
        return .queued
    }
    func updates(sourceRoomID:RoomID) async -> AsyncThrowingStream<[V2ForwardPlanSnapshot],any Error> { await service.updates(sourceRoomID:sourceRoomID) }
    func resumeConfirmation(workID:UUID) async throws { try await service.resumeConfirmation(workID:workID) }
    func cancelRemaining(workID:UUID) async throws { try await service.cancelRemaining(workID:workID) }
}

struct V2OperationGroupAnnouncementManager: V2GroupAnnouncementManaging {
    let service:V2GroupCapabilityOperationService
    func setAnnouncement(roomID:String,body:String,expectedRevision:UInt64) async throws -> V2ConversationCapabilityOutcome {
        let confirmation=try service.confirmationWindow(roomID:.init(roomID),action:.announcement(body:body,expectedRevision:expectedRevision))
        try await service.enqueue(confirmation:confirmation)
        return .queuedForRetry
    }
}

struct V2OperationGroupMemberRoleChanger: V2GroupMemberRoleChanging {
    let service:V2GroupCapabilityOperationService
    func setRole(roomID:String,userID:String,role:V2RoomMembershipRole,expectedMembershipRevision:UInt64) async throws -> V2ConversationCapabilityOutcome {
        let confirmation=try service.confirmationWindow(roomID:.init(roomID),action:.memberRole(targetUserID:.init(userID),role:role,expectedMembershipRevision:expectedMembershipRevision))
        try await service.enqueue(confirmation:confirmation)
        return .queuedForRetry
    }
}

struct V2OperationGroupRolePolicyChanger: V2GroupRolePolicyChanging {
    let service:V2GroupCapabilityOperationService
    func setPolicy(roomID:String,role:V2RoomMembershipRole,permissions:Set<V2GroupPermission>,expectedRevision:UInt64) async throws -> V2ConversationCapabilityOutcome {
        let confirmation=try service.confirmationWindow(roomID:.init(roomID),action:.rolePermissions(role:role,permissions:permissions,expectedRevision:expectedRevision))
        try await service.enqueue(confirmation:confirmation)
        return .queuedForRetry
    }
}

enum V2DirectConversationOpeningState:Error {
    case queued(UUID)
    case rejected
    case expired
}

protocol V2DirectConversationRecovering:V2DirectConversationOpening {
    var service:V2DirectRoomOperationService { get }
}

struct V2OperationDirectConversationOpener:V2DirectConversationRecovering {
    let service:V2DirectRoomOperationService
    func openConversation(with publicIdentity:V2PublicIdentity) async throws -> String {
        let id=try await service.enqueue(publicIdentity:publicIdentity)
        try Task.checkCancellation()
        if let receipt=try await service.receipt(id:id) {
            switch receipt.outcome {
            case .opened(let roomID,_):return roomID.rawValue
            case .closed,.rejected(.firstSubmissionExpired):throw V2DirectConversationOpeningState.expired
            case .rejected:throw V2DirectConversationOpeningState.rejected
            }
        }
        try await service.resumeIfNeeded(id:id)
        throw V2DirectConversationOpeningState.queued(id)
    }
}

/// 持久化建群的界面边界。
///
/// 请求先写入本地，再由账户执行器推进有界步骤。
protocol V2GroupCreationRecovering:V2GroupConversationCreating {
    func creationUpdates() async -> AsyncThrowingStream<Void,any Error>
    func resumeCreation(operationID:String) async throws
}
struct V2OperationGroupConversationCreator:V2GroupCreationRecovering {
    let service:V2GroupCreationOperationService
    func creationUpdates() async -> AsyncThrowingStream<Void,any Error> { await service.updates() }
    func createConversation(title:String,initialMemberUserIDs:[String]) async throws -> V2GroupConversationCreationOutcome {
        let members=try initialMemberUserIDs.map { try UserID($0.trimmingCharacters(in:.whitespacesAndNewlines)) }
        let id=try await service.enqueue(title:title,members:members)
        return .queuedForRetry(operationID:id.uuidString)
    }
    func cancelConversationCreation(operationID:String) async throws -> V2GroupConversationCancellationOutcome {
        guard let id=UUID(uuidString:operationID) else { throw V2OperationWorkError.invalidRecord }
        try await service.requestCancellation(id:id)
        let pending=try await service.pending(id:id)
        return pending.progress?.phase == .finalizing ? .finalizationAlreadyStarted:.queuedForRetry
    }
    func resumeCreation(operationID:String) async throws {
        guard let id=UUID(uuidString:operationID) else { throw V2OperationWorkError.invalidRecord }
        try await service.resume(id:id)
    }
    func restoredCreationStatus() async throws -> V2RestoredGroupConversationCreationStatus? {
        guard let pending=try await service.latest() else { return nil }
        let id=pending.work.id.uuidString
        if let receipt=pending.receipt {
            switch receipt.outcome {
            case .created(let room,_,_,_): return .created(roomID:room.rawValue)
            case .closed:return pending.cancellationRequested ? .cancelled:.expired
            case .rejected(.submissionExpired):return .expired
            case .rejected(let reason):return .rejected(code:reason.rawValue)
            }
        }
        if pending.work.execution == .expiredUnsubmitted { return .expired }
        if pending.work.execution == .cancelledLocally { return .cancelled }
        if pending.work.scheduling == .needsAttention { return .needsConfirmation(operationID:id) }
        if pending.progress?.phase == .finalizing { return .finalizing(operationID:id) }
        if pending.cancellationRequested { return .cancelling(operationID:id) }
        return .queuedForRetry(operationID:id)
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
                    role: Self.displayRole($0.role)
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

actor V2OperationLiveActivityPreferenceUpdater:V2LiveActivityPreferenceUpdating,V2LiveActivityPreferenceReading {
    let service:V2AccountPreferenceService
    init(service:V2AccountPreferenceService) { self.service=service }
    func update(allowsOnlinePresence:Bool,allowsTypingIndicators:Bool) async throws -> V2LiveActivityPreferenceUpdateOutcome {
        _ = try await service.enqueue(value:.liveActivity(allowsOnlinePresence:allowsOnlinePresence,allowsTypingIndicators:allowsTypingIndicators));return .queuedForRetry
    }
    func preferences() async throws -> V2LiveActivityPreferences {
        let snapshot:V2AccountPreferenceSnapshot
        if let cached=try await service.cachedBaseline(kind:.liveActivityPreference) {snapshot=cached} else {return .init(allowsOnlinePresence:true,allowsTypingIndicators:true,updatedAt:Date())}
        guard case .liveActivity(let online,let typing)=snapshot.value else { throw V2AccountPreferenceValidationError.invalidSnapshot }
        return .init(allowsOnlinePresence:online,allowsTypingIndicators:typing,updatedAt:Date())
    }
}

actor V2RealtimeConversationLiveActivity: V2ConversationLiveActivityManaging {
    private let transport: any V2ClientLiveActivityTransport
    private let events: any V2LiveActivityEventSource
    private let localStore:GRDBV2LocalSyncStore

    init(transport: any V2ClientLiveActivityTransport, events: any V2LiveActivityEventSource,localStore:GRDBV2LocalSyncStore) {
        self.transport = transport; self.events = events;self.localStore=localStore
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

    func setTyping(roomID: String, isTyping: Bool) async throws {
        let permitted:Bool
        if isTyping { permitted=try await localStore.allowsLocalTypingPublication() } else { permitted=true }
        try await transport.setTyping(roomID: .init(roomID), isTyping: isTyping && permitted)
    }
    func nextEvent() async throws -> V2LiveActivityEvent { try await events.nextLiveActivityEvent() }
}

/// 面向界面的群成员变更实现。
///
/// 它在尝试实时请求之前记录成员操作；授权权威仍在服务端，
/// 界面只是不再展示已知对当前成员角色无效的控件。
protocol V2MembershipManaging:Sendable {
    func membershipUpdates(roomID:RoomID) async -> AsyncThrowingStream<[V2MembershipPending],any Error>
    func resumeMembership(id:UUID) async throws
    func reconfirmMembership(id:UUID,confirmation:V2MembershipConfirmationWindow) async throws
    func discardMembership(id:UUID) async throws
}
actor V2OperationGroupMembershipChanger:V2GroupMembershipChanging,V2MembershipManaging {
    let service:V2MembershipOperationService
    init(service:V2MembershipOperationService) { self.service=service }
    nonisolated func membershipConfirmation(roomID:String,action:V2RoomMembershipAction,expectedMembershipRevision:UInt64) throws -> V2MembershipConfirmationWindow {
        try service.confirmationWindow(roomID:.init(roomID),action:action,expectedMembershipRevision:expectedMembershipRevision)
    }
    func changeMembership(targetUserID:String,confirmation:V2MembershipConfirmationWindow) async throws -> V2GroupMembershipChangeOutcome {
        _ = try await service.enqueue(targetUserID:.init(targetUserID),confirmation:confirmation)
        return .queuedForRetry
    }
    func membershipUpdates(roomID:RoomID) async -> AsyncThrowingStream<[V2MembershipPending],any Error> { await service.updates(roomID:roomID) }
    func resumeMembership(id:UUID) async throws { try await service.resumeConfirmation(id:id) }
    func reconfirmMembership(id:UUID,confirmation:V2MembershipConfirmationWindow) async throws { _ = try await service.reconfirmDraft(id:id,confirmation:confirmation) }
    func discardMembership(id:UUID) async throws { try await service.discardDraft(id:id) }
}

actor V2OperationGroupMemberAdministrator: V2GroupMemberMuting, V2ModeratedGroupMemberRemoving, V2MemberAdministrationManaging {
    let service:V2MemberAdministrationOperationService
    init(service:V2MemberAdministrationOperationService) { self.service=service }
    func administrationUpdates(roomID:RoomID) async -> AsyncThrowingStream<[V2MemberAdministrationPending],any Error> { await service.updates(roomID:roomID) }
    func resumeAdministration(id:UUID) async throws { try await service.resumeConfirmation(id:id) }
    func reconfirmAdministration(id:UUID,revision:UInt64) async throws { _ = try await service.reconfirmDraft(id:id,expectedMembershipRevision:revision) }
    func discardAdministration(id:UUID) async throws { try await service.discardDraft(id:id) }
    func muteMember(roomID:String,targetUserID:String,muteUntil:Date,reasonCode:V2ModerationReasonCode,expectedMembershipRevision:UInt64) async throws -> V2GroupModerationOutcome {
        guard let until=UInt64(exactly:(muteUntil.timeIntervalSince1970*1_000).rounded(.towardZero)),until>0 else { throw V2MemberAdministrationValidationError.invalidIntent }
        _ = try await service.enqueue(roomID:.init(roomID),targetUserID:.init(targetUserID),action:.mute(untilMilliseconds:until),reasonCode:reasonCode,expectedMembershipRevision:expectedMembershipRevision)
        return .queuedForRetry
    }
    func removeMemberByModerator(roomID:String,targetUserID:String,reasonCode:V2ModerationReasonCode,expectedMembershipRevision:UInt64) async throws -> V2GroupModerationOutcome {
        _ = try await service.enqueue(roomID:.init(roomID),targetUserID:.init(targetUserID),action:.remove,reasonCode:reasonCode,expectedMembershipRevision:expectedMembershipRevision)
        return .queuedForRetry
    }
}

/// 面向界面的陌生人消息偏好更新实现。
///
/// 它把用户接收偏好保存在持久化社交命令发件箱中。其他设备修改该设置后，
/// 远端同步投影仍是权威；该 actor 负责在连接中断时保留本地意图。
actor V2OperationStrangerMessagePreferenceUpdater:V2StrangerMessagePreferenceUpdating {
    let service:V2AccountPreferenceService
    init(service:V2AccountPreferenceService) { self.service=service }
    func update(allowsStrangerMessages:Bool) async throws -> V2StrangerMessagePreferenceUpdateOutcome {
        _ = try await service.enqueue(value:.strangerMessage(allowsStrangerMessages ? .allow : .deny));return .queuedForRetry
    }
}
actor V2OperationUserAddPreferenceUpdater:V2UserAddPreferenceUpdating {
    let service:V2AccountPreferenceService
    init(service:V2AccountPreferenceService) { self.service=service }
    func update(allowsBeingAdded:Bool) async throws -> V2UserAddPreferenceUpdateOutcome {
        _ = try await service.enqueue(value:.userAdd(allowsBeingAdded ? .allow : .deny));return .queuedForRetry
    }
}
actor V2OperationReadReceiptPreferenceUpdater:V2ReadReceiptPreferenceUpdating {
    let service:V2AccountPreferenceService
    init(service:V2AccountPreferenceService) { self.service=service }
    func update(allowsDirectReadReceipts:Bool,allowsGroupReadReceipts:Bool) async throws -> V2ReadReceiptPreferenceUpdateOutcome {
        _ = try await service.enqueue(value:.readReceipt(allowsDirectReadReceipts:allowsDirectReadReceipts,allowsGroupReadReceipts:allowsGroupReadReceipts));return .queuedForRetry
    }
}

protocol V2SocialOperationManaging:Sendable {
    func socialProposals() async -> AsyncThrowingStream<[V2SocialOperationProposal],any Error>
    func saveSocialProposal(action:V2SocialOperationAction,target:UserID) async throws -> UUID
    func confirmSocialProposal(id:UUID,snapshot:V2SocialOperationSnapshot) async throws
    func discardSocialProposal(id:UUID) async throws
    func socialBaseline(target:UserID) async throws -> V2SocialOperationSnapshot
    func enqueueSocial(action:V2SocialOperationAction,snapshot:V2SocialOperationSnapshot) async throws
    func socialUpdates() async -> AsyncThrowingStream<[V2SocialOperationPending],any Error>
    func resumeSocialConfirmation(workID:UUID) async throws
}
actor V2OperationUserBlockChanger:V2UserBlockChanging,V2SocialOperationManaging {
    let service:V2SocialOperationService
    init(service:V2SocialOperationService) { self.service=service }
    func changeBlock(targetUserID:String,action:V2UserBlockAction) async throws -> V2UserBlockChangeOutcome {
        _ = try await service.enqueue(action:.userBlock(action),targetUserID:.init(targetUserID));return .queuedForRetry
    }
    func socialProposals() async -> AsyncThrowingStream<[V2SocialOperationProposal],any Error> { await service.proposalUpdates() }
    func saveSocialProposal(action:V2SocialOperationAction,target:UserID) async throws -> UUID { try await service.saveProposal(action:action,target:target) }
    func confirmSocialProposal(id:UUID,snapshot:V2SocialOperationSnapshot) async throws { try await service.confirmProposal(id:id,snapshot:snapshot) }
    func discardSocialProposal(id:UUID) async throws { try await service.discardProposal(id:id) }
    func socialBaseline(target:UserID) async throws -> V2SocialOperationSnapshot { try await service.baseline(targetUserID:target) }
    func enqueueSocial(action:V2SocialOperationAction,snapshot:V2SocialOperationSnapshot) async throws { _ = try await service.enqueue(action:action,snapshot:snapshot) }
    func socialUpdates() async -> AsyncThrowingStream<[V2SocialOperationPending],any Error> { await service.updates() }
    func resumeSocialConfirmation(workID:UUID) async throws { try await service.resumeConfirmation(workID:workID) }
}
actor V2OperationRelationshipChanger:V2RelationshipChanging,V2SocialOperationManaging {
    let service:V2SocialOperationService
    init(service:V2SocialOperationService) { self.service=service }
    func changeRelationship(targetUserID:String,action:V2RelationshipAction) async throws -> V2RelationshipChangeOutcome {
        _ = try await service.enqueue(action:.relationship(action),targetUserID:.init(targetUserID));return .queuedForRetry
    }
    func socialProposals() async -> AsyncThrowingStream<[V2SocialOperationProposal],any Error> { await service.proposalUpdates() }
    func saveSocialProposal(action:V2SocialOperationAction,target:UserID) async throws -> UUID { try await service.saveProposal(action:action,target:target) }
    func confirmSocialProposal(id:UUID,snapshot:V2SocialOperationSnapshot) async throws { try await service.confirmProposal(id:id,snapshot:snapshot) }
    func discardSocialProposal(id:UUID) async throws { try await service.discardProposal(id:id) }
    func socialBaseline(target:UserID) async throws -> V2SocialOperationSnapshot { try await service.baseline(targetUserID:target) }
    func enqueueSocial(action:V2SocialOperationAction,snapshot:V2SocialOperationSnapshot) async throws { _ = try await service.enqueue(action:action,snapshot:snapshot) }
    func socialUpdates() async -> AsyncThrowingStream<[V2SocialOperationPending],any Error> { await service.updates() }
    func resumeSocialConfirmation(workID:UUID) async throws { try await service.resumeConfirmation(workID:workID) }
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
    let accountRuntime: V2AccountRuntime
    let personalPreferences: V2PersonalPreferenceService
    let nameOperations: V2NameOperationService
    let resourceTransfers: V2ResourceTransferEngine
    let runtime: V2ClientRuntime
    let roomRecovery: V2RoomRecoveryRunner
    let backgroundSync: V2BackgroundSyncRunner
    let projectionChangeNotifier: V2ProjectionChangeNotifier
    let sender: any V2ConversationSending
    let messageWithdrawer: any V2MessageWithdrawing
    let messageReactionOperations:V2MessageReactionOperationService
    let messageReactionChanger: any V2MessageReactionChanging
    let messageSendOperations: V2MessageSendOperationService
    let messageMutationOperations: V2MessageMutationOperationService
    let messageEditor: any V2MessageEditing
    let readReceiptOperations: V2ReadReceiptOperationService
    let readReceiptReporter: any V2ConversationReadReporting
    let conversationStateChanger: any V2ConversationStateChanging
    let messageFavoriter: any V2MessageFavoriting
    let groupMessagePinner: any V2GroupMessagePinning
    let messageModerationOperations:V2MessageModerationOperationService
    let directRoomOperations:V2DirectRoomOperationService
    let groupCreationOperations:V2GroupCreationOperationService
    let groupCapabilityOperations:V2GroupCapabilityOperationService
    let accountPreferences:V2AccountPreferenceService
    let socialOperations:V2SocialOperationService
    let membershipOperations:V2MembershipOperationService
    let memberAdministrationOperations:V2MemberAdministrationOperationService
    let forwardPlanOperations:V2ForwardPlanOperationService
    let messageForwarder: any V2MessageForwarding
    let groupAnnouncementManager: any V2GroupAnnouncementManaging
    let groupMemberRoleChanger: any V2GroupMemberRoleChanging
    let groupRolePolicyChanger: any V2GroupRolePolicyChanging
    let groupReadReceiptReader: any V2GroupReadReceiptReading
    let conversationLiveActivity: any V2ConversationLiveActivityManaging
    let attachmentUploader: V2ForegroundConversationAttachmentUploader
    let groupAvatarIntents: V2GroupAvatarIntentEngine
    let groupAvatarManager: V2GroupAvatarManagementService
    let mediaDownloader: any V2ConversationMediaDownloading
    let mediaCacheMaintenance: V2ForegroundConversationMediaDownloader
    let activeHybridGroupSynchronizer: any V2ActiveHybridGroupSynchronizing
    let roomSubscriptions: V2RoomSubscriptionCoordinator
    let makeAuthorPresentationCoordinator: @Sendable (V2ProfilePresentationRepository) -> V2AuthorPresentationPageCoordinator
    let profileRepository: V2ProfileRepository
    let profilePresentations: V2ProfilePresentationRepository

    init(
        configuration: V2AppConfiguration,
        actorUserID: UserID,
        deviceID: DeviceID,
        authSession: V2AuthSession,
        authEpoch: V2AuthSessionEpoch,
        localStore: GRDBV2LocalSyncStore,
        mediaCacheDirectory: URL,
        mediaStagingDirectory: URL
    ) throws {
        let frameLimits = try V2FrameLimits(
            maximumPayloadBytes: 65_536,
            acceptedVersions: [0, UInt8(IMV2ProtocolVersion.current)]
        )
        let accountRuntime = V2AccountRuntime()
        self.accountRuntime = accountRuntime
        let connection = V2TLSFrameConnection(endpoint: configuration.realtimeEndpoint, frameLimits: frameLimits,
                                              supportsAuthorPresentationDelta: true, workScheduler: accountRuntime.scheduler,initialPresenceMode:{
                                                  try await localStore.localPublicationPolicy().allowsOnlinePresence ? .allowWhenAuthorized:.suppressed
                                              })
        let transport = V2ProtobufSyncTransport(
            wire: connection,
            protocolVersion: UInt8(IMV2ProtocolVersion.current)
        )
        let accountHTTP = V2SessionHTTPAuthorization(session: authSession, epoch: authEpoch,
            transport: try V2RegisteredAccountHTTPTransport(executor: accountRuntime.httpExecutor,
                allowedBases: [configuration.accountBaseURL, configuration.mediaEdgeEndpoint.deletingLastPathComponent().deletingLastPathComponent()],
                scope: accountRuntime.queryScope(accountID: actorUserID.rawValue, authorizationDomain: "accountHTTP")), scheduler: accountRuntime.scheduler)
        let messageSendOperations=V2MessageSendOperationService(accountID:actorUserID,store:localStore,
            client:try V2HTTPMessageSendOperationClient(baseURL:configuration.accountBaseURL,credentials:accountHTTP,transport:accountHTTP))
        self.messageSendOperations=messageSendOperations
        let socialOperations=V2SocialOperationService(accountID:actorUserID,store:localStore,
            client:try V2HTTPSocialOperationClient(baseURL:configuration.accountBaseURL,credentials:accountHTTP,transport:accountHTTP))
        self.socialOperations=socialOperations
        let accountPreferences=V2AccountPreferenceService(accountID:actorUserID,activationID:accountRuntime.ownerID,store:localStore,
            client:try V2HTTPAccountPreferenceOperationClient(baseURL:configuration.accountBaseURL,credentials:accountHTTP,transport:accountHTTP))
        self.accountPreferences=accountPreferences
        let groupCreationOperations=V2GroupCreationOperationService(accountID:actorUserID,store:localStore,
            client:try V2HTTPGroupCreationOperationClient(baseURL:configuration.accountBaseURL,credentials:accountHTTP,transport:accountHTTP))
        self.groupCreationOperations=groupCreationOperations
        self.messageModerationOperations=V2MessageModerationOperationService(accountID:actorUserID,activationID:accountRuntime.ownerID,store:localStore,
            client:try V2HTTPMessageModerationClient(baseURL:configuration.accountBaseURL,credentials:accountHTTP,transport:accountHTTP))
        self.directRoomOperations=V2DirectRoomOperationService(accountID:actorUserID,store:localStore,
            client:try V2HTTPDirectRoomOperationClient(baseURL:configuration.accountBaseURL,credentials:accountHTTP,transport:accountHTTP))
        let membershipOperations=V2MembershipOperationService(accountID:actorUserID,activationID:accountRuntime.ownerID,store:localStore,
            client:try V2HTTPMembershipOperationClient(baseURL:configuration.accountBaseURL,credentials:accountHTTP,transport:accountHTTP))
        self.membershipOperations=membershipOperations
        let memberAdministrationOperations=V2MemberAdministrationOperationService(accountID:actorUserID,activationID:accountRuntime.ownerID,store:localStore,
            client:try V2HTTPMemberAdministrationClient(baseURL:configuration.accountBaseURL,credentials:accountHTTP,transport:accountHTTP))
        self.memberAdministrationOperations=memberAdministrationOperations
        let messageReactionOperations=V2MessageReactionOperationService(accountID:actorUserID,store:localStore,
            client:try V2HTTPMessageReactionOperationClient(baseURL:configuration.accountBaseURL,credentials:accountHTTP,transport:accountHTTP))
        self.messageReactionOperations=messageReactionOperations
        let messageMutationOperations=V2MessageMutationOperationService(accountID:actorUserID,store:localStore,
            client:try V2HTTPMessageMutationOperationClient(baseURL:configuration.accountBaseURL,credentials:accountHTTP,transport:accountHTTP))
        self.messageMutationOperations=messageMutationOperations
        let readReceiptOperations = V2ReadReceiptOperationService(accountID:actorUserID,store:localStore,
            client:try V2ReadReceiptOperationAdapter(realtime:transport,baseURL:configuration.accountBaseURL,credentials:accountHTTP,transport:accountHTTP))
        self.readReceiptOperations = readReceiptOperations
        let personalPreferences = V2PersonalPreferenceService(accountID: actorUserID, store: localStore, transport: transport,
            recovery: try V2HTTPPersonalPreferenceRecoveryClient(roomsEndpoint: configuration.endpoint("v2/rooms"), credentials: accountHTTP, transport: accountHTTP))
        self.personalPreferences = personalPreferences
        let groupCapabilityOperations=V2GroupCapabilityOperationService(accountID:actorUserID,activationID:accountRuntime.ownerID,store:localStore,
            client:try V2HTTPGroupCapabilityOperationClient(baseURL:configuration.accountBaseURL,credentials:accountHTTP,transport:accountHTTP))
        self.groupCapabilityOperations=groupCapabilityOperations
        let forwardPlanOperations=V2ForwardPlanOperationService(accountID:actorUserID,store:localStore,
            client:try V2HTTPForwardPlanOperationClient(baseURL:configuration.accountBaseURL,credentials:accountHTTP,transport:accountHTTP))
        self.forwardPlanOperations=forwardPlanOperations
        let mediaDownloadResolver = try V2HTTPMediaDownloadTargetResolver(
            endpoint: configuration.mediaEdgeEndpoint,
            credentials: accountHTTP, transport: accountHTTP
        )
        let mediaDownloader = V2ClientMediaDownloadService(
            targetResolver: mediaDownloadResolver,
            byteTransfer: V2URLSessionMediaByteTransfer(scheduler: accountRuntime.scheduler, diagnostics: accountRuntime.networkDiagnostics)
        )
        let profilePresentations = V2ProfilePresentationRepository(actorUserID: actorUserID, deviceID: deviceID,
            reader: try V2HTTPProfilePresentationClient(endpoint: configuration.endpoint("v2/profile-presentations/batch"),
                credentials: accountHTTP, transport: accountHTTP),
            nicknameRevisions: { try await localStore.groupNicknameRevisions(keys: $0) },
            aliasRevisions: { try await localStore.contactAliasRevisions(keys: $0) })
        self.profilePresentations = profilePresentations
        self.nameOperations = V2NameOperationService(accountID: actorUserID, store: localStore,
            client: try V2HTTPNameOperationClient(endpoint: configuration.endpoint("v2/profile-presentations"),
                credentials: accountHTTP, transport: accountHTTP),
            didCommit: { await profilePresentations.invalidateEditedName($0) })
        let profileRepository = V2ProfileRepository(store: localStore,
            reader: V2ProfileProjectionReader(presentations: profilePresentations))
        self.profileRepository = profileRepository
        let syncOwnership = V2SyncOperationGate()
        let syncEngine = V2SyncEngine(transport: transport, store: localStore, capabilityProfile: "base", operationGate: syncOwnership)
        let backgroundConnection = V2TLSFrameConnection(endpoint: configuration.realtimeEndpoint, frameLimits: frameLimits, workScheduler: accountRuntime.scheduler, workService: "realtime-background",initialPresenceMode:{.suppressed})
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
        makeAuthorPresentationCoordinator = { profiles in
            .init(rooms: roomSubscriptions, source: connection, subscriptions: transport, profiles: profiles,
                roomCursor: { try await localStore.groupEventCursor(roomID: $0) })
        }
        let coordinator = V2RealtimeSessionCoordinator(
            authSession: authSession,
            connection: connection,
            supportedCapabilityProfiles: ["base"]
        )
        localStore.installNetworkDiagnostics(accountRuntime.networkDiagnostics)
        let projectionChangeNotifier = V2ProjectionChangeNotifier(localStore: localStore)
        let roomRecoveryEngine = V2RoomRecoveryEngine(transport: transport, latestVisible: transport, store: localStore, groupEvents: groupEventSync)
        let roomCatchUpWorker = V2RoomRecoveryRunner(engine: roomRecoveryEngine, source: connection, personalSync: syncEngine)
        self.roomRecovery = roomCatchUpWorker
        let activity = V2DefaultClientRuntimeActivity(
            syncEngine: syncEngine,
            availabilitySource: connection,
            heartbeatSender: transport,
            heartbeatInterval: .seconds(30),
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
                try await withThrowingTaskGroup(of:Void.self) {group in
                    group.addTask {try await V2RolePolicyRecoveryRunner(store:localStore,transport:transport).run()}
                    group.addTask {
                        for try await policy in localStore.publicationPolicyUpdates() {
                            try Task.checkCancellation()
                            try await transport.setPresencePublicationMode(policy.allowsOnlinePresence ? .allowWhenAuthorized:.suppressed)
                        }
                    }
                    try await group.waitForAll()
                }
            }
        )
        runtime = .init(connection: coordinator, activity: activity)
        self.projectionChangeNotifier = projectionChangeNotifier
        self.activeHybridGroupSynchronizer = activeHybridGroupSynchronizer
        sender = V2OperationConversationSender(service:messageSendOperations)
        messageWithdrawer = V2OperationMessageWithdrawer(service:messageMutationOperations)
        messageReactionChanger = V2OperationMessageReactionChanger(service: messageReactionOperations)
        messageEditor = V2OperationMessageEditor(service:messageMutationOperations)
        readReceiptReporter = V2OperationConversationReadReporter(service: readReceiptOperations)
        conversationStateChanger = V2OutboxConversationStateChanger(service: personalPreferences)
        messageFavoriter = V2OutboxMessageFavoriter(service: personalPreferences)
        groupMessagePinner = V2OperationGroupMessagePinner(service:groupCapabilityOperations)
        messageForwarder = V2OperationMessageForwarder(service:forwardPlanOperations)
        groupAnnouncementManager = V2OperationGroupAnnouncementManager(service:groupCapabilityOperations)
        groupMemberRoleChanger = V2OperationGroupMemberRoleChanger(service:groupCapabilityOperations)
        groupRolePolicyChanger = V2OperationGroupRolePolicyChanger(service:groupCapabilityOperations)
        groupReadReceiptReader = V2RealtimeGroupReadReceiptReader(transport: transport)
        conversationLiveActivity = V2RealtimeConversationLiveActivity(transport: transport, events: connection,localStore:localStore)
        let resourceControl = try V2HTTPResourceUploadClient(endpoint: configuration.endpoint("v2/resource-uploads"), credentials: accountHTTP, transport: accountHTTP)
        let resourceEngine = V2ResourceTransferEngine(store: localStore, control: resourceControl, executor: V2URLSessionResourcePlanExecutor(scheduler: accountRuntime.scheduler, diagnostics: accountRuntime.networkDiagnostics), directory: mediaStagingDirectory,
            capabilities: V2ResourceCapabilitiesCache(reader: resourceControl))
        self.resourceTransfers = resourceEngine
        let resourceImports = try V2HTTPResourceImportClient(endpoint: configuration.endpoint("v2/resource-imports"), credentials: accountHTTP, transport: accountHTTP)
        let groupAvatarCommands = try V2HTTPGroupAvatarCommandClient(roomsEndpoint: configuration.endpoint("v2/rooms"),
            actorUserID: actorUserID, credentials: accountHTTP, transport: accountHTTP)
        let groupAvatarIntents = V2GroupAvatarIntentEngine(actorUserID: actorUserID, store: localStore,
            transfers: resourceEngine, submissions: groupAvatarCommands, recovery: groupAvatarCommands)
        self.groupAvatarIntents = groupAvatarIntents
        let groupReader = try V2HTTPGroupAvatarPresentationClient(roomsEndpoint: configuration.endpoint("v2/rooms"),
            actorUserID: actorUserID, credentials: accountHTTP, transport: accountHTTP)
        let groupAvatarManager = V2GroupAvatarManagementService(actorUserID: actorUserID, deviceID: deviceID,
            store: localStore, intents: groupAvatarIntents, reader: groupReader,
            capabilities: resourceControl, directory: mediaStagingDirectory)
        self.groupAvatarManager = groupAvatarManager
        let durableSender = V2DurableConversationSendService(store: localStore, engine: resourceEngine, messageOperations:messageSendOperations,
            imports: resourceImports, groupAvatars: groupAvatarIntents, groupAvatarManager: groupAvatarManager)
        attachmentUploader = V2ForegroundConversationAttachmentUploader(durable: durableSender)
        let foregroundMediaDownloader = try V2ForegroundConversationMediaDownloader(
            downloader: mediaDownloader,
            directory: mediaCacheDirectory
        )
        self.mediaDownloader = foregroundMediaDownloader
        self.mediaCacheMaintenance = foregroundMediaDownloader
        directConversationOpener = V2OperationDirectConversationOpener(service:directRoomOperations)
        groupConversationCreator = V2OperationGroupConversationCreator(service:groupCreationOperations)
        groupMemberDirectory = V2RealtimeGroupMemberDirectory(transport: transport)
        groupMembershipChanger = V2OperationGroupMembershipChanger(service:membershipOperations)
        groupMemberMuter = V2OperationGroupMemberAdministrator(service:memberAdministrationOperations)
        moderatedGroupMemberRemover = V2OperationGroupMemberAdministrator(service:memberAdministrationOperations)
        strangerMessagePreferenceUpdater = V2OperationStrangerMessagePreferenceUpdater(service:accountPreferences)
        userAddPreferenceUpdater = V2OperationUserAddPreferenceUpdater(service:accountPreferences)
        readReceiptPreferenceUpdater = V2OperationReadReceiptPreferenceUpdater(service:accountPreferences)
        let liveActivityPreferenceService = V2OperationLiveActivityPreferenceUpdater(service:accountPreferences)
        liveActivityPreferenceUpdater = liveActivityPreferenceService
        liveActivityPreferenceReader = liveActivityPreferenceService
        userBlockChanger = V2OperationUserBlockChanger(service:socialOperations)
        relationshipChanger = V2OperationRelationshipChanger(service:socialOperations)
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

protocol V2AccountPreferenceManaging:Sendable {
    var accountPreferenceService:V2AccountPreferenceService { get }
}
extension V2OperationStrangerMessagePreferenceUpdater:V2AccountPreferenceManaging { nonisolated var accountPreferenceService:V2AccountPreferenceService { service } }
extension V2OperationUserAddPreferenceUpdater:V2AccountPreferenceManaging { nonisolated var accountPreferenceService:V2AccountPreferenceService { service } }
extension V2OperationReadReceiptPreferenceUpdater:V2AccountPreferenceManaging { nonisolated var accountPreferenceService:V2AccountPreferenceService { service } }
extension V2OperationLiveActivityPreferenceUpdater:V2AccountPreferenceManaging { nonisolated var accountPreferenceService:V2AccountPreferenceService { service } }
