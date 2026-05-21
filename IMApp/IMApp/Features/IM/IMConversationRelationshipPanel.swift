import SwiftUI

struct DirectPeerRelationshipActionPanel: View {
    let presentation: DirectPeerRelationshipPresentation
    let actionMessage: String?
    let onSendRequest: () -> Void
    let onAccept: () -> Void
    let onDecline: () -> Void
    let onCancelRequest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if presentation.state == .resolving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: iconName)
                        .foregroundStyle(.orange)
                }

                Text(presentation.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }

            switch presentation.state {
            case .none:
                Button("添加好友", action: onSendRequest)
                    .buttonStyle(.borderedProminent)
            case .outgoingPending:
                Button("取消申请", role: .destructive, action: onCancelRequest)
                    .buttonStyle(.bordered)
            case .incomingPending:
                HStack(spacing: 10) {
                    Button("接受", action: onAccept)
                        .buttonStyle(.borderedProminent)

                    Button("拒绝", role: .destructive, action: onDecline)
                        .buttonStyle(.bordered)
                }
            case .friend, .resolving, .unavailable:
                EmptyView()
            }

            if let actionMessage, !actionMessage.isEmpty {
                IMInlineStatusBanner(message: actionMessage)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var iconName: String {
        switch presentation.state {
        case .friend:
            return "person.crop.circle.badge.checkmark"
        case .none:
            return "person.badge.plus"
        case .outgoingPending:
            return "paperplane.fill"
        case .incomingPending:
            return "person.crop.circle.badge.plus"
        case .resolving:
            return "arrow.trianglehead.2.clockwise"
        case .unavailable:
            return "person.crop.circle.badge.exclamationmark"
        }
    }
}

