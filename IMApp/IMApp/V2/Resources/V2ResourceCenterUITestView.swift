#if DEBUG
import CryptoKit
import Foundation
import IMV2ClientKit
import IMV2Core
import SwiftUI
import UIKit

/// Isolated signed-out harness. Production views, routes, database, file owner
/// and download cache are unchanged; only authenticated remote I/O is replaced.
struct V2ResourceCenterUITestView: View {
    let scope: UUID
    let cleanup: Bool
    @State private var fixture: ResourceCenterUIFixture?
    @State private var navigation = V2RootNavigationStore()
    @State private var status = "正在准备"
    @State private var showingProfile = false
    var body: some View {
        @Bindable var navigation = navigation
        NavigationStack(path: $navigation.path) {
            Group {
                if fixture != nil {
                    V2AccountHomeView(displayName: "资源测试账号", handle: "@resource-test",
                        canOpenPublicIdentity: ProcessInfo.processInfo.arguments.contains("-v2-ui-testing-resource-center-profile-picker"), canOpenDevices: false, canOpenSecurity: false,
                        openPublicIdentity: { showingProfile = true }, openDevices: {}, openPrivacy: {}, openSecurity: {},
                        openFavorites: {}, openResources: { navigation.path.append(V2ResourceRoute.home) }, signOut: {})
                } else { Text(status).accessibilityIdentifier("v2.resources.fixture-status") }
            }
            .navigationTitle("我的").navigationBarTitleDisplayMode(.inline)
            .v2ResourceDestinations(service: fixture?.service, navigation: navigation, profile: fixture?.profileSettings)
        }
        .environment(\.v2MediaThumbnailCache, fixture?.thumbnails)
        .sheet(isPresented: $showingProfile) {
            if let settings = fixture?.profileSettings {
                NavigationStack {
                    V2PublicIdentitySettingsView(store: settings)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingProfile = false }.accessibilityIdentifier("v2.resources.fixture.profile.done") } }
                }.environment(\.v2ResourceManagement, fixture?.service)
            }
        }
        .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("-v2-ui-testing-resource-center-dark") ? .dark : nil)
        .task {
            let root = FileManager.default.temporaryDirectory.appending(path: "v2-resource-center-ui-" + scope.uuidString)
            do {
                if cleanup {
                    if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
                    status = "测试数据已清理"; return
                }
                let prepared = try await ResourceCenterUIFixture.make(root: root)
                guard !Task.isCancelled else { try await prepared.close(); return }
                fixture = prepared
                let lifetime = AsyncStream<Void>.makeStream()
                let downloader = prepared.downloader
                try await withThrowingTaskGroup(of: Void.self) { group in
                    if !ProcessInfo.processInfo.arguments.contains("-v2-ui-testing-resource-center-manual-queue") || ProcessInfo.processInfo.arguments.contains("-v2-ui-testing-resource-center-network-wait") {
                        group.addTask { try await downloader.runRecovery() }
                    }
                    group.addTask {
                        await withTaskCancellationHandler {
                            for await _ in lifetime.stream { }
                        } onCancel: { lifetime.continuation.finish() }
                    }
                    _ = try await group.next()
                    group.cancelAll()
                }
                navigation.path = .init(); fixture = nil
                try await prepared.close()
            } catch { if !Task.isCancelled { status = "准备失败" } }
        }
    }
}

