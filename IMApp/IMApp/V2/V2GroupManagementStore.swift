import Foundation
import IMV2ClientKit
import IMV2Core
import Observation

/// Owns the group's directory, permission baseline and management confirmations.
/// Pages observe this store directly; account services retain durable work when
/// a page's observation is cancelled.
@MainActor
@Observable
final class V2GroupManagementStore {
    private let messageModerator: V2MessageModerationOperationService?
    private let groupMessagePinner: (any V2GroupMessagePinning)?
    private let groupAnnouncementReader: (any V2GroupAnnouncementReading)?
    private let groupAnnouncementManager: (any V2GroupAnnouncementManaging)?
    private let groupMemberRoleChanger: (any V2GroupMemberRoleChanging)?
    private let groupRolePolicyReader: (any V2GroupRolePolicyAccessing)?
    private let groupRolePolicyChanger: (any V2GroupRolePolicyChanging)?
    private let groupMemberDirectory: (any V2GroupMemberDirectoryReading)?
    private let groupMembershipChanger: (any V2GroupMembershipChanging)?
    private let groupMemberMuter: (any V2GroupMemberMuting)?
    private let moderatedGroupMemberRemover: (any V2ModeratedGroupMemberRemoving)?
    private let publicIdentityResolver: (any V2ConversationPublicIdentityResolving)?
    private let messageActions: V2ConversationMessageActionActivity
    private let userID: String
    let roomID: String
    let kind: V2ConversationKind
    var isGroupConversation: Bool { kind.isGroup }
    private(set) var feedback: String?
    @ObservationIgnored private var metadataReadGeneration: UInt64 = 0

    private(set) var groupMembers: [V2GroupMemberItem] = []
    private(set) var hasEarlierGroupMembers = false
    private(set) var groupMemberRevision: UInt64?
    private(set) var groupMemberDirectoryIsStale = true
    enum GroupMemberRefreshReason { case userInitiated, authorizationChanged }
    private(set) var groupActorRole: String?
    private(set) var canLoadMoreGroupMembers = false
    private(set) var groupMemberFeedback: String?
    private(set) var isLoadingGroupMembers = false
    private(set) var isChangingGroupMembership = false
    private(set) var isApplyingGroupModeration = false
    private var nextGroupMemberCursor: String?
    private var groupMemberReloadPending = false
    private(set) var groupAnnouncement: V2ClientGroupAnnouncement?
    private(set) var isSavingGroupAnnouncement = false
    private(set) var groupRolePolicyState = V2ClientGroupRolePolicyState(policies: [], recovery: .needed)
    var groupRolePolicies: [V2ClientGroupRolePolicy] { groupRolePolicyState.policies }
    enum PolicyRecoveryAction: Equatable { case idle, requesting, failed }
    private(set) var policyRecoveryAction = PolicyRecoveryAction.idle
    private var rolePolicyReadGeneration: UInt64 = 0
    private(set) var isLoadingGroupRolePolicies = false
    private(set) var isSavingGroupRolePolicy = false

    init(
        roomID: String, userID: String, kind: V2ConversationKind,
        groups: V2ConversationGroupDependencies,
        announcementReader: (any V2GroupAnnouncementReading)?,
        policyReader: (any V2GroupRolePolicyAccessing)?,
        messagePinner: (any V2GroupMessagePinning)?,
        messageModerator: V2MessageModerationOperationService?,
        publicIdentityResolver: (any V2ConversationPublicIdentityResolving)?,
        messageActions: V2ConversationMessageActionActivity
    ) {
        self.roomID = roomID
        self.userID = userID
        self.kind = kind
        self.messageActions = messageActions
        self.publicIdentityResolver = publicIdentityResolver
        self.messageModerator = messageModerator
        groupMessagePinner = messagePinner
        groupAnnouncementReader = announcementReader
        groupRolePolicyReader = policyReader
        groupAnnouncementManager = groups.announcementManager
        groupMemberRoleChanger = groups.memberRoleChanger
        groupRolePolicyChanger = groups.rolePolicyChanger
        groupMemberDirectory = groups.memberDirectory
        groupMembershipChanger = groups.membershipChanger
        groupMemberMuter = groups.memberMuter
        moderatedGroupMemberRemover = groups.moderatedMemberRemover
    }

    /// Metadata has its own read generation; a timeline refresh cannot supersede
    /// the group's permission read or cause a group failure to replace the chat.
    func refreshMetadata() async {
        guard isGroupConversation, !Task.isCancelled else { return }
        metadataReadGeneration &+= 1
        let generation = metadataReadGeneration
        do {
            let announcement = if let groupAnnouncementReader {
                try await groupAnnouncementReader.groupAnnouncement(in: roomID)
            } else { groupAnnouncement }
            try Task.checkCancellation()
            guard generation == metadataReadGeneration else { return }
            rolePolicyReadGeneration &+= 1
            let policyGeneration = rolePolicyReadGeneration
            let policies = if let groupRolePolicyReader {
                try await groupRolePolicyReader.groupRolePolicyState(in: roomID)
            } else { groupRolePolicyState }
            try Task.checkCancellation()
            guard generation == metadataReadGeneration else { return }
            groupAnnouncement = announcement
            if policyGeneration == rolePolicyReadGeneration { updateGroupRolePolicyState(policies) }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == metadataReadGeneration else { return }
            feedback = "无法刷新群信息，请稍后重试。"
        }
    }

