import SwiftUI
import IMClientKit

struct NewContactRequestsEntryRow: View {
    let pendingCount: Int
    let outgoingPendingCount: Int
    let expiredCount: Int
    let unseenCount: Int
    let isLoading: Bool

    var body: some View {
        AppListActionRow(
            title: "新的朋友",
            subtitle: subtitle,
            systemImage: "person.crop.circle.badge.plus",
            tint: .orange
        ) {
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
                    .accessibilityIdentifier("contacts.newFriends.badge")
            }
        }
    }

    private var subtitle: String {
        if unseenCount > 0 {
            return "有 \(unseenCount) 条新的好友申请待查看"
        }

        if pendingCount > 0 {
            if outgoingPendingCount == pendingCount {
                return "有 \(pendingCount) 条发出的申请等待验证"
            }
            return "有 \(pendingCount) 条待处理申请"
        }

        if expiredCount > 0 {
            return "有 \(expiredCount) 条已过期申请记录"
        }

        return "暂时没有新的好友申请"
    }
}

struct ContactsInlineStatusBanner: View {
    let message: String

    var body: some View {
        AppStatusBanner(message: message, tone: .info)
    }
}

struct ContactRow: View {
    let contact: ContactResponseBody

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

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
    }

    private var subtitle: String {
        contact.displayName == contact.email ? "联系人 ID \(contact.id.uuidString.prefix(8))" : contact.email
    }
}

struct ContactsEmptyState: View {
    let onAdd: () -> Void

    var body: some View {
        AppEmptyState(
            title: "还没有联系人",
            message: "发送好友申请并通过验证后，可以直接从通讯录发起私聊。",
            systemImage: "person.2.crop.square.stack",
            actionTitle: "添加联系人",
            actionSystemImage: "person.badge.plus",
            action: onAdd
        )
    }
}

struct NewContactRequestsEmptyState: View {
    var body: some View {
        AppEmptyState(
            title: "没有新的好友申请",
            message: "收到的好友申请会显示在这里。",
            systemImage: "person.crop.circle.badge.checkmark"
        )
    }
}

struct ContactsNoSearchResultState: View {
    let searchText: String
    let onClear: () -> Void

    var body: some View {
        AppEmptyState(
            title: "没有找到联系人",
            message: "当前搜索：\(searchText)",
            systemImage: "magnifyingglass",
            actionTitle: "清除搜索",
            actionSystemImage: "xmark.circle",
            action: onClear
        )
    }
}
