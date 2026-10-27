import Foundation
import IMV2ClientKit
import IMV2Core
import SwiftUI

/// Only identities enter the signed-in navigation path.
enum V2ResourceRoute: Hashable {
    case home, library(RoomID?), detail(V2ResourceKey), storage, downloadSettings, transfers, businessOwners(V2ManagedResourceTransferID)
}
private struct V2ResourceManagementKey: EnvironmentKey {
    static let defaultValue: V2ResourceManagementService? = nil
}
private struct V2ResourceNavigationKey: EnvironmentKey {
    static let defaultValue: V2RootNavigationStore? = nil
}
extension EnvironmentValues {
    var v2ResourceManagement: V2ResourceManagementService? {
        get { self[V2ResourceManagementKey.self] }
        set { self[V2ResourceManagementKey.self] = newValue }
    }
    var v2ResourceNavigation: V2RootNavigationStore? {
        get { self[V2ResourceNavigationKey.self] }
        set { self[V2ResourceNavigationKey.self] = newValue }
    }
}

private struct V2ResourceDestinations: ViewModifier {
    let service: V2ResourceManagementService?
    let navigation: V2RootNavigationStore
    let profile: V2PublicIdentitySettingsStore?
    let groups: V2PendingGroupAvatarsStore?
    @MainActor private var businessManagers: V2ResourceBusinessManagers {
        let factory: (@MainActor @Sendable (RoomID, GroupAvatarOperationID) -> V2GroupAvatarManagementStore)?
        if let groups { factory = { room, operation in groups.managementStore(for: .init(roomID: room, operationID: operation)) } }
        else { factory = nil }
        return V2ResourceBusinessManagers(profile: profile?.resourceIntentManager, group: factory)
    }
    func body(content: Content) -> some View {
        content.navigationDestination(for: V2ResourceRoute.self) { route in
            Group {
                if let service {
                    switch route {
                    case .home: V2ResourceCenterView(service: service)
                    case .library(let room): V2ResourceLibraryView(room: room, service: service)
                    case .storage: V2ResourceStorageView(service: service)
                    case .downloadSettings: V2ResourceDownloadSettingsView(service: service)
                    case .transfers: V2ResourceTransferView(service: service)
                    case .detail(let key): V2ResourceDetailView(key: key, service: service)
                    case .businessOwners(let transfer): V2ResourceBusinessOwnersView(transfer: transfer, service: service, managers: businessManagers)
                    }
                } else { ContentUnavailableView("资源中心不可用", systemImage: "folder", description: Text("请重新打开当前账号。")) }
            }
            .environment(\.v2ResourceNavigation, navigation)
            .environment(\.v2ResourceManagement, service)
        }
        .environment(\.v2ResourceNavigation, navigation)
        .environment(\.v2ResourceManagement, service)
    }
}
extension View {
    func v2ResourceDestinations(service: V2ResourceManagementService?, navigation: V2RootNavigationStore,
                                profile: V2PublicIdentitySettingsStore? = nil, groups: V2PendingGroupAvatarsStore? = nil) -> some View {
        modifier(V2ResourceDestinations(service: service, navigation: navigation, profile: profile, groups: groups))
    }
}

enum V2ResourceFormatting {
    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
    static func duration(_ milliseconds: Int64) -> String {
        // Divide before rounding so even a decoded Int64.max cannot overflow.
        let positive = max(0, milliseconds)
        let seconds = positive / 1000 + (positive % 1000 == 0 ? 0 : 1)
        let hours = seconds / 3600, minutes = seconds % 3600 / 60, remainder = seconds % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) 小时") }
        if minutes > 0 { parts.append("\(minutes) 分") }
        if remainder > 0 || parts.isEmpty { parts.append("\(remainder) 秒") }
        return parts.joined(separator: " ")
    }
    static func title(_ category: V2ResourceCategory) -> String {
        switch category { case .all: "全部"; case .image: "图片"; case .video: "视频"; case .audio: "音频"; case .file: "文件" }
    }
    static func symbol(_ kind: V2MediaPresentation.Kind) -> String {
        switch kind { case .image, .animatedImage: "photo"; case .video: "film"; case .audio: "waveform"; case .file: "doc" }
    }
    static func color(_ kind: V2MediaPresentation.Kind) -> Color {
        switch kind { case .image, .animatedImage: .blue; case .video: .purple; case .audio: .orange; case .file: .teal }
    }
}

