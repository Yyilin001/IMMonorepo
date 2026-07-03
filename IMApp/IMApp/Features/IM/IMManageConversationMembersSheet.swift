import IMClientKit
import SwiftUI

/// Member-management sheet state projected from the current conversation and member page.
struct IMManageMembersSnapshot: Equatable {
    let hasConversation: Bool
    let rows: [IMManageMemberRowSnapshot]
    let loadedMemberCount: Int
    let memberTotal: Int
    let isLoading: Bool
    let isLoadingMore: Bool
    let canLoadMore: Bool

    static let empty = IMManageMembersSnapshot(
        hasConversation: false,
        rows: [],
        loadedMemberCount: 0,
        memberTotal: 0,
        isLoading: false,
        isLoadingMore: false,
        canLoadMore: false
    )
}

/// Renderable member row plus the actions allowed for the current user's role.
struct IMManageMemberRowSnapshot: Identifiable, Equatable {
    let id: UUID
    let displayTitle: String
    let roleEmailText: String
    let isCurrentUser: Bool
    let actions: [IMManageMemberActionSnapshot]
}

/// Button model for one role or membership action.
struct IMManageMemberActionSnapshot: Identifiable, Equatable {
    let kind: IMManageMemberActionKind
    let title: String
    let failureMessage: String
    let isDestructive: Bool

    var id: IMManageMemberActionKind {
        kind
    }
}

/// Domain action represented by a member-management button.
enum IMManageMemberActionKind: Hashable {
    case promoteAdmin(memberID: UUID)
    case demoteAdmin(memberID: UUID)
    case transferOwner(memberID: UUID)
    case removeMember(memberID: UUID)
}

/// Projects raw member state into sheet rows and role-scoped actions.
struct IMManageMembersSnapshotBuilder {
    func build(
        conversation: IMConversation?,
        pageState: IMConversationMemberPageState,
        currentUserID: UUID?,
        visibleQuery: String
    ) -> IMManageMembersSnapshot {
        guard let conversation else {
            return IMManageMembersSnapshot(
                hasConversation: false,
                rows: [],
                loadedMemberCount: 0,
                memberTotal: 0,
                isLoading: pageState.isLoading,
                isLoadingMore: pageState.isLoadingMore,
                canLoadMore: pageState.canLoadMore
            )
        }

        let trimmedQuery = visibleQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayedMembers = pageState.query == trimmedQuery ? pageState.items : conversation.members
        let currentRole = currentUserID.flatMap { userID in
            displayedMembers.first(where: { $0.id == userID })?.role
                ?? conversation.members.first(where: { $0.id == userID })?.role
        }

        return IMManageMembersSnapshot(
            hasConversation: true,
            rows: displayedMembers.map { member in
                IMManageMemberRowSnapshot(
                    id: member.id,
                    displayTitle: member.displayTitle,
                    roleEmailText: "\(member.role.displayName) · \(member.email)",
                    isCurrentUser: member.id == currentUserID,
                    actions: actions(for: member, currentUserID: currentUserID, currentRole: currentRole)
                )
            },
            loadedMemberCount: displayedMembers.count,
            memberTotal: pageState.total > 0 ? pageState.total : conversation.memberCount,
            isLoading: pageState.isLoading,
            isLoadingMore: pageState.isLoadingMore,
            canLoadMore: pageState.canLoadMore
        )
    }

    private func actions(
        for member: IMConversationMember,
        currentUserID: UUID?,
        currentRole: IMConversationMemberRole?
    ) -> [IMManageMemberActionSnapshot] {
        guard let currentRole, member.id != currentUserID else {
            return []
        }

        var actions: [IMManageMemberActionSnapshot] = []

        if currentRole.canManageRoles {
            switch member.role {
            case .owner:
                break
            case .admin:
                actions.append(
                    IMManageMemberActionSnapshot(
                        kind: .demoteAdmin(memberID: member.id),
                        title: "取消管理员",
                        failureMessage: "取消管理员失败。",
                        isDestructive: false
                    )
                )
                actions.append(
                    IMManageMemberActionSnapshot(
                        kind: .transferOwner(memberID: member.id),
                        title: "转让群主",
                        failureMessage: "转让群主失败。",
                        isDestructive: false
                    )
                )
            case .member:
                actions.append(
                    IMManageMemberActionSnapshot(
                        kind: .promoteAdmin(memberID: member.id),
                        title: "设为管理员",
                        failureMessage: "设置管理员失败。",
                        isDestructive: false
                    )
                )
                actions.append(
                    IMManageMemberActionSnapshot(
                        kind: .transferOwner(memberID: member.id),
                        title: "转让群主",
                        failureMessage: "转让群主失败。",
                        isDestructive: false
                    )
                )
            }
        }

        if currentRole.canRemove(memberWithRole: member.role) {
            actions.append(
                IMManageMemberActionSnapshot(
                    kind: .removeMember(memberID: member.id),
                    title: "移除成员",
                    failureMessage: "移除成员失败。",
                    isDestructive: true
                )
            )
        }

        return actions
    }
}

/// Lightweight dependency signature for rebuilding member-management snapshots.
struct IMManageMembersObservedState: Equatable, Sendable {
    let conversationID: String
    let conversation: IMManageMembersConversationSignature?
    let pageState: IMConversationMemberPageState
    let currentUserID: UUID?
    let visibleQuery: String

