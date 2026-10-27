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
    @State private var previewRequested = false
    @State private var preview: V2ResourcePresentation?
    @State private var fileActionFailure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
        if presentation.kind == .file, let descriptor = presentation.resourceDescriptor {
            Label(descriptor.displayName.value, systemImage: "doc")
                .font(.subheadline).lineLimit(2)
                .accessibilityIdentifier(identifier + ".name")
            Text(byteCountLabel).font(.caption).foregroundStyle(secondaryContentColor)
        }
        if presentation.kind == .image || presentation.kind == .animatedImage {
            imageAttachment
        } else {
        switch store.mediaDownloadState(for: media) {
        case .notDownloaded:
            downloadButton(title: downloadTitle, systemImage: "arrow.down.circle")
        case .downloading:
            Label("正在下载\(kindLabel)", systemImage: "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(secondaryContentColor)
                .accessibilityLabel("正在下载\(kindLabel)")
                .accessibilityIdentifier(identifier)
        case .downloaded(let downloaded):
            downloadedContent(downloaded)
        case .failed:
            downloadButton(title: "重新下载\(kindLabel)", systemImage: "arrow.clockwise")
        }
        }
        }
        .foregroundStyle(contentColor)
        .tint(contentColor)
        .task(id: [message.id, String(message.revision), media.mediaID.rawValue].joined(separator: ":")) {
            if presentation.kind == .image || presentation.kind == .animatedImage {
                await store.loadImagePreview(media, from: message)
            } else { await store.restoreCachedMedia(media, from: message) }
        }
        .onDisappear { previewRequested = false; preview = nil }
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
            if presentation.kind == .file, let descriptor = presentation.resourceDescriptor {
                Button("查看文件", systemImage: "doc.text.magnifyingglass") { previewRequested = true }
                    .font(.caption).frame(minWidth: 44, minHeight: 44)
                    .disabled(previewRequested || preview != nil)
                    .accessibilityIdentifier(identifier + ".open")
                    .sheet(item: $preview) { item in
                        NavigationStack {
                            V2ResourceQuickLook(presentation: item)
                                .navigationTitle(descriptor.displayName.value).navigationBarTitleDisplayMode(.inline)
                                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { preview = nil } } }
                        }
                    }
                    .task(id: previewRequested) {
                        guard previewRequested else { return }
                        fileActionFailure = nil
                        do {
                            let original = try await downloaded.borrowFile()
                            let lease: V2ConversationMediaFileLease
                            do {
                                if let ext = UTType(mimeType: presentation.contentType)?.preferredFilenameExtension {
                                    lease = try await original.forPresentation(fileExtension: ext.lowercased())
                                    await original.release()
                                } else { lease = original }
                            } catch { await original.release(); throw error }
                            guard !Task.isCancelled else { await lease.release(); return }
                            preview = .init(purpose: .preview, descriptor: descriptor, lease: lease)
                        } catch is CancellationError { }
                        catch V2MediaFileAccessError.unavailable { store.mediaFileUnavailable(downloaded) }
                        catch { fileActionFailure = V2ResourceFailure.message(error) }
                        previewRequested = false
                    }
            }
            if let fileActionFailure {
                Text(fileActionFailure).font(.caption).foregroundStyle(secondaryContentColor)
                    .accessibilityIdentifier(identifier + ".feedback")
            }
        }
        .onDisappear { previewRequested = false; preview = nil }
    }

    private var imageDimensions: V2LocalResourceImageDimensions? {
        guard let width = presentation.resourceDescriptor?.pixelWidth,
              let height = presentation.resourceDescriptor?.pixelHeight else { return nil }
        return try? .init(width: width, height: height)
    }

    private var imageAttachment: some View {
        VStack(alignment: .leading, spacing: 6) {
            V2ConversationImageLayout(dimensions: imageDimensions) {
                if case .downloaded(let file) = store.imagePreviewStates[media.mediaID] {
                    V2LocalMediaImagePreview(downloaded: file, accessibilityLabel: kindLabel,
                        accessibilityValue: byteCountLabel, accessibilityIdentifier: identifier + ".preview",
                        initialImage: store.initialImagePreviews[media.mediaID]?.image,
                        maximumPixelSize: 1280, loadOriginal: { await store.originalImage(media, from: message) },
                        onUnavailable: { store.imagePreviewUnavailable(file) })
                } else if store.imagePreviewStates[media.mediaID] == .failed {
                    V2ConversationImageAvailabilityPlaceholder(availability: .retry,
                        download: { Task { await store.loadImagePreview(media, from: message) } })
                        .accessibilityIdentifier(identifier)
                } else {
                    V2ConversationMediaPlaceholder().accessibilityLabel("正在加载缩略图")
                }
            }
            .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            if let fileActionFailure {
                Text(fileActionFailure).font(.caption).foregroundStyle(secondaryContentColor)
                    .accessibilityIdentifier(identifier + ".feedback")
            }
        }
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

    private var contentColor: Color { message.isOutgoing ? .white : .primary }
    private var secondaryContentColor: Color { message.isOutgoing ? .white.opacity(0.85) : .secondary }

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
struct V2ConversationMediaPlaceholder: View {
    var systemImage = "photo"

    var body: some View {
        Image(systemName: systemImage)
            .font(.title2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.secondary.opacity(0.12))
            .accessibilityLabel("图片占位")
    }
}

/// Not knowing whether an authorized local copy exists is a lookup phase, not
/// a cache miss. Every phase keeps the same image-shaped, text-free surface.
struct V2ConversationImageAvailabilityPlaceholder: View {
    enum Availability: CaseIterable { case checkingCache, needsDownload, retry }
    let availability: Availability
    let download: () -> Void

    var body: some View {
        if availability == .checkingCache {
            V2ConversationMediaPlaceholder()
                .accessibilityLabel("正在读取本机图片")
        } else {
            Button(action: download) {
                V2ConversationMediaPlaceholder()
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: availability == .retry ? "arrow.clockwise.circle.fill" : "arrow.down.circle.fill")
                            .font(.title2)
                            .padding(10)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(availability == .retry ? "重新下载图片" : "下载图片")
            .accessibilityHint("下载完成后可点击查看大图")
        }
    }
}

/// The viewer owns decoded pixels only. File access stays in the existing lease
/// and bounded thumbnail cache, shared by pending and accepted message images.
struct V2ZoomableConversationImage: View {
    let image: UIImage
    var loadOriginal: (@MainActor () async -> UIImage?)? = nil
    @Namespace private var transition
    @State private var selection: Selection?

    private struct Selection: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    var body: some View {
        Button { selection = Selection(image: image) } label: {
            Image(uiImage: image).resizable().scaledToFit()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("查看大图")
        .accessibilityIdentifier("v2.message.image.open")
        .matchedTransitionSource(id: "image", in: transition)
        .fullScreenCover(item: $selection) { selected in
            NavigationStack {
                V2ConversationOriginalImageView(preview: selected.image, loadOriginal: loadOriginal)
                    .ignoresSafeArea()
                    .background(.black)
                    .navigationTitle("图片")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarColorScheme(.dark, for: .navigationBar)
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("关闭", systemImage: "xmark") { selection = nil }
                                .accessibilityIdentifier("v2.message.image.close")
                        }
                    }
            }
            .navigationTransition(.zoom(sourceID: "image", in: transition))
        }
    }
}

