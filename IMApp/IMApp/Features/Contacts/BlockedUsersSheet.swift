import SwiftUI
import IMClientKit

struct BlockedUsersSheet: View {
    @EnvironmentObject private var authManager: AuthManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var contactStore: ContactStore

    var body: some View {
        List {
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
                    ContentUnavailableView("黑名单为空", systemImage: "hand.raised")
                }
            } else {
                Section {
                    ForEach(contactStore.blockedUsers, id: \.blockedUserID) { block in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(displayName(for: block.blockedUserID))
                                    .font(.body.weight(.semibold))
                                Text(block.blockedUserID.uuidString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if let reason = block.reason, !reason.isEmpty {
                                    Text(reason)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }

                            Spacer()

                            Button("解除") {
                                Task {
                                    _ = await authManager.unblockUser(block.blockedUserID)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                } footer: {
                    Text("拉黑后，对方不能向你发起好友申请、创建私聊或发送私聊消息。")
                }
            }
        }
        .navigationTitle("黑名单")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await authManager.loadBlockedUsers()
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") {
                    dismiss()
                }
            }
        }
    }

    private func displayName(for userID: UUID) -> String {
        contactStore.contacts.first(where: { $0.id == userID })?.displayName
            ?? "用户 \(userID.uuidString.prefix(8))"
    }
}
