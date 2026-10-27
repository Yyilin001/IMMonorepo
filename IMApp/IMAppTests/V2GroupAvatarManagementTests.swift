import Foundation
import IMV2Core
import Synchronization
import Testing
@testable import IMV2ClientKit
@testable import IMApp

@MainActor
@Suite("Group avatar management admission and recovery", .timeLimit(.minutes(1)))
struct V2GroupAvatarManagementTests {
    @Test func existingResourceCreatesImportAndRevalidatesPermissionsAndSource() async throws {
        let f = try await AvatarManagementFixture()
        let location = V2MediaMessageLocation(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()))
        let key = V2ResourceKey(home: .room(location.roomID), mediaID: .init(uuid: UUID()))
        let descriptor = try V2ResourceDescriptor(key: key, revision: 1, displayName: .init("已有头像.png"), contentType: "image/png", byteCount: 3,
            checksum: .init(value: String(repeating: "a", count: 64)), state: .ready)
        try await f.store.indexResource(descriptor, reference: .message(location, ordinal: 0), businessRevision: 1)
        let source = try #require(try await f.resources.details(for: key)?.sources.first)
        let selection = V2AvatarResourceSelection(key: key, source: source, displayName: descriptor.displayName.value)
        await f.authority.configure(canManage: false)
        await #expect(throws: V2GroupAvatarManagementError.forbidden) { try await f.manager.changeUsingResource(roomID: f.room, expectedRevision: 0, selection: selection) }
        #expect(try await f.store.pendingGroupAvatarIntents(in: f.room).isEmpty)
        await f.authority.configure(canManage: true)
        try await f.manager.changeUsingResource(roomID: f.room, expectedRevision: 0, selection: selection)
        let intent = try #require(try await f.store.pendingGroupAvatarIntents(in: f.room).first)
        let id = try #require(intent.importJobID), imported = try #require(try await f.store.resourceImport(id: id))
        #expect(intent.uploadJobID == nil && imported.request.targetUsage == .groupAvatar(f.room))
        #expect(imported.request.source == selection.importSource && imported.request.targetMediaID == intent.command.mutation.mediaID)
        #expect(imported.request.targetMediaID != key.mediaID)
        try await f.intents.cancel(intent.id)
        try await f.store.revokeResourceReference(.message(location, ordinal: 0), businessRevision: 2)
        await #expect(throws: V2GroupAvatarManagementError.invalidDraft) { try await f.manager.changeUsingResource(roomID: f.room, expectedRevision: 0, selection: selection) }
        #expect(try await f.store.pendingGroupAvatarIntents(in: f.room).isEmpty)
        try await f.close()
    }
    @Test("a recreated page restores unsubmitted originals and hands them to the durable upload once")
    func restoresGroupSelectionAndTransfersOwnership() async throws {
        let f = try await AvatarManagementFixture(), image = try await f.image()
        let stager = V2FileConversationAttachmentStager(resources: f.resources)
        let first = V2GroupAvatarManagementStore(roomID: f.room, manager: f.manager, stager: stager, notifier: nil)
        await first.observe()
        #expect(first.drafts.map(\.localAssetID) == [image.localAssetID])
        first.suspend()
        let second = V2GroupAvatarManagementStore(roomID: f.room, manager: f.manager, stager: stager, notifier: nil)
        await second.observe()
        #expect(second.drafts.map(\.localAssetID) == [image.localAssetID])
        second.submitDraft(image)
        while second.isPerformingAction { await Task.yield() }
        #expect(second.drafts.isEmpty)
        #expect(second.pending.count == 1)
        let job = try #require(try await f.store.resourceTransfer(id: image.id))
        #expect(job.localAssetID == image.localAssetID)
        let lease = try await stager.borrow(.upload(job.id))
        #expect(try Data(contentsOf: lease.fileURL) == Data([1,2,3]))
        await lease.release()
        await #expect(throws: V2ResourceStorageError.unavailable) { try await stager.borrow(.selection(image.localAssetID)) }
        second.suspend(); await stager.close(); try await f.close()
    }

    @Test("a rejected new group mutation preserves its selection for retry and explicit discard")
    func selectionSurvivesAuthorityFailure() async throws {
        let f = try await AvatarManagementFixture(), image = try await f.image()
        let stager = V2FileConversationAttachmentStager(resources: f.resources)
        let page = V2GroupAvatarManagementStore(roomID: f.room, manager: f.manager, stager: stager, notifier: nil)
        await page.observe()
        await f.authority.configure(revision: 2)
        page.submitDraft(image)
        while page.isPerformingAction { await Task.yield() }
        #expect(page.feedback != nil)
        #expect(page.drafts.map(\.localAssetID) == [image.localAssetID])
        #expect(try await f.store.resourceTransfer(id: image.id) == nil)
        let lease = try await stager.borrow(.selection(image.localAssetID))
        #expect(try Data(contentsOf: lease.fileURL) == Data([1,2,3]))
        await lease.release()
        page.discardDraft(image)
        while page.isPerformingAction { await Task.yield() }
        #expect(page.drafts.isEmpty)
        #expect(try await stager.selectedAttachments(purpose: .groupAvatar(f.room)).isEmpty)
        page.suspend(); await stager.close(); try await f.close()
    }

    @Test func newImagesRequireCurrentCapabilityRoleRevisionAndManagedFile() async throws {
        let f = try await AvatarManagementFixture(), image = try await f.image()
        await f.authority.configure(uploads: false)
        await #expect(throws: V2GroupAvatarManagementError.unavailable) {
            try await f.manager.change(roomID: f.room, expectedRevision: 0, image: image)
        }
        await f.authority.configure(uploads: true, canManage: false)
        await #expect(throws: V2GroupAvatarManagementError.forbidden) {
            try await f.manager.change(roomID: f.room, expectedRevision: 0, image: image)
        }
        await f.authority.configure(canManage: true, revision: 2)
        await #expect(throws: V2GroupAvatarManagementError.revisionChanged) {
            try await f.manager.change(roomID: f.room, expectedRevision: 0, image: image)
        }
        let unsupported = V2StagedConversationAttachment(id: image.id, localAssetID: image.localAssetID,
            displayName: image.displayName, contentType: "image/gif", byteCount: image.byteCount)
        await #expect(throws: V2GroupAvatarManagementError.imageUnsupported) {
            try await f.manager.change(roomID: f.room, expectedRevision: 2, image: unsupported)
        }
        let outside = V2StagedConversationAttachment(id: image.id, localAssetID: .init(),
            displayName: image.displayName, contentType: image.contentType, byteCount: image.byteCount)
        await #expect(throws: V2GroupAvatarManagementError.invalidDraft) {
            try await f.manager.change(roomID: f.room, expectedRevision: 2, image: outside)
        }
        #expect(try await f.store.resourceTransfer(id: image.id) == nil)
        #expect(try await f.manager.pending(roomID: f.room).isEmpty)
        try await f.manager.change(roomID: f.room, expectedRevision: 2, image: image)
        let saved = try #require(try await f.manager.pending(roomID: f.room).first)
        #expect(saved.command.expectedRevision == 2 && saved.uploadJobID == image.id)
        let job = try #require(try await f.store.resourceTransfer(id: image.id))
        #expect(job.request.usage == .groupAvatar(f.room) && job.localAssetID == image.localAssetID)
        #expect(job.request.checksum.value == (try #require(try await f.resources.localAsset(image.localAssetID)).checksum.value))
        let another = try await f.image()
        await #expect(throws: V2GroupAvatarManagementError.pendingDecision) {
            try await f.manager.change(roomID: f.room, expectedRevision: 2, image: another)
        }
        #expect(try await f.store.resourceTransfer(id: another.id) == nil)
        try await f.close()
    }

    @Test func closedReplacementNeedsFreshAuthorityAndRetainsTheOriginalFile() async throws {
        let f = try await AvatarManagementFixture(), image = try await f.image()
        try await f.manager.change(roomID: f.room, expectedRevision: 0, image: image)
        let original = try #require(try await f.manager.pending(roomID: f.room).first)
        _ = try? await f.intents.resume(original.id)
        try await f.manager.act(roomID: f.room, operationID: original.id, action: .closeIfAbsent)
        #expect(try await f.store.groupAvatarIntent(original.id)?.stage == .closed)
        await f.authority.configure(uploads: false, revision: 5)
        await #expect(throws: V2GroupAvatarManagementError.unavailable) {
            try await f.manager.act(roomID: f.room, operationID: original.id, action: .replace(expectedRevision: 5))
        }
        await f.authority.configure(uploads: true)
        await #expect(throws: V2GroupAvatarManagementError.revisionChanged) {
            try await f.manager.act(roomID: f.room, operationID: original.id, action: .replace(expectedRevision: 4))
        }
        #expect(try await f.store.groupAvatarIntent(original.id)?.closedDisposition == .awaitingDecision)
        try await f.manager.act(roomID: f.room, operationID: original.id, action: .replace(expectedRevision: 5))
        let replacement = try #require(try await f.manager.pending(roomID: f.room).first)
        #expect(replacement.id != original.id && replacement.command.expectedRevision == 5)
        #expect(replacement.command.mutation.mediaID != original.command.mutation.mediaID)
        let replacementJobID = try #require(replacement.uploadJobID)
        let job = try #require(try await f.store.resourceTransfer(id: replacementJobID))
        #expect(job.localAssetID == image.localAssetID)
        #expect(try await f.store.groupAvatarIntent(original.id)?.closedDisposition == .replaced)
        #expect(try await f.resources.localAsset(image.localAssetID)?.availability == .local)
        try await f.close()
    }

    @Test func losingMembershipStillAllowsRecoveryAndAbandonmentOfOwnOperation() async throws {
        let f = try await AvatarManagementFixture()
        try await f.manager.change(roomID: f.room, expectedRevision: 0, image: nil)
        let intent = try #require(try await f.manager.pending(roomID: f.room).first)
        _ = try? await f.intents.resume(intent.id)
        await f.authority.configure(denied: true)
        let snapshot = try await f.manager.load(roomID: f.room)
        guard case .forbidden = snapshot.access else { Issue.record("membership denial was hidden"); try await f.close(); return }
        #expect(snapshot.pending.map(\.id) == [intent.id])
        #expect(try await f.manager.pendingPage(after: nil).entries.map(\.id) == [intent.id])
        #expect(try await f.manager.pendingIntent(roomID: f.room, operationID: intent.id)?.id == intent.id)
        await #expect(throws: V2GroupAvatarIntentError.accountMismatch) {
            _ = try await f.manager.pendingIntent(roomID: .init(uuid: UUID()), operationID: intent.id)
        }
        await #expect(throws: V2GroupAvatarIntentError.accountMismatch) {
            try await f.manager.act(roomID: .init(uuid: UUID()), operationID: intent.id, action: .closeIfAbsent)
        }
        try await f.manager.act(roomID: f.room, operationID: intent.id, action: .query)
        #expect(try await f.store.groupAvatarIntent(intent.id)?.closureProof == nil)
        try await f.manager.act(roomID: f.room, operationID: intent.id, action: .closeIfAbsent)
        try await f.manager.act(roomID: f.room, operationID: intent.id, action: .abandon)
        #expect(try await f.manager.pending(roomID: f.room).isEmpty)
        #expect(try await f.store.groupAvatarIntent(intent.id)?.closedDisposition == .abandoned)
        #expect(try await f.manager.pendingPage(after: nil).entries.isEmpty)
        #expect(try await f.manager.pendingIntent(roomID: f.room, operationID: intent.id) == nil)
        try await f.close()
    }

    @Test("capability lookup cannot mask invalidation after the presentation read")
    func capabilitySessionInvalidation() async throws {
        let f = try await AvatarManagementFixture()
        await f.authority.invalidateCapabilitySession()
        await #expect(throws: V2AuthSessionError.sessionInvalidated) { try await f.manager.load(roomID: f.room) }
        #expect(try await f.manager.pending(roomID: f.room).isEmpty)
        try await f.close()
    }

    @Test("expired or wrong-device presentations cannot admit a new command", arguments: [false, true])
    func presentationFences(wrongDevice: Bool) async throws {
        let clock = Mutex(ContinuousClock.now)
        let f = try await AvatarManagementFixture(now: { clock.withLock { $0 } })
        if wrongDevice { await f.authority.configure(wrongDevice: true) }
        else { await f.authority.configure(onRead: { clock.withLock { $0 = $0.advanced(by: .seconds(301)) } }) }
        if wrongDevice {
            await #expect(throws: V2GroupAvatarReadError.invalidResponse) { try await f.manager.load(roomID: f.room) }
        } else {
            await #expect(throws: V2GroupAvatarManagementError.unavailable) { try await f.manager.load(roomID: f.room) }
        }
        if wrongDevice {
            await #expect(throws: V2GroupAvatarReadError.invalidResponse) { try await f.manager.change(roomID: f.room, expectedRevision: 0, image: nil) }
        } else {
            await #expect(throws: V2GroupAvatarManagementError.unavailable) { try await f.manager.change(roomID: f.room, expectedRevision: 0, image: nil) }
        }
        #expect(try await f.manager.pending(roomID: f.room).isEmpty)
        try await f.close()
    }
}