/// Open immediately with the thumbnail. Original transfer belongs to this
/// presentation's task and never changes the chat row's dimensions or pixels.
private struct V2ConversationOriginalImageView: View {
    let preview: UIImage
    let loadOriginal: (@MainActor () async -> UIImage?)?
    @State private var original: UIImage?
    @State private var failed = false
    @State private var retry = 0
    var body: some View {
        V2ConversationImageZoomView(image: original ?? preview)
            .overlay(alignment: .bottom) {
                if failed { Button("重试加载原图") { retry += 1 }.padding().tint(.white) }
            }
            .task(id: retry) {
                guard let loadOriginal else { return }
                failed = false
                let value = await loadOriginal()
                guard !Task.isCancelled else { return }
                original = value; failed = value == nil
            }
    }
}

struct V2ConversationImageZoomView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ImageScrollView {
        let view = ImageScrollView()
        view.delegate = context.coordinator
        view.imageView.image = image
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        return view
    }

    func updateUIView(_ view: ImageScrollView, context: Context) {
        guard view.imageView.image !== image else { return }
        view.imageView.image = image
        view.resetImageLayout()
    }

    static func dismantleUIView(_ view: ImageScrollView, coordinator: Coordinator) {
        view.delegate = nil
        for gesture in view.gestureRecognizers ?? [] where gesture is UITapGestureRecognizer {
            view.removeGestureRecognizer(gesture)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? ImageScrollView)?.imageView
        }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? ImageScrollView)?.centerImage()
        }
        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? ImageScrollView else { return }
            if view.zoomScale > view.minimumZoomScale + 0.01 {
                view.setZoomScale(view.minimumZoomScale, animated: true)
            } else {
                let scale = min(view.maximumZoomScale, 2.5)
                let point = gesture.location(in: view.imageView)
                let size = CGSize(width: view.bounds.width / scale, height: view.bounds.height / scale)
                view.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                     width: size.width, height: size.height), animated: true)
            }
        }
    }

    final class ImageScrollView: UIScrollView {
        let imageView = UIImageView()
        private var fittedBounds: CGSize = .zero

        init() {
            super.init(frame: .zero)
            backgroundColor = .black
            minimumZoomScale = 1
            maximumZoomScale = 5
            showsHorizontalScrollIndicator = false
            showsVerticalScrollIndicator = false
            contentInsetAdjustmentBehavior = .never
            imageView.contentMode = .scaleAspectFit
            imageView.isAccessibilityElement = true
            imageView.accessibilityLabel = "图片"
            addSubview(imageView)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.size != fittedBounds else { return }
            resetImageLayout()
        }

        func resetImageLayout() {
            guard bounds.width > 0, bounds.height > 0, let image = imageView.image,
                  image.size.width > 0, image.size.height > 0 else { return }
            fittedBounds = bounds.size
            setZoomScale(1, animated: false)
            let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            imageView.frame = CGRect(origin: .zero, size: CGSize(width: image.size.width * scale, height: image.size.height * scale))
            contentSize = imageView.bounds.size
            centerImage()
        }

        func centerImage() {
            contentInset = UIEdgeInsets(top: max(0, (bounds.height - contentSize.height) / 2), left: max(0, (bounds.width - contentSize.width) / 2),
                                       bottom: max(0, (bounds.height - contentSize.height) / 2), right: max(0, (bounds.width - contentSize.width) / 2))
        }
    }
}

