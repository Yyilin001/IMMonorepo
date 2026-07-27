import IMV2ClientKit
import IMV2Core
import Observation
import SwiftUI

@MainActor
@Observable
final class V2PublicIdentitySettingsStore {
    private let manager: any V2PublicIdentityProfileManaging
    private(set) var handle = ""
    var displayName = ""
    private(set) var feedback: String?
    private(set) var isLoading = false
    private(set) var isSaving = false

    init(manager: any V2PublicIdentityProfileManaging) throws {
        self.manager = manager
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let profile = try await manager.currentProfile()
            try Task.checkCancellation()
            handle = profile.handle.description
            displayName = profile.displayName
            feedback = nil
        } catch is CancellationError {
        } catch {
            feedback = "无法读取公开资料，请稍后重试。"
        }
    }

    func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let profile = try await manager.updateDisplayName(displayName)
            try Task.checkCancellation()
            handle = profile.handle.description
            displayName = profile.displayName
            feedback = "已更新显示名称。"
        } catch is CancellationError {
        } catch {
            feedback = "显示名称格式不正确或资料服务暂不可用。"
        }
    }
}

struct V2PublicIdentitySettingsView: View {
    @Bindable var store: V2PublicIdentitySettingsStore
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section("公开 ID") {
                Text(store.handle.isEmpty ? "正在加载…" : store.handle)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("v2.identity.handle")
                Text("公开 ID 暂不可修改；它与登录账号相互独立。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("显示名称") {
                TextField("显示名称", text: $store.displayName)
                    .accessibilityIdentifier("v2.identity.display-name.edit")
                Button("保存") {
                    saveTask?.cancel()
                    saveTask = Task { await store.save() }
                }
                    .disabled(store.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isSaving)
                    .accessibilityIdentifier("v2.identity.save")
            }
            if let feedback = store.feedback {
                Section {
                    Text(feedback)
                        .foregroundStyle(.secondary)
                        .onAppear { announceV2AccessibilityAnnouncement(feedback) }
                        .onChange(of: feedback) { _, updatedFeedback in
                            announceV2AccessibilityAnnouncement(updatedFeedback)
                        }
                }
            }
        }
        .navigationTitle("我的资料")
        .task { await store.load() }
        .onDisappear { saveTask?.cancel() }
    }
}
