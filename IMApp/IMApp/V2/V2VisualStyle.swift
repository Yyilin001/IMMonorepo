import SwiftUI
import UIKit

/// Shared presentation tokens. These carry no account or messaging state.
enum V2VisualStyle {
    static let accent = Color.primary
    static let canvas = Color(uiColor: .systemBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    // A dark neutral fill keeps white button labels readable in either appearance.
    static let outgoing = Color(white: 0.24)
    static let incoming = Color(uiColor: .secondarySystemBackground)
    static let separator = Color.primary.opacity(0.08)
    static let avatarTint = Color.secondary

}

struct V2AvatarPlaceholder: View {
    var symbol = "person.fill"
    var title: String? = nil
    var size: CGFloat = 52

    var body: some View {
        let color = V2VisualStyle.avatarTint
        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
            .fill(color.opacity(0.13).gradient)
            .overlay {
                if let title, let first = title.first {
                    Text(String(first)).font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                        .foregroundStyle(color)
                } else {
                    Image(systemName: symbol).font(.system(size: size * 0.36, weight: .medium))
                        .foregroundStyle(color)
                }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct V2PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(isEnabled ? V2VisualStyle.outgoing : Color.secondary.opacity(0.35),
                        in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

private struct V2PageSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.scrollContentBackground(.hidden)
            .background(V2VisualStyle.canvas)
            .tint(V2VisualStyle.accent)
    }
}

/// Native grouped containers keep cards distinct from their surrounding canvas.
private struct V2GroupedPageSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .tint(V2VisualStyle.accent)
    }
}

private struct V2InputSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(16).frame(minHeight: 54)
            .background(V2VisualStyle.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(V2VisualStyle.separator) }
    }
}

extension View {
    func v2PageSurface() -> some View { modifier(V2PageSurface()) }
    func v2GroupedPageSurface() -> some View { modifier(V2GroupedPageSurface()) }
    func v2InputSurface() -> some View { modifier(V2InputSurface()) }
}
