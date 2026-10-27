import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit
@testable import IMApp

@MainActor
@Suite("Resource business management destinations", .timeLimit(.minutes(1)))
struct V2ResourceBusinessOwnerStoreTests {
    @Test func ownerPagingCannotAdvanceAgainBeforeTheRequestedPageLoads() async throws {
        let f = try await Fixture()
        let source = try V2ProfileAvatarImport(id: UUID(), request: .init(operationID: .init(uuid: UUID()),
            source: .message(location: .init(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID())), mediaID: .init(uuid: UUID()), variantID: nil),
            targetUsage: .userAvatar, targetMediaID: .init(uuid: UUID())))
        for index in 0..<26 {
            _ = try await f.local.enqueueProfileImportIntent(accountID: f.user, expectedRevision: .init(rawValue: 1)!,
                patch: .init(displayName: .set("Draft \(index)")), source: source)
        }
        let page = V2ResourceBusinessOwnersStore(transfer: .serverImport(source.id), service: f.service)
        var observer = Task { await page.observe() }
        try await until { !page.isReading && page.page?.nextCursor != nil }
        page.nextPage()
        let requested = try #require(page.cursor)
        page.nextPage()
        #expect(page.pageNumber == 2 && page.cursor == requested && page.isReading)
        page.previousPage()
        #expect(page.pageNumber == 2 && page.cursor == requested)
        observer.cancel(); await observer.value
        observer = Task { await page.observe() }
        try await until { !page.isReading && page.page?.entries.count == 1 }
        #expect(page.pageNumber == 2 && page.page?.nextCursor == nil)
        page.previousPage()
        #expect(page.pageNumber == 1 && page.cursor == nil)
        observer.cancel(); await observer.value
        observer = Task { await page.observe() }
        try await until { page.hasCurrentPage && page.page?.entries.count == 25 }
        await f.center.close()
        await observer.value
        #expect(page.page == nil && !page.hasCurrentPage)
        try await f.close()
    }

    @Test func importedAvatarRoutesToExactProfileChangeAndDisposesTheWholeDraft() async throws {
        let f = try await Fixture()
        let source = try V2ProfileAvatarImport(id: UUID(), request: .init(operationID: .init(uuid: UUID()),
            source: .message(location: .init(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID())), mediaID: .init(uuid: UUID()), variantID: nil),
            targetUsage: .userAvatar, targetMediaID: .init(uuid: UUID())))
        let intent = try await f.local.enqueueProfileImportIntent(accountID: f.user, expectedRevision: .init(rawValue: 1)!, patch: .init(displayName: .set("imported name")), source: source)
        let page = V2ResourceBusinessOwnersStore(transfer: .serverImport(source.id), service: f.service)
        let observer = Task { await page.observe() }
        try await until { page.page?.entries.map(\.owner) == [.profileIntent(intent.id)] }
        page.select(.profileIntent(intent.id))
        await page.open(try #require(page.selection), managers: .init(profile: f.profileManager, group: nil))
        guard case .profile(let detail) = try #require(page.presentation).content else { throw V2ResourceStorageError.invalidRecord }
        let status = Task { await detail.observe() }
        try await until { detail.status?.intent.id == intent.id }
        #expect(detail.status?.phase == .preparingAvatar)
        detail.reviewDisposition(); await detail.execute(try #require(detail.command))
        detail.confirmDisposition(try #require(detail.dispositionPlan)); await detail.execute(try #require(detail.command))
        try await until { detail.status?.sourceRetained == false && page.page?.entries.isEmpty == true }
        #expect(detail.feedback == "已放弃此次资料更改。")
        #expect(try await f.local.resourceImport(id: source.id)?.cancellationRequested == true)
        status.cancel(); observer.cancel(); await status.value; await observer.value
        try await f.close()
    }

    @Test func originalProfileEditorObservesExternalDispositionWithoutRevivingItsPendingSave() async throws {
        let f = try await Fixture(), intent = try await f.profile()
        let editor = V2PublicIdentitySettingsStore(service: f.profileManager, attachmentStager: nil)
        await editor.load()
        try await until { editor.feedback == "正在准备头像。" }
        try await f.center.commitProfileDisposition(try await f.center.planProfileDisposition(transfer: .upload(f.job), intentID: intent.id))
        try await until { editor.feedback == "此次保存操作已结束，当前编辑内容已保留。" }
        #expect(!editor.needsAttention && !editor.canReplacePending)
        #expect(editor.displayName == "original")
        editor.stopObserving(); try await f.close()
    }

    @Test func profileDestinationKeepsExactOlderIntentAndWithdrawsItWithoutTouchingNewerDraft() async throws {
        let f = try await Fixture(), original = try await f.profile()
        let newer = try await f.local.enqueueProfileIntent(accountID: f.user, expectedRevision: .init(rawValue: 1)!, patch: .init(displayName: .set("newer unrelated")), avatarUpload: nil)
        let page = V2ResourceBusinessOwnersStore(transfer: .upload(f.job), service: f.service)
        let observer = Task { await page.observe() }
        try await until { page.page?.entries.map(\.owner) == [.profileIntent(original.id)] }
        page.select(.profileIntent(original.id))
        await page.open(try #require(page.selection), managers: .init(profile: f.profileManager, group: nil))
        guard case .profile(let detail) = try #require(page.presentation).content else { throw V2ResourceStorageError.invalidRecord }
        #expect(detail.intentID == original.id && detail.intentID != newer.id)
        let status = Task { await detail.observe() }
        try await until { detail.status?.intent.id == original.id }
        detail.reviewDisposition(); await detail.execute(try #require(detail.command))
        #expect(detail.dispositionPlan?.effect == .withdrawUnsubmittedChange)
        #expect(try await f.center.containsBusinessOwner(.profileIntent(original.id), transfer: .upload(f.job)))
        detail.dismissDisposition()
        #expect(detail.dispositionPlan == nil)
        detail.reviewDisposition(); await detail.execute(try #require(detail.command))
        detail.confirmDisposition(try #require(detail.dispositionPlan)); await detail.execute(try #require(detail.command))
        try await until { detail.status?.sourceRetained == false && page.page?.entries.isEmpty == true }
        #expect(detail.feedback == "已放弃此次资料更改。" && !detail.canDispose && !detail.canResume)
        #expect(try await f.local.profileIntent(id: newer.id) == newer)
        #expect(try await f.local.firstUnfinishedProfileIntent(accountID: f.user)?.id == newer.id)
        #expect(try await f.local.resourceTransfer(id: f.job)?.cancellationRequested == true)
        #expect(await f.io.calls == 0)
        status.cancel(); await status.value; observer.cancel(); await observer.value; try await f.close()
    }

    @Test func reviewedProfileDispositionCannotWithdrawAnIntentThatWasHandedOff() async throws {
        let f = try await Fixture(), intent = try await f.profile()
        let detail = V2ResourceProfileIntentStore(transfer: .upload(f.job), intentID: intent.id, center: f.center, manager: f.profileManager)
        let observer = Task { await detail.observe() }
        try await until { detail.canDispose }
        detail.reviewDisposition(); await detail.execute(try #require(detail.command))
        let plan = try #require(detail.dispositionPlan)
        try await f.local.saveResourceSession(.init(locator: .init(home: .account(f.user), sessionID: .init(uuid: UUID())),
            mediaID: .init(uuid: f.job), generation: 1, state: .completed, resourceState: .ready,
            expiresAt: .distantFuture, bindableUntil: .distantFuture), for: f.job)
        _ = try await f.local.freezeProfileIntent(id: intent.id, avatar: .init(mediaID: .init(uuid: f.job)))
        detail.confirmDisposition(plan); await detail.execute(try #require(detail.command))
        #expect(detail.feedback == "任务状态已变化，当前无法执行此操作。")
        #expect(try await f.local.resourceTransfer(id: f.job)?.cancellationRequested == false)
        #expect(try await f.center.containsBusinessOwner(.profileIntent(intent.id), transfer: .upload(f.job)))
        observer.cancel(); await observer.value; try await f.close()
    }

    @Test func groupDestinationReceivesExactRoomAndOperationAndRemovedOwnerCannotReopen() async throws {
        let f = try await Fixture(), room = RoomID(uuid: UUID())
        let asset = try await f.center.importLocal(data: Data("group".utf8), displayName: .init("group.png"), contentType: .init("image/png"), purpose: .groupAvatar(room))
        let request = try V2ResourceUploadRequest(operationID: .init(uuid: f.job), mediaID: .init(uuid: f.job), usage: .groupAvatar(room), contentType: asset.contentType.value, byteCount: asset.byteCount, checksum: asset.checksum, displayName: asset.displayName)
        _ = try await f.local.prepareResourceTransfer(id: f.job, request: request, localAssetID: asset.id)
        let command = try V2GroupAvatarCommand(operationID: .init(uuid: UUID()), roomID: room, expectedRevision: 0, mutation: .set(request.mediaID))
        _ = try await f.local.freezeGroupAvatarIntent(actorUserID: f.user, command: command, uploadJobID: f.job)
        let page = V2ResourceBusinessOwnersStore(transfer: .upload(f.job), service: f.service), probe = GroupProbe()
        let observer = Task { await page.observe() }
        try await until { page.page?.entries.first?.owner == .groupAvatar(room, command.operationID) }
        let managers = V2ResourceBusinessManagers(profile: nil, group: { room, operation in
            probe.room = room; probe.operation = operation
            return .init(roomID: room, manager: f.io, stager: f.io, notifier: nil, focusedOperationID: operation)
        })
        let wrongFactory = V2ResourceBusinessManagers(profile: nil, group: { room, _ in
            .init(roomID: room, manager: f.io, stager: f.io, notifier: nil, focusedOperationID: .init(uuid: UUID()))
        })
        page.select(.groupAvatar(room, command.operationID)); await page.open(try #require(page.selection), managers: wrongFactory)
        #expect(page.presentation == nil)
        page.select(.groupAvatar(room, command.operationID)); await page.open(try #require(page.selection), managers: managers)
        guard case .group(let detail) = try #require(page.presentation).content else { throw V2ResourceStorageError.invalidRecord }
        #expect(detail.roomID == room && detail.focusedOperationID == command.operationID)
        #expect(probe.room == room && probe.operation == command.operationID)
        page.presentation = nil
        page.select(.groupAvatar(room, command.operationID))
        let stale = try #require(page.selection)
        try await f.local.cancelGroupAvatarIntent(command.operationID)
        await page.open(stale, managers: managers)
        #expect(page.presentation == nil && page.feedback == "任务状态已变化，当前无法执行此操作。")
        #expect(await f.io.calls == 0)
        observer.cancel(); await observer.value; try await f.close()
    }

    @MainActor private final class GroupProbe { var room: RoomID?; var operation: GroupAvatarOperationID? }
    private func until(_ condition: () async throws -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while try await !condition() { try #require(ContinuousClock.now < end); try await Task.sleep(for: .milliseconds(5)) }
    }
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "resource-owner-store-\(UUID())")
        let user = UserID(uuid: UUID()), job = UUID()
        let io = UnusedOwnerIO()
        let local: GRDBV2LocalSyncStore
        let center: V2ResourceCenter
        var service: V2ResourceManagementService { .init(center: center, localStore: local, downloader: io, directory: io) }
        var profileManager: V2ProfileIntentService { .init(store: local, accountID: user, manager: io) }
        init() async throws {
            local = try .init(databaseURL: root.appending(path: "V2.sqlite"), installationBinding: .init(value: UUID()), userID: user)
            center = try await .make(scope: .init(incarnation: UUID(), accountID: user, directory: root.appending(path: "account"), cacheDirectory: root.appending(path: "cache")), store: local)
        }
        func profile() async throws -> V2ProfileIntent {
            let asset = try await center.importLocal(data: Data("avatar".utf8), displayName: .init("avatar.png"), contentType: .init("image/png"), purpose: .personalAvatar)
            let source = try V2ProfileAvatarUpload(id: job, localAssetID: asset.id, displayName: asset.displayName.value, contentType: asset.contentType.value, byteCount: asset.byteCount)
            let intent = try await local.enqueueProfileIntent(accountID: user, expectedRevision: .init(rawValue: 1)!, patch: .init(displayName: .set("original"), avatar: .set(.init(mediaID: .init(uuid: job)))), avatarUpload: source)
            let request = try V2ResourceUploadRequest(operationID: .init(uuid: job), mediaID: .init(uuid: job), usage: .userAvatar, contentType: asset.contentType.value, byteCount: asset.byteCount, checksum: asset.checksum, displayName: asset.displayName)
            _ = try await local.prepareResourceTransfer(id: job, request: request, localAssetID: asset.id)
            return intent
        }
        func close() async throws { await center.close(); try await local.close(); try FileManager.default.removeItem(at: root) }
    }
}

private actor UnusedOwnerIO: V2OwnProfileManaging, V2ConversationMediaDownloading, V2RoomResourceDirectoryReading, V2GroupAvatarManaging, V2ConversationAttachmentStaging {
    func changeUsingResource(roomID: RoomID, expectedRevision: UInt64, selection: V2AvatarResourceSelection) throws { throw unexpected() }
    private(set) var calls = 0
    private func unexpected() -> V2ResourceStorageError { calls += 1; return .unavailable }
    func currentProfile() throws -> V2ProfileView { throw unexpected() }
    func patchProfile(_ command: V2ProfileUpdateCommand) throws -> V2ProfileUpdateResult { throw unexpected() }
    func recoverProfile(_ request: V2ProfileOperationRecoveryRequest) throws -> V2ProfileOperationRecoveryResult { throw unexpected() }
    func cachedFile(_ media: V2MediaReference, message: V2MediaMessageLocation?) async throws -> V2DownloadedConversationMedia? { nil }
    func borrowCached(_ media: V2MediaReference, message: V2MediaMessageLocation?) throws -> V2ConversationMediaFileLease? { throw unexpected() }
    func download(_ media: V2MediaReference, message: V2MediaMessageLocation?) throws -> V2DownloadedConversationMedia { throw unexpected() }
    func query(roomID: RoomID, query: V2RoomResourceQuery) throws -> V2RoomResourcePage { throw unexpected() }
    func load(roomID: RoomID) throws -> V2GroupAvatarManagementSnapshot { throw unexpected() }
    func pending(roomID: RoomID) throws -> [V2GroupAvatarIntent] { throw unexpected() }
    func pendingIntent(roomID: RoomID, operationID: GroupAvatarOperationID) throws -> V2GroupAvatarIntent? { throw unexpected() }
    func change(roomID: RoomID, expectedRevision: UInt64, image: V2StagedConversationAttachment?) throws { throw unexpected() }
    func act(roomID: RoomID, operationID: GroupAvatarOperationID, action: V2GroupAvatarManagementAction) throws { throw unexpected() }
    func stageImportedFile(at sourceURL: URL, purpose: V2LocalResourceAssetPurpose) throws -> V2StagedConversationAttachment { throw unexpected() }
    func stageNormalizedPhoto(_ photo: V2NormalizedPhoto, purpose: V2LocalResourceAssetPurpose) throws -> V2StagedConversationAttachment { throw unexpected() }
    func selectedAttachments(purpose: V2LocalResourceAssetPurpose) throws -> [V2StagedConversationAttachment] { throw unexpected() }
    func borrow(_ context: V2LocalResourceReadContext) throws -> V2ResourceFileLease { throw unexpected() }
    func discard(_ attachment: V2StagedConversationAttachment) { Issue.record("Owner routing must not discard a file directly") }
}
