import IMClientKit
import SwiftUI

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

    var body: some View {
        List {
            if let conversation {
                Section {
                    TextField("搜索成员", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("成员 \(loadedMemberCount) / \(memberTotal) 人")
                }

                Section {
                    ForEach(displayMembers) { member in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(member.displayTitle)
                                        .font(.body)
                                    if member.id == currentUserID {
                                        Text("我")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color(.tertiarySystemFill))
                                            .clipShape(Capsule())
                                    }
                                }

                                Text("\(member.role.displayName) · \(member.email)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if actionMenuItems(for: member).isEmpty {
                                EmptyView()
                            } else {
                                Menu {
                                    ForEach(actionMenuItems(for: member)) { item in
                                        Button(item.title, role: item.role) {
                                            Task {
                                                await submitter.run(messageOnFailure: item.failureMessage) {
                                                    let succeeded = await item.action()
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
                        if pageState.isLoading {
                            ProgressView()
                        } else if pageState.canLoadMore {
                            Button(pageState.isLoadingMore ? "加载中..." : "加载更多") {
                                Task {
                                    await onLoadMoreMembers()
                                }
                            }
                            .disabled(pageState.isLoadingMore)
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
            await refreshCurrentQuery()
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

    private var pageState: IMConversationMemberPageState {
        conversationStore.memberPageState(for: conversationID)
    }

    private var displayMembers: [IMConversationMember] {
        if pageState.query == query.trimmingCharacters(in: .whitespacesAndNewlines) {
            return pageState.items
        }
        return conversation?.members ?? []
    }

    private var loadedMemberCount: Int {
        displayMembers.count
    }

    private var memberTotal: Int {
        pageState.total > 0 ? pageState.total : conversation?.memberCount ?? 0
    }

    private var conversation: IMConversation? {
        conversationStore.conversations.first(where: { $0.id == conversationID })
    }

    private var currentRole: IMConversationMemberRole? {
        guard let currentUserID else {
            return nil
        }

        return displayMembers.first(where: { $0.id == currentUserID })?.role
            ?? conversation?.members.first(where: { $0.id == currentUserID })?.role
    }

    private func refreshCurrentQuery() async {
        await onSearchMembers(query)
    }

    private func actionMenuItems(for member: IMConversationMember) -> [MemberActionItem] {
        guard let currentRole, member.id != currentUserID else {
            return []
        }

        var items: [MemberActionItem] = []

        if currentRole.canManageRoles {
            switch member.role {
            case .owner:
                break
            case .admin:
                items.append(
                    MemberActionItem(
                        title: "取消管理员",
                        failureMessage: "取消管理员失败。",
                        action: { await onDemoteAdmin(member.id) }
                    )
                )
                items.append(
                    MemberActionItem(
                        title: "转让群主",
                        failureMessage: "转让群主失败。",
                        action: { await onTransferOwner(member.id) }
                    )
                )
            case .member:
                items.append(
                    MemberActionItem(
                        title: "设为管理员",
                        failureMessage: "设置管理员失败。",
                        action: { await onPromoteAdmin(member.id) }
                    )
                )
                items.append(
                    MemberActionItem(
                        title: "转让群主",
                        failureMessage: "转让群主失败。",
                        action: { await onTransferOwner(member.id) }
                    )
                )
            }
        }

        if currentRole.canRemove(memberWithRole: member.role) {
            items.append(
                MemberActionItem(
                    title: "移除成员",
                    role: .destructive,
                    failureMessage: "移除成员失败。",
                    action: { await onRemoveMember(member.id) }
                )
            )
        }

        return items
    }
}

struct MemberActionItem: Identifiable {
    let id = UUID()
    let title: String
    let role: ButtonRole?
    let failureMessage: String
    let action: () async -> Bool

    init(
        title: String,
        role: ButtonRole? = nil,
        failureMessage: String,
        action: @escaping () async -> Bool
    ) {
        self.title = title
        self.role = role
        self.failureMessage = failureMessage
        self.action = action
    }
}