@MainActor
private struct AvatarManagementFixture {
    let root: URL, directory: URL
    let actor = UserID(uuid: UUID()), device = DeviceID(uuid: UUID()), room = RoomID(uuid: UUID())
    let store: GRDBV2LocalSyncStore
    let authority: ManagementAuthority
    let transfers: V2ResourceTransferEngine
    let intents: V2GroupAvatarIntentEngine
    let resources: V2ResourceCenter
    let manager: V2GroupAvatarManagementService
    init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directory = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try GRDBV2LocalSyncStore(databaseURL: root.appendingPathComponent("db.sqlite"), installationBinding: .init(value: UUID()), userID: actor)
        authority = ManagementAuthority(actor: actor, device: device, room: room)
        let commands = ManagementCommands(actor: actor, device: device)
        resources = try await makeAppResourceTestCenter(store: store, root: root)
        transfers = V2ResourceTransferEngine(store: store, control: ManagementResourceControl(), executor: ManagementResourceControl(), resources: resources)
        intents = V2GroupAvatarIntentEngine(actorUserID: actor, store: store, transfers: transfers, submissions: commands, recovery: commands)
        manager = V2GroupAvatarManagementService(actorUserID: actor, deviceID: device, store: store, intents: intents,
            reader: authority, capabilities: authority, resources: resources, now: now)
    }
    func image() async throws -> V2StagedConversationAttachment {
        let id = UUID(), bytes = Data([1, 2, 3]), url = directory.appendingPathComponent(id.uuidString)
        try bytes.write(to: url)
        let asset = try await resources.importLocal(at: url, displayName: .init("image.png"), contentType: .init("image/png"), purpose: .groupAvatar(room), id: .init(id))
        return .init(asset: asset)
    }
    func close() async throws {
        async let management: Void = manager.close()
        await intents.close(); await transfers.close(); await management
        await resources.close(); try await store.close()
        try FileManager.default.removeItem(at: root)
    }
}

