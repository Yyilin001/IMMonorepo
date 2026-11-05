import CryptoKit
import Foundation
import IMV2ClientKit
import IMV2Core
import Testing
import os
import Observation
import UIKit
import SwiftUI
@testable import IMApp

@MainActor
struct V2GroupAvatarPipelineTests {
    @Test("the management sheet reuses authorized header pixels while its larger decode is unavailable")
    func sheetReusesHeaderPixels() async throws {
        let f = try await GroupPipelineFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let thumbnails = V2LocalMediaThumbnailCache(directories: [f.root])
        let pipeline = f.pipeline(thumbnails)
        let scope = V2AuthorPresentationPageScope(context: .list(UUID()))
        let running = Task { await scope.run(pipeline: pipeline) }
        let deadline = ContinuousClock.now + .seconds(5)
        while scope.activation == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        scope.prepareGroup(room: f.presentation.state.roomID, pixels: 52, pipeline: pipeline)
        while scope.cachedGroup(room: f.presentation.state.roomID, pixels: 52, pipeline: pipeline)?.image == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(scope.cachedGroup(room: f.presentation.state.roomID, pixels: 52, pipeline: pipeline)?.image != nil)
        scope.prepareGroup(room: f.presentation.state.roomID, pixels: 144, pipeline: pipeline)
        #expect(scope.cachedGroup(room: f.presentation.state.roomID, pixels: 144, pipeline: pipeline)?.image != nil,
                "The sheet must reuse valid header pixels while loading its larger image")
        scope.hide(); running.cancel(); await running.value
        #expect(scope.cachedGroup(room: f.presentation.state.roomID, pixels: 144, pipeline: pipeline) == nil)
        await pipeline.close(); await thumbnails.close(); try await f.files.close()
    }

    @Test("cold launch starts avatar loading when the pipeline arrives after the visible page", arguments: [false, true])
    func delayedPipelineStartsVisibleAvatar(inCollection: Bool) async throws {
        await V2UITestWindowOwnership.acquire()
        defer { V2UITestWindowOwnership.release() }
        let f = try await GroupPipelineFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let thumbnails = V2LocalMediaThumbnailCache(directories: [f.root]), pipeline = f.pipeline(thumbnails)
        let state = ColdAvatarLaunchState()
        let displayed = OSAllocatedUnfairLock(initialState: false)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let listStore = V2ConversationListStore(environment: .init(userID: f.presentation.actorUserID.rawValue,
            projections: .init(dataSource: GroupAvatarSettingsDataSource())))
        let host = UIHostingController(rootView: ColdAvatarLaunchView(state: state, room: f.presentation.state.roomID,
            listStore: inCollection ? listStore : nil)
            .environment(\.v2GroupAvatarDisplayObservation, { _, image in displayed.withLock { $0 = image } }))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let appearedBy = ContinuousClock.now + .seconds(5)
        while !state.appeared && ContinuousClock.now < appearedBy { await Task.yield() }
        #expect(state.appeared)
        state.pipeline = pipeline
        let loadedBy = ContinuousClock.now + .seconds(5)
        while !displayed.withLock({ $0 }) && ContinuousClock.now < loadedBy {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(displayed.withLock { $0 }, "The first visible avatar must load without switching tabs")
        await pipeline.close(); await thumbnails.close(); try await f.files.close()
    }

    @Test("shared group pixels survive row recreation but clear on revocation and page exit")
    func sharedGroupPixels() async throws {
        let f = try await GroupPipelineFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let thumbnails = V2LocalMediaThumbnailCache(directories: [f.root]), pipeline = f.pipeline(thumbnails)
        let scope = V2AuthorPresentationPageScope(context: .list(UUID()))
        let running = Task { await scope.run(pipeline: pipeline) }
        let deadline = ContinuousClock.now + .seconds(5)
        while scope.activation == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        scope.prepareGroup(room: f.presentation.state.roomID, pixels: 52, pipeline: pipeline)
        while scope.cachedGroup(room: f.presentation.state.roomID, pixels: 52, pipeline: pipeline) == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(scope.cachedGroup(room: f.presentation.state.roomID, pixels: 52, pipeline: pipeline)?.image != nil)
        let reads = await f.reader.calls
        scope.prepareGroup(room: f.presentation.state.roomID, pixels: 52, pipeline: pipeline)
        #expect(await f.reader.calls == reads)
        await pipeline.groups.invalidate(roomID: f.presentation.state.roomID)
        let clearedBy = ContinuousClock.now + .seconds(3)
        while scope.cachedGroup(room: f.presentation.state.roomID, pixels: 52, pipeline: pipeline) != nil && ContinuousClock.now < clearedBy { await Task.yield() }
        #expect(scope.cachedGroup(room: f.presentation.state.roomID, pixels: 52, pipeline: pipeline) == nil)
        scope.hide(); running.cancel(); await running.value
        await pipeline.close(); await thumbnails.close(); try await f.files.close()
    }

    @Test("opening the management sheet keeps the underlying group's unchanged avatar grant")
    func openingManagementSheetKeepsUnderlyingAvatarGrant() async throws {
        await V2UITestWindowOwnership.acquire()
        defer { V2UITestWindowOwnership.release() }
        let f = try await GroupPipelineFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let thumbnails = V2LocalMediaThumbnailCache(directories: [f.root]), pipeline = f.pipeline(thumbnails)
        let activation = try await pipeline.groups.activate(roomID: f.presentation.state.roomID)
        _ = try await pipeline.groupSnapshot(activation: activation, pixels: 52)
        let grant = try #require(try await pipeline.groups.avatarReadGrant(for: activation))
        let boundary = GroupManagementBoundary(state: f.presentation.state)
        let store = V2GroupAvatarManagementStore(roomID: f.presentation.state.roomID,
            manager: boundary, stager: boundary, notifier: nil)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let conversation = V2ConversationDetailStore(environment: .init(userID: f.presentation.actorUserID.rawValue,
            projections: .init(dataSource: GroupAvatarSettingsDataSource()),
            groups: .init(avatarManager: boundary), media: .init(attachmentStager: boundary)),
            context: .init(roomID: f.presentation.state.roomID.rawValue, title: "头像测试群", kind: .group))
        let displayedStates = OSAllocatedUnfairLock(initialState: [Bool]())
        let host = UIHostingController(rootView: NavigationStack {
            V2ConversationSettingsView(store: conversation, focusMessage: { _ in })
        }.environment(\.v2AvatarPipeline, pipeline).environment(\.scenePhase, .active)
            .environment(\.v2GroupAvatarDisplayObservation, { size, hasImage in
                if size == 52 { displayedStates.withLock { $0.append(hasImage) } }
            })
            .environment(\.v2AuthorPresentationPageScope, V2AuthorPresentationPageScope(context: .group(f.presentation.state.roomID))))
        let sheetHasImage = OSAllocatedUnfairLock(initialState: false)
        let sheet = UIHostingController(rootView: V2GroupAvatarManagementView(store: store)
            .environment(\.v2AvatarPipeline, pipeline).environment(\.scenePhase, .active)
            .environment(\.v2GroupAvatarDisplayObservation, { size, hasImage in
                if size == 144 { sheetHasImage.withLock { $0 = hasImage } }
            }))
        sheet.modalPresentationStyle = .pageSheet
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey(); store.suspend() }
        let loadedBy = ContinuousClock.now + .seconds(5)
        while !displayedStates.withLock({ $0.last == true }) && ContinuousClock.now < loadedBy {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(displayedStates.withLock { $0.last == true })
        // Let the independent page cache finish before opening the sheet.
        try await Task.sleep(for: .milliseconds(100))
        displayedStates.withLock { $0.removeAll() }
        let initialReads = await f.reader.calls
        #expect(initialReads >= 3)
        await withCheckedContinuation { continuation in
            host.present(sheet, animated: true) { continuation.resume() }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let reads = await f.reader.calls
            if store.authority != nil && reads > initialReads && sheetHasImage.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(sheetHasImage.withLock { $0 }, "The management sheet must display the group avatar, not just load permission")
        #expect(store.authority?.state == f.presentation.state)
        #expect(await f.reader.calls == initialReads + 1)
        do { try await grant.requireValid() }
        catch { Issue.record(error, "Opening an unchanged group avatar must preserve the underlying page's grant") }
        await withCheckedContinuation { continuation in
            host.dismiss(animated: true) { continuation.resume() }
        }
        #expect(displayedStates.withLock { !$0.contains(false) }, "The settings header must never return to its placeholder while opening or closing the sheet")
        await pipeline.close(); await thumbnails.close(); try await f.files.close()
    }

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
        let clock = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
        await f.reader.shortenFirstLease(to: 1, beforeRefresh: { clock.withLock { $0 += .seconds(2) } })
        let thumbnails = V2LocalMediaThumbnailCache(directories: [f.root])
        let pipeline = f.pipeline(thumbnails, now: { clock.withLock { $0 } })
        let page = try await pipeline.groups.activate(roomID: f.presentation.state.roomID)
        _ = try await pipeline.groups.presentation(for: page)
        let original = try #require(try await pipeline.groups.authorizationDeadline(for: page))
        let snapshot = try await pipeline.groupSnapshot(activation: page, pixels: 16)
        let now = clock.withLock { $0 }
        #expect(original <= now && snapshot.deadline > now)
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
    func pipeline(_ thumbnails: V2LocalMediaThumbnailCache, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) -> V2AvatarPipeline {
        let groups = V2GroupAvatarPresentationRepository(actorUserID: presentation.actorUserID, deviceID: presentation.deviceID,
            reader: reader, minimumRevision: { _ in 0 }, now: now)
        let profiles = V2ProfilePresentationRepository(actorUserID: presentation.actorUserID, deviceID: presentation.deviceID,
            reader: NoGroupByteIO())
        return .init(profiles: profiles, groups: groups, files: files.downloader, thumbnails: thumbnails, now: now)
    }
}

private actor GroupPipelineReader: V2GroupAvatarPresentationReading {
    let value: V2GroupAvatarPresentation
    var calls = 0, denied = false
    private var omitFirstPlan = false
    private var firstLifetime: TimeInterval?
    private var beforeRefresh: @Sendable () -> Void = {}
    func shortenFirstLease(to seconds: TimeInterval, beforeRefresh: @escaping @Sendable () -> Void) {
        firstLifetime = seconds; self.beforeRefresh = beforeRefresh
    }
    func withholdFirstPlan() { omitFirstPlan = true }
    init(value: V2GroupAvatarPresentation) { self.value = value }
    func deny() { denied = true }
    func readGroupAvatar(roomID: RoomID) async throws -> V2GroupAvatarPresentation {
        calls += 1
        if calls > 1 { beforeRefresh() }
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

private struct GroupManagementBoundary: V2GroupAvatarManaging, V2ConversationAttachmentStaging {
    let state: V2GroupAvatarState
    func load(roomID: RoomID) -> V2GroupAvatarManagementSnapshot {
        .init(access: .authorized(.init(state: state, canManage: false,
            deadline: .now.advanced(by: .seconds(300)), maximumUploadBytes: nil)), pending: [])
    }
    func pending(roomID: RoomID) -> [V2GroupAvatarIntent] { [] }
    func pendingIntent(roomID: RoomID, operationID: GroupAvatarOperationID) -> V2GroupAvatarIntent? { nil }
    func change(roomID: RoomID, expectedRevision: UInt64, image: V2StagedConversationAttachment?) throws { throw CancellationError() }
    func changeUsingResource(roomID: RoomID, expectedRevision: UInt64, selection: V2AvatarResourceSelection) throws { throw CancellationError() }
    func act(roomID: RoomID, operationID: GroupAvatarOperationID, action: V2GroupAvatarManagementAction) throws { throw CancellationError() }
    func stageNormalizedPhoto(_ photo: V2NormalizedPhoto, purpose: V2LocalResourceAssetPurpose) throws -> V2StagedConversationAttachment { throw CancellationError() }
    func stageImportedFile(at sourceURL: URL, purpose: V2LocalResourceAssetPurpose) throws -> V2StagedConversationAttachment { throw CancellationError() }
    func discard(_ attachment: V2StagedConversationAttachment) {}
}

private struct GroupAvatarSettingsDataSource: V2ConversationDataSource {
    func conversationSummaryPage(for userID: String, isArchived: Bool, before cursor: V2ClientConversationListCursor?, limit: Int) async throws -> V2ConversationListPage { throw CancellationError() }
    func timelinePage(in roomID: String, for userID: String, before cursor: V2ConversationTimelineCursor?, limit: Int) async throws -> V2ConversationTimelinePage { throw CancellationError() }
    func timelineWindow(in roomID: String, for userID: String, around messageID: String, before: Int, after: Int) async throws -> V2ConversationTimelineLocation { throw CancellationError() }
}

@MainActor @Observable private final class ColdAvatarLaunchState {
    var pipeline: V2AvatarPipeline?
    var appeared = false
}
private struct ColdAvatarLaunchView: View {
    let state: ColdAvatarLaunchState
    let room: RoomID
    let listStore: V2ConversationListStore?
    @State private var pageID = UUID()
    @State private var navigation = V2RootNavigationStore()
    var body: some View {
        Group {
            if let listStore {
                V2ConversationCollectionView(store: listStore,
                    conversations: [.init(id: room.rawValue, title: "冷启动测试群", preview: "测试", lastActivity: .now, isOutgoing: false, kind: .group)],
                    pending: [], navigation: navigation, restoration: nil)
            } else {
                V2AuthorizedGroupAvatarView(roomID: room, size: 52)
            }
        }
            .authorPresentationPage(context: .list(pageID))
            .environment(\.v2AvatarPipeline, state.pipeline)
            .environment(\.scenePhase, .active)
            .onAppear { state.appeared = true }
    }
}
