import Foundation
import IMV2ClientKit
import IMV2Core
import Observation
import SwiftUI

protocol V2StrangerMessagePreferenceReading: Sendable {
    func strangerMessagePreference() async throws -> Bool?
}

protocol V2UserAddPreferenceReading: Sendable {
    func userAddPreference() async throws -> Bool?
}
protocol V2ReadReceiptPreferenceReading: Sendable { func readReceiptPreference() async throws -> V2ReadReceiptPreferences? }

@MainActor
@Observable
final class V2UserBlockSettingsStore {
    private let localStore: GRDBV2LocalSyncStore?
    private let projectionChangeNotifier: V2ProjectionChangeNotifier?
    private(set) var blockedUsers: [V2ClientUserBlockProjection] = []
    private let resolver: any V2PublicIdentityResolving
    private(set) var socialPending:[V2SocialOperationPending]=[]
    private(set) var socialProposals:[V2SocialOperationProposal]=[]
    var socialConfirmation:V2SocialConfirmationProposal?
    private let changer: any V2UserBlockChanging
    private let currentUserID: UserID

    private(set) var isChanging = false
    private(set) var feedback: String?

    init(
        resolver: any V2PublicIdentityResolving,
        changer: any V2UserBlockChanging,
        currentUserID: UserID,
        localStore: GRDBV2LocalSyncStore? = nil,
        projectionChangeNotifier: V2ProjectionChangeNotifier? = nil
    ) {
        self.localStore = localStore
        self.projectionChangeNotifier = projectionChangeNotifier
        self.resolver = resolver
        self.changer = changer
        self.currentUserID = currentUserID
    }

    func observeBlockedUsers() async {
        await loadBlockedUsers()
        guard let projectionChangeNotifier else { return }
        await V2ProjectionRefreshObserver.run(await projectionChangeNotifier.updates(scopes: .contacts)) {
            await self.loadBlockedUsers()
        }
    }
    func loadBlockedUsers() async {
        guard let localStore else { return }
        do { blockedUsers = try await localStore.blocks() }
        catch { feedback = "暂时无法读取已屏蔽用户。" }
    }
    func unblockKnownUser(_ user: UserID) async {
        guard !isChanging, let manager = changer as? any V2SocialOperationManaging else { return }
        isChanging = true
        defer { isChanging = false }
        do {
            let baseline = try await manager.socialBaseline(target: user)
            guard baseline.isBlocked else { await loadBlockedUsers(); return }
            try await manager.enqueueSocial(action: .userBlock(.unblock), snapshot: baseline)
            feedback = "正在解除屏蔽…"
        } catch { feedback = "无法解除屏蔽，请重试。" }
    }