private actor ManagementAuthority: V2GroupAvatarPresentationReading, V2ResourceCapabilityReading {
    let actor: UserID, device: DeviceID, room: RoomID
    var uploads = true, canManage = true, denied = false, wrongDevice = false
    var revision: UInt64 = 0
    var capabilityInvalidated = false
    var onRead: (@Sendable () -> Void)?
    init(actor: UserID, device: DeviceID, room: RoomID) { self.actor = actor; self.device = device; self.room = room }
    func configure(uploads: Bool? = nil, canManage: Bool? = nil, revision: UInt64? = nil, denied: Bool? = nil,
                   wrongDevice: Bool? = nil, onRead: (@Sendable () -> Void)? = nil) {
        if let uploads { self.uploads = uploads }; if let canManage { self.canManage = canManage }
        if let revision { self.revision = revision }; if let denied { self.denied = denied }
        if let wrongDevice { self.wrongDevice = wrongDevice }; self.onRead = onRead
    }
    func readGroupAvatar(roomID: RoomID) throws -> V2GroupAvatarPresentation {
        if denied { throw V2GroupAvatarReadError.forbidden }
        let time = Date()
        onRead?()
        return try .init(actorUserID: actor, deviceID: wrongDevice ? .init(uuid: UUID()) : device,
            state: .init(roomID: room, mediaID: nil, revision: revision), membershipRevision: 1, resourceGeneration: nil,
            canManage: canManage, avatar: nil, observedAt: time, validUntil: time.addingTimeInterval(300), serverNow: time)
    }
    func invalidateCapabilitySession() { capabilityInvalidated = true }
    func capabilities() throws -> V2ResourceCapabilities {
        if capabilityInvalidated { throw V2AuthSessionError.sessionInvalidated }
        return try .init(uploadModes: [.httpPut], maximumBytes: 10 * 1_024 * 1_024,
            allowedUsages: uploads ? [.messageAttachment, .groupAvatar] : [.messageAttachment], maximumParts: 0, backgroundTransfer: false)
    }
}

