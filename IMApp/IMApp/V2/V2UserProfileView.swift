import IMV2ClientKit
import IMV2Core
import Observation
import SwiftUI

/// Shared navigation and actions; profile pixels still use the caller's authorized context.
struct V2UserInteractionContext {
    let contacts: V2ContactsStore
    let conversations: V2ConversationListStore
    let navigation: V2RootNavigationStore
}
private struct V2UserInteractionContextKey: EnvironmentKey {
    static let defaultValue: V2UserInteractionContext? = nil
}
extension EnvironmentValues {
    var v2UserInteractionContext: V2UserInteractionContext? {
        get { self[V2UserInteractionContextKey.self] }
        set { self[V2UserInteractionContextKey.self] = newValue }
    }
}

@MainActor @Observable
final class V2UserProfileActionStore {
    enum Relationship: Equatable { case stranger, friend, incoming, outgoing, blocked }
    let target: UserID
    private let manager: any V2SocialOperationManaging
    private let notifier: V2ProjectionChangeNotifier?
    private(set) var snapshot: V2SocialOperationSnapshot?
    private(set) var isUpdating = false
    private(set) var pending = false
    private(set) var retryWorkID: UUID?
    private(set) var feedback: String?
    private var refreshGeneration = 0

    init(target: UserID, manager: any V2SocialOperationManaging, notifier: V2ProjectionChangeNotifier?) {
        self.target = target; self.manager = manager; self.notifier = notifier
    }
    var relationship: Relationship? {
        guard let snapshot else { return nil }
        if snapshot.isBlocked { return .blocked }
        switch snapshot.relationshipState {
        case .accepted: return .friend
        case .pending: return snapshot.requestedByUserID == snapshot.actorUserID ? .outgoing : .incoming
        default: return .stranger
        }
    }
    var relationshipTitle: String {
        switch relationship {
        case .friend: "已是好友"
        case .incoming: "对方请求添加你为好友"
        case .outgoing: "好友申请已发送，等待对方接受"
        case .blocked: "你已屏蔽此用户"
        case .stranger: "对方还不是你的好友"
        case nil: "关系信息暂不可用"
        }
    }
    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        do {
            let value = try await manager.socialBaseline(target: target)
            try Task.checkCancellation()
            guard value.targetUserID == target else { throw V2SocialOperationValidationError.invalidSnapshot }
            guard generation == refreshGeneration else { return }
            snapshot = value
        } catch is CancellationError { }
        catch { if generation == refreshGeneration { snapshot = nil; feedback = "无法读取关系，请重试。" } }
    }
    func run() async {
        await refresh()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.observeOperations() }
            if let notifier {
                group.addTask {
                    await V2ProjectionRefreshObserver.run(await notifier.updates(scopes: .contacts)) {
                        await self.refresh()
                    }
                }
            }
            await group.waitForAll()
        }
    }
    private func observeOperations() async {
        do {
            var previous: [V2SocialOperationPending] = []
            for try await values in await manager.socialUpdates() {
                try Task.checkCancellation()
                let relevant = values.filter { $0.command.targetUserID == target }
                guard relevant != previous else { continue }
                previous = relevant
                pending = relevant.contains { $0.work.scheduling != .finished }
                retryWorkID = relevant.first { $0.work.scheduling == .needsAttention }?.work.id
                if let last = relevant.first, last.work.scheduling == .finished {
                    feedback = last.work.execution == .committed ? "操作已完成。" : "操作未完成，请刷新后重试。"
                    await refresh()
                }
            }
        } catch is CancellationError { }
        catch { feedback = "暂时无法更新操作状态。" }
    }
    func retry() async {
        guard let id = retryWorkID, !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        do { try await manager.resumeSocialConfirmation(workID: id) }
        catch { feedback = "无法重试，请稍后再试。" }
    }
    func submit(_ action: V2SocialOperationAction) async {
        guard !isUpdating, !pending, let snapshot else { return }
        // The visible baseline belongs to this click. Never silently replace its revision.
        let allowed: Bool = switch action {
        case .relationship(.request): relationship == .stranger
        case .relationship(.accept), .relationship(.reject): relationship == .incoming
        case .relationship(.remove): relationship == .friend || relationship == .outgoing
        case .userBlock(.block): relationship != .blocked
        case .userBlock(.unblock): relationship == .blocked
        }
        guard allowed else { return }
        isUpdating = true
        defer { isUpdating = false }
        pending = true
        feedback = "正在处理…"
        do {
            try await manager.enqueueSocial(action: action, snapshot: snapshot)
        } catch is CancellationError { pending = false }
        catch { pending = false; feedback = "无法提交，请刷新关系后重试。" }
    }
}

