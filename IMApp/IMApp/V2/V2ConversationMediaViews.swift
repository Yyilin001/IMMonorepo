import AVKit
import Foundation
import ImageIO
import IMV2ClientKit
import IMV2Core
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct V2ConversationMediaAttachmentRow: View {
    @Bindable var store: V2ConversationDetailStore
    let message: V2ConversationMessageItem
    let media: V2MediaReference
    let presentation: V2MediaPresentation
    let index: Int
    @State private var isPresentingPlayer = false
    @State private var shareRequested = false
    @State private var shareLease: V2ConversationMediaFileLease?

    var body: some View {
        switch store.mediaDownloadState(for: media) {
        case .notDownloaded:
            downloadButton(title: downloadTitle, systemImage: "arrow.down.circle")
        case .downloading:
            Label("正在下载\(kindLabel)", systemImage: "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("正在下载\(kindLabel)")
                .accessibilityIdentifier(identifier)
        case .downloaded(let downloaded):
            downloadedContent(downloaded)
        case .failed:
            downloadButton(title: "重新下载\(kindLabel)", systemImage: "arrow.clockwise")
        }
    }

    @ViewBuilder
    private func downloadedContent(_ downloaded: V2DownloadedConversationMedia) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if presentation.kind == .image || presentation.kind == .animatedImage {
                V2LocalMediaImagePreview(
                    downloaded: downloaded,
                    accessibilityLabel: kindLabel,
                    accessibilityValue: byteCountLabel,
                    accessibilityIdentifier: identifier + ".preview",
                    onUnavailable: { store.mediaFileUnavailable(downloaded) }
                )
            }
            if presentation.kind == .video || presentation.kind == .audio {
                Button(playbackTitle, systemImage: playbackSymbol) {
                    isPresentingPlayer = true
                }
                .font(.caption)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityHint("播放已下载到此设备的\(kindLabel)")
                .accessibilityIdentifier(identifier + ".play")
                .sheet(isPresented: $isPresentingPlayer) {
                    V2LocalMediaPlayerSheet(
                        downloaded: downloaded,
                        kind: presentation.kind,
                        accessibilityIdentifier: identifier + ".player",
                        onUnavailable: { store.mediaFileUnavailable(downloaded) }
                    )
                }
            }
            Button { shareRequested = true } label: {
                Label("分享\(kindLabel)", systemImage: "square.and.arrow.up")
            }
            .disabled(shareRequested || shareLease != nil)
            .font(.caption)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("分享\(kindLabel)")
            .accessibilityHint("打开系统分享菜单")
            .accessibilityIdentifier(identifier)
            .sheet(item: $shareLease) { lease in
                V2LocalMediaShareSheet(lease: lease, kind: presentation.kind, contentType: presentation.contentType)
            }
            .task(id: shareRequested) {
                guard shareRequested else { return }
                do {
                    let lease = try await downloaded.borrowFile()
                    guard !Task.isCancelled else { await lease.release(); return }
                    shareLease = lease
                } catch is CancellationError { }
                catch V2MediaFileAccessError.unavailable { store.mediaFileUnavailable(downloaded) }
                catch { }
                shareRequested = false
            }
        }
        .onDisappear { shareRequested = false; shareLease = nil }
    }

    @ViewBuilder
    private func downloadButton(title: String, systemImage: String) -> some View {
        Button(title, systemImage: systemImage) {
            Task { await store.downloadMedia(media, from: message) }
        }
        .font(.caption)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityHint("重新验证权限后下载\(kindLabel)到此设备，\(byteCountLabel)")
        .accessibilityIdentifier(identifier)
    }

    private var kindLabel: String {
        switch presentation.kind {
        case .image: "图片"
        case .animatedImage: "动图"
        case .video: "视频"
        case .audio: "音频"
        case .file: "文件"
        }
    }

    private var downloadTitle: String {
        "下载\(kindLabel)"
    }

    private var byteCountLabel: String {
        presentation.byteCount > 0
            ? ByteCountFormatter.string(fromByteCount: presentation.byteCount, countStyle: .file)
            : "大小未知"
    }

    private var identifier: String {
        "v2.message.media." + message.id + "." + String(index)
    }

    private var playbackTitle: String { presentation.kind == .video ? "播放视频" : "播放音频" }
    private var playbackSymbol: String { presentation.kind == .video ? "play.rectangle" : "play.circle" }
}