    func observeSocialProposals() async {
        guard let manager=changer as? any V2SocialOperationManaging else { return }
        do { for try await values in await manager.socialProposals() { guard !Task.isCancelled else {return};socialProposals=values } } catch is CancellationError {} catch {feedback="保存的联系人提案暂不可读。"}
    }
    func prepareSocialProposal(_ proposal:V2SocialOperationProposal) async {
        guard let manager=changer as? any V2SocialOperationManaging else {return}
        do { let baseline=try await manager.socialBaseline(target:proposal.targetUserID);socialConfirmation = .init(snapshot:baseline,action:proposal.action,proposalID:proposal.id) } catch {feedback="提案已保留，读取权威基线后才能确认。"}
    }
    func discardSocialProposal(_ id:UUID) async {
        guard let manager=changer as? any V2SocialOperationManaging else {return}
        do {try await manager.discardSocialProposal(id:id)} catch {feedback="无法取消提案。"}
    }
    func observeSocialOperations() async {
        guard let manager=changer as? any V2SocialOperationManaging else { return }
        do { for try await values in await manager.socialUpdates() { guard !Task.isCancelled else { return };socialPending=values.filter { $0.work.identity.kind == .userBlock }; await loadBlockedUsers() } }
        catch is CancellationError {} catch { feedback="屏蔽操作状态暂时无法读取。" }
    }
    func confirmSocialOperation() async {
        guard let proposal=socialConfirmation,let manager=changer as? any V2SocialOperationManaging else { return };socialConfirmation=nil
        guard proposal.expiresAt > .now else { feedback="确认基线已过期，请重新读取后确认。";return }
        do { if let id=proposal.proposalID {try await manager.confirmSocialProposal(id:id,snapshot:proposal.snapshot)} else {try await manager.enqueueSocial(action:proposal.action,snapshot:proposal.snapshot)};feedback="原屏蔽操作已保存，正在核对。" }
        catch { feedback="无法保存屏蔽操作，请重新读取后确认。" }
    }
    func resumeSocialOperation(_ id:UUID) async {
        guard let manager=changer as? any V2SocialOperationManaging else { return }
        do { try await manager.resumeSocialConfirmation(workID:id) } catch { feedback="无法继续核对原屏蔽操作。" }
    }
    func changeBlock(handle: String, action: V2UserBlockAction) async {
        guard !isChanging else { return }
        let trimmedHandle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHandle.isEmpty else {
            feedback = "请输入要管理的公开 ID。"
            return
        }
        isChanging = true
        feedback = nil
        defer { isChanging = false }
        do {
            let confirmationDeadline=ContinuousClock.now.advanced(by:.seconds(120))
            let identity = try await V2HTTPRequestDeadline.run(until:min(confirmationDeadline,.now.advanced(by:.seconds(15))),service:"accountAPI") { try await self.resolver.resolve(handle:trimmedHandle) }
            try Task.checkCancellation()
            guard identity.userID != currentUserID else {
                feedback = "不能屏蔽自己。"
                return
            }
            if let manager=changer as? any V2SocialOperationManaging {
                let id=try await manager.saveSocialProposal(action:.userBlock(action),target:identity.userID)
                let baseline=try await manager.socialBaseline(target:identity.userID)
                socialConfirmation = .init(snapshot:baseline,action:.userBlock(action),proposalID:id)
                return
            }
            let outcome = try await V2HTTPRequestDeadline.$current.withValue(confirmationDeadline) {
                try await self.changer.changeBlock(targetUserID:identity.userID.rawValue,action:action)
            }
            try Task.checkCancellation()
            switch outcome {
            case .accepted:
                feedback = action == .block ? "已屏蔽该用户。" : "已解除屏蔽。"
            case .queuedForRetry:
                feedback = action == .block
                    ? "屏蔽请求已安全保存，连接恢复后会同步。"
                    : "解除屏蔽请求已安全保存，连接恢复后会同步。"
            case .rejected:
                // Do not disclose whether a target exists, has blocked this
                // user, or another privacy policy caused the rejection.
                feedback = "无法完成此用户设置。"
            }
        } catch is CancellationError {
            return
        } catch {
            feedback = "无法解析公开 ID 或保存设置，请稍后重试。"
        }
    }
}

actor V2GRDBStrangerMessagePreferenceDataSource: V2StrangerMessagePreferenceReading {
    private let localStore: GRDBV2LocalSyncStore

    init(localStore: GRDBV2LocalSyncStore) {
        self.localStore = localStore
    }

    func strangerMessagePreference() async throws -> Bool? {
        if let snapshot=try await localStore.cachedAccountPreference(kind:.strangerMessagePreference),case .strangerMessage(let permission)=snapshot.value { return permission == .allow }
        return try await localStore.strangerMessagePreference()?.allowsStrangerMessages
    }
}

actor V2GRDBUserAddPreferenceDataSource: V2UserAddPreferenceReading {
    private let localStore: GRDBV2LocalSyncStore

    init(localStore: GRDBV2LocalSyncStore) { self.localStore = localStore }

    func userAddPreference() async throws -> Bool? {
        if let snapshot=try await localStore.cachedAccountPreference(kind:.userAddPreference),case .userAdd(let permission)=snapshot.value {return permission == .allow}
        return try await localStore.userAddPreference()?.allowsBeingAdded
    }
}
actor V2GRDBReadReceiptPreferenceDataSource: V2ReadReceiptPreferenceReading {
    private let localStore: GRDBV2LocalSyncStore
    init(localStore: GRDBV2LocalSyncStore) { self.localStore = localStore }
    func readReceiptPreference() async throws -> V2ReadReceiptPreferences? {
        if let snapshot=try await localStore.cachedAccountPreference(kind:.readReceiptPreference),case .readReceipt(let direct,let group)=snapshot.value {return .init(allowsDirectReadReceipts:direct,allowsGroupReadReceipts:group,updatedAt:Date())}
        return try await localStore.readReceiptPreference()
    }
}

