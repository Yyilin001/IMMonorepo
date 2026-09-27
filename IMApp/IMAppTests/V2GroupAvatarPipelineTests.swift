import CryptoKit
import Foundation
import IMV2ClientKit
import IMV2Core
import Testing
import UIKit
@testable import IMApp

@MainActor
struct V2GroupAvatarPipelineTests {
    @Test("a cached image still requires new display authorization after suspension")
    func cachedImageRequiresPermission() async throws {
        let f = try GroupPipelineFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let thumbnails = V2LocalMediaThumbnailCache(directory: f.root)
        let pipeline = f.pipeline(thumbnails)
        let activation = try await pipeline.groups.activate(roomID: f.presentation.state.roomID)
        let result = try await pipeline.groupSnapshot(activation: activation, pixels: 16)
        #expect(result.image?.image.cgImage?.width == 16)
        #expect(result.deadline > ContinuousClock.now)
        let generation = pipeline.generation
        await pipeline.suspend()
        #expect(pipeline.generation > generation)
        await #expect(throws: V2GroupAvatarPresentationError.inactive) {
            _ = try await pipeline.groupSnapshot(activation: activation, pixels: 16)
        }
        await f.reader.deny()
        let next = try await pipeline.groups.activate(roomID: f.presentation.state.roomID)
        await #expect(throws: V2GroupAvatarReadError.forbidden) {
            _ = try await pipeline.groupSnapshot(activation: next, pixels: 16)
        }
        #expect(FileManager.default.fileExists(atPath: f.cachedFile.path))
        #expect(await f.reader.calls == 2)
        await pipeline.close(); await thumbnails.close(); try await f.files.close()
    }

    @Test("late decoded pixels cannot cross invalidation, background or account-close boundaries",
          arguments: ["invalidate", "suspend", "close"])
    func lateDecode(boundary: String) async throws {
        let f = try GroupPipelineFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let entered = AsyncStream<Void>.makeStream(), gate = GroupPipelineDecodeGate()
        let image = V2SendableImage(image: UIImage())
        let thumbnails = V2LocalMediaThumbnailCache(directory: f.root) { _, _ in
            await gate.wait(entered.continuation)
            return image
        }
        let pipeline = f.pipeline(thumbnails)
        let activation = try await pipeline.groups.activate(roomID: f.presentation.state.roomID)
        let request = Task { try await pipeline.groupSnapshot(activation: activation, pixels: 16) }
        var starts = entered.stream.makeAsyncIterator()
        _ = await starts.next()
        switch boundary {
        case "invalidate": await pipeline.groups.invalidate(roomID: f.presentation.state.roomID)
        case "suspend": await pipeline.suspend()
        default: await pipeline.close()
        }
        await gate.release()
        await #expect(throws: V2GroupAvatarPresentationError.inactive) { _ = try await request.value }
        await pipeline.close()
        await #expect(throws: V2GroupAvatarPresentationError.inactive) {
            _ = try await pipeline.groupSnapshot(activation: activation, pixels: 16)
        }
        #expect(pipeline.isSuspending)
        await thumbnails.close(); try await f.files.close(); entered.continuation.finish()
    }
}

@MainActor
private struct GroupPipelineFixture {
    let root: URL, cachedFile: URL
    let presentation: V2GroupAvatarPresentation
    let reader: GroupPipelineReader
    let files: V2ForegroundConversationMediaDownloader
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("group-pipeline-\(UUID())")
        files = try .init(downloader: .init(targetResolver: NoGroupByteIO(), byteTransfer: NoGroupByteIO()), directory: root)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).pngData { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        let media = MediaID(uuid: UUID()), variant = ResourceVariantID(uuid: UUID())
        let checksum = try V2ResourceChecksum(value: SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined())
        let key = media.rawValue + ":" + variant.rawValue + ":1:" + checksum.value
        cachedFile = root.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".media")
        try png.write(to: cachedFile)
        let now = Date()
        let plan = try V2ResourceTransferPlan(mode: .httpGet, url: #require(URL(string: "https://delivery.invalid/avatar")),
            expiresAt: now.addingTimeInterval(120), expectedByteCount: Int64(png.count), checksum: checksum)
        presentation = try .init(actorUserID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()),
            state: .init(roomID: .init(uuid: UUID()), mediaID: media, revision: 1), membershipRevision: 1, resourceGeneration: 1,
            canManage: false, avatar: .init(mediaID: media, variantID: variant, version: 1, checksum: checksum, plan: plan),
            observedAt: now, validUntil: now.addingTimeInterval(300), serverNow: now)
        reader = .init(value: presentation)
    }
    func pipeline(_ thumbnails: V2LocalMediaThumbnailCache) -> V2AvatarPipeline {
        let groups = V2GroupAvatarPresentationRepository(actorUserID: presentation.actorUserID, deviceID: presentation.deviceID,
            reader: reader, minimumRevision: { _ in 0 })
        let profiles = V2ProfilePresentationRepository(actorUserID: presentation.actorUserID, deviceID: presentation.deviceID,
            reader: NoGroupByteIO())
        return .init(profiles: profiles, groups: groups, files: files, thumbnails: thumbnails)
    }
}

private actor GroupPipelineReader: V2GroupAvatarPresentationReading {
    let value: V2GroupAvatarPresentation
    var calls = 0, denied = false
    init(value: V2GroupAvatarPresentation) { self.value = value }
    func deny() { denied = true }
    func readGroupAvatar(roomID: RoomID) throws -> V2GroupAvatarPresentation {
        calls += 1
        if denied { throw V2GroupAvatarReadError.forbidden }
        return value
    }
}
private actor GroupPipelineDecodeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait(_ entered: AsyncStream<Void>.Continuation) async {
        await withCheckedContinuation { continuation = $0; entered.yield(()) }
    }
    func release() { continuation?.resume(); continuation = nil }
}
private struct NoGroupByteIO: V2ClientMediaDownloadTargetResolver, V2ClientMediaByteTransfer, V2ProfilePresentationReading {
    func resolveDownloadTarget(mediaID: MediaID, message: V2MediaMessageLocation?) throws -> V2ClientMediaTransferTarget { throw CancellationError() }
    func upload(fileURL: URL, target: V2ClientMediaTransferTarget) throws { throw CancellationError() }
    func download(target: V2ClientMediaTransferTarget, destinationURL: URL) throws { throw CancellationError() }
    func readPresentations(_ keys: [V2ProfileViewLookupKey]) throws -> V2ProfilePresentationBatch { throw CancellationError() }
}
