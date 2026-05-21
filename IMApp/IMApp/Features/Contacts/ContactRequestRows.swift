import SwiftUI
import IMClientKit

struct IncomingContactRequestRow: View {
    let request: ContactRequestResponseBody
    let isAccepting: Bool
    let isDeclining: Bool
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            UserAvatarView(
                displayName: request.requester.preferredDisplayName,
                email: request.requester.email,
                avatarPreset: request.requester.avatarPreset,
                size: 42
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(request.requester.preferredDisplayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(request.message?.isEmpty == false ? request.message ?? "" : "请求添加你为好友")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            HStack(spacing: 8) {
                if isDeclining {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 40)
                } else {
                    Button("拒绝") {
                        onDecline()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isAccepting)
                }

                if isAccepting {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 40)
                } else {
                    Button("接受") {
                        onAccept()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isDeclining)
                }
            }
        }
        .padding(.vertical, 6)
    }
}


struct OutgoingContactRequestRow: View {
    let request: ContactRequestResponseBody
    let isCancelling: Bool
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            UserAvatarView(
                displayName: request.addressee.preferredDisplayName,
                email: request.addressee.email,
                avatarPreset: request.addressee.avatarPreset,
                size: 42
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(request.addressee.preferredDisplayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("等待验证")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isCancelling {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 40)
            } else {
                Button("取消") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 6)
    }
}

struct ResolvedContactRequestRow: View {
    let request: ContactRequestResponseBody
    let currentUserID: UUID?
    let isStartingConversation: Bool
    let onStartConversation: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            UserAvatarView(
                displayName: request.peerDisplayName(for: currentUserID),
                email: request.peerUser(for: currentUserID).email,
                avatarPreset: request.peerAvatarPreset(for: currentUserID),
                size: 42
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(request.peerDisplayName(for: currentUserID))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(statusDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if let onStartConversation {
                Button {
                    onStartConversation()
                } label: {
                    if isStartingConversation {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 40)
                    } else {
                        Label("发消息", systemImage: "message.fill")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isStartingConversation)
            } else {
                Text(statusTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(statusColor.opacity(0.12)))
            }
        }
        .padding(.vertical, 6)
    }

    private var statusTitle: String {
        switch request.status {
        case .accepted:
            "已接受"
        case .declined:
            "已拒绝"
        case .cancelled:
            "已取消"
        case .pending:
            "处理中"
        }
    }

    private var statusDescription: String {
        let peerName = request.peerDisplayName(for: currentUserID)
        let base: String
        switch request.status {
        case .accepted:
            base = "你与 \(peerName) 已成为好友。"
        case .declined:
            base = "你已拒绝 \(peerName) 的好友申请。"
        case .cancelled:
            base = "你已取消发给 \(peerName) 的好友申请。"
        case .pending:
            base = "申请处理中。"
        }

        guard let timestamp = request.respondedAt ?? request.updatedAt else {
            return base
        }

        return "\(base) \(timestamp.formatted(date: .abbreviated, time: .shortened))"
    }

    private var statusColor: Color {
        switch request.status {
        case .accepted:
            .green
        case .declined:
            .red
        case .cancelled:
            .secondary
        case .pending:
            .orange
        }
    }

    private var statusIconName: String {
        switch request.status {
        case .accepted:
            "checkmark.circle.fill"
        case .declined:
            "xmark.circle.fill"
        case .cancelled:
            "minus.circle.fill"
        case .pending:
            "clock.fill"
        }
    }
}