@MainActor
@Observable
final class V2PrivacySettingsStore {
    enum State: Equatable {
        case loading
        case loaded
        case failed
    }

    private let reader: any V2StrangerMessagePreferenceReading
    private let updater: any V2StrangerMessagePreferenceUpdating
    private let userAddReader: (any V2UserAddPreferenceReading)?
    private let userAddUpdater: (any V2UserAddPreferenceUpdating)?
    private let readReceiptUpdater: (any V2ReadReceiptPreferenceUpdating)?
    private let readReceiptReader: (any V2ReadReceiptPreferenceReading)?
    private let liveActivityUpdater: (any V2LiveActivityPreferenceUpdating)?
    private let liveActivityReader: (any V2LiveActivityPreferenceReading)?
    private let projectionChangeNotifier: V2ProjectionChangeNotifier?
    private(set) var state: State = .loading
    private var hasLoadedPreferences = false
    private(set) var allowsStrangerMessages = true
    private(set) var allowsBeingAdded = true
    private(set) var allowsDirectReadReceipts = true
    private(set) var allowsGroupReadReceipts = true
    private(set) var allowsOnlinePresence = true
    private(set) var allowsTypingIndicators = true
    private(set) var isSaving = false
    private(set) var feedback: String?
    private(set) var accountPreferenceDrafts:[V2AccountPreferenceDraft]=[]
    private(set) var accountPreferencePending:[V2AccountPreferencePending]=[]
    private var refreshGeneration = 0

    private struct ConfirmedPreferences {
        var strangerMessages = true
        var beingAdded = true
        var directReadReceipts = true
        var groupReadReceipts = true
        var onlinePresence = true
        var typingIndicators = true
    }
    private var confirmedPreferences = ConfirmedPreferences()
    private var authoritySnapshots: [V2OperationKind: V2AccountPreferenceSnapshot] = [:]

    private func loadCachedAuthority(_ service: V2AccountPreferenceService) async throws {
        // Read the receipt-backed cache, not old command values: another device
        // may already have published a newer revision of the same preference.
        let kinds: [V2OperationKind] = [.strangerMessagePreference, .userAddPreference,
                                       .readReceiptPreference, .liveActivityPreference]
        var snapshots: [V2AccountPreferenceSnapshot] = []
        for kind in kinds {
            if let snapshot = try await service.cachedBaseline(kind: kind) { snapshots.append(snapshot) }
        }
        try Task.checkCancellation()
        for snapshot in snapshots {
            if let current = authoritySnapshots[snapshot.value.kind], current.revision > snapshot.revision { continue }
            authoritySnapshots[snapshot.value.kind] = snapshot
        }
    }

