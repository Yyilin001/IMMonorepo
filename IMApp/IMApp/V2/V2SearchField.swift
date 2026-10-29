import SwiftUI

/// Shared search surface, matching the conversation list. Callers own query and search work.
struct V2SearchField: View {
    let title: String
    @Binding var text: String
    @FocusState private var isFocused: Bool
    let identifier: String
    var clearLabel = "清除搜索"
    var hint = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.body).foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(title, text: $text, axis: .vertical)
                .focused($isFocused)
                .textFieldStyle(.plain)
                .font(.body).foregroundStyle(.primary).lineLimit(1...3)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityLabel(title)
                .accessibilityHint(hint)
                .accessibilityIdentifier(identifier)
            if !text.isEmpty {
                Button { text = ""; isFocused = true } label: {
                    Image(systemName: "xmark.circle.fill").font(.body)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(clearLabel)
                .accessibilityIdentifier(identifier + ".clear")
            }
        }
        .padding(12)
        .background(V2VisualStyle.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(V2VisualStyle.separator) }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(V2VisualStyle.canvas)
    }
}
