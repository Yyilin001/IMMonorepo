#if DEBUG
import CryptoKit
import Foundation
import IMV2ClientKit
import IMV2Core
import Observation
import SwiftUI

/// Explicit signed-out fixture using the real cache, AVPlayer sheet and system
/// share controller. Only authenticated remote byte acquisition is substituted.
struct V2MediaFileUsageUITestView: View {
    let scope: UUID
    let cleanup: Bool
    private enum Sheet: Identifiable {
        case player, share(V2ConversationMediaFileLease)
        var id: String { switch self { case .player: "player"; case .share(let lease): lease.id.uuidString } }
    }
    @State private var fixture: FileUsageUIFixture?
    @State private var sheet: Sheet?
    @State private var status = "正在准备"
    @State private var shareRequested = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text(status).accessibilityIdentifier("v2.file-use.status")
                if let fixture {
                    Button("打开播放器") { sheet = .player }.accessibilityIdentifier("v2.file-use.player")
                    Button("打开系统分享") { shareRequested = true }.accessibilityIdentifier("v2.file-use.share")
                    Button("验证账户关闭") {
                        Task {
                            do {
                                try await fixture.files.close()
                                status = FileManager.default.fileExists(atPath: fixture.downloaded.fileURL.path) ? "文件仍然存在" : "关闭完成"
                            } catch { status = "关闭失败" }
                        }
                    }.accessibilityIdentifier("v2.file-use.close")
                }
            }
            .navigationTitle("文件使用测试")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $sheet) { value in
                if let fixture {
                    Group {
                        switch value {
                        case .player:
                            V2LocalMediaPlayerSheet(downloaded: fixture.downloaded, kind: .audio,
                                accessibilityIdentifier: "v2.file-use.audio", onUnavailable: { status = "借用失败" })
                        case .share(let lease): V2LocalMediaShareSheet(lease: lease, kind: .audio, contentType: "audio/wav")
                        }
                    }
                    .safeAreaInset(edge: .bottom) {
                        VStack {
                            Text(fixture.retirementStatus).accessibilityIdentifier("v2.file-use.retirement")
                            Button("回收测试文件") { Task { await fixture.discard() } }
                                .accessibilityIdentifier("v2.file-use.discard")
                            Button("关闭测试页面") { sheet = nil }.accessibilityIdentifier("v2.file-use.dismiss")
                        }.padding().background(.regularMaterial)
                    }
                }
            }
        }
        .task {
            let directory = FileManager.default.temporaryDirectory.appending(path: "v2-file-use-ui-" + scope.uuidString)
            do {
                if cleanup {
                    if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
                    status = "测试数据已清理"; return
                }
                let prepared = try await FileUsageUIFixture.make(directory: directory)
                guard !Task.isCancelled else { try await prepared.files.close(); return }
                fixture = prepared; status = "已准备"
                let lifetime = AsyncStream<Void>.makeStream()
                await withTaskCancellationHandler {
                    for await _ in lifetime.stream { }
                } onCancel: { lifetime.continuation.finish() }
                sheet = nil; fixture = nil
                try await prepared.files.close()
            } catch { if !Task.isCancelled { status = "准备失败" } }
        }
        .task(id: shareRequested) {
            guard shareRequested, let fixture else { return }
            do {
                let lease = try await fixture.downloaded.borrowFile()
                guard !Task.isCancelled else { await lease.release(); return }
                sheet = .share(lease)
            } catch { status = "借用失败" }
            shareRequested = false
        }
    }
}

@MainActor @Observable private final class FileUsageUIFixture {
    let files: V2ForegroundConversationMediaDownloader
    let downloaded: V2DownloadedConversationMedia
    var retirementStatus = "尚未回收"
    private init(files: V2ForegroundConversationMediaDownloader, downloaded: V2DownloadedConversationMedia) {
        self.files = files; self.downloaded = downloaded
    }
    static func make(directory: URL) async throws -> FileUsageUIFixture {
        let boundary = FileUsageUIBytes()
        let files = try V2ForegroundConversationMediaDownloader(downloader: .init(targetResolver: boundary, byteTransfer: boundary), directory: directory)
        do {
            let downloaded = try await files.download(.init(mediaID: .init(uuid: UUID())))
            return .init(files: files, downloaded: downloaded)
        } catch { try? await files.close(); throw error }
    }
    func discard() async {
        await files.discard(.init(mediaID: downloaded.mediaID))
        retirementStatus = FileManager.default.fileExists(atPath: downloaded.fileURL.path) ? "使用中的文件已保留" : "文件被提前删除"
    }
}

private struct FileUsageUIBytes: V2ClientMediaDownloadTargetResolver, V2ClientMediaByteTransfer {
    func resolveDownloadTarget(mediaID: MediaID, message: V2MediaMessageLocation?) throws -> V2ClientMediaTransferTarget {
        try .init(downloadPlan: .init(mode: .httpGet, url: URL(string: "https://media.invalid/ui-fixture")!, expiresAt: .distantFuture, expectedByteCount: Int64(Self.wave.count), checksum: .init(value: SHA256.hash(data: Self.wave).map { String(format: "%02x", $0) }.joined())))
    }
    func download(target: V2ClientMediaTransferTarget, destinationURL: URL) throws { try Self.wave.write(to: destinationURL) }
    /// A one-second mono PCM wave exercises AVFoundation with valid local bytes.
    private static var wave: Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func word(_ value: UInt32, bytes: Int) { for shift in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) } }
        text("RIFF"); word(32_036, bytes: 4); text("WAVEfmt "); word(16, bytes: 4)
        word(1, bytes: 2); word(1, bytes: 2); word(16_000, bytes: 4); word(32_000, bytes: 4)
        word(2, bytes: 2); word(16, bytes: 2); text("data"); word(32_000, bytes: 4)
        data.append(Data(repeating: 0, count: 32_000)); return data
    }
}
#endif