    private func applyPreferenceOverlay() {
        allowsStrangerMessages = confirmedPreferences.strangerMessages
        allowsBeingAdded = confirmedPreferences.beingAdded
        allowsDirectReadReceipts = confirmedPreferences.directReadReceipts
        allowsGroupReadReceipts = confirmedPreferences.groupReadReceipts
        allowsOnlinePresence = confirmedPreferences.onlinePresence
        allowsTypingIndicators = confirmedPreferences.typingIndicators
        for snapshot in authoritySnapshots.values {
            switch snapshot.value {
            case .strangerMessage(let value): allowsStrangerMessages = value == .allow
            case .userAdd(let value): allowsBeingAdded = value == .allow
            case .readReceipt(let direct, let group): allowsDirectReadReceipts = direct; allowsGroupReadReceipts = group
            case .liveActivity(let online, let typing): allowsOnlinePresence = online; allowsTypingIndicators = typing
            }
        }
        var seen = Set<V2OperationKind>()
        for item in accountPreferencePending.sorted(by: { $0.work.localSequence > $1.work.localSequence }) {
            guard !item.work.execution.isTerminal, seen.insert(item.command.value.kind).inserted else { continue }
            switch item.command.value {
            case .strangerMessage(.deny): allowsStrangerMessages = false
            case .userAdd(.deny): allowsBeingAdded = false
            case .readReceipt(let direct, let group):
                if !direct { allowsDirectReadReceipts = false }; if !group { allowsGroupReadReceipts = false }
            case .liveActivity(let online, let typing):
                if !online { allowsOnlinePresence = false }; if !typing { allowsTypingIndicators = false }
            default: break
            }
        }
        for draft in accountPreferenceDrafts {
            switch draft.patch {
            case .strangerMessage(.deny):allowsStrangerMessages=false
            case .userAdd(.deny):allowsBeingAdded=false
            case .readReceipt(let direct,let group):if direct==false {allowsDirectReadReceipts=false};if group==false {allowsGroupReadReceipts=false}
            case .liveActivity(let online,let typing):if online==false {allowsOnlinePresence=false};if typing==false {allowsTypingIndicators=false}
            default:break
            }
        }
    }
    func observeAccountPreferenceOperations() async {
        guard let manager=updater as? any V2AccountPreferenceManaging else { return }
        do {
            for try await values in await manager.accountPreferenceService.updates() {
                try Task.checkCancellation()
                try await loadCachedAuthority(manager.accountPreferenceService)
                accountPreferencePending = values
                applyPreferenceOverlay()
            }
        }
        catch is CancellationError {} catch { feedback="设置操作状态暂时无法读取，已保存的请求不会撤销。" }
    }
    func observeAccountPreferenceDrafts() async {
        guard let manager=updater as? any V2AccountPreferenceManaging else { return }
        do { for try await values in await manager.accountPreferenceService.draftUpdates() { guard !Task.isCancelled else { return };accountPreferenceDrafts=values;applyPreferenceOverlay() } }
        catch is CancellationError {} catch { feedback="离线设置提案暂时无法读取。" }
    }
    func discardAccountPreferenceDraft(_ id:UUID) async {
        guard let manager=updater as? any V2AccountPreferenceManaging else { return }
        do { try await manager.accountPreferenceService.discardDraft(id:id) } catch { feedback="无法取消未提交的设置提案。" }
    }
    func reconfirmAccountPreferenceDraft(_ id:UUID) async {
        guard let manager=updater as? any V2AccountPreferenceManaging else { return }
        do { try await manager.accountPreferenceService.reconfirmDraft(id:id) } catch { feedback="无法重新确认设置提案。" }
    }
    func resumeAccountPreference(_ id:UUID) async {
        guard let manager=updater as? any V2AccountPreferenceManaging else { return }
        do { try await manager.accountPreferenceService.resumeConfirmation(workID:id) } catch { feedback="无法继续核对原设置操作。" }
    }
    init(
        reader: any V2StrangerMessagePreferenceReading,
        updater: any V2StrangerMessagePreferenceUpdating,
        userAddReader: (any V2UserAddPreferenceReading)? = nil,
        userAddUpdater: (any V2UserAddPreferenceUpdating)? = nil,
        readReceiptUpdater: (any V2ReadReceiptPreferenceUpdating)? = nil,
        readReceiptReader: (any V2ReadReceiptPreferenceReading)? = nil,
        liveActivityUpdater: (any V2LiveActivityPreferenceUpdating)? = nil,
        liveActivityReader: (any V2LiveActivityPreferenceReading)? = nil,
        projectionChangeNotifier: V2ProjectionChangeNotifier? = nil
    ) {
        self.reader = reader
        self.updater = updater
        self.userAddReader = userAddReader
        self.userAddUpdater = userAddUpdater
        self.readReceiptUpdater = readReceiptUpdater
        self.readReceiptReader = readReceiptReader
        self.liveActivityUpdater = liveActivityUpdater
        self.liveActivityReader = liveActivityReader
        self.projectionChangeNotifier = projectionChangeNotifier
    }

    func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        if !hasLoadedPreferences { state = .loading }
        do {
            // The server defaults to allow. Absence only means this device has
            // not yet received a projection, not that the preference is deny.
            let refreshedPreference = try await reader.strangerMessagePreference() ?? true
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            let refreshedUserAddPreference = try await userAddReader?.userAddPreference() ?? true
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            let receiptPreference = try await readReceiptReader?.readReceiptPreference()
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            let liveActivityPreference = try await liveActivityReader?.preferences()
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            if let manager = updater as? any V2AccountPreferenceManaging {
                // Merge current local projection revisions before publishing or
                // waiting for the network; an old in-memory receipt must not win.
                try await loadCachedAuthority(manager.accountPreferenceService)
                guard generation == refreshGeneration else { return }
            }
            confirmedPreferences = .init(
                strangerMessages: refreshedPreference, beingAdded: refreshedUserAddPreference,
                directReadReceipts: receiptPreference?.allowsDirectReadReceipts ?? true,
                groupReadReceipts: receiptPreference?.allowsGroupReadReceipts ?? true,
                onlinePresence: liveActivityPreference?.allowsOnlinePresence ?? true,
                typingIndicators: liveActivityPreference?.allowsTypingIndicators ?? true)
            hasLoadedPreferences = true
            state = .loaded
            applyPreferenceOverlay()
            // Publish local settings before waiting for an online authority refresh.
            if let manager = updater as? any V2AccountPreferenceManaging {
                await manager.accountPreferenceService.refreshAuthority()
                try Task.checkCancellation()
                guard generation == refreshGeneration else { return }
                try await loadCachedAuthority(manager.accountPreferenceService)
                guard generation == refreshGeneration else { return }
                applyPreferenceOverlay()
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            if hasLoadedPreferences {
                state = .loaded
                feedback = "无法刷新设置，保留上次读取的内容。"
            } else {
                state = .failed
            }
        }
    }

