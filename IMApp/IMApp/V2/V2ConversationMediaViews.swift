import AVKit
import Foundation
import ImageIO
import IMV2ClientKit
import IMV2Core
import Observation
import SwiftUI
import UIKit

struct V2ConversationMediaAttachmentRow: View {
    @Bindable var store: V2ConversationDetailStore
    let message: V2ConversationMessageItem
    let media: V2MediaReference
    let presentation: V2MediaPresentation
    let index: Int
    @State private var isPresentingPlayer = false

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
                    fileURL: downloaded.fileURL,
                    accessibilityLabel: kindLabel,
                    accessibilityValue: byteCountLabel,
                    accessibilityIdentifier: identifier + ".preview"
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
                        fileURL: downloaded.fileURL,
                        kind: presentation.kind,
                        accessibilityIdentifier: identifier + ".player"
                    )
                }
            }
            ShareLink(item: downloaded.fileURL) {
                Label("分享\(kindLabel)", systemImage: "square.and.arrow.up")
            }
            .font(.caption)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("分享\(kindLabel)")
            .accessibilityHint("打开系统分享菜单")
            .accessibilityIdentifier(identifier)
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

/// A downloaded image may be tens of megapixels even though the conversation
/// row is small. Decode and downsample it away from MainActor, then retain only
/// a bounded thumbnail cache instead of reopening the file from `body`.
private struct V2LocalMediaImagePreview: View {
    let fileURL: URL
    let accessibilityLabel: String
    let accessibilityValue: String
    let accessibilityIdentifier: String
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
        .task(id: fileURL) {
            image = await V2LocalMediaThumbnailCache.shared.thumbnail(
                fileURL: fileURL,
                maximumPixelSize: 960
            )?.image
        }
    }
}

private struct V2SendableImage: @unchecked Sendable {
    let image: UIImage
}

private actor V2LocalMediaThumbnailCache {
    static let shared = V2LocalMediaThumbnailCache()

    private struct Key: Hashable, Sendable {
        let path: String
        let maximumPixelSize: Int
    }

    private let maximumEntryCount = 24
    private var images: [Key: V2SendableImage] = [:]
    private var recency: [Key] = []
    private var inFlight: [Key: Task<V2SendableImage?, Never>] = [:]

    func thumbnail(fileURL: URL, maximumPixelSize: Int) async -> V2SendableImage? {
        let key = Key(path: fileURL.path, maximumPixelSize: maximumPixelSize)
        if let cached = images[key] {
            touch(key)
            return cached
        }
        if let existing = inFlight[key] { return await existing.value }
        let task = Task.detached(priority: .utility) { () -> V2SendableImage? in
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions) else { return nil }
            let thumbnailOptions = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
            ] as CFDictionary
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
            return V2SendableImage(image: UIImage(cgImage: thumbnail))
        }
        inFlight[key] = task
        let result = await task.value
        inFlight.removeValue(forKey: key)
        if let result {
            images[key] = result
            touch(key)
            while recency.count > maximumEntryCount, let oldest = recency.first {
                recency.removeFirst()
                images.removeValue(forKey: oldest)
            }
        }
        return result
    }

    private func touch(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}

/// A privacy-preserving card: rendering a message never fetches a remote
/// page, image, or favicon. The user explicitly chooses whether to hand the
/// already-validated HTTP(S) URL to the system browser.
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
    let fileURL: URL
    let kind: V2MediaPresentation.Kind
    let accessibilityIdentifier: String
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var isPlaying = false

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
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityValue(isPlaying ? "正在播放" : "已暂停")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .accessibilityIdentifier(accessibilityIdentifier)
            .navigationTitle(kind == .video ? "视频" : "音频")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onAppear {
            guard player == nil else { return }
            player = AVPlayer(url: fileURL)
        }
        .onDisappear {
            player?.pause()
            isPlaying = false
            player = nil
        }
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
