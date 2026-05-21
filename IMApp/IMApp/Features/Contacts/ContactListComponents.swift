import SwiftUI
import IMClientKit

struct NewContactRequestsEntryRow: View {
    let pendingCount: Int
    let unseenCount: Int
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 12) {
            requestAvatar(systemImage: "person.crop.circle.badge.plus", color: .orange)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("新的朋友")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)

                    if unseenCount > 0 {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                    }
                }

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if pendingCount > 0 {
                Text("\(pendingCount)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(unseenCount > 0 ? .red : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill((unseenCount > 0 ? Color.red : Color.secondary).opacity(0.12))
                    )
            }

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
    }

    private var subtitle: String {
        if unseenCount > 0 {
            return "有 \(unseenCount) 条新的好友申请待查看"
        }

        if pendingCount > 0 {
            return "有 \(pendingCount) 条待处理申请"
        }

        return "暂时没有新的好友申请"
    }
}

struct ContactsInlineStatusBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "info.circle.fill")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ContactRow: View {
    let contact: ContactResponseBody
    let isStartingConversation: Bool
    let onStartConversation: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onBlock: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            UserAvatarView(
                displayName: contact.displayName,
                email: contact.email,
                avatarPreset: contact.avatarPreset,
                size: 42
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(contact.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                onStartConversation()
            } label: {
                if isStartingConversation {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "message.fill")
                        .font(.body.weight(.semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isStartingConversation)
        }
        .padding(.vertical, 6)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("删除", systemImage: "trash")
            }

            Button {
                onEdit()
            } label: {
                Label("备注", systemImage: "pencil")
            }
            .tint(.blue)

            Button(role: .destructive) {
                onBlock()
            } label: {
                Label("拉黑", systemImage: "hand.raised.fill")
            }
        }
    }

    private var subtitle: String {
        contact.displayName == contact.email ? "联系人 ID \(contact.id.uuidString.prefix(8))" : contact.email
    }
}

private func requestAvatar(systemImage: String, color: Color) -> some View {
    Circle()
        .fill(color.opacity(0.14))
        .frame(width: 42, height: 42)
        .overlay {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(color)
        }
}

struct ContactsEmptyState: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.2.crop.square.stack")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.teal)

            VStack(spacing: 6) {
                Text("还没有联系人")
                    .font(.headline)

                Text("发送好友申请并通过验证后，可以从通讯录直接发起私聊。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                onAdd()
            } label: {
                Label("发送好友申请", systemImage: "person.badge.plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

struct NewContactRequestsEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.orange)

            Text("暂时没有新的好友申请")
                .font(.headline)

            Text("收到新的好友申请时，这里会第一时间显示。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

struct ContactsNoSearchResultState: View {
    let searchText: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("没有找到匹配联系人")
                .font(.headline)

            Text("当前搜索：\(searchText)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}