    /// 观察投影变更。
    ///
    /// 设置与会话、联系人数据一样都是持久化用户投影。
    /// 当另一台安装改变了偏好时，已展示的设置页应当即时更新，
    /// 而不是要求用户关闭后重新打开。
    func observeProjectionChanges() async {
        guard let projectionChangeNotifier else { return }
        await V2ProjectionRefreshObserver.run(await projectionChangeNotifier.updates(scopes: .privacy)) { [self] in
            await refresh()
        }
    }

    func setAllowsStrangerMessages(_ desiredValue: Bool) async {
        guard !isSaving, desiredValue != allowsStrangerMessages else { return }
        isSaving = true
        feedback = nil
        defer { isSaving = false }
        do {
            let outcome = try await updater.update(allowsStrangerMessages: desiredValue)
            try Task.checkCancellation()
            switch outcome {
            case .accepted:
                confirmedPreferences.strangerMessages = desiredValue
                applyPreferenceOverlay()
                feedback = "已更新消息接收设置。"
            case .queuedForRetry:
                if !desiredValue { allowsStrangerMessages = false }
                feedback = "设置已安全保存，连接恢复后会同步。"
            case .rejected(let code):
                feedback = "设置被拒绝（\(code)）。"
            }
        } catch is CancellationError {
            return
        } catch {
            feedback = "无法保存设置，请稍后重试。"
        }
    }

    func setAllowsBeingAdded(_ desiredValue: Bool) async {
        guard !isSaving, desiredValue != allowsBeingAdded, let userAddUpdater else { return }
        isSaving = true
        feedback = nil
        defer { isSaving = false }
        do {
            let outcome = try await userAddUpdater.update(allowsBeingAdded: desiredValue)
            try Task.checkCancellation()
            switch outcome {
            case .accepted:
                confirmedPreferences.beingAdded = desiredValue
                applyPreferenceOverlay()
                feedback = "已更新添加权限。"
            case .queuedForRetry:
                if !desiredValue { allowsBeingAdded = false }
                feedback = "设置已安全保存，连接恢复后会同步。"
            case .rejected:
                feedback = "无法保存设置，请稍后重试。"
            }
        } catch is CancellationError {
            return
        } catch {
            feedback = "无法保存设置，请稍后重试。"
        }
    }

    func setReadReceiptPermission(direct: Bool? = nil, group: Bool? = nil) async {
        let desiredDirect = direct ?? allowsDirectReadReceipts
        let desiredGroup = group ?? allowsGroupReadReceipts
        guard !isSaving, (desiredDirect != allowsDirectReadReceipts || desiredGroup != allowsGroupReadReceipts), let readReceiptUpdater else { return }
        isSaving = true; feedback = nil; defer { isSaving = false }
        do {
            let outcome:V2ReadReceiptPreferenceUpdateOutcome
            if let manager=readReceiptUpdater as? any V2AccountPreferenceManaging {
                _ = try await manager.accountPreferenceService.enqueue(patch:.readReceipt(direct:direct,group:group));outcome = .queuedForRetry
            } else { outcome=try await readReceiptUpdater.update(allowsDirectReadReceipts:desiredDirect,allowsGroupReadReceipts:desiredGroup) }
            try Task.checkCancellation()
            switch outcome {
            case .accepted:
                confirmedPreferences.directReadReceipts = desiredDirect
                confirmedPreferences.groupReadReceipts = desiredGroup
                applyPreferenceOverlay()
                feedback = "已更新已读回执设置。"
            case .queuedForRetry:
                if !desiredDirect { allowsDirectReadReceipts=false };if !desiredGroup { allowsGroupReadReceipts=false }
                feedback = "已保存已读回执设置，连接恢复后会同步。"
            case .rejected:
                feedback = "无法保存设置，请稍后重试。"
            }
        } catch is CancellationError { return }
        catch { feedback = "连接恢复后请重试保存已读回执设置。" }
    }

