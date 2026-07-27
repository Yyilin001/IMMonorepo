import Foundation
import IMV2ClientKit
import IMV2Core
import Observation
import SwiftUI

protocol V2StrangerMessagePreferenceReading: Sendable {
    func strangerMessagePreference() async throws -> Bool?
}

@MainActor
@Observable
final class V2UserBlockSettingsStore {
    private let resolver: any V2PublicIdentityResolving
    private let changer: any V2UserBlockChanging
    private let currentUserID: String

    private(set) var isChanging = false
    private(set) var feedback: String?

    init(
        resolver: any V2PublicIdentityResolving,
        changer: any V2UserBlockChanging,
        currentUserID: String
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
            guard identity.userID.rawValue != currentUserID else {
                feedback = "不能屏蔽自己。"
                return
            }
            switch try await changer.changeBlock(
                targetUserID: identity.userID.rawValue,
                action: action
            ) {
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
    private(set) var state: State = .loading
    private(set) var allowsStrangerMessages = true
    private(set) var isSaving = false
    private(set) var feedback: String?
    private var refreshGeneration = 0

    init(
        reader: any V2StrangerMessagePreferenceReading,
        updater: any V2StrangerMessagePreferenceUpdating
    ) {
        self.reader = reader
        self.updater = updater
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
            allowsStrangerMessages = refreshedPreference
            state = .loaded
        } catch is CancellationError {
            return
        } catch {
            guard generation == refreshGeneration else { return }
            state = .failed
        }
    }

    func setAllowsStrangerMessages(_ desiredValue: Bool) async {
        guard !isSaving, desiredValue != allowsStrangerMessages else { return }
        isSaving = true
        feedback = nil
        defer { isSaving = false }
        do {
            switch try await updater.update(allowsStrangerMessages: desiredValue) {
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
                    Toggle(
                        "接收非好友消息",
                        isOn: Binding(
                            get: { store.allowsStrangerMessages },
                            set: { desiredValue in
                                run { await store.setAllowsStrangerMessages(desiredValue) }
                            }
                        )
                    )
                    .disabled(store.isSaving)
                    .accessibilityIdentifier("v2.privacy.allow-stranger-messages")
                    Text("关闭后，非好友无法向你发起新的陌生人消息。")
                        .font(.footnote)
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
                        .accessibilityIdentifier("v2.privacy.feedback")
                }
            }
        }
        .navigationTitle("消息接收设置")
        .task { await store.refresh() }
        .onDisappear { preferenceTask?.cancel() }
    }

    private func run(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        preferenceTask?.cancel()
        preferenceTask = Task { await operation() }
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
                .font(.footnote)
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
            .disabled(store.state == .loading || store.state == .registering)
            .accessibilityIdentifier("v2.push-wake.enabled")
            Text("仅发送无内容唤醒，用于提示应用拉取已授权的同步数据；不在通知中包含消息内容。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if store.state == .waitingForToken || store.state == .registering {
                ProgressView("正在更新后台同步唤醒…")
            }
            if let feedback = store.feedback {
                Text(feedback)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("v2.push-wake.feedback")
            }
        }
        .onDisappear { preferenceTask?.cancel() }
    }
}
