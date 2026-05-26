import SwiftUI
import IMClientKit

struct IncomingContactRequestRow: View {
    let presentation: ContactRequestPresentation
    let isAccepting: Bool
    let isDeclining: Bool
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            UserAvatarView(
                displayName: presentation.title,
                email: presentation.email,
                avatarPreset: presentation.avatarPreset,
                size: 42
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(presentation.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if presentation.state == .expired {
                ContactRequestStatusBadge(title: presentation.statusTitle, color: presentation.statusColor)
            } else {
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
                        .accessibilityIdentifier("contacts.request.reject")
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
                        .accessibilityIdentifier("contacts.request.accept")
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("contacts.request.row.\(presentation.id.uuidString)")
    }
}


struct OutgoingContactRequestRow: View {
    let presentation: ContactRequestPresentation
    let isCancelling: Bool
    let isResending: Bool
    let onCancel: () -> Void
    let onResend: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            UserAvatarView(
                displayName: presentation.title,
                email: presentation.email,
                avatarPreset: presentation.avatarPreset,
                size: 42
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(presentation.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if isCancelling || isResending {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 40)
            } else if presentation.state == .expired {
                Button("重新发送") {
                    onResend()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("contacts.request.resend")
            } else {
                Button("取消") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("contacts.request.cancel")
            }
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("contacts.request.row.\(presentation.id.uuidString)")
    }
}

struct ResolvedContactRequestRow: View {
    let presentation: ContactRequestPresentation
    let isStartingConversation: Bool
    let onStartConversation: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            UserAvatarView(
                displayName: presentation.title,
                email: presentation.email,
                avatarPreset: presentation.avatarPreset,
                size: 42
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(presentation.subtitle)
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
                .accessibilityIdentifier("contacts.request.message")
            } else {
                ContactRequestStatusBadge(title: presentation.statusTitle, color: presentation.statusColor)
            }
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("contacts.request.row.\(presentation.id.uuidString)")
    }
}

struct ContactRequestStatusBadge: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}