    func setLiveActivityPermission(online: Bool? = nil, typing: Bool? = nil) async {
        let desiredOnline = online ?? allowsOnlinePresence
        let desiredTyping = typing ?? allowsTypingIndicators
        guard !isSaving,
              desiredOnline != allowsOnlinePresence || desiredTyping != allowsTypingIndicators,
              let liveActivityUpdater
        else { return }

        isSaving = true
        feedback = nil
        defer { isSaving = false }
        do {
            let outcome:V2LiveActivityPreferenceUpdateOutcome
            if let manager=liveActivityUpdater as? any V2AccountPreferenceManaging {
                _ = try await manager.accountPreferenceService.enqueue(patch:.liveActivity(online:online,typing:typing));outcome = .queuedForRetry
            } else { outcome=try await liveActivityUpdater.update(allowsOnlinePresence:desiredOnline,allowsTypingIndicators:desiredTyping) }
            // A view can be dismissed while the authenticated update is in
            // flight. Do not let a late response overwrite fresher projected
            // settings or a new editing intent after its task was cancelled.
            try Task.checkCancellation()
            switch outcome {
            case .accepted:
                confirmedPreferences.onlinePresence = desiredOnline
                confirmedPreferences.typingIndicators = desiredTyping
                applyPreferenceOverlay()
                feedback = "已更新在线与输入状态设置。"
            case .queuedForRetry:
                if !desiredOnline { allowsOnlinePresence=false };if !desiredTyping { allowsTypingIndicators=false }
                feedback = "在线与输入状态设置已保存，正在核对原操作。"
            case .rejected(let code):
                feedback = "设置被拒绝（\(code)）。"
            }
        } catch is CancellationError {
            return
        } catch {
            feedback = "无法保存在线与输入状态设置，请稍后重试。"
        }
    }
}

struct V2PrivacySettingsView: View {
    @Bindable var store: V2PrivacySettingsStore
    let pushWakeSettingsStore: V2PushWakeSettingsStore?
    let userBlockSettingsStore: V2UserBlockSettingsStore?
    @State private var preferenceTask: Task<Void, Never>?

