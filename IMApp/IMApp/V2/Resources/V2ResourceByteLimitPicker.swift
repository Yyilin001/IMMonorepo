import SwiftUI

struct V2ResourceByteLimitPicker: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let value: Int64
    let options: [Int64]
    let optionPrefix: String
    let select: (Int64) -> Void

    var body: some View {
        NavigationLink {
            Options(title: title, value: value, options: options, optionPrefix: optionPrefix, select: select)
        } label: {
            HStack(spacing: 12) {
                let vertical = dynamicTypeSize.isAccessibilitySize
                let layout = vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
                layout {
                    Text(title).frame(maxWidth: .infinity, alignment: .leading)
                    Text(V2ResourceFormatting.bytes(value))
                        .multilineTextAlignment(vertical ? .leading : .trailing)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold)).accessibilityHidden(true)
            }
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(Color.primary)
        }
        .accessibilityLabel(title)
        .accessibilityValue(V2ResourceFormatting.bytes(value))
    }

    private struct Options: View {
        @Environment(\.dismiss) private var dismiss
        let title: String
        let value: Int64
        let options: [Int64]
        let optionPrefix: String
        let select: (Int64) -> Void
        var body: some View {
            List(options, id: \.self) { bytes in
                Button {
                    select(bytes)
                    dismiss()
                } label: {
                    HStack {
                        Text(V2ResourceFormatting.bytes(bytes))
                        Spacer()
                        if bytes == value { Image(systemName: "checkmark").accessibilityHidden(true) }
                    }.foregroundStyle(Color.primary).frame(minHeight: 44)
                }
                .accessibilityIdentifier(optionPrefix + String(bytes))
                .accessibilityAddTraits(bytes == value ? .isSelected : [])
            }
            .v2GroupedPageSurface().listRowSpacing(0)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        }
    }
}