@MainActor private struct ResourceCenterUIFixture {
    let service: V2ResourceManagementService
    let downloader: V2ForegroundConversationMediaDownloader
    let thumbnails: V2LocalMediaThumbnailCache
    let profileSettings: V2PublicIdentitySettingsStore?
    static func make(root: URL) async throws -> Self {
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let scope = try await V2AccountStorageDirectory(root: root, cacheRoot: root.appending(path: "cache-scopes")).openScope(accountID: user)
        let local = try await V2LocalStoreBootstrapper(bindingStore: ResourceCenterUIBinding()).open(databaseURL: scope.database.primary, userID: user)
        let center = try await V2ResourceCenter.make(scope: scope, store: local)
        do {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 200), format: format)
            let bytes = renderer.pngData { context in
                UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
                ("资源中心" as NSString).draw(at: CGPoint(x: 60, y: 80), withAttributes: [.font: UIFont.systemFont(ofSize: 28), .foregroundColor: UIColor.white])
            }
            let interruptedBytes = renderer.pngData { context in
                UIColor.systemOrange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
            }
            let interruptedMedia = MediaID(uuid: UUID())
            let boundary = ResourceCenterUIBytes(bytes: bytes, interruptedBytes: interruptedBytes, interruptedMedia: interruptedMedia,
                holdRecoveryOnce: ProcessInfo.processInfo.arguments.contains("-v2-ui-testing-resource-center-active-download"),
                holdAuthorization: ProcessInfo.processInfo.arguments.contains("-v2-ui-testing-resource-center-wait-for-authorization"))
            let descriptor = try V2ResourceDescriptor(key: .init(home: .room(room), mediaID: .init(uuid: UUID())), revision: 1,
                displayName: .init("设计说明与产品界面方案.png"), contentType: "image/png", byteCount: Int64(bytes.count), checksum: boundary.checksum, state: .ready, pixelWidth: 320, pixelHeight: 200)
            let location = V2MediaMessageLocation(roomID: room, messageID: .init(uuid: UUID()))
            if ProcessInfo.processInfo.arguments.contains("-v2-ui-testing-resource-center-unresolved-demand") {
                _ = try await center.prepareMessageDownload(mediaID: .init(uuid: UUID()),
                    message: .init(roomID: room, messageID: .init(uuid: UUID())))
            }
            try await local.indexResource(descriptor, reference: .message(location, ordinal: 0), businessRevision: 1)
            if ProcessInfo.processInfo.arguments.contains("-v2-ui-testing-resource-center-timed-media") {
                // Descriptor presentation fixture only; real byte probing and
                // trusted publication are covered by server integration tests.
                let audio = try V2ResourceDescriptor(key: .init(home: .room(room), mediaID: .init(uuid: UUID())), revision: 1,
                    displayName: .init("实测音频.wav"), contentType: "audio/wav", byteCount: 32044,
                    checksum: .init(value: String(repeating: "b", count: 64)), state: .ready, durationMilliseconds: 2000)
                try await local.indexResource(audio, reference: .message(.init(roomID: room, messageID: .init(uuid: UUID())), ordinal: 0), businessRevision: 1)
            }
            if ProcessInfo.processInfo.arguments.contains("-v2-ui-testing-resource-center-directory-pages") {
                for number in 0..<51 {
                    let extra = try V2ResourceDescriptor(key: .init(home: .room(room), mediaID: .init(uuid: UUID())), revision: 1,
                        displayName: .init("分页图片-\(number).png"), contentType: "image/png", byteCount: Int64(bytes.count),
                        checksum: boundary.checksum, state: .ready, pixelWidth: 320, pixelHeight: 200)
                    try await local.indexResource(extra, reference: .message(.init(roomID: room, messageID: .init(uuid: UUID())), ordinal: 0), businessRevision: 1)
                }
            }
            if ProcessInfo.processInfo.arguments.contains("-v2-ui-testing-resource-center-document") {
                // Metadata-only fixture: no fabricated downloaded bytes or access grants.
                let document = try V2ResourceDescriptor(key: .init(home: .room(room), mediaID: .init(uuid: UUID())), revision: 1,
                    displayName: .init("项目资源管理功能验证与交付说明.txt"), contentType: "text/plain", byteCount: 77,
                    checksum: .init(value: String(repeating: "c", count: 64)), state: .ready)
                try await local.indexResource(document, reference: .message(.init(roomID: room, messageID: .init(uuid: UUID())), ordinal: 0), businessRevision: 1)
            }
            let networkWait = ProcessInfo.processInfo.arguments.contains("-v2-ui-testing-resource-center-network-wait")
            let networkSource: V2ResourceAutomaticNetworkSource = networkWait ? .init(initial: .unavailable) { AsyncStream { _ in } } : .system
            let files = V2ForegroundConversationMediaDownloader(cache: try await center.downloadCache(using: .init(targetResolver: boundary, byteTransfer: boundary), automaticNetwork: networkSource), center: center)
            // A real cache entry makes the initial storage display and cleanup
            // exercise physical files rather than fabricated capacity values.
            if !ProcessInfo.processInfo.arguments.contains("-v2-ui-testing-resource-center-manual-queue") {
                _ = try await files.download(.init(mediaID: descriptor.key.mediaID), message: location)
            }
            if ProcessInfo.processInfo.arguments.contains("-v2-ui-testing-resource-center-unavailable-retention") {
                try await center.setRetained(true, variant: .init(resource: descriptor.key))
                try await local.revokeResourceReference(.message(location, ordinal: 0), businessRevision: 2)
            }
            let interruptedDescriptor = try V2ResourceDescriptor(key: .init(home: .room(room), mediaID: interruptedMedia), revision: 1,
                displayName: .init("下载中断图片.png"), contentType: "image/png", byteCount: Int64(interruptedBytes.count), checksum: boundary.interruptedChecksum, state: .ready)
            let interruptedLocation = V2MediaMessageLocation(roomID: room, messageID: .init(uuid: UUID()))
            try await local.indexResource(interruptedDescriptor, reference: .message(interruptedLocation, ordinal: 0), businessRevision: 1)
            do { _ = try await files.download(.init(mediaID: interruptedMedia), message: interruptedLocation) }
            catch let error as URLError where error.code == .networkConnectionLost { /* real partial left in the owner */ }
            if networkWait {
                try await center.setDownloadNetworkPreferences(.init(automaticDownloads: .init(categories: [.image], maximumByteCount: 2 * 1_024 * 1_024)))
            }
            // Seed a real imported source and journal through the production
            // engine. Only this fixture's control endpoint rejects the attempt.
            let uploadBytes = renderer.pngData { context in
                UIColor.systemGreen.setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
            }
            let asset = try await center.importLocal(data: uploadBytes, displayName: .init("待处理头像.png"), contentType: .init("image/png"), purpose: .personalAvatar)
            let uploadID = UUID(uuidString: "00000000-0000-0000-0000-000000002001")!
            var profileSettings: V2PublicIdentitySettingsStore?
            if ProcessInfo.processInfo.arguments.contains("-v2-ui-testing-resource-center-profile-picker") {
                let profile = try V2ProfileView(userID: user, publicIdentity: .init(userID: user, handle: .init("resource_test"), displayName: "资源测试账号", accountKind: .regular),
                    avatar: nil, state: .active, revision: .init(rawValue: 1)!, visibilityRevision: .init(rawValue: 1)!)
                try await local.saveOwnProfileSnapshot(profile)
                profileSettings = .init(service: V2ProfileIntentService(store: local, accountID: user, manager: ResourceCenterUIProfiles()), attachmentStager: nil)
            }
            if ProcessInfo.processInfo.arguments.contains("-v2-ui-testing-resource-center-profile-owner") {
                let source = try V2ProfileAvatarUpload(id: uploadID, localAssetID: asset.id, displayName: asset.displayName.value,
                    contentType: asset.contentType.value, byteCount: asset.byteCount)
                _ = try await local.enqueueProfileIntent(accountID: user, expectedRevision: .init(rawValue: 1)!,
                    patch: .init(displayName: .set("头像对应的原始昵称"), avatar: .set(.init(mediaID: .init(uuid: uploadID)))), avatarUpload: source)
                _ = try await local.enqueueProfileIntent(accountID: user, expectedRevision: .init(rawValue: 1)!,
                    patch: .init(displayName: .set("另一条更新的资料更改")), avatarUpload: nil)
                profileSettings = .init(service: V2ProfileIntentService(store: local, accountID: user, manager: ResourceCenterUIProfiles()), attachmentStager: nil)
            }
            let request = try V2ResourceUploadRequest(operationID: .init(uuid: uploadID), mediaID: .init(uuid: uploadID), usage: .userAvatar,
                contentType: asset.contentType.value, byteCount: asset.byteCount, checksum: asset.checksum, displayName: asset.displayName)
            let engine = V2ResourceTransferEngine(store: local, control: ResourceCenterUIUploadControl(), executor: V2URLSessionResourcePlanExecutor(), resources: center)
            _ = try await engine.prepare(id: uploadID, request: request, localAssetID: asset.id)
            if !ProcessInfo.processInfo.arguments.contains("-v2-ui-testing-resource-center-pausable-upload") {
                do { _ = try await engine.resume(id: uploadID) }
                catch V2ClientMediaTransferError.invalidTarget { /* expected controlled endpoint failure */ }
            }
            await engine.close()
            if ProcessInfo.processInfo.arguments.contains("-v2-ui-testing-resource-center-space-failure") {
                _ = try await center.setStoragePolicy(.init(maximumCacheBytes: 512 * 1_024 * 1_024, maximumTemporaryBytes: 1))
                do { _ = try await files.download(.init(mediaID: descriptor.key.mediaID), message: location) }
                catch V2ResourceStorageError.capacityExceeded { /* actual FileStore quota denial, not a fabricated task state */ }
            }
            if ProcessInfo.processInfo.arguments.contains("-v2-ui-testing-resource-center-pending-message") || ProcessInfo.processInfo.arguments.contains("-v2-ui-testing-resource-center-cancel-attention") || ProcessInfo.processInfo.arguments.contains("-v2-ui-testing-resource-center-pausable-import") {
                let job = UUID(uuidString: "00000000-0000-0000-0000-000000002002")!
                let copy = try V2ResourceImportRequest(operationID: .init(uuid: UUID()),
                    source: .message(location: location, mediaID: descriptor.key.mediaID, variantID: nil),
                    targetUsage: .messageAttachment(room), targetMediaID: .init(uuid: UUID()))
                try await local.prepareResourceImport(id: job, request: copy)
                let pending = try V2SendIntent(id: UUID(), roomID: room, clientMessageID: .init(uuid: UUID()), text: "待确认取消的消息", attachmentJobIDs: [job])
                try await local.freezeSendIntent(pending)
                if ProcessInfo.processInfo.arguments.contains("-v2-ui-testing-resource-center-cancel-attention") {
                    try await center.cancelPreparation(try await center.planPreparationCancellation(.serverImport(job)))
                    try await local.pauseResourceImport(id: job, needsAttention: true)
                }
            }
            return .init(service: .init(center: center, localStore: local, downloader: files, directory: boundary), downloader: files,
                thumbnails: V2LocalMediaThumbnailCache(directories: [scope.directory, scope.cacheDirectory]), profileSettings: profileSettings)
        } catch { await center.close(); try? await local.close(); throw error }
    }
    func close() async throws { await thumbnails.close(); await service.center.close(); try await service.localStore.close() }
}

