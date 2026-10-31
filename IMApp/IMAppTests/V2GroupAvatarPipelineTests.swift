import CryptoKit
import Foundation
import IMV2ClientKit
import IMV2Core
import Testing
import UIKit
@testable import IMApp

@MainActor
struct V2GroupAvatarPipelineTests {
    @Test("a cold group avatar obtains a fresh plan with its own bounded display deadline")
    func coldAvatarRecovery() async throws {
        let f = try await GroupPipelineFixture(seedCache: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.reader.withholdFirstPlan()
        let thumbnails = V2LocalMediaThumbnailCache(directories: [f.root]), pipeline = f.pipeline(thumbnails)
        let page = try await pipeline.groups.activate(roomID: f.presentation.state.roomID)
        _ = try await pipeline.groups.presentation(for: page)
        let initialDeadline = try #require(try await pipeline.groups.authorizationDeadline(for: page))
        let snapshot = try await pipeline.groupSnapshot(activation: page, pixels: 16)
        #expect(snapshot.image?.image.cgImage?.width == 16 && snapshot.avatarRetryAt == nil)
        #expect(snapshot.deadline <= (try await pipeline.groups.authorizationDeadline(for: page) ?? initialDeadline))
        #expect(await f.reader.calls == 2)
        let warm = try await pipeline.groupSnapshot(activation: page, pixels: 16)
        #expect(warm.image != nil)
        #expect(await f.reader.calls == 2)
        await pipeline.close(); await thumbnails.close(); try await f.files.close()
    }

    @Test("a group avatar uses its renewed read grant when the initial lease expires during refresh")
    func renewalPastInitialExpiry() async throws {
        let f = try await GroupPipelineFixture(seedCache: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.reader.withholdFirstPlan()
        await f.reader.shortenFirstLease(to: 0.15, refreshDelay: .milliseconds(300))
        let thumbnails = V2LocalMediaThumbnailCache(directories: [f.root]), pipeline = f.pipeline(thumbnails)
        let page = try await pipeline.groups.activate(roomID: f.presentation.state.roomID)
        _ = try await pipeline.groups.presentation(for: page)
        let original = try #require(try await pipeline.groups.authorizationDeadline(for: page))
        let snapshot = try await pipeline.groupSnapshot(activation: page, pixels: 16)
        #expect(original <= .now && snapshot.deadline > .now)
        #expect(snapshot.image != nil && snapshot.avatarRetryAt == nil)
        #expect(snapshot.deadline <= (try await pipeline.groups.avatarReadGrant(for: page)?.deadline ?? original))
        #expect(await f.reader.calls == 2)
        await pipeline.close(); await thumbnails.close(); try await f.files.close()
    }

    @Test("cached group pixels work without a download URL and require new authority after suspension", arguments: [false, true])
    func cachedImageRequiresPermission(includeDownloadPlan: Bool) async throws {
        let f = try await GroupPipelineFixture(includeDownloadPlan: includeDownloadPlan)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let thumbnails = V2LocalMediaThumbnailCache(directories: [f.root])
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
        let f = try await GroupPipelineFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let entered = AsyncStream<Void>.makeStream(), gate = GroupPipelineDecodeGate()
        let image = V2SendableImage(image: UIImage())
        let thumbnails = V2LocalMediaThumbnailCache(directories: [f.root]) { _, _ in
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
    let files: V2ResourceMediaTestOwner
    init(includeDownloadPlan: Bool = true, seedCache: Bool = true) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("group-pipeline-\(UUID())")
        let png = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).pngData { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        let media = MediaID(uuid: UUID()), variant = ResourceVariantID(uuid: UUID())
        let checksum = try V2ResourceChecksum(value: SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined())
        let now = Date()
        let plan = try V2ResourceTransferPlan(mode: .httpGet, url: #require(URL(string: "https://delivery.invalid/avatar")),
            expiresAt: now.addingTimeInterval(120), expectedByteCount: Int64(png.count), checksum: checksum)
        let avatar = try V2ResourceAvatarAccess(mediaID: media, variantID: variant, version: 1, checksum: checksum,
            byteCount: Int64(png.count), plan: plan)
        presentation = try .init(actorUserID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()),
            state: .init(roomID: .init(uuid: UUID()), mediaID: media, revision: 1), membershipRevision: 1, resourceGeneration: 1,
            canManage: false, avatar: includeDownloadPlan ? avatar : avatar.withoutDownloadPlan(),
            observedAt: now, validUntil: now.addingTimeInterval(300), serverNow: now)
        reader = .init(value: presentation)
        files = try await makeResourceMediaTestDownloader(downloader: .init(targetResolver: NoGroupByteIO(), byteTransfer: ResourceMediaSeedBytes(png)), directory: root)
        if seedCache {
            let seeded = try await files.avatar(avatar, home: .room(presentation.state.roomID))
            cachedFile = seeded.fileURL
            await seeded.release()
        } else { cachedFile = root.appendingPathComponent("not-seeded") }
    }
    func pipeline(_ thumbnails: V2LocalMediaThumbnailCache) -> V2AvatarPipeline {
        let groups = V2GroupAvatarPresentationRepository(actorUserID: presentation.actorUserID, deviceID: presentation.deviceID,
            reader: reader, minimumRevision: { _ in 0 })
        let profiles = V2ProfilePresentationRepository(actorUserID: presentation.actorUserID, deviceID: presentation.deviceID,
            reader: NoGroupByteIO())
        return .init(profiles: profiles, groups: groups, files: files.downloader, thumbnails: thumbnails)
    }
}

private actor GroupPipelineReader: V2GroupAvatarPresentationReading {
    let value: V2GroupAvatarPresentation
    var calls = 0, denied = false
    private var omitFirstPlan = false
    private var firstLifetime: TimeInterval?
    private var refreshDelay: Duration = .zero
    func shortenFirstLease(to seconds: TimeInterval, refreshDelay: Duration) {
        firstLifetime = seconds; self.refreshDelay = refreshDelay
    }
    func withholdFirstPlan() { omitFirstPlan = true }
    init(value: V2GroupAvatarPresentation) { self.value = value }
    func deny() { denied = true }
    func readGroupAvatar(roomID: RoomID) async throws -> V2GroupAvatarPresentation {
        calls += 1
        if calls > 1 && refreshDelay > .zero { try await Task.sleep(for: refreshDelay) }
        if denied { throw V2GroupAvatarReadError.forbidden }
        if (calls == 1 && omitFirstPlan) || firstLifetime != nil {
            return try .init(actorUserID: value.actorUserID, deviceID: value.deviceID, state: value.state,
                membershipRevision: value.membershipRevision, resourceGeneration: value.resourceGeneration,
                canManage: value.canManage, avatar: calls == 1 && omitFirstPlan ? value.avatar?.withoutDownloadPlan() : value.avatar,
                observedAt: firstLifetime == nil ? Date(timeIntervalSince1970: Double(value.observedAtUnixMilliseconds) / 1_000) : Date(),
                validUntil: firstLifetime.map { Date().addingTimeInterval(calls == 1 ? $0 : 300) } ?? Date(timeIntervalSince1970: Double(value.validUntilUnixMilliseconds) / 1_000),
                serverNow: firstLifetime == nil ? Date(timeIntervalSince1970: Double(value.serverNowUnixMilliseconds) / 1_000) : Date())
        }
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
