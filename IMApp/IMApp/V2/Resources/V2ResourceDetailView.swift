import IMV2ClientKit
import IMV2Core
import QuickLook
import SwiftUI
import UIKit

struct V2ResourceDetailView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var store: V2ResourceDetailStore
    @State private var showingUsageExplanation = false
    @Environment(\.v2ResourceNavigation) private var navigation
    init(key: V2ResourceKey, service: V2ResourceManagementService) { _store = State(initialValue: .init(key: key, service: service)) }
    var body: some View {
        @Bindable var store = store
        List {
            switch store.content {
            case .initial: ProgressView("正在读取资源资料")
            case .unavailable(let message):
                ContentUnavailableView {
                    Label("资源不可用", systemImage: "doc.badge.ellipsis")
                } description: { Text(message) } actions: {
                    Button("重新读取", systemImage: "arrow.clockwise") { store.retryRead() }
                        .disabled(store.isWorking)
                        .accessibilityIdentifier("v2.resources.detail.retry-read")
                }
            case .available(let snapshot):
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: V2ResourceFormatting.symbol(snapshot.descriptor.kind))
                            .font(.largeTitle).foregroundStyle(V2ResourceFormatting.color(snapshot.descriptor.kind)).accessibilityHidden(true)
                        Text(snapshot.descriptor.displayName.value).font(.title3.weight(.semibold))
                            .contextMenu {
                                Button("复制文件名", systemImage: "doc.on.doc") { UIPasteboard.general.string = snapshot.descriptor.displayName.value }
                            }
                            .accessibilityAction(named: Text("复制文件名")) { UIPasteboard.general.string = snapshot.descriptor.displayName.value }
                            .accessibilityLabel("文件名称").accessibilityValue(snapshot.descriptor.displayName.value)
                        Text(V2ResourceFormatting.bytes(snapshot.descriptor.byteCount)).foregroundStyle(Color.primary)
                            .accessibilityLabel("文件大小").accessibilityValue(V2ResourceFormatting.bytes(snapshot.descriptor.byteCount))
                    }.padding(.vertical, 12)
                    V2ResourceMetadataRow(title: "类型", value: snapshot.descriptor.contentType)
                    if let width = snapshot.descriptor.pixelWidth, let height = snapshot.descriptor.pixelHeight {
                        V2ResourceMetadataRow(title: snapshot.descriptor.kind == .video ? "视频尺寸" : "原图尺寸", value: "\(width) × \(height) 像素")
                            .accessibilityIdentifier("v2.resources.image-dimensions")
                    }
                    if snapshot.descriptor.kind == .audio || snapshot.descriptor.kind == .video,
                       let duration = snapshot.descriptor.durationMilliseconds, duration > 0 {
                        V2ResourceMetadataRow(title: "时长", value: V2ResourceFormatting.duration(duration))
                            .accessibilityIdentifier("v2.resources.duration")
                    }
                    V2ResourceMetadataRow(title: "本机状态", value: localStatus)
                }
                Section {
                    if let original = store.original, original.localState == .needsDownload || original.localState == .invalid {
                        Button("下载文件", systemImage: "arrow.down.circle") { store.download() }
                            .accessibilityHint("先保存下载请求，稍后由账号任务执行")
                            .accessibilityIdentifier("v2.resources.download")
                    }
                    if store.queuedTransfer != nil {
                        NavigationLink("查看传输任务", value: V2ResourceRoute.transfers)
                            .accessibilityIdentifier("v2.resources.download.tasks")
                    }
                    Button("查看文件", systemImage: "doc.text.magnifyingglass") { store.present(.preview) }
                        .accessibilityHint("验证当前权限，必要时先下载文件")
                        .accessibilityIdentifier("v2.resources.preview")
                    Button("分享文件", systemImage: "square.and.arrow.up") { store.present(.share) }
                        .accessibilityIdentifier("v2.resources.share")
                    if let original = store.original {
                        Button(original.isRetained ? "解除保留本机" : "保留本机", systemImage: original.isRetained ? "pin.slash" : "pin") {
                            store.setRetained(!original.isRetained)
                        }.accessibilityIdentifier("v2.resources.retain")
                    }
                    Button("使用与保留说明", systemImage: "info.circle") { showingUsageExplanation = true }
                        .accessibilityIdentifier("v2.resources.usage-explanation")
                } header: { Text("使用文件").font(.headline).foregroundStyle(Color.primary) }
                    .disabled(store.isWorking || !store.hasCurrentDetails)
                if store.isWorking { ProgressView("正在准备资源") }
                if let feedback = store.feedback { Section { Text(feedback).font(.footnote).foregroundStyle(.secondary) } }
                Section {
                    ForEach(snapshot.sources, id: \.self) { source in
                        Button {
                            navigation?.showConversation(roomID: source.location.roomID.rawValue, messageID: source.location.messageID.rawValue)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "bubble.left").foregroundStyle(Color.primary).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("在会话中查看").foregroundStyle(Color.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let date = source.createdAt {
                                        Text(date, format: .dateTime.month().day().hour().minute())
                                            .font(.caption).foregroundStyle(Color.primary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.primary).accessibilityHidden(true)
                            }.padding(.vertical, 4)
                                .accessibilityElement(children: .combine)
                        }.disabled(navigation == nil)
                            .accessibilityIdentifier("v2.resources.source." + source.location.messageID.rawValue)
                    }
                    if snapshot.nextSourceCursor != nil {
                        Button("更多来源") { store.nextSources() }.disabled(!store.canGoNextSources)
                    }
                    if store.sourceCursor != nil { Button("返回最初来源") { store.firstSources() } }
                } header: { Text("来源消息").font(.headline).foregroundStyle(Color.primary) }
                    .disabled(!store.hasCurrentDetails)
                if let message = store.readFailure {
                    Section {
                        Text(message + " 当前显示上次读取的资料，重新读取成功后可继续操作文件。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("重新读取", systemImage: "arrow.clockwise") { store.retryRead() }
                            .disabled(store.isWorking)
                            .accessibilityIdentifier("v2.resources.detail.retry-read")
                    }
                }
            }
        }
        .id(dynamicTypeSize)
        .v2GroupedPageSurface().listRowSpacing(0)
        .navigationTitle("资源详情").navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(uiColor: .systemGroupedBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .accessibilityIdentifier("v2.resources.detail")
        .task(id: store.sourceCursor) { await store.observe() }
        .task(id: store.command) { if let command = store.command { await store.execute(command) } }
        .alert("使用与保留说明", isPresented: $showingUsageExplanation) {
            Button("好", role: .cancel) { }
        } message: {
            Text("查看和分享前会验证当前访问权限。保留本机可防止自动清理，但不会获得永久访问权限。")
        }
        .sheet(item: $store.presentation) { item in
            switch item.purpose {
            case .preview:
                NavigationStack {
                    V2ResourceQuickLook(presentation: item)
                        .navigationTitle(item.descriptor.displayName.value).navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { store.presentation = nil } } }
                }
            case .share:
                V2LocalMediaShareSheet(lease: item.lease)
            }
        }
    }
    private var localStatus: String {
        guard let variant = store.original else { return "尚未下载" }
        switch variant.localState {
        case .needsDownload: return variant.isRetained ? "已保留，等待下载" : "尚未下载"
        case .invalid: return "文件需重新下载"
        case .available: return variant.isRetained ? "已下载并保留本机" : "已下载"
        }
    }
}

/// The platform controller retains its byte owner until UIKit releases the
/// actual preview hierarchy, including any dismissal transition.
struct V2ResourceQuickLook: UIViewControllerRepresentable {
    let presentation: V2ResourcePresentation
    func makeCoordinator() -> Coordinator { Coordinator(presentation: presentation) }
    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.owner = context.coordinator
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: Controller, context: Context) { }
    static func dismantleUIViewController(_ controller: Controller, coordinator: Coordinator) {
        controller.dataSource = nil
        // owner remains with the controller until the actual UI consumer dies.
    }
    final class Controller: QLPreviewController { var owner: Coordinator? }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        private let presentation: V2ResourcePresentation
        private let item: Item
        init(presentation: V2ResourcePresentation) { self.presentation = presentation; item = Item(presentation: presentation) }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { item }
    }
    final class Item: NSObject, QLPreviewItem {
        let previewItemURL: URL?
        let previewItemTitle: String?
        init(presentation: V2ResourcePresentation) {
            previewItemURL = presentation.lease.fileURL; previewItemTitle = presentation.descriptor.displayName.value
        }
    }
}
