import Foundation
import IMV2ClientKit
import Observation
import SwiftUI

protocol V2StrangerMessagePreferenceReading: Sendable {
    func strangerMessagePreference() async throws -> Bool?
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

    init(
        reader: any V2StrangerMessagePreferenceReading,
        updater: any V2StrangerMessagePreferenceUpdating
    ) {
        self.reader = reader
        self.updater = updater
    }

    func refresh() async {
        state = .loading
        do {
            // The server defaults to allow. Absence only means this device has
            // not yet received a projection, not that the preference is deny.
            allowsStrangerMessages = try await reader.strangerMessagePreference() ?? true
            state = .loaded
        } catch is CancellationError {
            isSaving = false
            return
        } catch {
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
                Button("重试") { Task { await store.refresh() } }
            case .loaded:
                Section("陌生人消息") {
                    Toggle(
                        "接收非好友消息",
                        isOn: Binding(
                            get: { store.allowsStrangerMessages },
                            set: { desiredValue in
                                Task { await store.setAllowsStrangerMessages(desiredValue) }
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
    }
}

private struct V2PushWakeSettingsSection: View {
    @Bindable var store: V2PushWakeSettingsStore

    var body: some View {
        Section("后台同步唤醒") {
            Toggle(
                "允许后台同步唤醒",
                isOn: Binding(
                    get: { store.isEnabled },
                    set: { desiredValue in
                        Task { await store.setEnabled(desiredValue) }
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
    }
}