struct V2ConversationImageLayout: Layout {
    let dimensions: V2LocalResourceImageDimensions?

    static func size(dimensions: V2LocalResourceImageDimensions?, availableWidth: CGFloat = 260) -> CGSize {
        let width = min(260, availableWidth.isFinite ? max(1, availableWidth) : 260)
        let ratio = dimensions.map { CGFloat($0.width) / CGFloat($0.height) } ?? (4.0 / 3.0)
        let height = min(320, width / ratio)
        return .init(width: height * ratio, height: height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        Self.size(dimensions: dimensions, availableWidth: proposal.width ?? 260)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews { view.place(at: bounds.origin, proposal: .init(bounds.size)) }
    }
}

struct V2LocalMediaImagePreview: View {
    let downloaded: V2DownloadedConversationMedia
    let accessibilityLabel: String
    let accessibilityValue: String
    let accessibilityIdentifier: String
    let onUnavailable: @MainActor () -> Void
    let maximumPixelSize: Int
    let loadOriginal: (@MainActor () async -> UIImage?)?
    @Environment(\.v2MediaThumbnailCache) private var thumbnailCache
    @State private var image: UIImage?
    @State private var imageFile: V2DownloadedConversationMedia?

    init(downloaded: V2DownloadedConversationMedia, accessibilityLabel: String, accessibilityValue: String,
         accessibilityIdentifier: String, initialImage: UIImage? = nil, maximumPixelSize: Int = 2048,
         loadOriginal: (@MainActor () async -> UIImage?)? = nil, onUnavailable: @escaping @MainActor () -> Void) {
        self.downloaded = downloaded
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
        self.accessibilityIdentifier = accessibilityIdentifier
        self.onUnavailable = onUnavailable
        self.maximumPixelSize = maximumPixelSize; self.loadOriginal = loadOriginal
        _image = State(initialValue: initialImage)
        _imageFile = State(initialValue: initialImage == nil ? nil : downloaded)
    }