/// 本地媒体图片预览。
///
/// 即便会话行很小，下载到的图片也可能达到数千万像素。
/// 因此在 MainActor 之外解码并降采样，且只保留有界的缩略图缓存，
/// 而不是在 `body` 中反复重新打开文件。
private struct V2LocalMediaImagePreview: View {
    let downloaded: V2DownloadedConversationMedia
    let accessibilityLabel: String
    let accessibilityValue: String
    let accessibilityIdentifier: String
    let onUnavailable: @MainActor () -> Void
    @Environment(\.v2MediaThumbnailCache) private var thumbnailCache
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .frame(maxWidth: 260, maxHeight: 320)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier(accessibilityIdentifier)
        .task(id: downloaded) {
            image = nil
            do {
                let lease = try await downloaded.borrowFile()
                let result = await thumbnailCache?.thumbnail(fileURL: lease.fileURL, maximumPixelSize: 960)
                await lease.release()
                guard !Task.isCancelled else { return }
                image = result?.image
            } catch V2MediaFileAccessError.unavailable {
                guard !Task.isCancelled else { return }
                onUnavailable()
            } catch { }
        }
    }
}

/// Immutable decoded UIImage; the cache never mutates it after publication.
struct V2SendableImage: @unchecked Sendable {
    let image: UIImage
}

private struct V2MediaThumbnailCacheKey: EnvironmentKey {
    static let defaultValue: V2LocalMediaThumbnailCache? = nil
}

extension EnvironmentValues {
    var v2MediaThumbnailCache: V2LocalMediaThumbnailCache? {
        get { self[V2MediaThumbnailCacheKey.self] }
        set { self[V2MediaThumbnailCacheKey.self] = newValue }
    }
}