struct V2ResourceCenterView: View {
    @State private var storage: V2ResourceStorageStore
    init(service: V2ResourceManagementService) { _storage = State(initialValue: .init(service: service)) }
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("本机资源文件").foregroundStyle(Color.primary)
                    if let snapshot = storage.content.snapshot {
                        Text(V2ResourceFormatting.bytes(snapshot.totalBytes)).font(.largeTitle.bold())
                    } else { ProgressView().accessibilityLabel("正在读取资源占用") }
                    Text("集中查看聊天附件，管理下载与本机空间。")
                        .font(.subheadline).foregroundStyle(Color.primary)
                }.padding(.vertical, 10)
            }
            Section {
                NavigationLink(value: V2ResourceRoute.library(nil)) {
                    V2ResourceNavigationLabel(title: "浏览资源", symbol: "folder")
                }.accessibilityIdentifier("v2.resources.library.open")
                NavigationLink(value: V2ResourceRoute.transfers) {
                    V2ResourceNavigationLabel(title: "传输任务", symbol: "arrow.up.arrow.down")
                }.accessibilityIdentifier("v2.resources.transfers.open")
            } header: { Text("资源").foregroundStyle(Color.primary) }
            Section {
                NavigationLink(value: V2ResourceRoute.storage) {
                    V2ResourceNavigationLabel(title: "存储管理", symbol: "internaldrive")
                }.accessibilityIdentifier("v2.resources.storage.open")
            } header: { Text("本机存储").foregroundStyle(Color.primary) }
            Section {
                Text("资源目录覆盖本机已索引的内容。会话中的“聊天文件”可联网补齐该会话的可见历史。")
                    .font(.footnote).foregroundStyle(Color.primary)
            }
        }
        .v2GroupedPageSurface().listRowSpacing(0)
        .navigationTitle("文件与存储").navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .accessibilityIdentifier("v2.resources.home")
        .task { await storage.observe() }
    }
}

struct V2ResourceNavigationLabel: View {
    let title: LocalizedStringKey
    let symbol: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 28).accessibilityHidden(true)
            Text(title).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 4)
    }
}