    var body: some View {
        Form {
            switch store.state {
            case .loading:
                ProgressView("正在读取设置…")
            case .failed:
                ContentUnavailableView(
                    "无法读取设置",
                    systemImage: "exclamationmark.triangle",
                    description: Text("请检查本地数据后重试。")
                )
                Button("重试") { run { await store.refresh() } }
            case .loaded:
                Section {
                    V2PrivacyToggleRow(
                        title: "接收非好友消息",
                        isOn: store.allowsStrangerMessages,
                        isDisabled: store.isSaving,
                        identifier: "v2.privacy.allow-stranger-messages"
                    ) { desiredValue in
                        run { await store.setAllowsStrangerMessages(desiredValue) }
                    }
                } header: {
                    Text("陌生人消息")
                } footer: {
                    Text("关闭后，非好友无法向你发起新的陌生人消息。")
                }
                Section {
                    V2PrivacyToggleRow(title: "允许他人添加我", isOn: store.allowsBeingAdded, isDisabled: store.isSaving, identifier: "v2.privacy.allow-being-added") { value in
                        run { await store.setAllowsBeingAdded(value) }
                    }
                } header: {
                    Text("添加权限")
                } footer: {
                    Text("关闭后，新的添加请求会被拒绝；已有好友和待处理请求不受影响。")
                }
                Section {
                    V2PrivacyToggleRow(title: "单聊已读回执", isOn: store.allowsDirectReadReceipts, isDisabled: store.isSaving, identifier: "v2.privacy.share-direct-read-receipts") { value in
                        run { await store.setReadReceiptPermission(direct: value) }
                    }
                    V2PrivacyToggleRow(title: "群聊已读回执", isOn: store.allowsGroupReadReceipts, isDisabled: store.isSaving, identifier: "v2.privacy.share-group-read-receipts") { value in
                        run { await store.setReadReceiptPermission(group: value) }
                    }
                } header: {
                    Text("已读回执")
                } footer: {
                    Text("关闭单聊共享后，双方都不会看到彼此的已读状态；群聊已读详情仅在需要时查询。")
                }
                Section {
                    V2PrivacyToggleRow(title: "在线状态", isOn: store.allowsOnlinePresence, isDisabled: store.isSaving, identifier: "v2.privacy.share-online-presence") { value in
                        run { await store.setLiveActivityPermission(online: value) }
                    }
                    V2PrivacyToggleRow(title: "正在输入", isOn: store.allowsTypingIndicators, isDisabled: store.isSaving, identifier: "v2.privacy.share-typing-indicators") { value in
                        run { await store.setLiveActivityPermission(typing: value) }
                    }
                } header: {
                    Text("在线与输入状态")
                } footer: {
                    Text("关闭后，不再向会话成员共享你的在线状态或正在输入提示；这些状态不会写入聊天记录。")
                }
                if let pushWakeSettingsStore {
                    V2PushWakeSettingsSection(store: pushWakeSettingsStore)
                }
                if let userBlockSettingsStore {
                    V2UserBlockSettingsSection(store: userBlockSettingsStore)
                }
                if store.isSaving {
                    ProgressView("正在保存…")
                }
                if let feedback = store.feedback {
                    Text(feedback)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .onAppear { announceV2AccessibilityAnnouncement(feedback) }
                        .onChange(of: feedback) { _, updatedFeedback in
                            announceV2AccessibilityAnnouncement(updatedFeedback)
                        }
                        .accessibilityIdentifier("v2.privacy.feedback")
                }
            }
        }
        .v2PageSurface()
        .navigationTitle("消息与隐私")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge:.bottom) { VStack { ForEach(store.accountPreferenceDrafts,id:\.id) { draft in HStack { Text(draft.patch.confirmationDescription + (draft.paused ? "；等待重新确认。" : "；已保存，正在准备原版本。"))
                    if draft.paused { Button("重新确认") { Task {await store.reconfirmAccountPreferenceDraft(draft.id)} } }
                    Button("取消提案") { Task {await store.discardAccountPreferenceDraft(draft.id)} } } }
                V2AccountPreferencePendingView(pending:store.accountPreferencePending) { id in await store.resumeAccountPreference(id) } } }
        .task { await store.observeAccountPreferenceDrafts() }
        .task { await store.observeAccountPreferenceOperations() }
        .task { await store.refresh() }
        .task { await store.observeProjectionChanges() }
        .onDisappear { preferenceTask?.cancel() }
    }

    private func run(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        preferenceTask?.cancel()
        preferenceTask = Task { await operation() }
    }
}

private struct V2PrivacyToggleRow: View {
    let title: String
    let isOn: Bool
    let isDisabled: Bool
    let identifier: String
    let setValue: @MainActor @Sendable (Bool) -> Void

    var body: some View {
        Toggle(title, isOn: Binding(
            get: { isOn },
            set: { desiredValue in setValue(desiredValue) }
        ))
        .tint(V2VisualStyle.outgoing)
        .disabled(isDisabled)
        .accessibilityIdentifier(identifier)
        .accessibilityHint("更改此设置后会同步到你的设备")
    }
}

private struct V2UserBlockSettingsSection: View {
    @Bindable var store: V2UserBlockSettingsStore
    @State private var handle = ""
    @State private var changeTask: Task<Void, Never>?