struct V2UserProfileSheet: View {
    let key: V2ProfileViewLookupKey
    var usesNavigationStack = true
    var openConversation: ((V2ConversationDestination) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.v2UserInteractionContext) private var context
    @State private var identity: V2PublicIdentity?
    @State private var actions: V2UserProfileActionStore?
    @State private var confirmation: V2SocialOperationAction?
    @State private var nameEditor: V2NameEditorStore?
    @State private var pageID = UUID()
    @State private var messageTask: Task<Void, Never>?
    @State private var messageFeedback: String?
    var body: some View {
        Group {
            if usesNavigationStack {
                NavigationStack { profileContent }
            } else {
                profileContent
            }
        }
        .onDisappear {
            messageTask?.cancel()
            messageTask = nil
        }
    }
    private var profileContent: some View {
        Group {
            List {
                Section {
                    VStack(spacing: 12) {
                        V2AuthorizedAvatarView(key: key, size: 88)
                        V2AuthorizedProfileNameView(key: key, placeholder: knownIdentity?.displayName ?? "资料暂不可用").font(.title2.bold())
                        V2AuthorizedPublicHandleView(key: key, onIdentity: { identity = $0 }).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                    }.frame(maxWidth: .infinity).padding(.vertical, 22)
                }.listRowBackground(Color.clear)
                if let actions {
                    Section("关系") {
                        Text(actions.relationshipTitle).accessibilityIdentifier("v2.user.relationship")
                        if actions.pending { Label("正在处理…", systemImage: "clock") }
                        relationshipActions(actions)
                    }
                    .disabled(actions.isUpdating || actions.pending)
                    Section {
                        if actions.relationship == .blocked {
                            Button("解除屏蔽") { Task { await actions.submit(.userBlock(.unblock)) } }
                                .accessibilityIdentifier("v2.user.unblock")
                        } else if actions.relationship != nil {
                            Button("屏蔽此人", role: .destructive) { confirmation = .userBlock(.block) }
                                .accessibilityIdentifier("v2.user.block")
                        }
                    }.disabled(actions.isUpdating || actions.pending)
                    if actions.retryWorkID != nil {
                        Button("重试") { Task { await actions.retry() } }
                            .disabled(actions.isUpdating)
                            .accessibilityIdentifier("v2.user.retry")
                    }
                    if let feedback = actions.feedback { Text(feedback).font(.footnote).foregroundStyle(.secondary) }
                }
                if knownIdentity != nil, context != nil, actions?.relationship != .blocked {
                    Section { messageAction }
                }
                if let context, let item = context.contacts.item(userID: key.userID.rawValue), item.relationship == .friend {
                    Button("编辑备注") { nameEditor = context.contacts.nameEditor(for: item) }
                }
            }
            .v2GroupedPageSurface()
            .navigationTitle("用户资料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if usesNavigationStack { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
                ToolbarItem(placement: .topBarTrailing) { Button("刷新", systemImage: "arrow.clockwise") { Task { await actions?.refresh() } } }
            }
            .confirmationDialog(confirmation == .userBlock(.block) ? "屏蔽此人？" : "删除好友？", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
                Button(confirmation == .userBlock(.block) ? "屏蔽" : "删除好友", role: .destructive) {
                    if let action = confirmation { confirmation = nil; Task { await actions?.submit(action) } }
                }
            } message: {
                Text(confirmation == .userBlock(.block) ? "屏蔽后，你们将无法发送新的私聊消息，已有好友关系也会解除。解除屏蔽不会自动恢复好友。" : "删除好友后，你们将不再是好友。")
            }
            .sheet(item: Binding(get: { nameEditor.map { NameEditorPresentation(store: $0) } }, set: { if $0 == nil { nameEditor = nil } })) { value in V2NameEditorView(store: value.store) }
            .task(id: key) {
                actions = context?.contacts.profileActions(for: key.userID)
                await actions?.run()
            }
        }
        .authorPresentationPage(context: .list(pageID))
        .accessibilityIdentifier("v2.user.profile")
    }
    @ViewBuilder private func relationshipActions(_ actions: V2UserProfileActionStore) -> some View {
        switch actions.relationship {
        case .stranger:
            Button("添加好友") { Task { await actions.submit(.relationship(.request)) } }
                .accessibilityIdentifier("v2.user.add-friend")
        case .incoming:
            Button("接受好友申请") { Task { await actions.submit(.relationship(.accept)) } }
                .accessibilityIdentifier("v2.user.accept")
            Button("拒绝申请", role: .destructive) { Task { await actions.submit(.relationship(.reject)) } }
        case .outgoing:
            Button("撤销好友申请") { Task { await actions.submit(.relationship(.remove)) } }
                .accessibilityIdentifier("v2.user.cancel-request")
        case .friend:
            Button("删除好友", role: .destructive) { confirmation = .relationship(.remove) }
        case .blocked, nil: EmptyView()
        }
    }

