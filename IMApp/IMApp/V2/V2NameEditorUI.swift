import SwiftUI
import Observation
import IMV2Core
import IMV2ClientKit

@MainActor @Observable
final class V2NameEditorStore {
    let target: V2NameTarget
    private let service: V2NameOperationService
    private(set) var baseline: V2NameSnapshot?
    private(set) var pending: V2NameIntentSnapshot?
    private(set) var isSaving = false
    private(set) var isRefreshing = false
    private(set) var feedback: String?
    private(set) var hasEdited = false
    private var restoredIntentID: UUID?
    private var awaitingIntentID: UUID?
    private var rebasedConflictID: UUID?
    var text = ""
    init(target: V2NameTarget, service: V2NameOperationService) { self.target = target; self.service = service }
    var title: String { switch target { case .contact: "联系人备注"; case .group: "我的群昵称" } }
    var canSave: Bool {
        baseline != nil && !isSaving && !isRefreshing && awaitingIntentID == nil &&
            (pending?.work.execution.isTerminal ?? true) &&
            (pending?.work.execution != .conflicted || rebasedConflictID == pending?.id)
    }
    var status: String? {
        guard let work = pending?.work else { return nil }
        switch work.execution {
        case .committed: return "已保存到服务器"
        case .conflicted: return "其他设备已修改，请读取最新值后决定是否重新应用。"
        case .rejected: return "服务器未接受这次修改。"
        case .closed, .cancelledLocally: return "已停止这次修改。"
        case .expiredUnsubmitted: return "修改尚未提交，已超过有效期。"
        default:
            if work.scheduling == .needsAttention { return "结果仍待确认，请继续确认或尝试关闭原操作。" }
            return work.submissionStarted ? "正在确认保存结果" : "已保存，等待同步"
        }
    }
    func edit(_ value: String) { text = value; hasEdited = true }
    func load() async {
        do {
            let cached = try await service.cached(target)
            try Task.checkCancellation()
            if let cached { apply(cached) }
            await refresh(rebaseConflict: false)
        } catch is CancellationError { }
        catch { feedback = "无法读取本地资料。" }
    }
    private func apply(_ value: V2NameSnapshot) {
        baseline = value
        if !hasEdited && restoredIntentID == nil { text = value.name ?? "" }
    }
    func refresh() async { await refresh(rebaseConflict: true) }
    private func refresh(rebaseConflict: Bool) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let value = try await service.refresh(target)
            try Task.checkCancellation()
            apply(value)
            if rebaseConflict, pending?.work.execution == .conflicted { rebasedConflictID = pending?.id }
            feedback = nil
        }
        catch is CancellationError { }
        catch { feedback = baseline == nil ? "无法读取编辑基线，请联网后重试。" : "刷新失败，保留本地内容。" }
    }
    func observeBaseline() async {
        do {
            for try await value in await service.baselineUpdates(target) {
                try Task.checkCancellation()
                if let value {
                    if baseline?.revision != value.revision { rebasedConflictID = nil }
                    apply(value)
                } else {
                    if baseline != nil { hasEdited = true }
                    baseline = nil
                    rebasedConflictID = nil
                }
            }
        } catch is CancellationError { }
        catch {
            baseline = nil
            rebasedConflictID = nil
            feedback = "无法确认编辑基线，请读取最新值后重试。"
        }
    }
    func observe() async {
        do {
            for try await value in await service.updates(target) {
                try Task.checkCancellation()
                pending = value
                if value?.id == awaitingIntentID { awaitingIntentID = nil }
                if let value, !hasEdited, restoredIntentID != value.id,
                   value.work.execution != .committed && value.work.execution != .cancelledLocally && value.work.execution != .closed {
                    text = value.name ?? ""; restoredIntentID = value.id
                }
                if value?.work.execution == .committed {
                    let cached = try await service.cached(target)
                    try Task.checkCancellation()
                    // A completed command is history, not an unsaved draft.
                    // The cache may already contain another device's newer name.
                    // Keep actual typing, but release restored text after success.
                    restoredIntentID = nil
                    if let cached { apply(cached) }
                }
            }
        } catch is CancellationError { }
        catch { feedback = "无法观察保存状态，请重新打开页面。" }
    }
    func save() async {
        guard canSave, let baseline else { return }
        isSaving = true
        let value = text
        defer { isSaving = false }
        do {
            let id = try await service.save(target, name: value, expectedRevision: baseline.revision)
            if pending?.id != id { awaitingIntentID = id }
            // Persistence has succeeded even if the page disappears while returning.
            feedback = "已保存，等待同步"
        } catch { feedback = "未能保存，请检查输入或本地存储后重试。" }
    }
    func continueConfirmation() async {
        guard let pending else { return }
        do { try await service.continueConfirmation(id: pending.id); feedback = nil }
        catch { feedback = "当前操作仍在执行，请稍后重试。" }
    }
    func discard() async {
        guard let pending else { return }
        do { try await service.discard(id: pending.id); feedback = "正在确认能否关闭原操作。" }
        catch { feedback = "当前操作仍在执行，请稍后尝试关闭。" }
    }
}

struct V2NameEditorView: View {
    @State var store: V2NameEditorStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称（留空清除）", text: Binding(get: { store.text }, set: { store.edit($0) }))
                        .accessibilityIdentifier("v2.nameEditor.name")
                    if let baseline = store.baseline { LabeledContent("服务器确认值", value: baseline.name ?? "未设置") }
                    Button("保存") { Task { await store.save() } }.disabled(!store.canSave)
                        .accessibilityIdentifier("v2.nameEditor.save")
                } footer: { Text("保存后可离开页面，应用会继续同步；版本冲突时保留你的输入。") }
                if let status = store.status { Section("保存状态") { Text(status) } }
                if let pending = store.pending, !pending.work.execution.isTerminal {
                    Section {
                        Button("继续确认") { Task { await store.continueConfirmation() } }
                            .disabled(pending.work.scheduling == .claimed)
                        Button("尝试关闭原操作", role: .destructive) { Task { await store.discard() } }
                            .disabled(pending.work.scheduling == .claimed)
                    }
                }
                if let feedback = store.feedback { Section { Text(feedback).foregroundStyle(.secondary) } }
                Button("读取最新值（保留输入）") { Task { await store.refresh() } }.disabled(store.isRefreshing)
            }
            .navigationTitle(store.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { await store.load() }
            .task { await store.observe() }
            .task { await store.observeBaseline() }
        }
    }
}