    var body: some View {
        Section("已屏蔽用户") {
            if store.blockedUsers.isEmpty { Text("暂无已屏蔽用户").foregroundStyle(.secondary) }
            ForEach(store.blockedUsers, id: \.targetUserID) { user in
                HStack {
                    V2AuthorizedAvatarView(key: .init(userID: user.targetUserID, context: .relationship), showsName: true)
                    Spacer()
                    Button("解除屏蔽") { Task { await store.unblockKnownUser(user.targetUserID) } }
                        .disabled(store.isChanging)
                }
            }
        }
        .task { await store.observeBlockedUsers() }
        Section("通过公开 ID 管理") {
            TextField("公开 ID（例如 @alice）", text: $handle)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(store.isChanging)
                .accessibilityIdentifier("v2.privacy.block.handle")
            Text("屏蔽会解除已有好友关系并阻止新的私聊消息。可从上方列表解除屏蔽；解除后不会自动恢复好友。")
                .font(.body)
                .foregroundStyle(.secondary)
            HStack {
                Button("屏蔽", role: .destructive) {
                    run(action: .block)
                }
                .disabled(handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isChanging)
                .accessibilityIdentifier("v2.privacy.block.submit")
                Button("解除屏蔽") {
                    run(action: .unblock)
                }
                .disabled(handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isChanging)
                .accessibilityIdentifier("v2.privacy.unblock.submit")
            }
            if store.isChanging {
                ProgressView("正在保存用户设置…")
            }
            if let feedback = store.feedback {
                Text(feedback)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .onAppear { announceV2AccessibilityAnnouncement(feedback) }
                    .onChange(of: feedback) { _, updatedFeedback in
                        announceV2AccessibilityAnnouncement(updatedFeedback)
                    }
                    .accessibilityIdentifier("v2.privacy.block.feedback")
            }
        }
        .confirmationDialog("确认屏蔽设置",isPresented:Binding(get:{store.socialConfirmation != nil},set:{if !$0 {store.socialConfirmation=nil}})) { Button("确认") { Task {await store.confirmSocialOperation()} } } message: { Text(store.socialConfirmation?.description ?? "") }
        .task { await store.observeSocialProposals() }
            .task { await store.observeSocialOperations() }
        .overlay(alignment:.bottom) { VStack { V2SocialProposalList(proposals:store.socialProposals,prepare:{await store.prepareSocialProposal($0)},discard:{await store.discardSocialProposal($0)})
                V2SocialPendingStatusView(pending:store.socialPending) { id in await store.resumeSocialOperation(id) } } }
        .onDisappear { changeTask?.cancel() }
    }

    private func run(action: V2UserBlockAction) {
        changeTask?.cancel()
        let submittedHandle = handle
        changeTask = Task {
            await store.changeBlock(handle: submittedHandle, action: action)
        }
    }
}

private struct V2PushWakeSettingsSection: View {
    @Bindable var store: V2PushWakeSettingsStore
    @State private var preferenceTask: Task<Void, Never>?

    var body: some View {
        Section("后台同步唤醒") {
            Toggle(
                "允许后台同步唤醒",
                isOn: Binding(
                    get: { store.isEnabled },
                    set: { desiredValue in
                        preferenceTask?.cancel()
                        preferenceTask = Task { await store.setEnabled(desiredValue) }
                    }
                )
            )
            .disabled(store.state == .loading || store.isSigningOut)
            .accessibilityIdentifier("v2.push-wake.enabled")
            Text(pushRegistrationStatus)
                .accessibilityIdentifier("v2.push-wake.registration-status")
            Text("仅发送无内容唤醒，用于提示应用拉取已授权的同步数据；不在通知中包含消息内容。")
                // This is actionable privacy information, not decorative
                // caption text. Use a fully Dynamic-Type-scaled body style.
                .font(.body)
                .foregroundStyle(.secondary)
            if store.state == .waitingForToken || store.state == .registering {
                ProgressView("正在更新后台同步唤醒…")
            }
            if store.state == .retryableFailure && !store.isSigningOut {
                Button("重试后台同步唤醒设置") {
                    preferenceTask?.cancel()
                    preferenceTask = Task { await store.retry() }
                }
                .accessibilityIdentifier("v2.push-wake.retry")
            }
            if let feedback = store.feedback {
                Text(feedback)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .onAppear { announceV2AccessibilityAnnouncement(feedback) }
                    .onChange(of: feedback) { _, updatedFeedback in
                        announceV2AccessibilityAnnouncement(updatedFeedback)
                    }
                    .accessibilityIdentifier("v2.push-wake.feedback")
            }
        }
        .onDisappear { preferenceTask?.cancel() }
    }

    private var pushRegistrationStatus: String {
        switch store.state {
        case .loading: "正在读取设置"
        case .disabled: "后台同步唤醒已关闭"
        case .waitingForToken: "正在获取设备唤醒令牌"
        case .registering: "正在注册后台同步唤醒"
        case .enabled: "后台同步唤醒已就绪"
        case .retryableFailure: "后台同步唤醒尚未就绪"
        }
    }
}