    func groupPresentationKey(for target: UserID) -> V2ProfileViewLookupKey? {
        guard isGroupConversation, let room = try? RoomID(roomID) else { return nil }
        return .init(userID: target, context: .room(room))
    }

    private(set) var groupCapabilityPending:[V2GroupCapabilityPending]=[]
    func observeGroupCapabilities() async {
        guard let manager=groupMessagePinner as? any V2GroupCapabilityManaging,let room=try? RoomID(roomID) else { return }
        do {
            for try await pending in await manager.service.updates(roomID:room) {
                try Task.checkCancellation()
                let completedIDs = Set(groupCapabilityPending.compactMap { $0.work?.scheduling == .finished ? $0.work?.id : nil })
                if pending.contains(where: { value in
                    guard let work = value.work, work.scheduling == .finished,
                          !completedIDs.contains(work.id) else { return false }
                    return work.execution == .rejected || work.execution == .conflicted
                }) {
                    // A rejected authority/CAS attempt cannot keep an earlier
                    // member editing baseline valid for the next user proposal.
                    groupMemberDirectoryIsStale = true
                    groupCapabilityReconfirmation = nil
                }
                let lifecycleCompleted = pending.filter {
                    guard let work = $0.work, work.scheduling == .finished, work.execution == .committed,
                          !completedIDs.contains(work.id) else { return false }
                    return work.identity.kind == .groupOwnership || work.identity.kind == .groupDissolution
                }
                groupCapabilityPending=pending
                if lifecycleCompleted.contains(where: { $0.intent.identity.kind == .groupDissolution }) {
                    groupIsDissolved = true
                    invalidateGroupMemberDirectory()
                    groupMemberFeedback = "群聊已解散。"
                } else if !lifecycleCompleted.isEmpty {
                    groupMemberDirectoryIsStale = true
                    await loadGroupMembers(reset: true, reason: .authorizationChanged)
                    groupMemberFeedback = "群主已转让，你现在是普通成员。"
                }
            }
        } catch is CancellationError {} catch { feedback="群操作状态暂不可读，已保存的请求不会撤销。" }
    }
    func continueGroupCapability(_ pending:V2GroupCapabilityPending) async {
        guard pending.work != nil,let manager=groupMessagePinner as? any V2GroupCapabilityManaging else { return }
        do { try await manager.service.resumeConfirmation(id:pending.id) }
        catch { feedback="暂时无法核对原操作，请稍后继续。" }
    }
    struct GroupCapabilityReconfirmation:Identifiable {
        let id:UUID
        let action:V2GroupCapabilityAction
    }
    var groupCapabilityReconfirmation:GroupCapabilityReconfirmation?
    func prepareGroupCapabilityReconfirmation(_ pending:V2GroupCapabilityPending) async {
        guard pending.work==nil,pending.confirmationRequired,
            let manager=groupMessagePinner as? any V2GroupCapabilityManaging else { return }
        do {
            let action:V2GroupCapabilityAction
            switch pending.intent.action {
            case .pin(let messageID,let desired,_):
                let baseline=try await manager.service.pinBaseline(roomID:.init(roomID),messageID:messageID)
                action = .pin(messageID:messageID,isPinned:desired,expectedRoomSequence:baseline.roomSequence)
            case .announcement(let body,_):
                await refreshMetadata()
                action = .announcement(body:body,expectedRevision:groupAnnouncement?.revision ?? 0)
            case .rolePermissions(let role,let permissions,_):
                await loadGroupRolePolicies()
                guard let policy=groupRolePolicies.first(where:{$0.role==role}) else { throw V2GroupCapabilityAdmissionError.confirmationRequired }
                action = .rolePermissions(role:role,permissions:permissions,expectedRevision:policy.revision)
            case .transferOwnership(let target,_):
                await loadGroupMembers(reset: true, reason: .authorizationChanged)
                guard canManageGroupLifecycle, let revision = groupMemberRevision,
                      groupMembers.contains(where: { $0.id == target.rawValue && $0.role != "群主" }) else { throw V2GroupCapabilityAdmissionError.confirmationRequired }
                action = .transferOwnership(targetUserID: target, expectedMembershipRevision: revision)
            case .dissolve:
                await loadGroupMembers(reset: true, reason: .authorizationChanged)
                guard canManageGroupLifecycle, let revision = groupMemberRevision else { throw V2GroupCapabilityAdmissionError.confirmationRequired }
                action = .dissolve(expectedMembershipRevision: revision)
            case .memberRole(let target,let role,_):
                await loadGroupMembers(reset:true,reason:.authorizationChanged)
                guard let revision=groupMemberRevision,let member=groupMembers.first(where:{$0.id==target.rawValue}),canChangeGroupMemberRole(member) else { throw V2GroupCapabilityAdmissionError.confirmationRequired }
                action = .memberRole(targetUserID:target,role:role,expectedMembershipRevision:revision)
            }
            try Task.checkCancellation()
            groupCapabilityReconfirmation = .init(id:pending.id,action:action)
        } catch is CancellationError {} catch { feedback="无法读取确认所需的群状态，请稍后重试。" }
    }
    func confirmGroupCapability(_ proposal:GroupCapabilityReconfirmation) async {
        guard let manager=groupMessagePinner as? any V2GroupCapabilityManaging else { return }
        groupCapabilityReconfirmation=nil
        do {
            let confirmation=try manager.service.confirmationWindow(roomID:.init(roomID),action:proposal.action)
            _ = try await manager.service.reconfirmDraft(id:proposal.id,confirmation:confirmation)
            feedback="新的确认已保存，服务器仍会校验当前权限与版本。"
        } catch is CancellationError {} catch { feedback="原操作状态已变化，无法重新确认，请查看最新状态。" }
    }
    func discardGroupCapability(_ pending:V2GroupCapabilityPending) async {
        guard pending.work==nil,let manager=groupMessagePinner as? any V2GroupCapabilityManaging else { return }
        do { try await manager.service.discardDraft(id:pending.id) }
        catch { feedback="无法取消未提交的群操作。" }
    }
    struct MessageRemovalProposal {
        let id: UUID
        let baseline: V2MessageModerationBaseline
        let generation: UUID
        let expires: ContinuousClock.Instant
        let confirmedUntil: Date
        let policies: [V2ClientGroupRolePolicy]
        let membershipRevision: UInt64?
    }
    var messageRemovalProposal: MessageRemovalProposal?
    private(set) var messageRemovalPending: [V2MessageModerationPending] = []
    private var removalPolicyIsCurrent = false
    private var removalPageActive = false
    private var removalGeneration = UUID()
    private var removalIsPreparing = false
    private var removalIsSaving = false
    private var consumedRemovalProposalID: UUID?
    var canManageMessages: Bool {
        guard isGroupConversation, messageModerator != nil, !groupMemberDirectoryIsStale,
              !isLoadingGroupMembers, removalPolicyIsCurrent, groupRolePolicyState.recovery == .ready, let roleName = groupActorRole else { return false }
        let role: V2RoomMembershipRole = roleName == "群主" ? .owner : roleName == "管理员" ? .admin : .member
        return V2GroupPermissionDefaults.allows(role: role, permission: .moderateMessages,
            configured: groupRolePolicies.first(where: { $0.role == role })?.permissions)
    }
    func endMessageRemovalPage() {
        removalPageActive = false; removalGeneration = UUID(); messageRemovalProposal = nil
    }
    func messageRemovalStatus(_ pending: V2MessageModerationPending) -> String {
        if let receipt = pending.receipt {
            switch receipt.outcome {
            case .redacted, .alreadySatisfied: return "消息已被管理移除"
            case .rejected: return "原移除操作被拒绝，请重新读取状态后确认"
            case .closed: return "原移除操作已确认未执行"
            }
        }
        if pending.work.execution == .expiredUnsubmitted { return "尚未提交的移除确认已过期" }
        return pending.work.scheduling == .needsAttention ? "移除结果未知，已暂停核对" : "正在核对原消息移除操作"
    }
    func observeMessageRemoval() async {
        guard let messageModerator, isGroupConversation else { return }
        removalPageActive = true
        removalGeneration = UUID()
        let generation = removalGeneration
        defer {
            if removalGeneration == generation { removalPageActive = false; messageRemovalProposal = nil }
        }
        do {
            for try await values in await messageModerator.updates() {
                try Task.checkCancellation()
                guard removalPageActive, removalGeneration == generation else { return }
                messageRemovalPending = values.filter { $0.intent.roomID.rawValue == roomID }
            }
        } catch is CancellationError {} catch {
            if removalPageActive, removalGeneration == generation { feedback = "移除状态暂不可读，原操作仍保留。" }
        }
    }
    func prepareMessageRemoval(_ message: V2ConversationMessageItem) async {
        guard removalPageActive, !removalIsPreparing, !removalIsSaving, canManageMessages, !message.isWithdrawn, let messageModerator,
              let room = try? RoomID(roomID), let id = try? MessageID(message.id) else { return }
        removalIsPreparing = true
        defer { removalIsPreparing = false }
        messageRemovalProposal = nil
        let generation = removalGeneration
        let expires = ContinuousClock.now.advanced(by: .seconds(120))
        let end = Date().addingTimeInterval(120)
        do {
            let baseline = try await messageModerator.baseline(roomID: room, messageID: id)
            try Task.checkCancellation()
            guard removalPageActive, removalGeneration == generation, canManageMessages, expires > .now else { return }
            messageRemovalProposal = .init(id: UUID(), baseline: baseline, generation: generation, expires: expires, confirmedUntil: end,
                policies: groupRolePolicies, membershipRevision: groupMemberRevision)
        } catch is CancellationError {} catch {
            if removalPageActive, removalGeneration == generation { feedback = "无法读取当前消息管理基线。" }
        }
    }
    func confirmMessageRemoval(_ proposal: MessageRemovalProposal) async {
        guard let messageModerator, !removalIsSaving, consumedRemovalProposalID != proposal.id else { return }
        guard removalPageActive, removalGeneration == proposal.generation, canManageMessages, proposal.expires > .now,
              proposal.policies == groupRolePolicies, proposal.membershipRevision == groupMemberRevision else {
            if removalPageActive { feedback = "确认已过期或权限变化，请重新读取消息状态。" }; return
        }
        consumedRemovalProposalID = proposal.id
        removalIsSaving = true
        messageRemovalProposal = nil
        defer { removalIsSaving = false }
        let generation = removalGeneration
        do {
            _ = try await messageModerator.enqueue(baseline: proposal.baseline,
                reason: .init("moderation_removal"), confirmedUntil: proposal.confirmedUntil)
            guard !Task.isCancelled, removalPageActive, removalGeneration == generation else { return }
            feedback = "管理移除已保存，正在核对原操作。"
        } catch is CancellationError {} catch {
            if removalPageActive, removalGeneration == generation { feedback = "无法保存管理移除确认。" }
        }
    }
    func resumeMessageRemoval(_ id: UUID) async {
        guard let messageModerator, messageRemovalPending.contains(where: { $0.work.id == id && $0.work.scheduling == .needsAttention }) else { return }
        let generation = removalGeneration
        do { try await messageModerator.resume(id: id) }
        catch is CancellationError {} catch {
            if removalPageActive, removalGeneration == generation { feedback = "暂时无法继续核对原移除操作。" }
        }
    }