    init(
        conversationID: String,
        conversation: IMManageMembersConversationSignature?,
        pageState: IMConversationMemberPageState,
        currentUserID: UUID?,
        visibleQuery: String
    ) {
        self.conversationID = conversationID
        self.conversation = conversation
        self.pageState = pageState
        self.currentUserID = currentUserID
        self.visibleQuery = visibleQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    init(
        conversationStore: IMConversationStore,
        conversationID: String,
        currentUserID: UUID?,
        visibleQuery: String
    ) {
        self.init(
            conversationID: conversationID,
            conversation: conversationStore.conversations
                .first { $0.id == conversationID }
                .map(IMManageMembersConversationSignature.init),
            pageState: conversationStore.memberPageState(for: conversationID),
            currentUserID: currentUserID,
            visibleQuery: visibleQuery
        )
    }
}

struct IMManageMembersConversationSignature: Equatable, Sendable {
    let id: String
    let memberCount: Int
    let members: [IMConversationMember]

    init(conversation: IMConversation) {
        self.id = conversation.id
        self.memberCount = conversation.memberCount
        self.members = conversation.members
    }
}

@MainActor
extension IMConversationStore {
    func manageMembersSnapshot(
        conversationID: String,
        currentUserID: UUID?,
        visibleQuery: String
    ) -> IMManageMembersSnapshot {
        IMManageMembersSnapshotBuilder().build(
            conversation: conversations.first(where: { $0.id == conversationID }),
            pageState: memberPageState(for: conversationID),
            currentUserID: currentUserID,
            visibleQuery: visibleQuery
        )
    }
}

struct IMManageConversationMembersSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var submitter = IMAsyncSubmitter()

    let conversationStore: IMConversationStore
    let conversationID: String
    let currentUserID: UUID?
    let onPromoteAdmin: (UUID) async -> Bool
    let onDemoteAdmin: (UUID) async -> Bool
    let onTransferOwner: (UUID) async -> Bool
    let onRemoveMember: (UUID) async -> Bool
    let onSearchMembers: (String) async -> Void
    let onLoadMoreMembers: () async -> Void
    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var memberSnapshot: IMManageMembersSnapshot = .empty

    var body: some View {
        List {
            if memberSnapshot.hasConversation {
                Section {
                    TextField("搜索成员", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("成员 \(memberSnapshot.loadedMemberCount) / \(memberSnapshot.memberTotal) 人")
                }

                Section {
                    ForEach(memberSnapshot.rows) { member in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(member.displayTitle)
                                        .font(.body)
                                    if member.isCurrentUser {
                                        Text("我")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color(.tertiarySystemFill))
                                            .clipShape(Capsule())
                                    }
                                }

                                Text(member.roleEmailText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if member.actions.isEmpty {
                                EmptyView()
                            } else {
                                Menu {
                                    ForEach(member.actions) { item in
                                        Button(item.title, role: item.isDestructive ? .destructive : nil) {
                                            Task {
                                                await submitter.run(messageOnFailure: item.failureMessage) {
                                                    let succeeded = await perform(item.kind)
                                                    if succeeded {
                                                        await refreshCurrentQuery()
                                                    }
                                                    return succeeded
                                                }
                                            }
                                        }
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .font(.title3)
                                }
                            }
                        }
                    }
                } header: {
                    Text("成员管理")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("群主可以设置管理员、转让群主并移除成员；管理员只能移除普通成员。")
                        if memberSnapshot.isLoading {
                            ProgressView()
                        } else if memberSnapshot.canLoadMore {
                            Button(memberSnapshot.isLoadingMore ? "加载中..." : "加载更多") {
                                Task {
                                    await onLoadMoreMembers()
                                }
                            }
                            .disabled(memberSnapshot.isLoadingMore)
                        }
                    }
                }
            } else {
                Section {
                    Text("当前没有可管理的成员信息。")
                        .foregroundStyle(.secondary)
                }
            }

            if let message = submitter.message, !message.isEmpty {
                Section {
                    IMInlineStatusBanner(message: message)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle("管理成员")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            refreshMemberSnapshot()
            await refreshCurrentQuery()
            refreshMemberSnapshot()
        }
        .onChange(of: manageMembersObservedState) { _, _ in
            refreshMemberSnapshot()
        }
        .onChange(of: query) { _, newValue in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else {
                    return
                }
                await onSearchMembers(newValue)
            }
        }
        .onDisappear {
            searchTask?.cancel()
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") {
                    dismiss()
                }
            }
        }
    }

    private var manageMembersObservedState: IMManageMembersObservedState {
        IMManageMembersObservedState(
            conversationStore: conversationStore,
            conversationID: conversationID,
            currentUserID: currentUserID,
            visibleQuery: query
        )
    }

    private func refreshMemberSnapshot() {
        memberSnapshot = conversationStore.manageMembersSnapshot(
            conversationID: conversationID,
            currentUserID: currentUserID,
            visibleQuery: query
        )
    }

    private func refreshCurrentQuery() async {
        await onSearchMembers(query)
    }

    private func perform(_ action: IMManageMemberActionKind) async -> Bool {
        switch action {
        case .promoteAdmin(let memberID):
            return await onPromoteAdmin(memberID)
        case .demoteAdmin(let memberID):
            return await onDemoteAdmin(memberID)
        case .transferOwner(let memberID):
            return await onTransferOwner(memberID)
        case .removeMember(let memberID):
            return await onRemoveMember(memberID)
        }
    }
}