private struct ResourceCenterUIBinding: V2InstallationBindingStore {
    func load() -> V2LocalInstallationBinding? { nil }
    func save(_ binding: V2LocalInstallationBinding) { }
    func delete() { }
}
private struct ResourceCenterUIProfiles: V2OwnProfileManaging {
    func currentProfile() throws -> V2ProfileView { throw V2ResourceStorageError.unavailable }
    func patchProfile(_ command: V2ProfileUpdateCommand) throws -> V2ProfileUpdateResult { throw V2ResourceStorageError.unavailable }
    func recoverProfile(_ request: V2ProfileOperationRecoveryRequest) throws -> V2ProfileOperationRecoveryResult { throw V2ResourceStorageError.unavailable }
}
private actor ResourceCenterUIBytes: V2ClientMediaDownloadTargetResolver, V2ClientMediaByteTransfer, V2RoomResourceDirectoryReading {
    let bytes: Data
    let interruptedBytes: Data
    let interruptedMedia: MediaID
    private var interrupted = false
    private var holdRecoveryOnce: Bool
    private let holdAuthorization: Bool
    init(bytes: Data, interruptedBytes: Data, interruptedMedia: MediaID, holdRecoveryOnce: Bool, holdAuthorization: Bool) {
        self.bytes = bytes; self.interruptedBytes = interruptedBytes; self.interruptedMedia = interruptedMedia
        self.holdRecoveryOnce = holdRecoveryOnce
        self.holdAuthorization = holdAuthorization
    }
    nonisolated var checksum: V2ResourceChecksum { get throws { try .init(value: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()) } }
    nonisolated var interruptedChecksum: V2ResourceChecksum { get throws { try .init(value: SHA256.hash(data: interruptedBytes).map { String(format: "%02x", $0) }.joined()) } }
    func resolveDownloadTarget(mediaID: MediaID, message: V2MediaMessageLocation?) async throws -> V2ClientMediaTransferTarget {
        if holdAuthorization, mediaID != interruptedMedia {
            let wait = AsyncStream<Void>.makeStream()
            for await _ in wait.stream { }
            throw CancellationError()
        }
        return try .init(downloadPlan: .init(mode: .httpGet, url: URL(string: "https://media.invalid/resource-center-fixture")!, expiresAt: .distantFuture,
            expectedByteCount: Int64(mediaID == interruptedMedia ? interruptedBytes.count : bytes.count), checksum: mediaID == interruptedMedia ? interruptedChecksum : checksum))
    }
    func download(target: V2ClientMediaTransferTarget, destinationURL: URL) async throws {
        if target.checksum == (try interruptedChecksum) {
            if !interrupted {
                interrupted = true
                try Data(interruptedBytes.prefix(20)).write(to: destinationURL.appendingPathExtension("range-part"))
                throw URLError(.networkConnectionLost)
            }
            if holdRecoveryOnce {
                holdRecoveryOnce = false
                // Only the remote leaf is gated. Actual task ownership,
                // durable pause/cancel and file cleanup remain production code.
                try await Task.sleep(for: .seconds(120))
            }
            try interruptedBytes.write(to: destinationURL)
            return
        }
        try bytes.write(to: destinationURL)
    }
    func query(roomID: RoomID, query: V2RoomResourceQuery) throws -> V2RoomResourcePage {
        try .init(items: [], snapshotUpperRoomSequence: 0, nextCursor: nil)
    }
}

private struct ResourceCenterUIUploadControl: V2ResourceUploadControlling {
    func create(_ request: V2ResourceUploadRequest) throws -> V2ResourceUploadSession { throw V2ClientMediaTransferError.invalidTarget }
    func status(_ locator: V2ResourceUploadLocator) throws -> V2ResourceUploadSession { throw V2ClientMediaTransferError.invalidTarget }
    func target(_ session: V2ResourceUploadSession) throws -> V2ResourceTransferPlan? { throw V2ClientMediaTransferError.invalidTarget }
    func finalize(_ session: V2ResourceUploadSession) throws -> V2ResourceUploadSession { throw V2ClientMediaTransferError.invalidTarget }
    func cancel(_ session: V2ResourceUploadSession) throws -> V2ResourceUploadSession { throw V2ClientMediaTransferError.invalidTarget }
}
#endif