    var pendingPinBaseline:V2PinnedMessageBaseline?
    func pinInGroup(_ message: V2ConversationMessageItem) async {
        guard isGroupConversation,!message.isWithdrawn,messageActions.begin(message.id) else { return }
        defer { messageActions.finish(message.id) }
        guard let groupMessagePinner else { feedback="置顶消息暂不可用。";return }
        do {
            let baseline=try await groupMessagePinner.pinBaseline(roomID:roomID,messageID:message.id)
            try Task.checkCancellation()
            pendingPinBaseline=baseline
        } catch is CancellationError {} catch { feedback="无法读取最新置顶状态，请稍后重试。" }
    }
    func confirmPinInGroup(_ baseline:V2PinnedMessageBaseline) async {
        guard let groupMessagePinner else { return }
        pendingPinBaseline=nil
        do {
            _ = try await groupMessagePinner.setPinned(roomID:roomID,messageID:baseline.messageID.rawValue,isPinned:!baseline.isPinned,expectedRoomSequence:baseline.roomSequence)
            feedback="置顶确认已保存；两分钟内核对，状态变化或超时需重新确认。"
        } catch is CancellationError {} catch { feedback="无法保存置顶确认。" }
    }

    func saveGroupAnnouncement(_ body: String) async -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            feedback = "群公告不能为空。"
            return false
        }
        return await submitGroupAnnouncement(trimmed)
    }

    func clearGroupAnnouncement() async -> Bool {
        guard let groupAnnouncement, !groupAnnouncement.body.isEmpty else { return false }
        return await submitGroupAnnouncement("")
    }

    private func submitGroupAnnouncement(_ body: String) async -> Bool {
        guard isGroupConversation, !isSavingGroupAnnouncement else { return false }
        guard let groupAnnouncementManager else {
            feedback = "群公告暂不可用。"
            return false
        }
        guard body.lengthOfBytes(using: .utf8) <= V2GroupAnnouncementCommand.maximumUTF8Bytes else {
            feedback = "群公告不能超过 \(V2GroupAnnouncementCommand.maximumUTF8Bytes) 字节。"
            return false
        }
        isSavingGroupAnnouncement = true
        defer { isSavingGroupAnnouncement = false }
        do {
            switch try await groupAnnouncementManager.setAnnouncement(
                roomID: roomID,
                body: body,
                expectedRevision: groupAnnouncement?.revision ?? 0
            ) {
            case .accepted:
                feedback = body.isEmpty ? "清除公告已提交，正在同步。" : "群公告已提交，正在同步。"
                await refreshMetadata()
                return true
            case .queuedForRetry:
                feedback = "群公告确认已保存；两分钟内核对，超时需重新确认。"
                return true
            case .rejected(let code):
                feedback = "群公告被拒绝（\(code)）。"
                return false
            }
        } catch is CancellationError {
            return false
        } catch {
            feedback = "无法保存群公告。"
            return false
        }
    }

    func loadGroupRolePolicies() async {
        guard isGroupConversation, !isLoadingGroupRolePolicies else { return }
        guard let groupRolePolicyReader else {
            updateGroupRolePolicyState(.init(policies: [], recovery: .unavailable))
            feedback = "群权限策略暂不可用。"
            return
        }
        removalPolicyIsCurrent = false
        messageRemovalProposal = nil
        rolePolicyReadGeneration &+= 1
        let generation = rolePolicyReadGeneration
        isLoadingGroupRolePolicies = true
        defer { isLoadingGroupRolePolicies = false }
        do {
            let policies = try await groupRolePolicyReader.groupRolePolicyState(in: roomID)
            try Task.checkCancellation()
            guard generation == rolePolicyReadGeneration else { return }
            updateGroupRolePolicyState(policies)
            removalPolicyIsCurrent = policies.recovery == .ready
        } catch is CancellationError {
            return
        } catch {
            guard generation == rolePolicyReadGeneration else { return }
            updateGroupRolePolicyState(.init(policies: groupRolePolicies, recovery: .unavailable))
            feedback = "无法读取群权限策略。"
        }
    }

    func retryGroupRolePolicyRecovery() async {
        guard policyRecoveryAction != .requesting else { return }
        guard let groupRolePolicyReader else {
            updateGroupRolePolicyState(.init(policies: [], recovery: .unavailable))
            return
        }
        switch groupRolePolicyState.recovery {
        case .paused, .needed: break
        default: return
        }
        rolePolicyReadGeneration &+= 1
        let generation = rolePolicyReadGeneration
        policyRecoveryAction = .requesting
        do {
            let state = try await groupRolePolicyReader.retryGroupRolePolicyRecovery(in: roomID)
            try Task.checkCancellation()
            if generation == rolePolicyReadGeneration { updateGroupRolePolicyState(state) }
            policyRecoveryAction = .idle
        } catch is CancellationError {
            policyRecoveryAction = .idle
        } catch {
            policyRecoveryAction = generation == rolePolicyReadGeneration ? .failed : .idle
        }
    }

    private func updateGroupRolePolicyState(_ state: V2ClientGroupRolePolicyState) {
        if policyRecoveryAction == .failed, groupRolePolicyState.recovery != state.recovery {
            policyRecoveryAction = .idle
        }
        groupRolePolicyState = state
    }

    func saveGroupRolePolicy(_ policy: V2ClientGroupRolePolicy, permissions: Set<V2GroupPermission>) async -> Bool {
        guard !isSavingGroupRolePolicy, policy.role != .owner else { return false }
        guard let groupRolePolicyChanger else {
            feedback = "群权限策略暂不可用。"
            return false
        }
        isSavingGroupRolePolicy = true
        defer { isSavingGroupRolePolicy = false }
        do {
            switch try await groupRolePolicyChanger.setPolicy(
                roomID: roomID,
                role: policy.role,
                permissions: permissions,
                expectedRevision: policy.revision
            ) {
            case .accepted:
                feedback = "群权限策略已提交，正在同步。"
                await loadGroupRolePolicies()
                return true
            case .queuedForRetry:
                feedback = "群权限确认已保存；两分钟内核对，超时需重新确认。"
                return true
            case .rejected(let code):
                feedback = "群权限策略被拒绝（\(code)）。"
                return false
            }
        } catch is CancellationError {
            return false
        } catch {
            feedback = "无法保存群权限策略。"
            return false
        }
    }

    private func invalidateGroupMemberDirectory() {
        groupMemberDirectoryIsStale = true
        groupMembers = []
        hasEarlierGroupMembers = false
        groupMemberRevision = nil
        groupActorRole = nil
        nextGroupMemberCursor = nil
        canLoadMoreGroupMembers = false
    }

    func loadGroupMembers(reset: Bool = false, reason: GroupMemberRefreshReason = .userInitiated) async {
        guard !Task.isCancelled else { return }
        if reset {
            groupMemberDirectoryIsStale = true
            groupActorRole = nil
            if reason == .authorizationChanged { invalidateGroupMemberDirectory() }
            if isLoadingGroupMembers {
                // Keep one network owner, but never publish a response that
                // predates a requested refresh (for example a role change).
                groupMemberReloadPending = true
                return
            }
        }
        guard !isLoadingGroupMembers else { return }
        guard let groupMemberDirectory else {
            groupMemberFeedback = "成员目录暂不可用。"
            return
        }
        var cursor = reset ? nil : nextGroupMemberCursor
        if !reset, cursor == nil, !groupMembers.isEmpty { return }
        var revisionRestarts = 0
        isLoadingGroupMembers = true
        defer { isLoadingGroupMembers = false; groupMemberReloadPending = false }
        if reset || groupRolePolicyState.recovery != .ready {
            await loadGroupRolePolicies()
        }
        while !Task.isCancelled {
            if groupMemberReloadPending {
                groupMemberReloadPending = false
                cursor = nil
                revisionRestarts = 0
            }
            do {
                let page = try await groupMemberDirectory.members(in: roomID, cursor: cursor)
                try Task.checkCancellation()
                if groupMemberReloadPending { continue }
                if cursor != nil, let loadedRevision = groupMemberRevision,
                   loadedRevision != page.membershipRevision || groupActorRole != page.actorRole {
                    invalidateGroupMemberDirectory()
                    guard revisionRestarts == 0 else {
                        groupMemberFeedback = "成员目录已变化，请刷新后重试。"
                        return
                    }
                    revisionRestarts += 1
                    cursor = nil
                    continue
                }
                let known = cursor == nil ? Set<String>() : Set(groupMembers.map(\.id))
                let incoming = Set(page.members.map(\.id))
                guard incoming.count == page.members.count, known.isDisjoint(with: incoming),
                      page.nextCursor == nil || page.nextCursor != cursor
                else {
                    invalidateGroupMemberDirectory()
                    groupMemberFeedback = "成员目录返回了无效分页，请刷新后重试。"
                    return
                }
                if cursor == nil {
                    groupMembers = page.members
                    hasEarlierGroupMembers = false
                } else { groupMembers += page.members }
                if groupMembers.count > 1_000 {
                    groupMembers.removeFirst(groupMembers.count - 1_000)
                    hasEarlierGroupMembers = true
                }
                groupMemberDirectoryIsStale = false
                groupMemberRevision = page.membershipRevision
                groupActorRole = page.actorRole
                nextGroupMemberCursor = page.nextCursor
                canLoadMoreGroupMembers = page.nextCursor != nil
                groupMemberFeedback = nil
                return
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                if groupMemberReloadPending { continue }
                groupMemberDirectoryIsStale = true
                groupActorRole = nil
                if (error as? V2HTTPFailure)?.statusCode == 403
                    || (error as? V2AuthSessionError) == .sessionInvalidated
                    || (error as? V2AuthSessionError) == .unauthenticated { invalidateGroupMemberDirectory() }
                if case V2RealtimeTransportError.server(let code, _, _, _) = error {
                    if code == "REVISION_CONFLICT" {
                        invalidateGroupMemberDirectory()
                        if cursor != nil, revisionRestarts == 0 {
                            revisionRestarts += 1
                            cursor = nil
                            continue
                        }
                    } else if code == "FORBIDDEN" || code == "NOT_FOUND" {
                        invalidateGroupMemberDirectory()
                    }
                }
                groupMemberFeedback = groupMembers.isEmpty
                    ? "无法读取群成员，请检查网络后重试。"
                    : "刷新失败，显示上次成员目录；刷新成功后可继续管理。"
                return
            }
        }
    }

    var canAddGroupMembers: Bool {
        allowsGroupMemberManagement(.inviteMembers)
    }

    private func allowsGroupMemberManagement(_ permission: V2GroupPermission) -> Bool {
        guard isGroupConversation, !groupIsDissolved, !groupMemberDirectoryIsStale, !isLoadingGroupMembers,
              groupMemberRevision != nil else { return false }
        let role: V2RoomMembershipRole
        switch groupActorRole {
        case "群主": role = .owner
        case "管理员": role = .admin
        case "成员": role = .member
        default: return false
        }
        guard role == .owner || groupRolePolicyState.recovery == .ready else { return false }
        return V2GroupPermissionDefaults.allows(role: role, permission: permission,
            configured: groupRolePolicies.first(where: { $0.role == role })?.permissions)
    }

    private(set) var groupIsDissolved = false
    struct GroupLifecycleProposal: Identifiable {
        let id = UUID()
        let action: V2GroupCapabilityAction
        var isDissolution: Bool { if case .dissolve = action { true } else { false } }
    }
    var groupLifecycleProposal: GroupLifecycleProposal?
    var canManageGroupLifecycle: Bool {
        isGroupConversation && !groupIsDissolved && !groupMemberDirectoryIsStale && !isLoadingGroupMembers
            && !isChangingGroupMembership && !isApplyingGroupModeration && groupActorRole == "群主"
            && groupMemberRevision != nil && groupMessagePinner is any V2GroupCapabilityManaging
    }
    func prepareOwnershipTransfer(to member: V2GroupMemberItem) {
        guard canManageGroupLifecycle, member.id != userID, member.role != "群主",
              groupMembers.contains(member), let revision = groupMemberRevision,
              let target = try? UserID(member.id) else { return }
        groupLifecycleProposal = .init(action: .transferOwnership(targetUserID: target, expectedMembershipRevision: revision))
    }
    func prepareGroupDissolution() {
        guard canManageGroupLifecycle, let revision = groupMemberRevision else { return }
        groupLifecycleProposal = .init(action: .dissolve(expectedMembershipRevision: revision))
    }
    func confirmGroupLifecycle(_ proposal: GroupLifecycleProposal) async {
        groupLifecycleProposal = nil
        guard canManageGroupLifecycle, proposal.action.observedRevision == groupMemberRevision,
              let manager = groupMessagePinner as? any V2GroupCapabilityManaging else {
            groupMemberFeedback = "群状态已变化，请刷新后重新确认。"; return
        }
        isChangingGroupMembership = true
        defer { isChangingGroupMembership = false }
        do {
            let confirmation = try manager.service.confirmationWindow(roomID: .init(roomID), action: proposal.action)
            _ = try await manager.service.enqueue(confirmation: confirmation)
            groupMemberFeedback = proposal.isDissolution ? "解散确认已保存，正在核对结果。" : "转让确认已保存，正在核对结果。"
        } catch is CancellationError { return }
        catch { groupMemberFeedback = "无法保存确认，请先核对已有群操作的结果。" }
    }

    var canLeaveGroup: Bool {
        !groupIsDissolved && !groupMemberDirectoryIsStale && !isLoadingGroupMembers && groupMemberRevision != nil
            && (groupActorRole == "成员" || groupActorRole == "管理员")
    }

    private func canConfirmMembership(target: String, action: V2RoomMembershipAction) -> Bool {
        if action == .add { return canAddGroupMembers }
        if target == userID { return canLeaveGroup }
        return groupMembers.first(where: { $0.id == target }).map(canRemoveGroupMember) ?? false
    }

    @discardableResult func leaveGroup() async -> Bool {
        await changeGroupMembership(targetUserID: userID, action: .remove)
    }

    func canRemoveGroupMember(_ member: V2GroupMemberItem) -> Bool {
        member.id != userID && member.role != "群主" && allowsGroupMemberManagement(.removeMembers)
    }

    func canChangeGroupMemberRole(_ member: V2GroupMemberItem) -> Bool {
        member.id != userID && member.role != "群主" && allowsGroupMemberManagement(.changeMemberRoles)
    }

    func changeGroupMemberRole(_ member: V2GroupMemberItem, to role: V2RoomMembershipRole) async {
        guard canChangeGroupMemberRole(member),
              let expectedMembershipRevision = groupMemberRevision,
              !isChangingGroupMembership,
              let groupMemberRoleChanger
        else { return }
        let currentRole: V2RoomMembershipRole = member.role == "管理员" ? .admin : .member
        guard currentRole != role else { return }
        isChangingGroupMembership = true
        defer { isChangingGroupMembership = false }
        do {
            switch try await groupMemberRoleChanger.setRole(
                roomID: roomID,
                userID: member.id,
                role: role,
                expectedMembershipRevision: expectedMembershipRevision
            ) {
            case .accepted:
                groupMemberFeedback = "成员角色已提交，正在同步。"
                await loadGroupMembers(reset: true, reason: .authorizationChanged)
            case .queuedForRetry:
                groupMemberFeedback = "角色确认已保存；两分钟内核对，超时需重新确认。"
            case .rejected(let code):
                groupMemberFeedback = "成员角色变更被拒绝（\(code)）。"
            }
        } catch is CancellationError {
            return
        } catch {
            groupMemberFeedback = "无法保存成员角色变更。"
        }
    }

    /// 禁言一名群成员。
    ///
    /// 审核保留独立的持久化命令与审计轨迹，而不复用普通成员移除；
    /// 权限与目标资格仍由服务端在受理命令时裁决。
    ///
    /// - Parameters:
    ///   - member: 目标成员。
    ///   - duration: 禁言时长秒数。
    private(set) var memberAdministrationPending:[V2MemberAdministrationPending]=[]
    func observeMemberAdministration() async {
        guard let manager=groupMemberMuter as? any V2MemberAdministrationManaging,let room=try? RoomID(roomID) else { return }
        do {
            for try await pending in await manager.administrationUpdates(roomID:room) {
                try Task.checkCancellation()
                let completedIDs = Set(memberAdministrationPending.compactMap { $0.work?.scheduling == .finished ? $0.work?.id : nil })
                if pending.contains(where: { value in
                    guard let work = value.work, work.scheduling == .finished,
                          !completedIDs.contains(work.id) else { return false }
                    return work.execution == .rejected || work.execution == .conflicted
                }) {
                    // A rejected authority/CAS attempt cannot keep an earlier
                    // member editing baseline valid for the next user proposal.
                    groupMemberDirectoryIsStale = true
                }
                memberAdministrationPending=pending
            }
        } catch is CancellationError {} catch { groupMemberFeedback="管理操作状态暂不可读，已保存的请求不会撤销。" }
    }
    func continueMemberAdministration(_ pending:V2MemberAdministrationPending) async {
        guard let manager=groupMemberMuter as? any V2MemberAdministrationManaging else { return }
        do {
            if pending.work != nil { try await manager.resumeAdministration(id:pending.id) }
            else {
                guard let revision=groupMemberRevision,let member=groupMembers.first(where:{$0.id==pending.intent.targetUserID.rawValue}),canRemoveGroupMember(member) else {
                    groupMemberFeedback="请先刷新成员与管理权限，再重新确认。";return
                }
                try await manager.reconfirmAdministration(id:pending.id,revision:revision)
            }
        } catch { groupMemberFeedback="无法继续；请刷新成员状态，或取消未提交的确认。" }
    }
    func discardMemberAdministration(_ pending:V2MemberAdministrationPending) async {
        guard pending.work==nil,let manager=groupMemberMuter as? any V2MemberAdministrationManaging else { return }
        do { try await manager.discardAdministration(id:pending.id) } catch { groupMemberFeedback="无法取消确认。" }
    }

    func muteGroupMember(_ member: V2GroupMemberItem, for duration: TimeInterval = 60 * 60) async {
        guard !isLoadingGroupMembers, !isChangingGroupMembership, !isApplyingGroupModeration,
              canRemoveGroupMember(member)
        else { return }
        guard duration > 0, let revision=groupMemberRevision, let groupMemberMuter else {
            groupMemberFeedback = "禁言暂不可用。"
            return
        }
        isApplyingGroupModeration = true
        defer { isApplyingGroupModeration = false }
        do {
            let outcome = try await groupMemberMuter.muteMember(
                roomID: roomID,
                targetUserID: member.id,
                muteUntil: Date().addingTimeInterval(duration),
                reasonCode: try .init("ADMIN_ACTION"),
                expectedMembershipRevision:revision
            )
            try Task.checkCancellation()
            switch outcome {
            case .accepted:
                groupMemberFeedback = "禁言已提交，正在同步。"
            case .queuedForRetry:
                groupMemberFeedback = "禁言确认已保存；将在两分钟确认窗口内核对权限，超时需重新确认。"
            case .rejected:
                groupMemberFeedback = "无法完成群管理操作。"
            }
        } catch is CancellationError {
            return
        } catch {
            groupMemberFeedback = "无法保存禁言请求。"
        }
    }

    func removeGroupMemberByModerator(_ member: V2GroupMemberItem) async {
        guard !isLoadingGroupMembers, !isChangingGroupMembership, !isApplyingGroupModeration,
              canRemoveGroupMember(member)
        else { return }
        guard let revision=groupMemberRevision, let moderatedGroupMemberRemover else {
            groupMemberFeedback = "管理员移除暂不可用。"
            return
        }
        isApplyingGroupModeration = true
        defer { isApplyingGroupModeration = false }
        do {
            let outcome = try await moderatedGroupMemberRemover.removeMemberByModerator(
                roomID: roomID,
                targetUserID: member.id,
                reasonCode: try .init("ADMIN_ACTION"),
                expectedMembershipRevision:revision
            )
            try Task.checkCancellation()
            switch outcome {
            case .accepted:
                groupMemberFeedback = "管理员移除已提交，正在同步。"
                await loadGroupMembers(reset: true, reason: .authorizationChanged)
            case .queuedForRetry:
                groupMemberFeedback = "移除确认已保存；将在两分钟确认窗口内核对权限，超时需重新确认。"
            case .rejected:
                groupMemberFeedback = "无法完成群管理操作。"
            }
        } catch is CancellationError {
            return
        } catch {
            groupMemberFeedback = "无法保存管理员移除请求。"
        }
    }

    private(set) var membershipPending:[V2MembershipPending]=[]
    func observeMembership() async {
        guard let manager=groupMembershipChanger as? any V2MembershipManaging,let room=try? RoomID(roomID) else { return }
        var observed:Set<UUID>=[]
        do {
            for try await pending in await manager.membershipUpdates(roomID:room) {
                try Task.checkCancellation();membershipPending=pending
                let committed=Set(pending.filter{$0.work?.execution == .committed}.map(\.id))
                let observedBefore = observed
                let changed = !committed.subtracting(observedBefore).isEmpty
                observed=committed
                if changed {
                    let selfExitCommitted = pending.contains {
                        $0.work?.execution == .committed && $0.intent.action == .remove
                            && $0.intent.targetUserID.rawValue == userID
                            && !observedBefore.contains($0.id)
                    }
                    if selfExitCommitted {
                        invalidateGroupMemberDirectory()
                        groupMemberFeedback = "已退出群聊。"
                    } else { await loadGroupMembers(reset:true,reason:.authorizationChanged) }
                }
            }
        } catch is CancellationError {} catch { groupMemberFeedback="成员操作状态暂不可读，已保存的请求不会撤销。" }
    }
    func continueMembership(_ pending:V2MembershipPending) async {
        guard let changer=groupMembershipChanger,let manager=changer as? any V2MembershipManaging else { return }
        do {
            if pending.work != nil { try await manager.resumeMembership(id:pending.id) }
            else {
                guard !groupMemberDirectoryIsStale,let revision=groupMemberRevision,
                    canConfirmMembership(target: pending.intent.targetUserID.rawValue, action: pending.intent.action)
                else { groupMemberFeedback="请先刷新成员与权限，再重新确认此操作。";return }
                let confirmation=try changer.membershipConfirmation(roomID:roomID,action:pending.intent.action,expectedMembershipRevision:revision)
                try await manager.reconfirmMembership(id:pending.id,confirmation:confirmation)
            }
        } catch { groupMemberFeedback="无法继续成员操作；请刷新权限，或取消未提交的确认。" }
    }
    func discardMembership(_ pending:V2MembershipPending) async {
        guard pending.work==nil,let manager=groupMembershipChanger as? any V2MembershipManaging else { return }
        do { try await manager.discardMembership(id:pending.id) } catch { groupMemberFeedback="无法取消成员确认。" }
    }

    @discardableResult func changeGroupMembership(targetUserID: String, action: V2RoomMembershipAction) async -> Bool {
        guard !isLoadingGroupMembers, !isChangingGroupMembership, !isApplyingGroupModeration else {
            return false
        }
        let input = targetUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            groupMemberFeedback = action == .add ? "请输入成员公开 ID。" : "请输入成员。"
            return false
        }
        guard !groupMemberDirectoryIsStale, let revision = groupMemberRevision else {
            groupMemberFeedback = "请先刷新成员目录。"
            return false
        }
        guard let groupMembershipChanger else {
            groupMemberFeedback = "成员变更暂不可用。"
            return false
        }
        guard canConfirmMembership(target: input, action: action) else {
            groupMemberFeedback="当前成员权限不可用，请刷新后确认。";return false
        }
        isChangingGroupMembership = true
        defer { isChangingGroupMembership = false }
        do {
            let confirmation=try groupMembershipChanger.membershipConfirmation(roomID:roomID,action:action,expectedMembershipRevision:revision)
            let target: String
            if action == .add {
                guard let publicIdentityResolver else {
                    groupMemberFeedback = "身份目录暂不可用，无法解析成员公开 ID。"
                    return false
                }
                target = try await V2HTTPRequestDeadline.run(until:min(confirmation.deadline,.now.advanced(by:.seconds(15))),service:"accountAPI") { try await publicIdentityResolver.resolve(handle:input).userID.rawValue }
                try Task.checkCancellation()
            } else {
                target = input
            }
            guard !groupMemberDirectoryIsStale,groupMemberRevision==revision else { groupMemberFeedback="成员版本已变化，请刷新后重新确认。";return false }
            let outcome = try await groupMembershipChanger.changeMembership(targetUserID:target,confirmation:confirmation)
            try Task.checkCancellation()
            switch outcome {
            case .accepted:
                if action == .remove && target == userID {
                    invalidateGroupMemberDirectory()
                    groupMemberFeedback = "已退出群聊。"
                } else {
                    groupMemberFeedback = nil
                    await loadGroupMembers(reset: true, reason: .authorizationChanged)
                }
            case .queuedForRetry:
                groupMemberFeedback = action == .remove && target == userID
                    ? "退出确认已保存；正在核对原操作结果，尚未确认退出。"
                    : "成员确认已保存；两分钟窗口内核对权限，超时需重新确认。"
            case .rejected(let code):
                groupMemberFeedback = "成员变更被拒绝（\(code)），请刷新后重试。"
                return false
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            groupMemberFeedback = "无法保存成员变更，当前输入已保留。"
            return false
        }
    }
}
