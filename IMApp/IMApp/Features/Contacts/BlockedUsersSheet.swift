import SwiftUI
import IMClientKit

struct BlockedUsersSheet: View {
    @Environment(\.dismiss) private var dismiss
    let contactStore: ContactStore
    let conversationStore: IMConversationStore
    let currentUserID: UUID?
    let currentUserEmail: String?
    var showsCloseButton = true
    let loadBlockedUsers: () async -> Void
    let unblockUser: (UUID) async -> ContactOperationResult
    let sendContactRequest: (String, String, String) async -> ContactOperationResult

    @State private var unblockingUserIDs: Set<UUID> = []
    @State private var pendingUnblockUserID: UUID?
    @State private var isPresentingAddContact = false
    @State private var taskBag = ContactTaskBag()

    var body: some View {
        List {
            if let notice = contactStore.notice(for: .blockedUsers), !notice.message.isEmpty {
                Section {
                    AppStatusBanner(message: notice.message, tone: notice.tone.appStatusTone)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                }
            }

            if contactStore.isLoadingBlockedUsers {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            } else if contactStore.blockedUsers.isEmpty {
                Section {
                    AppEmptyState(
                        title: "黑名单为空",
                        message: "已解除黑名单的用户不会自动恢复为联系人，可以重新发送好友申请。",
                        systemImage: "hand.raised",
                        actionTitle: "添加联系人",
                        actionSystemImage: "person.badge.plus"
                    ) {
                        isPresentingAddContact = true
                    }
                    .listRowInsets(EdgeInsets(top: 20, leading: 16, bottom: 20, trailing: 16))
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(contactStore.blockedUsers, id: \.blockedUserID) { block in
                        HStack(spacing: 12) {
                            let display = knownDisplay(for: block.blockedUserID)
                            UserAvatarView(
                                displayName: display.displayName,
                                email: display.email,
                                avatarPreset: display.avatarPreset,
                                size: 42
                            )

                            VStack(alignment: .leading, spacing: 4) {
                                Text(display.displayName)
                                    .font(.body.weight(.semibold))
                                Text(display.email ?? "用户 \(block.blockedUserID.uuidString.prefix(8))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(block.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                if let reason = block.reason, !reason.isEmpty {
                                    Text(reason)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }

                            Spacer()

                            if unblockingUserIDs.contains(block.blockedUserID) {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Button("解除") {
                                    pendingUnblockUserID = block.blockedUserID
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .accessibilityIdentifier("contacts.blocked.unblock")
                            }
                        }
                        .accessibilityIdentifier("contacts.blocked.row.\(block.blockedUserID.uuidString)")
                    }
                } footer: {
                    Text("拉黑后，对方不能向你发起好友申请、创建私聊或发送私聊消息。")
                }
            }
        }
        .navigationTitle("黑名单")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            contactStore.clearNotice(scope: .blockedUsers)
            await loadBlockedUsers()
        }
        .onDisappear {
            taskBag.cancelAll()
        }
        .confirmationDialog(
            "解除黑名单后，对方可以重新发起好友申请或私聊。",
            isPresented: pendingUnblockIsPresented,
            titleVisibility: .visible
        ) {
            if let pendingUnblockUserID {
                Button("解除黑名单", role: .destructive) {
                    let userID = pendingUnblockUserID
                    self.pendingUnblockUserID = nil
                    unblock(userID)
                }
                .accessibilityIdentifier("contacts.blocked.confirmUnblock")
            }

            Button("取消", role: .cancel) {
                pendingUnblockUserID = nil
            }
        }
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
        .sheet(isPresented: $isPresentingAddContact) {
            NavigationStack {
                SendContactRequestSheet(
                    contactStore: contactStore,
                    currentUserID: currentUserID,
                    currentUserEmail: currentUserEmail,
                    sendContactRequest: sendContactRequest
                )
            }
            .presentationDetents([.medium])
        }
    }

    private var pendingUnblockIsPresented: Binding<Bool> {
        Binding(
            get: { pendingUnblockUserID != nil },
            set: { isPresented in
                if !isPresented {
                    pendingUnblockUserID = nil
                }
            }
        )
    }

    private func knownDisplay(for userID: UUID) -> KnownContactUserDisplay {
        if let display = contactStore.knownUserDisplay(for: userID) {
            return display
        }

        if let peer = conversationStore.conversations.compactMap(\.directPeer).first(where: { $0.id == userID }) {
            let normalizedDisplayName = peer.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return KnownContactUserDisplay(
                id: peer.id,
                displayName: normalizedDisplayName?.isEmpty == false ? normalizedDisplayName ?? peer.email : peer.email,
                email: peer.email,
                avatarPreset: peer.avatarPreset
            )
        }

        return KnownContactUserDisplay(
            id: userID,
            displayName: "用户 \(userID.uuidString.prefix(8))",
            email: nil,
            avatarPreset: nil
        )
    }

    private func unblock(_ userID: UUID) {
        contactStore.clearNotice(scope: .blockedUsers)
        guard runTask(.unblock(userID), operation: {
            unblockingUserIDs.insert(userID)
            let result = await unblockUser(userID)
            guard !Task.isCancelled else {
                return
            }
            unblockingUserIDs.remove(userID)
            if !result.message.isEmpty {
                contactStore.setNotice(result.message, scope: .blockedUsers, tone: result.tone)
            }
        }) else { return }
    }

    @discardableResult
    private func runTask(
        _ key: ContactViewTaskKey,
        operation: @escaping @MainActor () async -> Void
    ) -> Bool {
        taskBag.run(key, operation: operation)
    }
}