private actor ManagementCommands: V2GroupAvatarCommandSubmitting, V2GroupAvatarOperationRecovering {
    let actor: UserID, device: DeviceID
    init(actor: UserID, device: DeviceID) { self.actor = actor; self.device = device }
    func submitGroupAvatar(_ command: V2GroupAvatarCommand) throws -> V2GroupAvatarCommandResponse {
        throw V2GroupAvatarSubmissionError.outcomeUnknown
    }
    func recoverGroupAvatar(_ request: V2GroupAvatarRecoveryRequest) throws -> V2GroupAvatarRecoveryResponse {
        try .init(actorUserID: actor, deviceID: device, request: request, result: request.action == .query ? .unresolved : .closed)
    }
}

private struct ManagementResourceControl: V2ResourceUploadControlling, V2ResourcePlanExecuting {
    func create(_ request: V2ResourceUploadRequest) throws -> V2ResourceUploadSession {
        try .init(locator: .init(home: request.usage.home(actorUserID: .init(uuid: UUID())), sessionID: .init(uuid: UUID())),
            mediaID: request.mediaID, generation: 1, state: .completed, resourceState: .ready,
            expiresAt: Date().addingTimeInterval(60), bindableUntil: Date().addingTimeInterval(60))
    }
    func status(_ locator: V2ResourceUploadLocator) throws -> V2ResourceUploadSession { throw CancellationError() }
    func target(_ session: V2ResourceUploadSession) throws -> V2ResourceTransferPlan? { throw CancellationError() }
    func finalize(_ session: V2ResourceUploadSession) throws -> V2ResourceUploadSession { throw CancellationError() }
    func cancel(_ session: V2ResourceUploadSession) -> V2ResourceUploadSession { session }
    func upload(fileURL: URL, plan: V2ResourceTransferPlan) throws { throw CancellationError() }
}