struct V2ResourceLibraryView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @State private var store: V2ResourceLibraryStore
    @State private var selection: V2ResourceSelectionStore
    @State private var showingSelectionExplanation = false
    init(room: RoomID?, service: V2ResourceManagementService) {
        _store = State(initialValue: .init(room: room, service: service))
        _selection = State(initialValue: .init(service: service))
    }
    @ViewBuilder private var pageContent: some View {
        @Bindable var store = store
        Group {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").accessibilityHidden(true)
                    TextField("搜索资源", text: $store.search,
                              prompt: Text("搜索资源").foregroundStyle(Color.primary))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .accessibilityIdentifier("v2.resources.library.search")
                    if !store.search.isEmpty {
                        Button("清除搜索", systemImage: "xmark.circle.fill") { store.search = "" }
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityIdentifier("v2.resources.library.search.clear")
                    }
                }
                .foregroundStyle(Color.primary)
                .frame(minHeight: 44)
            }
            selectionControls
            Section {
                Picker("类型", selection: $store.category) {
                    ForEach(V2ResourceCategory.allCases, id: \.self) { category in
                        Text(V2ResourceFormatting.title(category)).tag(category)
                    }
                }.accessibilityIdentifier("v2.resources.category")
                Toggle("仅查看保留本机", isOn: $store.retainedOnly)
                    .accessibilityIdentifier("v2.resources.retained-only")
            }
            Section {
                if let page = store.content.page {
                    if page.entries.isEmpty {
                        if store.search.isEmpty {
                            ContentUnavailableView("本机暂无已索引资源", systemImage: "folder",
                                description: Text(page.isIndexing ? "正在建立本机索引。" : "联网补齐会话历史，或接收新的附件后会显示在这里。"))
                        } else { ContentUnavailableView.search(text: store.search) }
                    }
                    if store.usesMediaGrid {
                        LazyVGrid(columns: [.init(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 240 : 140), spacing: 12, alignment: .top)], spacing: 20) {
                            ForEach(page.entries, id: \.descriptor.key) { entry in
                                resourceLink(entry)
                            }
                        }.accessibilityIdentifier("v2.resources.media-grid")
                    } else {
                        ForEach(page.entries, id: \.descriptor.key) { entry in
                            resourceLink(entry)
                        }
                    }
                    if page.isIndexing { Label("正在补齐本机索引", systemImage: "arrow.triangle.2.circlepath").font(.footnote).foregroundStyle(.secondary) }
                } else if case .initial = store.content { ProgressView("正在读取本机目录") }
            } header: { Text("本机已索引").foregroundStyle(Color.primary) }
            if case .unavailable(_, let message) = store.content {
                Section { Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.secondary) }
            }
            if let page = store.content.page, store.pageNumber > 1 || page.nextCursor != nil {
                Section {
                    HStack {
                        Button("上一页") { store.previousPage() }.disabled(store.pageNumber == 1)
                            .accessibilityIdentifier("v2.resources.library.previous")
                        Spacer()
                        Text("第 \(store.pageNumber) 页").font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("v2.resources.library.page-number")
                        Spacer()
                        Button("下一页") { store.nextPage() }.disabled(!store.canGoNextPage)
                            .accessibilityIdentifier("v2.resources.library.next")
                    }
                }
            }
            if store.room != nil {
                Section("会话历史") {
                    switch store.cloud {
                    case .idle: Button("补齐可见历史") { store.requestCloud(restart: true) }
                    case .loading: ProgressView("正在读取会话历史")
                    case .available(let more):
                        if more { Button("加载更多会话资源") { store.requestCloud(restart: false) } }
                        else { Label("本次查询已完成", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                        Button("重试会话查询") { store.requestCloud(restart: true) }
                    }
                }
            }
        }
    }

    @ViewBuilder private var selectionControls: some View {
        if let selected = selection.selected {
            Section {
                Button {
                    guard store.hasCurrentPage else { return }
                    selection.selectPage(store.content.page?.entries.map(\.descriptor.key) ?? [])
                } label: { V2ResourceNavigationLabel(title: "全选本页", symbol: "checkmark.circle") }.accessibilityIdentifier("v2.resources.selection.all")
                Button { selection.retain(true) } label: { V2ResourceNavigationLabel(title: "保留本机", symbol: "pin") }
                    .disabled(selected.isEmpty).accessibilityIdentifier("v2.resources.selection.retain")
                Button { selection.retain(false) } label: { V2ResourceNavigationLabel(title: "解除保留本机", symbol: "pin.slash") }
                    .disabled(selected.isEmpty).accessibilityIdentifier("v2.resources.selection.unretain")
                Button { selection.previewCleanup() } label: { V2ResourceNavigationLabel(title: "预览所选缓存清理", symbol: "trash") }
                    .disabled(selected.isEmpty).accessibilityIdentifier("v2.resources.selection.cleanup")
                Button { showingSelectionExplanation = true } label: { V2ResourceNavigationLabel(title: "选择说明", symbol: "info.circle") }
                    .accessibilityIdentifier("v2.resources.selection.explanation")
                if selection.isBusy { ProgressView("正在处理所选资源") }
            } header: { Text("已选择 \(selected.count.formatted()) 项").foregroundStyle(Color.primary) }
        }
        if let feedback = selection.feedback {
            Section {
                Text(feedback).foregroundStyle(Color.primary).accessibilityIdentifier("v2.resources.selection.feedback")
                ForEach(selection.failureDetails, id: \.self) { Text($0).font(.footnote).foregroundStyle(Color.primary) }
            }
        }
    }

    @ViewBuilder private func resourceContent(_ entry: V2ResourceDirectoryEntry) -> some View {
        if store.usesMediaGrid { V2ResourceMediaCell(entry: entry, service: store.service) }
        else { V2ResourceDirectoryRow(entry: entry) }
    }
    @ViewBuilder private func resourceLink(_ entry: V2ResourceDirectoryEntry) -> some View {
        if let values = selection.selected {
            let selected = values.contains(entry.descriptor.key)
            Button {
                guard store.isCurrentPageResource(entry.descriptor.key) else { return }
                selection.toggle(entry.descriptor.key)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(Color.primary).accessibilityHidden(true)
                    resourceContent(entry)
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }.buttonStyle(.plain)
                .accessibilityLabel(Text("选择资源：\((entry.descriptor.displayName.value as NSString).deletingPathExtension)"))
                .accessibilityValue("\((entry.descriptor.displayName.value as NSString).pathExtension.uppercased()) 文件，\(V2ResourceFormatting.bytes(entry.descriptor.byteCount))")
                .accessibilityHint(selected ? "取消选择此资源" : "选择此资源")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("v2.resources.selection.item." + entry.descriptor.key.mediaID.rawValue)
        } else if store.usesMediaGrid {
            NavigationLink(value: V2ResourceRoute.detail(entry.descriptor.key)) { resourceContent(entry) }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("查看\(entry.descriptor.kind == .video ? "视频" : "图片")：\((entry.descriptor.displayName.value as NSString).deletingPathExtension)"))
                .accessibilityIdentifier("v2.resources.item." + entry.descriptor.key.mediaID.rawValue)
        } else {
            NavigationLink(value: V2ResourceRoute.detail(entry.descriptor.key)) { resourceContent(entry) }
                .accessibilityIdentifier("v2.resources.item." + entry.descriptor.key.mediaID.rawValue)
        }
    }

    var body: some View {
        @Bindable var store = store
        Group {
            if store.usesMediaGrid {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) { pageContent.disabled(selection.isBusy) }
                        .padding(.horizontal, 20).padding(.vertical, 12)
                }
            } else { List { pageContent.disabled(selection.isBusy) } }
        }
        .id(dynamicTypeSize)
        .v2GroupedPageSurface().listRowSpacing(0)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(store.room == nil ? "资源" : "聊天文件").navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbarBackground(Color(uiColor: .systemGroupedBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(colorScheme, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(selection.isSelecting ? "完成" : "选择", systemImage: selection.isSelecting ? "checkmark" : "checkmark.circle") { selection.toggleMode() }
                    .labelStyle(.iconOnly).foregroundStyle(Color.primary).frame(minWidth: 44, minHeight: 44)
                    .disabled(selection.isBusy || !store.hasCurrentPage)
                    .accessibilityIdentifier("v2.resources.selection.mode")
            }
            if store.room != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("刷新会话资源", systemImage: "arrow.clockwise") { store.requestCloud(restart: true) }
                }
            }
        }
        .accessibilityIdentifier("v2.resources.library")
        .onChange(of: store.query) { selection.resetForQueryChange() }
        .task(id: selection.command) { if let command = selection.command { await selection.execute(command) } }
        .alert("批量选择说明", isPresented: $showingSelectionExplanation) {
            Button("好", role: .cancel) { }
        } message: {
            Text("选择范围为当前页；切换筛选或页码会结束选择。保留不会自动下载缺失文件。")
        }
        .sheet(item: Binding(get: { selection.cleanup }, set: { if $0 == nil { selection.dismissCleanup() } })) { preview in
            V2ResourceSelectionCleanupView(selection: selection, preview: preview.value)
        }
        .task(id: store.query) { await store.observe() }
        .task(id: store.cloudRequest) { if let request = store.cloudRequest { await store.synchronize(request) } }
    }
}

