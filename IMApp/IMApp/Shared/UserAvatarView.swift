import SwiftUI
import IMClientKit

struct UserAvatarView: View {
    let displayName: String
    let email: String?
    let avatarPreset: UserAvatarPreset?
    let size: CGFloat

    init(
        displayName: String,
        email: String? = nil,
        avatarPreset: UserAvatarPreset? = nil,
        size: CGFloat = 44
    ) {
        self.displayName = displayName
        self.email = email
        self.avatarPreset = avatarPreset
        self.size = size
    }

    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: gradientColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay {
                Text(initials)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }

    private var initials: String {
        let candidates = [displayName, email ?? ""]
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }

            return String(trimmed.prefix(2)).uppercased()
        }

        return "U"
    }

    private var fontSize: CGFloat {
        max(size * 0.34, 13)
    }

    private var gradientColors: [Color] {
        switch avatarPreset {
        case .sunrise:
            return [Color.orange.opacity(0.95), Color.pink.opacity(0.8)]
        case .ocean:
            return [Color.teal.opacity(0.95), Color.blue.opacity(0.82)]
        case .forest:
            return [Color.green.opacity(0.92), Color.mint.opacity(0.78)]
        case .graphite:
            return [Color(.systemGray), Color(.systemGray3)]
        case .rose:
            return [Color.pink.opacity(0.92), Color.red.opacity(0.78)]
        case .slate:
            return [Color.indigo.opacity(0.82), Color(.systemGray2)]
        case nil:
            return [Color.accentColor.opacity(0.92), Color.blue.opacity(0.78)]
        }
    }
}
