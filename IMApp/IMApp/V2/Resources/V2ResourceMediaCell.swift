import IMV2ClientKit
import IMV2Core
import SwiftUI

struct V2ResourceMediaCell: View {
    let entry: V2ResourceDirectoryEntry
    let service: V2ResourceManagementService
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.v2MediaThumbnailCache) private var cache
    @State private var image: V2SendableImage?

    private var localStatus: String {
        switch entry.localState {
        case .available: "已下载"
        case .needsDownload: "需下载"
        case .invalid: "需重新下载"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(.quaternary)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let image { Image(uiImage: image.image).resizable().scaledToFill() }
                    else {
                        Image(systemName: V2ResourceFormatting.symbol(entry.descriptor.kind))
                            .font(.largeTitle).foregroundStyle(.secondary)
                    }
                }
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    if entry.descriptor.kind == .video {
                        Label("视频", systemImage: "play.fill").font(.caption)
                            .padding(6).background(.regularMaterial, in: .capsule).padding(8)
                    }
                }
                .clipShape(.rect(cornerRadius: 12))
                .accessibilityHidden(true)
            Text(entry.descriptor.displayName.value).font(.subheadline).foregroundStyle(Color.primary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3).multilineTextAlignment(.leading)
            HStack(alignment: .top, spacing: 4) {
                Text(V2ResourceFormatting.bytes(entry.descriptor.byteCount))
                Spacer(minLength: 0)
                if entry.isRetained { Image(systemName: "pin.fill") }
            }.font(.caption).foregroundStyle(Color.primary)
            Label(localStatus, systemImage: entry.localState == .available ? "checkmark.circle" : "icloud.and.arrow.down")
                .font(.caption).foregroundStyle(Color.primary)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.descriptor.displayName.value)
        .accessibilityValue(Text("\((entry.descriptor.displayName.value as NSString).pathExtension.uppercased())，\(V2ResourceFormatting.bytes(entry.descriptor.byteCount))，\(localStatus)\(entry.isRetained ? "，保留本机" : "")"))
        .task(id: entry) {
            image = nil
            guard let cache, entry.localState == .available else { return }
            do {
                let decoded = try await service.thumbnail(entry.descriptor.key, using: cache)
                guard !Task.isCancelled else { return }
                image = decoded
            } catch { image = nil }
        }
    }
}
