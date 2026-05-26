import SwiftUI

struct DirectPeerRelationshipActionPanel: View {
    let presentation: DirectPeerRelationshipPresentation
    let notice: DirectRelationshipNotice?
    let isSendRequestRunning: Bool
    let isAcceptRunning: Bool
    let isDeclineRunning: Bool
    let isCancelRunning: Bool
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
                Button {
                    onSendRequest()
                } label: {
                    relationshipActionLabel(title: "添加好友", isRunning: isSendRequestRunning)
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSendRequestRunning)
            case .outgoingPending:
                Button(role: .destructive) {
                    onCancelRequest()
                } label: {
                    relationshipActionLabel(title: "取消申请", isRunning: isCancelRunning)
                }
                    .buttonStyle(.bordered)
                    .disabled(isCancelRunning)
            case .incomingPending:
                HStack(spacing: 10) {
                    Button {
                        onAccept()
                    } label: {
                        relationshipActionLabel(title: "接受", isRunning: isAcceptRunning)
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(isAcceptRunning)

                    Button(role: .destructive) {
                        onDecline()
                    } label: {
                        relationshipActionLabel(title: "拒绝", isRunning: isDeclineRunning)
                    }
                        .buttonStyle(.bordered)
                        .disabled(isDeclineRunning)
                }
            case .friend, .resolving, .unavailable:
                EmptyView()
            }

            if let notice, !notice.message.isEmpty {
                AppStatusBanner(message: notice.message, tone: notice.tone.appStatusTone)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func relationshipActionLabel(title: String, isRunning: Bool) -> some View {
        HStack(spacing: 6) {
            if isRunning {
                ProgressView()
                    .controlSize(.small)
            }
            Text(title)
        }
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