/// 单次账号激活拥有的有界缩略图缓存。
///
/// 只接受受管目录内的本地文件；同一尺寸与路径共享解码任务，最多保留 24 项。
/// 解码不在 MainActor 执行。关闭等待任务并拒绝迟到结果，避免旧图片重新进入缓存。
actor V2LocalMediaThumbnailCache {
    typealias Decoder = @Sendable (URL, Int) async -> V2SendableImage?
    private let directory: URL
    private let decode: Decoder
    private var isClosed = false

    init(directory: URL, decode: @escaping Decoder = V2LocalMediaThumbnailCache.decodeImage) {
        self.directory = directory.standardizedFileURL
        self.decode = decode
    }

    /// 终止缓存，释放已存图片并取消、等待解码任务。
    ///
    /// ImageIO 同步解码未必立即响应取消；结束后的结果不会重新缓存或返回给旧调用者。
    func close() async {
        isClosed = true
        images.removeAll()
        costs.removeAll(); decodedBytes = 0
        recency.removeAll()
        let tasks = Array(inFlight.values)
        for task in tasks { task.cancel() }
        for task in tasks { _ = await task.value }
        inFlight.removeAll()
    }

    private struct Key: Hashable, Sendable {
        let path: String
        let maximumPixelSize: Int
    }

    private let maximumEntryCount = 256
    private let maximumDecodedBytes = 32 * 1_024 * 1_024
    private var decodedBytes = 0
    private var reservedDecodeBytes = 0
    private var costs: [Key: Int] = [:]
    private var images: [Key: V2SendableImage] = [:]
    private var recency: [Key] = []
    private var inFlight: [Key: Task<V2SendableImage?, Never>] = [:]

    /// 读取或生成本地文件的缩略图。
    ///
    /// - Parameters:
    ///   - fileURL: 账号受管目录内的本地文件地址。
    ///   - maximumPixelSize: ImageIO 下采样的最大像素边长，必须为正。
    /// - Returns: 有效缩略图；关闭、取消、目录不匹配或解码失败时为 nil。
    ///   同一请求的一个等待者取消不会直接取消其他等待者共享的解码任务。
    func thumbnail(fileURL: URL, maximumPixelSize: Int) async -> V2SendableImage? {
        let fileURL = fileURL.standardizedFileURL
        guard !isClosed, !Task.isCancelled, maximumPixelSize > 0, maximumPixelSize <= 2_048,
              fileURL.isFileURL,
              fileURL.pathComponents.starts(with: directory.pathComponents),
              fileURL.pathComponents.count > directory.pathComponents.count else { return nil }
        let key = Key(path: fileURL.path, maximumPixelSize: maximumPixelSize)
        if let cached = images[key] {
            touch(key)
            return cached
        }
        if let existing = inFlight[key] {
            let result = await existing.value
            return isClosed || Task.isCancelled ? nil : result
        }
        guard inFlight.count < 2 else { return nil }
        let reservation = ((maximumPixelSize * 4 + 63) / 64) * 64 * maximumPixelSize
        while decodedBytes + reservedDecodeBytes + reservation > maximumDecodedBytes, let oldest = recency.first {
            recency.removeFirst(); images.removeValue(forKey: oldest)
            decodedBytes -= costs.removeValue(forKey: oldest) ?? 0
        }
        guard decodedBytes + reservedDecodeBytes + reservation <= maximumDecodedBytes else { return nil }
        reservedDecodeBytes += reservation
        defer { reservedDecodeBytes -= reservation }
        // The cache owns this shared decode, which must not inherit a view's
        // actor executor or cancellation. close() cancels and drains it.
        let decode = self.decode
        let task = Task.detached(priority: .utility) { await decode(fileURL, maximumPixelSize) }
        inFlight[key] = task
        let result = await task.value
        inFlight.removeValue(forKey: key)
        guard !isClosed else { return nil }
        if let result {
            let cost = result.image.cgImage.map { $0.bytesPerRow * $0.height } ?? reservation
            guard cost <= reservation else { return nil }
            images[key] = result
            costs[key] = cost
            decodedBytes += cost
            touch(key)
            while recency.count > maximumEntryCount, let oldest = recency.first {
                recency.removeFirst()
                images.removeValue(forKey: oldest)
                decodedBytes -= costs.removeValue(forKey: oldest) ?? 0
            }
        }
        return Task.isCancelled ? nil : result
    }

    nonisolated private static func decodeImage(fileURL: URL, maximumPixelSize: Int) async -> V2SendableImage? {
        guard !Task.isCancelled else { return nil }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        guard !Task.isCancelled else { return nil }
        return V2SendableImage(image: UIImage(cgImage: thumbnail))
    }

    private func touch(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}

/// 保护隐私的安全链接卡片。
///
/// 渲染消息时绝不抓取远端网页、图片或站点图标；
/// 是否把已校验的 HTTP(S) URL 交给系统浏览器，完全由用户显式决定。
struct V2SafeLinkPreview: View {
    let url: URL
    let messageID: String

    var body: some View {
        Link(destination: url) {
            Label(url.host ?? "网页链接", systemImage: "link")
                .lineLimit(1)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityLabel("打开链接：\(url.host ?? "网页链接")")
        .accessibilityHint("将在系统浏览器中打开；不会自动加载网页预览")
        .accessibilityIdentifier("v2.message.link.\(messageID).\(url.host ?? "unknown")")
    }
}

@MainActor
struct V2LocalMediaPlayerSheet: View {
    let downloaded: V2DownloadedConversationMedia
    let kind: V2MediaPresentation.Kind
    let accessibilityIdentifier: String
    let onUnavailable: @MainActor () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var fileLease: V2ConversationMediaFileLease?

    var body: some View {
        NavigationStack {
            Group {
                if kind == .video, let player {
                    VideoPlayer(player: player)
                        .accessibilityLabel("视频播放器")
                } else {
                    VStack(spacing: 20) {
                        Image(systemName: "waveform")
                            .font(.system(size: 44))
                            .accessibilityHidden(true)
                        Button(isPlaying ? "暂停音频" : "播放音频", systemImage: isPlaying ? "pause.circle.fill" : "play.circle.fill") {
                            togglePlayback()
                        }
                        .font(.title2)
                        .disabled(player == nil)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityValue(isPlaying ? "正在播放" : "已暂停")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .accessibilityIdentifier(accessibilityIdentifier)
            .navigationTitle(kind == .video ? "视频" : "音频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { stopPlayback(); return }
            do {
                let lease = try await downloaded.borrowFile()
                guard !Task.isCancelled else { await lease.release(); return }
                stopPlayback()
                fileLease = lease
                player = AVPlayer(url: lease.fileURL)
            } catch V2MediaFileAccessError.unavailable {
                guard !Task.isCancelled else { return }
                onUnavailable(); dismiss()
            } catch { }
        }
        .onDisappear { stopPlayback() }
    }

    private func stopPlayback() {
        player?.pause()
        player?.currentItem?.asset.cancelLoading()
        player?.replaceCurrentItem(with: nil)
        isPlaying = false; player = nil
        let lease = fileLease; fileLease = nil
        Task { await lease?.release() }
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }
}

/// A system share has a file lifetime independent from the source list row.
/// The coordinator retains it through completion or actual controller dismissal.
struct V2LocalMediaShareSheet: UIViewControllerRepresentable {
    let lease: V2ConversationMediaFileLease
    let kind: V2MediaPresentation.Kind
    let contentType: String
    func makeCoordinator() -> Coordinator { Coordinator(lease: lease) }
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let configuration = UIActivityItemsConfiguration(itemProviders: [Self.itemProvider(lease: lease, kind: kind, contentType: contentType)])
        let title = Self.title(for: kind)
        configuration.metadataProvider = { key in key == .title ? title : nil }
        let controller = UIActivityViewController(activityItemsConfiguration: configuration)
        let coordinator = context.coordinator
        controller.completionWithItemsHandler = { _, _, _, _ in coordinator.finish() }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
    static func itemProvider(lease: V2ConversationMediaFileLease, kind: V2MediaPresentation.Kind, contentType: String) -> NSItemProvider {
        let type = UTType(mimeType: contentType) ?? .data
        let provider = NSItemProvider()
        provider.suggestedName = title(for: kind) + "." + (type.preferredFilenameExtension ?? "dat")
        // The system copies this representation. Never export a signed URL or
        // offer in-place access to the app's managed cache namespace.
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
            completion(lease.fileURL, false, nil)
            return nil
        }
        return provider
    }
    private static func title(for kind: V2MediaPresentation.Kind) -> String {
        switch kind { case .image: "图片"; case .animatedImage: "动图"; case .video: "视频"; case .audio: "音频"; case .file: "文件" }
    }
    static func dismantleUIViewController(_ controller: UIActivityViewController, coordinator: Coordinator) {
        // An account/page removal also terminates the presented controller.
        // Do not release merely because the source row has disappeared.
        if controller.presentingViewController != nil {
            controller.dismiss(animated: false) { coordinator.finish() }
        } else { coordinator.finish() }
    }
    @MainActor final class Coordinator {
        private var lease: V2ConversationMediaFileLease?
        init(lease: V2ConversationMediaFileLease) { self.lease = lease }
        func finish() {
            let retained = lease; lease = nil
            Task { await retained?.release() }
        }
    }
}