    var body: some View {
        Group {
            if let image {
                V2ZoomableConversationImage(image: image, loadOriginal: loadOriginal)
            } else {
                V2ConversationMediaPlaceholder()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier(accessibilityIdentifier)
        .task(id: downloaded) {
            guard imageFile != downloaded || image == nil else { return }
            image = nil
            do {
                let lease = try await downloaded.borrowFile()
                let result = await thumbnailCache?.thumbnail(fileURL: lease.fileURL, maximumPixelSize: maximumPixelSize)
                await lease.release()
                guard !Task.isCancelled else { return }
                image = result?.image
                imageFile = downloaded
            } catch V2MediaFileAccessError.unavailable {
                guard !Task.isCancelled else { return }
                image = nil
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
/// 只接受当前账号持久/缓存根内的本地文件；同一类型、尺寸与路径共享解码，
/// 最多缓存256项和32MiB已解码像素，两个解码任务及16个有界等待者。
/// 解码不在 MainActor 执行。关闭等待任务并拒绝迟到结果，避免旧图片重新进入缓存。
actor V2LocalMediaThumbnailCache {
    enum Kind: Hashable, Sendable { case image, video }
    typealias Decoder = @Sendable (URL, Int) async -> V2SendableImage?
    private let directories: [URL]
    private let decode: Decoder
    private var isClosed = false

    init(directories: [URL], decode: @escaping Decoder = V2LocalMediaThumbnailCache.decodeImage) {
        self.directories = directories.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        self.decode = decode
    }

    /// 终止缓存，释放已存图片并取消、等待解码任务。
    ///
    /// ImageIO 同步解码未必立即响应取消；结束后的结果不会重新缓存或返回给旧调用者。
    func close() async {
        isClosed = true
        for waiter in decodeWaiters.values { waiter.finish() }
        decodeWaiters.removeAll()
        images.removeAll(); inputAliases.removeAll()
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
        let kind: Kind
    }

    private let maximumEntryCount = 256
    private let maximumDecodedBytes = 32 * 1_024 * 1_024
    private var decodedBytes = 0
    private var reservedDecodeBytes = 0
    private var costs: [Key: Int] = [:]
    private var images: [Key: V2SendableImage] = [:]
    private var inputAliases: [Key: Key] = [:]
    private var recency: [Key] = []
    private var inFlight: [Key: Task<V2SendableImage?, Never>] = [:]
    private var decodeWaiters: [UUID: AsyncStream<Void>.Continuation] = [:]
    var decodeCounts: (active: Int, waiting: Int) { (inFlight.count, decodeWaiters.count) }

    /// Looks up previously decoded pixels without touching the filesystem,
    /// joining a decoder, or starting work. Callers must first validate the
    /// account's current message-scoped preview authorization.
    func cachedThumbnail(fileURL: URL, maximumPixelSize: Int) -> V2SendableImage? {
        guard !isClosed, !Task.isCancelled else { return nil }
        let input = Key(path: fileURL.standardizedFileURL.path, maximumPixelSize: maximumPixelSize, kind: .image)
        let key = inputAliases[input] ?? input
        guard let image = images[key] else { return nil }
        touch(key)
        return image
    }

    /// 读取或生成本地文件的缩略图。
    ///
    /// - Parameters:
    ///   - fileURL: 账号受管目录内的本地文件地址。
    ///   - maximumPixelSize: ImageIO 下采样的最大像素边长，必须为正。
    /// - Returns: 有效缩略图；关闭、取消、目录不匹配或解码失败时为 nil。
    ///   同一请求的一个等待者取消不会直接取消其他等待者共享的解码任务。
    func thumbnail(fileURL: URL, maximumPixelSize: Int, kind: Kind = .image) async -> V2SendableImage? {
        guard fileURL.isFileURL else { return nil }
        let input = Key(path: fileURL.standardizedFileURL.path, maximumPixelSize: maximumPixelSize, kind: kind)
        let fileURL = Self.canonicalFileURL(fileURL)
        guard !isClosed, !Task.isCancelled, maximumPixelSize > 0, maximumPixelSize <= 2_048,
              fileURL.isFileURL,
              directories.contains(where: { fileURL.pathComponents.starts(with: $0.pathComponents) && fileURL.pathComponents.count > $0.pathComponents.count }) else { return nil }
        let key = Key(path: fileURL.path, maximumPixelSize: maximumPixelSize, kind: kind)
        // Only validated inputs receive an alias; bounded independently of pixels.
        if inputAliases.count >= maximumEntryCount, let oldest = inputAliases.keys.first { inputAliases[oldest] = nil }
        inputAliases[input] = key
        if let cached = images[key] {
            touch(key)
            return cached
        }
        if let existing = inFlight[key] {
            let result = await existing.value
            return isClosed || Task.isCancelled ? nil : result
        }
        while inFlight.count >= 2 {
            guard decodeWaiters.count < 16 else { return nil }
            let id = UUID(), signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            decodeWaiters[id] = signal.continuation
            for await _ in signal.stream { break }
            decodeWaiters[id] = nil; signal.continuation.finish()
            guard !isClosed, !Task.isCancelled else { return nil }
            if let cached = images[key] { touch(key); return cached }
            if let existing = inFlight[key] {
                let result = await existing.value
                return isClosed || Task.isCancelled ? nil : result
            }
        }
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
        let task = Task.detached(priority: .utility) {
            if kind == .video { return await Self.decodeVideo(fileURL: fileURL, maximumPixelSize: maximumPixelSize) }
            return await decode(fileURL, maximumPixelSize)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight.removeValue(forKey: key)
        for waiter in decodeWaiters.values { waiter.yield(()) }
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

    nonisolated private static func canonicalFileURL(_ input: URL) -> URL {
        // URL resolution may leave a symlink unresolved when the final child
        // doesn't exist. Resolve the nearest existing ancestor first, so even
        // cache keys and test decoders cannot escape an allowed account root.
        var ancestor = input.standardizedFileURL, suffix: [String] = []
        while ancestor.path != "/", !FileManager.default.fileExists(atPath: ancestor.path) {
            suffix.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var resolved = ancestor.resolvingSymlinksInPath()
        for component in suffix.reversed() { resolved.appendPathComponent(component) }
        return resolved
    }

    nonisolated private static func decodeVideo(fileURL: URL, maximumPixelSize: Int) async -> V2SendableImage? {
        guard !Task.isCancelled else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: fileURL))
        generator.maximumSize = CGSize(width: maximumPixelSize, height: maximumPixelSize)
        generator.appliesPreferredTrackTransform = true
        guard let frame = try? await generator.image(at: .zero), !Task.isCancelled else { return nil }
        return .init(image: UIImage(cgImage: frame.image))
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
    func makeCoordinator() -> Coordinator { Coordinator(lease: lease) }
    func makeUIViewController(context: Context) -> UIActivityViewController {
        // UIKit vends its native URL representation and sandbox extension.
        // This is a named FileStore export lease, never a provider/signed URL
        // or the canonical cache path. The coordinator survives nested export.
        let controller = UIActivityViewController(activityItems: [lease.fileURL], applicationActivities: nil)
        let coordinator = context.coordinator
        controller.completionWithItemsHandler = { _, _, _, _ in coordinator.finish() }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
    static func prepareLease(_ original: V2ConversationMediaFileLease, kind: V2MediaPresentation.Kind,
                             contentType: String, displayName: V2ResourceDisplayName?) async throws -> V2ConversationMediaFileLease {
        do {
            let ext = (UTType(mimeType: contentType) ?? .data).preferredFilenameExtension ?? "dat"
            let name = try V2ResourceExportFileName(displayName?.value ?? (title(for: kind) + "." + ext))
            let exported = try await original.forExport(fileName: name)
            await original.release()
            return exported
        } catch { await original.release(); throw error }
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
