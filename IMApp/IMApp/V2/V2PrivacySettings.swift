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
    private let resolver: any V2PublicIdentityResolving
    private let changer: any V2UserBlockChanging
    private let currentUserID: UserID

    private(set) var isChanging = false
    private(set) var feedback: String?

    init(
        resolver: any V2PublicIdentityResolving,
        changer: any V2UserBlockChanging,
        currentUserID: UserID
    ) {
        self.resolver = resolver
        self.changer = changer
        self.currentUserID = currentUserID
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
            let identity = try await resolver.resolve(handle: trimmedHandle)
            try Task.checkCancellation()
            guard identity.userID != currentUserID else {
                feedback = "不能屏蔽自己。"
                return
            }
            let outcome = try await changer.changeBlock(
                targetUserID: identity.userID.rawValue,
                action: action
            )
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
        try await localStore.strangerMessagePreference()?.allowsStrangerMessages
    }
}

actor V2GRDBUserAddPreferenceDataSource: V2UserAddPreferenceReading {
    private let localStore: GRDBV2LocalSyncStore

    init(localStore: GRDBV2LocalSyncStore) { self.localStore = localStore }

    func userAddPreference() async throws -> Bool? {
        try await localStore.userAddPreference()?.allowsBeingAdded
    }
}
actor V2GRDBReadReceiptPreferenceDataSource: V2ReadReceiptPreferenceReading {
    private let localStore: GRDBV2LocalSyncStore
    init(localStore: GRDBV2LocalSyncStore) { self.localStore = localStore }
    func readReceiptPreference() async throws -> V2ReadReceiptPreferences? { try await localStore.readReceiptPreference() }
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
    private(set) var allowsStrangerMessages = true
    private(set) var allowsBeingAdded = true
    private(set) var allowsDirectReadReceipts = true
    private(set) var allowsGroupReadReceipts = true
    private(set) var allowsOnlinePresence = true
    private(set) var allowsTypingIndicators = true
    private(set) var isSaving = false
    private(set) var feedback: String?
    private var refreshGeneration = 0

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
        state = .loading
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
            allowsStrangerMessages = refreshedPreference
            allowsBeingAdded = refreshedUserAddPreference
            allowsDirectReadReceipts = receiptPreference?.allowsDirectReadReceipts ?? true
            allowsGroupReadReceipts = receiptPreference?.allowsGroupReadReceipts ?? true
            allowsOnlinePresence = liveActivityPreference?.allowsOnlinePresence ?? true
            allowsTypingIndicators = liveActivityPreference?.allowsTypingIndicators ?? true
            state = .loaded
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            state = .failed
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
                allowsStrangerMessages = desiredValue
                feedback = "已更新消息接收设置。"
            case .queuedForRetry:
                allowsStrangerMessages = desiredValue
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
                allowsBeingAdded = desiredValue
                feedback = "已更新添加权限。"
            case .queuedForRetry:
                allowsBeingAdded = desiredValue
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
            switch try await readReceiptUpdater.update(allowsDirectReadReceipts: desiredDirect, allowsGroupReadReceipts: desiredGroup) {
            case .accepted:
                allowsDirectReadReceipts = desiredDirect; allowsGroupReadReceipts = desiredGroup
                feedback = "已更新已读回执设置。"
            case .queuedForRetry:
                allowsDirectReadReceipts = desiredDirect; allowsGroupReadReceipts = desiredGroup
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
            let outcome = try await liveActivityUpdater.update(
                allowsOnlinePresence: desiredOnline,
                allowsTypingIndicators: desiredTyping
            )
            // A view can be dismissed while the authenticated update is in
            // flight. Do not let a late response overwrite fresher projected
            // settings or a new editing intent after its task was cancelled.
            try Task.checkCancellation()
            switch outcome {
            case .accepted:
                allowsOnlinePresence = desiredOnline
                allowsTypingIndicators = desiredTyping
                feedback = "已更新在线与输入状态设置。"
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
                Section("陌生人消息") {
                    V2PrivacyToggleRow(
                        title: "接收非好友消息",
                        isOn: store.allowsStrangerMessages,
                        isDisabled: store.isSaving,
                        identifier: "v2.privacy.allow-stranger-messages"
                    ) { desiredValue in
                        run { await store.setAllowsStrangerMessages(desiredValue) }
                    }
                    Text("关闭后，非好友无法向你发起新的陌生人消息。")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                Section("添加权限") {
                    V2PrivacyToggleRow(title: "允许他人添加我", isOn: store.allowsBeingAdded, isDisabled: store.isSaving, identifier: "v2.privacy.allow-being-added") { value in
                        run { await store.setAllowsBeingAdded(value) }
                    }
                    Text("关闭后，新的添加请求会被拒绝；已有好友和待处理请求不受影响。")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                Section("已读回执") {
                    V2PrivacyToggleRow(title: "在单聊中共享已读状态", isOn: store.allowsDirectReadReceipts, isDisabled: store.isSaving, identifier: "v2.privacy.share-direct-read-receipts") { value in
                        run { await store.setReadReceiptPermission(direct: value) }
                    }
                    V2PrivacyToggleRow(title: "在群聊中共享已读状态", isOn: store.allowsGroupReadReceipts, isDisabled: store.isSaving, identifier: "v2.privacy.share-group-read-receipts") { value in
                        run { await store.setReadReceiptPermission(group: value) }
                    }
                    Text("关闭单聊共享后，双方都不会看到彼此的已读状态；群聊已读详情仅在需要时查询。")
                        .font(.body).foregroundStyle(.secondary)
                }
                Section("在线与输入状态") {
                    V2PrivacyToggleRow(title: "允许他人查看我的在线状态", isOn: store.allowsOnlinePresence, isDisabled: store.isSaving, identifier: "v2.privacy.share-online-presence") { value in
                        run { await store.setLiveActivityPermission(online: value) }
                    }
                    V2PrivacyToggleRow(title: "允许他人查看我正在输入", isOn: store.allowsTypingIndicators, isDisabled: store.isSaving, identifier: "v2.privacy.share-typing-indicators") { value in
                        run { await store.setLiveActivityPermission(typing: value) }
                    }
                    Text("关闭后，不再向会话成员共享你的在线状态或正在输入提示；这些状态不会写入聊天记录。")
                        .font(.body)
                        .foregroundStyle(.secondary)
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
        .navigationTitle("消息接收设置")
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
        Button { setValue(!isOn) } label: {
            HStack(spacing: 12) {
                Text(title)
                Spacer(minLength: 8)
                Text(isOn ? "已开启" : "已关闭")
                    .font(.body)
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "已开启" : "已关闭")
        .accessibilityHint("轻点以\(isOn ? "关闭" : "开启")")
    }
}

private struct V2UserBlockSettingsSection: View {
    @Bindable var store: V2UserBlockSettingsStore
    @State private var handle = ""
    @State private var changeTask: Task<Void, Never>?

    var body: some View {
        Section("屏蔽用户") {
            TextField("公开 ID（例如 @alice）", text: $handle)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(store.isChanging)
                .accessibilityIdentifier("v2.privacy.block.handle")
            Text("屏蔽后，你们之间不能再发送新的私聊消息。解除屏蔽时输入同一公开 ID。")
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
}
