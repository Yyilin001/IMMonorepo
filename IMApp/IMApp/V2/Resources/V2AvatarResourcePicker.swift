import IMV2ClientKit
import IMV2Core
import SwiftUI

/// A source selection is descriptive context, never an access grant.
struct V2AvatarResourceSelection: Equatable, Sendable {
    let key: V2ResourceKey
    let source: V2ResourceMessageSource
    let displayName: String
    var importSource: V2ResourceImportSource { .message(location: source.location, mediaID: key.mediaID, variantID: nil) }
}

extension V2ResourceManagementService {
    func avatarSelection(for key: V2ResourceKey) async throws -> V2AvatarResourceSelection {
        guard let detail = try await center.details(for: key), detail.descriptor.state == .ready,
              ["image/jpeg", "image/png"].contains(detail.descriptor.contentType),
              detail.descriptor.byteCount <= 50 * 1_024 * 1_024,
              let source = detail.sources.first,
              try await center.containsSource(source, for: key) else { throw V2ResourceStorageError.unavailable }
        try Task.checkCancellation()
        return .init(key: key, source: source, displayName: detail.descriptor.displayName.value)
    }
}

struct V2AvatarResourcePicker: View {
    @State private var library: V2ResourceLibraryStore
    @State private var selection: V2ResourceKey?
    @State private var feedback: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let choose: @MainActor (V2AvatarResourceSelection) -> Void
    init(service: V2ResourceManagementService, choose: @escaping @MainActor (V2AvatarResourceSelection) -> Void) {
        let store = V2ResourceLibraryStore(room: nil, service: service)
        store.category = .image
        _library = State(initialValue: store); self.choose = choose
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("搜索图片", text: $library.search).accessibilityIdentifier("v2.avatar.resources.search")
                }
                Section {
                    if let page = library.content.page {
                        let entries = page.entries.filter { $0.descriptor.state == .ready && ["image/jpeg", "image/png"].contains($0.descriptor.contentType) && $0.descriptor.byteCount <= 50 * 1_024 * 1_024 }
                        if entries.isEmpty { Text("本页暂无可用图片，可搜索或翻页查看其他记录。").foregroundStyle(.secondary) }
                        LazyVGrid(columns: [.init(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 240 : 140))], spacing: 16) {
                            ForEach(entries, id: \.descriptor.key) { entry in
                                Button { selection = entry.descriptor.key } label: {
                                    V2ResourceMediaCell(entry: entry, service: library.service)
                                }.buttonStyle(.plain).disabled(selection != nil)
                                    .accessibilityLabel("选择头像图片：" + entry.descriptor.displayName.value)
                                    .accessibilityIdentifier("v2.avatar.resources.item." + entry.descriptor.key.mediaID.rawValue)
                            }
                        }
                    } else if case .initial = library.content { ProgressView("正在读取本机目录") }
                    if case .unavailable(_, let message) = library.content { Text(message).foregroundStyle(.secondary) }
                } header: { Text("本机已索引的图片") }
                  footer: { Text("可选择 50 MB 以内的 JPEG 或 PNG。保存时会重新验证来源权限，并通过服务器复制为头像。") }
                if library.pageNumber > 1 || library.content.page?.nextCursor != nil {
                    Section {
                        HStack {
                            Button("上一页") { library.previousPage() }.disabled(library.pageNumber == 1)
                            Spacer(); Text("第 \(library.pageNumber) 页"); Spacer()
                            Button("下一页") { library.nextPage() }.disabled(library.content.page?.nextCursor == nil)
                        }
                    }
                }
                if selection != nil { Section { ProgressView("正在确认图片来源") } }
                if let feedback { Section { Text(feedback).foregroundStyle(.secondary) } }
            }.v2GroupedPageSurface()
                .navigationTitle("选择已有图片").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .task(id: library.query) { await library.observe() }
        .task(id: selection) {
            guard let key = selection else { return }
            do {
                let value = try await library.service.avatarSelection(for: key)
                try Task.checkCancellation()
                choose(value); dismiss()
            } catch is CancellationError { }
            catch { feedback = V2ResourceFailure.message(error); selection = nil }
        }
    }
}