    private var knownIdentity: V2PublicIdentity? {
        identity ?? context?.contacts.item(userID: key.userID.rawValue)?.publicIdentity
    }

    @ViewBuilder private var messageAction: some View {
        Button {
            guard let context, let identity = knownIdentity, messageTask == nil else { return }
            messageFeedback = nil
            messageTask = Task {
                let destination = await context.conversations.openLocalFirstDirectConversation(with: identity)
                guard !Task.isCancelled else { return }
                messageTask = nil
                guard let destination else {
                    messageFeedback = context.conversations.directConversationFeedback ?? "正在打开其他会话，请稍后重试。"
                    return
                }
                if case .room(let route) = destination, case .room(let currentRoom) = key.context,
                   currentRoom.rawValue == route.roomID, usesNavigationStack {
                    dismiss()
                } else if let openConversation {
                    openConversation(destination)
                } else {
                    // This profile is itself on the shared stack: replace the
                    // destination without also issuing a competing pop.
                    context.navigation.showConversation(destination)
                }
            }
        } label: {
            HStack {
                Text("发消息")
                if messageTask != nil { Spacer(); ProgressView() }
            }
        }
        .disabled(knownIdentity == nil || context == nil || messageTask != nil)
        .accessibilityIdentifier("v2.user.message")
        if let messageFeedback {
            Text(messageFeedback).font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("v2.user.message.feedback")
        }
    }
    private struct NameEditorPresentation: Identifiable { let store: V2NameEditorStore; var id: ObjectIdentifier { ObjectIdentifier(store) } }
}

struct V2UserProfileTarget: Identifiable { let key: V2ProfileViewLookupKey; var id: V2ProfileViewLookupKey { key } }

/// Profile sheets across contacts, chat messages and group members finish their
/// dismissal before handing a destination to the authenticated navigation stack.
private struct V2UserProfilePresentation: ViewModifier {
    @Binding var target: V2UserProfileTarget?
    @Environment(\.v2UserInteractionContext) private var context
    @State private var pendingDestination: V2ConversationDestination?

    func body(content: Content) -> some View {
        content.sheet(item: $target, onDismiss: {
            guard let destination = pendingDestination else { return }
            pendingDestination = nil
            context?.navigation.showConversation(destination)
        }) { target in
            V2UserProfileSheet(key: target.key, openConversation: { destination in
                pendingDestination = destination
                self.target = nil
            })
        }
    }
}

extension View {
    func v2UserProfileSheet(item: Binding<V2UserProfileTarget?>) -> some View {
        modifier(V2UserProfilePresentation(target: item))
    }
}