private struct V2ResourceDirectoryRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: V2ResourceDirectoryEntry
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: V2ResourceFormatting.symbol(entry.descriptor.kind))
                .font(.title2).foregroundStyle(V2ResourceFormatting.color(entry.descriptor.kind))
                .frame(width: 36).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.descriptor.displayName.value).foregroundStyle(Color.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(V2ResourceFormatting.bytes(entry.descriptor.byteCount))
                    if entry.isRetained { Label("保留本机", systemImage: "pin.fill") }
                }.font(.caption).foregroundStyle(Color.primary)
                if entry.referenceCount > 1 { Text("\(entry.referenceCount) 个来源").font(.caption).foregroundStyle(Color.primary) }
            }
        }.padding(.vertical, 4).accessibilityElement(children: .combine)
    }
}

/// Keep the same children when font changes; native LabeledContent can compress
/// one side at accessibility sizes. This row gives both facts their full height.
struct V2ResourceMetadataRow: View {
    let title: String
    let value: String
    var symbol: String? = nil
    var symbolColor: Color = .primary
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        let vertical = dynamicTypeSize.isAccessibilitySize
        let layout = vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 16))
        layout {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let symbol { Image(systemName: symbol).foregroundStyle(symbolColor).accessibilityHidden(true) }
                Text(title).foregroundStyle(Color.primary).fixedSize(horizontal: false, vertical: true)
            }
            Text(value).foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: vertical ? .leading : .trailing)
        }
        .font(.body)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}
