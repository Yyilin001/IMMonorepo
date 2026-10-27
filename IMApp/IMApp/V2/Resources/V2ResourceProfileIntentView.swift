import Foundation
import IMV2ClientKit
import IMV2Core
import Observation
import SwiftUI

@MainActor @Observable
final class V2ResourceProfileIntentStore {
    struct Command: Equatable {
        enum Action: Equatable { case resume, reviewDisposition, dispose(V2ResourceProfileDispositionPlan) }
        let id = UUID()
        let action: Action
    }
    let transfer: V2ManagedResourceTransferID
    private(set) var intentID: UUID
    let center: V2ResourceCenter
    let manager: any V2ProfileIntentManaging
    private(set) var status: V2ProfileIntentStatus?
    private(set) var feedback: String?
    private(set) var isWorking = false
    private(set) var command: Command?
    private(set) var dispositionPlan: V2ResourceProfileDispositionPlan?
    var canResume: Bool { status?.sourceRetained == true && (status?.phase == .needsAttention || status?.phase == .closed) }
    var canDispose: Bool { guard let status else { return false }; return status.sourceRetained && (status.intent.workID == nil || status.canReplace) }
    init(transfer: V2ManagedResourceTransferID, intentID: UUID, center: V2ResourceCenter, manager: any V2ProfileIntentManaging) {
        self.transfer = transfer; self.intentID = intentID; self.center = center; self.manager = manager
    }
    func observe() async {
        let expected = intentID
        do {
            guard try await center.containsBusinessOwner(.profileIntent(expected), transfer: transfer) else { feedback = "这次更改已处理完成。"; return }
            let account = await center.scope.accountID
            for try await value in await manager.observe(intentID: expected) {
                guard !Task.isCancelled, intentID == expected else { return }
                guard value.intent.id == expected, value.intent.accountID == account,
                      value.intent.avatarPreparation?.transferID == transfer else { throw V2ResourceStorageError.unavailable }
                status = value
            }
        } catch { if !Task.isCancelled, intentID == expected { feedback = V2ResourceFailure.message(error) } }
    }
    func resume() { guard !isWorking, canResume else { return }; command = .init(action: .resume) }
    func reviewDisposition() { guard !isWorking, canDispose else { return }; command = .init(action: .reviewDisposition) }
    func dismissDisposition() { dispositionPlan = nil }
    func confirmDisposition(_ plan: V2ResourceProfileDispositionPlan) { guard !isWorking else { return }; dispositionPlan = nil; command = .init(action: .dispose(plan)) }
    func execute(_ request: Command) async {
        guard command == request else { return }
        isWorking = true; feedback = nil
        defer { if command == request { command = nil; isWorking = false } }
        do {
            switch request.action {
            case .resume:
                guard try await center.containsBusinessOwner(.profileIntent(intentID), transfer: transfer) else { throw V2ResourceTransferManagementError.actionUnavailable }
                let next = try await manager.resumeOrReapply(intentID: intentID)
                guard !Task.isCancelled else { return }
                guard next.avatarPreparation?.transferID == transfer,
                      try await center.containsBusinessOwner(.profileIntent(next.id), transfer: transfer) else {
                    feedback = "更改已继续处理，请返回任务列表查看。"; return
                }
                intentID = next.id; feedback = "已继续处理对应的资料更改。"
            case .reviewDisposition:
                let plan = try await center.planProfileDisposition(transfer: transfer, intentID: intentID)
                guard !Task.isCancelled else { return }; dispositionPlan = plan
            case .dispose(let plan):
                try await center.commitProfileDisposition(plan)
                guard !Task.isCancelled else { return }
                feedback = plan.effect == .withdrawUnsubmittedChange ? "已放弃此次资料更改。" : (status?.intent.avatarImport == nil ? "已解除此次更改的本机原件保留。" : "已解除此次更改的资源关联。")
            }
        } catch is CancellationError { }
        catch { if !Task.isCancelled { feedback = V2ResourceFailure.message(error) } }
    }
}

struct V2ResourceProfileIntentView: View {
    @State private var store: V2ResourceProfileIntentStore
    @Environment(\.dismiss) private var dismiss
    init(store: V2ResourceProfileIntentStore) { _store = State(initialValue: store) }
    var body: some View {
        NavigationStack {
            List {
                if let state = store.status {
                    Section("本次资料更改") {
                        if case .set(let name) = state.intent.patch.displayName { LabeledContent("昵称", value: name) }
                        if let upload = state.intent.avatarUpload { LabeledContent("头像", value: upload.displayName) }
                        else if state.intent.avatarImport != nil { LabeledContent("头像", value: "使用已有资源") }
                        Text(Self.status(state)).foregroundStyle(.secondary).accessibilityIdentifier("v2.resources.owner.profile.status")
                    }
                    if store.canResume || store.canDispose {
                        Section {
                            if store.canResume {
                                Button(state.canReplace ? "重新应用此次更改" : "继续确认原更改", systemImage: "arrow.clockwise") { store.resume() }
                                    .accessibilityIdentifier("v2.resources.owner.profile.resume")
                            }
                            if store.canDispose {
                                Button(state.intent.workID == nil ? "放弃此次资料更改" : (state.intent.avatarImport == nil ? "解除本机原件保留" : "解除资源关联"), systemImage: "xmark.circle", role: .destructive) { store.reviewDisposition() }
                                    .accessibilityIdentifier("v2.resources.owner.profile.dispose")
                            }
                        }.disabled(store.isWorking)
                    }
                } else if store.feedback == nil { Section { ProgressView("正在读取对应更改") } }
                if store.isWorking { Section { ProgressView("正在处理") } }
                if let feedback = store.feedback { Section { Text(feedback).foregroundStyle(.secondary) } }
            }.v2GroupedPageSurface().navigationTitle("个人资料更改").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .task(id: store.intentID) { await store.observe() }
        .task(id: store.command) { if let request = store.command { await store.execute(request) } }
        .confirmationDialog("处理本次更改", isPresented: Binding(get: { store.dispositionPlan != nil }, set: { if !$0 { store.dismissDisposition() } })) {
            if let plan = store.dispositionPlan {
                Button(plan.effect == .withdrawUnsubmittedChange ? "放弃此次更改" : (store.status?.intent.avatarImport == nil ? "解除原件保留" : "解除资源关联"), role: .destructive) { store.confirmDisposition(plan) }
                    .accessibilityIdentifier("v2.resources.owner.profile.confirm-dispose")
                Button("继续保留") { store.dismissDisposition() }
                    .accessibilityIdentifier("v2.resources.owner.profile.keep")
            }
        } message: {
            if let plan = store.dispositionPlan {
                Text(plan.effect == .withdrawUnsubmittedChange ? "将整体放弃本次昵称与头像更改，已经生效的资料不会被修改。" : (store.status?.intent.avatarImport == nil ? "解除本次更改的本机原件保留，不会撤销已经生效的资料。" : "解除本次更改的资源关联，不会撤销已经生效的资料。"))
            }
        }
    }
    private static func status(_ value: V2ProfileIntentStatus) -> String {
        if !value.sourceRetained {
            if value.phase == .committed { return "更改已生效，本机原件保留已解除" }
            return value.intent.workID == nil ? "此次更改已放弃" : "本机原件保留已解除"
        }
        switch value.phase {
        case .waitingToSubmit: return "等待提交"
        case .preparingAvatar: return "资料尚未提交，头像传输状态可在任务列表查看"
        case .confirming: return "正在确认原更改"
        case .committed: return "更改已生效"
        case .needsAttention: return "需要处理"
        case .closed: return "原更改已结束"
        }
    }
}
