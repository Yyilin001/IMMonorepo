import Foundation
import GRDB
import IMV2Core
import Testing
@testable import IMV2ClientKit

struct V2ProfileIntentTests {
    @Test(arguments: ["missing", "pending", "expired", "wrongMedia", "cancelled", "ready"])
    func avatarFreezeRequiresCurrentReadyUpload(state: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let user = UserID(uuid: UUID()), id = UUID(), now = Date()
        let store = try GRDBV2LocalSyncStore(databaseURL: root.appendingPathComponent("profile.sqlite"),
            installationBinding: .init(value: UUID()), userID: user)
        let source = try V2ProfileAvatarUpload(id: id, localAssetID: .init(UUID()),
            displayName: "avatar", contentType: "image/png", byteCount: 10)
        try await store.seedMetadataProfileSource(source)
        let intent = try await store.enqueueProfileIntent(accountID: user, expectedRevision: .init(rawValue: 1)!,
            patch: .init(displayName: .set("Retained draft")), avatarUpload: source)
        if state != "missing" {
            try await prepareUpload(source, store: store, user: user,
                state: state == "pending" ? .uploading : state == "cancelled" ? .cancelled : .completed,
                until: state == "expired" ? now.addingTimeInterval(-60) : now.addingTimeInterval(600))
        }
        let avatar = V2AvatarReference(mediaID: .init(uuid: state == "wrongMedia" ? UUID() : id))
        if state == "ready" {
            #expect(try await store.freezeProfileIntent(id: intent.id, avatar: avatar, now: now).workID != nil)
        } else {
            let expected: V2ResourceJournalError? = state == "expired" ? .bindingExpired : nil
            do {
                _ = try await store.freezeProfileIntent(id: intent.id, avatar: avatar, now: now)
                Issue.record("Unready or expired upload froze a profile operation")
            } catch {
                if let expected { #expect(error as? V2ResourceJournalError == expected) }
                else { #expect(error as? V2OperationWorkError == .dependencyUnavailable) }
            }
            #expect(try await store.profileIntent(id: intent.id)?.workID == nil)
            #expect(try await store.testHeldAssetIDs().contains(source.localAssetID))
        }
        try await store.close()
    }

    @Test func expiredReadyAvatarPreparationRetainsDraftInsteadOfSubmitting() async throws {
        let (store, user) = try fixture(), id = UUID()
        let source = try V2ProfileAvatarUpload(id: id, localAssetID: .init(id),
            displayName: "avatar", contentType: "image/png", byteCount: 10)
        try await store.seedMetadataProfileSource(source)
        let intent = try await store.enqueueProfileIntent(accountID: user, expectedRevision: .init(rawValue: 1)!,
            patch: .init(displayName: .set("Retained draft")), avatarUpload: source)
        try await prepareUpload(source, store: store, user: user, until: Date().addingTimeInterval(-60))
        let service = V2ProfileIntentService(store: store, accountID: user,
            manager: ProfileLateSnapshotFixture(snapshot: try snapshot(user: user, revision: 2)), avatars: ProfileReadyAvatar())
        #expect(try await service.prepareNextIntent())
        #expect(try await store.profileIntent(id: intent.id)?.workID == nil)
        #expect(try await store.firstUnfinishedProfileIntent(accountID: user) == nil)
        #expect(try await service.pendingIntent()?.patch.displayName == .set("Retained draft"))
        #expect(try await store.testHeldAssetIDs().contains(source.localAssetID))
        let reapplied = try await service.resumeOrReapply(intentID: intent.id)
        #expect(reapplied.avatarUpload?.id != id && reapplied.avatarUpload?.localAssetID == source.localAssetID)
        try await store.close()
    }

    @Test(arguments: [V2ResourceUploadSessionState.failed, .cancelled, .expired])
    func terminalAvatarUploadStopsPreparationAndAllowsFreshReapplication(state: V2ResourceUploadSessionState) async throws {
        let (store, user) = try fixture(), id = UUID()
        let source = try V2ProfileAvatarUpload(id: id, localAssetID: .init(id),
            displayName: "avatar", contentType: "image/png", byteCount: 10)
        try await store.seedMetadataProfileSource(source)
        let intent = try await store.enqueueProfileIntent(accountID: user, expectedRevision: .init(rawValue: 1)!,
            patch: .init(displayName: .set("Retained draft")), avatarUpload: source)
        try await prepareUpload(source, store: store, user: user, state: state)
        let service = V2ProfileIntentService(store: store, accountID: user,
            manager: ProfileLateSnapshotFixture(snapshot: try snapshot(user: user, revision: 2)), avatars: ProfileReadyAvatar())
        #expect(try await service.prepareNextIntent())
        #expect(try await store.profileIntent(id: intent.id)?.workID == nil)
        #expect(try await store.firstUnfinishedProfileIntent(accountID: user) == nil)
        #expect(try await service.pendingIntent()?.patch.displayName == .set("Retained draft"))
        let reapplied = try await service.resumeOrReapply(intentID: intent.id)
        #expect(reapplied.avatarUpload?.id != id && reapplied.avatarUpload?.localAssetID == source.localAssetID)
        #expect(try await store.testHeldAssetIDs().contains(source.localAssetID))
        try await store.close()
    }

    private func prepareUpload(_ source: V2ProfileAvatarUpload, store: GRDBV2LocalSyncStore, user: UserID,
                               state: V2ResourceUploadSessionState = .completed, until: Date = .distantFuture) async throws {
        let request = try V2ResourceUploadRequest(operationID: .init(uuid: source.id), mediaID: .init(uuid: source.id),
            usage: .userAvatar, contentType: source.contentType, byteCount: source.byteCount,
            checksum: .init(value: String(repeating: "a", count: 64)), displayName: .init(source.displayName))
        _ = try await store.prepareResourceTransfer(id: source.id, request: request, localAssetID: source.localAssetID)
        try await store.saveResourceSession(.init(locator: .init(home: .account(user), sessionID: .init(uuid: UUID())),
            mediaID: request.mediaID, generation: 1, state: state, resourceState: state == .completed ? .ready : .pending,
            expiresAt: .distantFuture, bindableUntil: state == .completed ? until : nil), for: source.id)
    }

    @Test(arguments: ["readyExpired", "readyValid", "failed", "expired", "cancelled", "uploading", "uploadingExpired", "prepared"])
    func avatarReapplicationRenewsOnlyUnusableUploadIdentity(state: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let user = UserID(uuid: UUID()), id = UUID()
        let store = try GRDBV2LocalSyncStore(databaseURL: root.appendingPathComponent("profile.sqlite"),
            installationBinding: .init(value: UUID()), userID: user)
        let source = try V2ProfileAvatarUpload(id: id, localAssetID: .init(UUID()),
            displayName: "avatar.png", contentType: "image/png", byteCount: 10)
        try await store.seedMetadataProfileSource(source)
        let intent = try await store.enqueueProfileIntent(accountID: user, expectedRevision: .init(rawValue: 1)!,
            patch: .init(displayName: .set("Kept nickname")), avatarUpload: source)
        let request = try V2ResourceUploadRequest(operationID: .init(uuid: id), mediaID: .init(uuid: id), usage: .userAvatar,
            contentType: source.contentType, byteCount: source.byteCount, checksum: .init(value: String(repeating: "a", count: 64)),
            displayName: .init(source.displayName))
        _ = try await store.prepareResourceTransfer(id: id, request: request, localAssetID: source.localAssetID)
        let ready = state.hasPrefix("ready")
        if state != "prepared" {
            let sessionState: V2ResourceUploadSessionState = ready ? .completed : try #require(.init(rawValue: state == "uploadingExpired" ? "uploading" : state))
            try await store.saveResourceSession(.init(locator: .init(home: .account(user), sessionID: .init(uuid: UUID())),
                mediaID: request.mediaID, generation: 1, state: sessionState, resourceState: ready ? .ready : .pending,
                expiresAt: Date().addingTimeInterval(state == "uploadingExpired" ? -60 : 600),
                bindableUntil: ready ? Date().addingTimeInterval(state == "readyExpired" ? -60 : 600) : nil), for: id)
        }
        try await store.expireUnfrozenProfileIntent(id: intent.id)
        let service = V2ProfileIntentService(store: store, accountID: user,
            manager: ProfileLateSnapshotFixture(snapshot: try snapshot(user: user, revision: 2)))
        let replacement = try await service.resumeOrReapply(intentID: intent.id)
        let next = try #require(replacement.avatarUpload)
        let renew = !["readyValid", "uploading", "prepared"].contains(state)
        #expect((next.id != id) == renew)
        #expect(next.localAssetID == source.localAssetID)
        #expect(next.displayName == source.displayName && next.byteCount == source.byteCount)
        #expect(replacement.patch.displayName == intent.patch.displayName)
        #expect(replacement.operationID != intent.operationID)
        #expect(try await store.testHeldAssetIDs().contains(source.localAssetID))
        let oldOwners = try await store.resourceBusinessOwners(.init(transfer: .upload(id)))
        #expect(!oldOwners.entries.contains { $0.owner == .profileIntent(intent.id) })
        try await store.close()
    }

    @Test func reapplicationUsesHighestConfirmedRevision() async throws {
        let user = UserID(uuid: UUID())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("profile.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: .init(value: UUID()), userID: user)
        let intent = try await store.enqueueProfileIntent(accountID: user, expectedRevision: .init(rawValue: 1)!,
            patch: .init(displayName: .set("Retained draft")), avatarUpload: nil)
        let workID = try #require(intent.workID), command = try GRDBV2LocalSyncStore.profileCommand(intent: intent)
        guard case .claimed = try await store.claimOperationWork(id: workID, ownerID: UUID(), action: .submit, now: Date()) else { throw V2OperationWorkError.invalidTransition }
        let conflict = try V2ProfileOperationReceipt(actorUserID: user, operationID: intent.operationID, fingerprint: command.fingerprint,
            outcome: .rejected(.revisionConflict(current: .init(rawValue: 2)!)), resolvedAtMilliseconds: 1)
        try await store.completeProfileIntent(intent: intent, result: .init(receipt: conflict, currentSnapshot: nil))
        try await store.saveOwnProfileSnapshot(snapshot(user: user, revision: 5))
        let service = V2ProfileIntentService(store: store, accountID: user, manager: ProfileLateSnapshotFixture(snapshot: try snapshot(user: user, revision: 2)))
        let replacement = try await service.resumeOrReapply(intentID: intent.id)
        #expect(replacement.expectedRevision.rawValue == 5)
        #expect(replacement.patch == intent.patch)
        #expect(replacement.operationID != intent.operationID)
        #expect(try await store.ownProfileSnapshot(accountID: user)?.revision.rawValue == 5)
        try await store.close()
    }

    @Test func avatarIntentFreezesAtFullByteQuotaWithMaximumMediaIdentity() async throws {
        let (store, user) = try fixture(), now = Date()
        // Imported identities can use the full contract length; upload avatar
        // identities are UUIDs. Keep the quota test's maximum-size payload valid.
        let avatar = V2AvatarReference(mediaID: try .init(String(repeating: "z", count: MediaID.maximumUTF8Bytes)))
        let source = try V2ProfileAvatarImport(id: UUID(), request: .init(operationID: .init(uuid: UUID()),
            source: .message(location: .init(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID())),
                mediaID: .init(uuid: UUID()), variantID: nil), targetUsage: .userAvatar, targetMediaID: avatar.mediaID))
        let intent = try await store.enqueueProfileImportIntent(accountID: user, expectedRevision: .init(rawValue: 1)!,
            patch: .init(displayName: .set("Name")), source: source, now: now)
        let status = try V2ResourceImportStatus(locator: .init(home: .account(user), operationID: source.request.operationID),
            mediaID: avatar.mediaID, state: .ready, bindableUntil: now.addingTimeInterval(600))
        try await store.databasePool.write { try GRDBV2LocalSyncStore.saveResourceImport(status, id: source.id, db: $0) }
        let reservation = try await store.databasePool.read { db in
            try Int64.fetchOne(db, sql: "SELECT payload_bytes FROM v2_profile_intents WHERE intent_id=?", arguments: [intent.id.uuidString])!
        }
        let blocker = UUID()
        let identity = try V2OperationIdentity(accountID: user, scope: .account(user), operation: .profileUpdate(.init(uuid: blocker)))
        let fingerprint = try V2OperationFingerprint(kind: .profileUpdate, fields: [.init("fixture", .text("quota"))])
        try await store.databasePool.write { db in
            _ = try GRDBV2LocalSyncStore.insertOperationWork(.init(id: blocker, intentID: blocker,
                identity: identity, fingerprint: fingerprint, orderingKey: "quota-blocker",
                payloadBytes: V2OperationWorkLimits().maximumPayloadBytes - reservation,
                admissionDeadline: nil), now: now, db: db)
        }
        await #expect(throws: V2OperationWorkError.capacityExceeded) {
            try await store.databasePool.read { db in
                try GRDBV2LocalSyncStore.requireOperationCapacity(adding: 1, db: db)
            }
        }
        let frozen = try await store.freezeProfileIntent(id: intent.id, avatar: avatar, now: now)
        #expect(frozen.workID != nil)
        #expect(frozen.patch.avatar == .set(avatar))
        #expect(frozen.operationID == intent.operationID && frozen.deadline == intent.deadline)
        try await store.close()
    }
    @Test func avatarDeadlineCannotOverwriteDiscardedIntent() async throws {
        let (store, user) = try fixture()
        let id = UUID()
        let source = try V2ProfileAvatarUpload(id: id, localAssetID: .init(id),
            displayName: "avatar", contentType: "image/png", byteCount: 10)
        try await store.seedMetadataProfileSource(source)
        let intent = try await store.enqueueProfileIntent(accountID: user, expectedRevision: .init(rawValue: 1)!,
            patch: .init(avatar: .set(.init(mediaID: .init(uuid: id)))), avatarUpload: source)
        let avatars = ProfileWaitingAvatar()
        let service = V2ProfileIntentService(store: store, accountID: user, manager: ProfileRefreshed401Fixture(), avatars: avatars,
            sleepUntil: { _ in
                await avatars.waitUntilStarted()
                try await store.discardProfileIntentSource(id: intent.id)
            })
        #expect(try await service.prepareNextIntent())
        #expect(try await store.databasePool.read {
            try String.fetchOne($0, sql: "SELECT local_terminal FROM v2_profile_intents WHERE intent_id=?", arguments: [intent.id.uuidString])
        } == "cancelledLocally")
        #expect(try await store.profileIntent(id: intent.id)?.workID == nil)
        #expect(await avatars.finished)
        try await store.close()
    }
    @Test func avatarWaitExpiresWithoutFreezingAndRetainsSource() async throws {
        let (store, user) = try fixture()
        let id = UUID()
        let source = try V2ProfileAvatarUpload(id: id, localAssetID: .init(id),
            displayName: "avatar", contentType: "image/png", byteCount: 10)
        try await store.seedMetadataProfileSource(source)
        let intent = try await store.enqueueProfileIntent(accountID: user, expectedRevision: .init(rawValue: 1)!,
            patch: .init(avatar: .set(.init(mediaID: .init(uuid: id)))), avatarUpload: source)
        let avatars = ProfileWaitingAvatar()
        let service = V2ProfileIntentService(store: store, accountID: user, manager: ProfileRefreshed401Fixture(), avatars: avatars,
            sleepUntil: { _ in await avatars.waitUntilStarted() })
        #expect(try await service.prepareNextIntent())
        #expect(try await store.firstUnfinishedProfileIntent(accountID: user) == nil)
        #expect(try await store.profileIntent(id: intent.id)?.workID == nil)
        #expect(try await store.testHeldAssetIDs().contains(.init(id)))
        #expect(await avatars.finished)
        try await store.close()
    }
    private func fixture() throws -> (GRDBV2LocalSyncStore, UserID) {
        let user = UserID(uuid: UUID())
        return (try GRDBV2LocalSyncStore(databaseURL: FileManager.default.temporaryDirectory.appending(path: "profile-intent-\(UUID()).sqlite"), installationBinding: .init(value: UUID()), userID: user),user)
    }
    @Test func nicknameFreezeIsAtomicAndPreservesAvatarField() async throws {
        let (store,user) = try fixture()
        let intent = try await store.enqueueProfileIntent(accountID: user, expectedRevision: .init(rawValue: 1)!, patch: .init(displayName: .set("Name")), avatarUpload: nil)
        let workID = try #require(intent.workID)
        let work = try #require(try await store.operationWork(id: workID))
        #expect(work.execution == .prepared)
        #expect(intent.patch.avatar == .unchanged)
        let command = try GRDBV2LocalSyncStore.profileCommand(intent: intent)
        #expect(command.fingerprint == work.fingerprint)
        try await store.databasePool.write { try $0.execute(sql: "CREATE TRIGGER fail_profile_work BEFORE INSERT ON v2_operation_work BEGIN SELECT RAISE(ABORT,'test disk failure'); END") }
        // Once the first head finishes, the next enqueue tries its atomic freeze.
        try await store.cancelUnsubmittedOperation(id: work.id, now: Date())
        do { _ = try await store.enqueueProfileIntent(accountID: user, expectedRevision: .init(rawValue: 1)!, patch: .init(displayName: .set("Next")), avatarUpload: nil); Issue.record("must fail transaction") } catch {}
        #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_profile_intents") } == 1)
    }
    @Test func uploadHeadBlocksLaterNicknameAndExpiryUnblocksWithoutLosingFile() async throws {
        let (store,user) = try fixture()
        let id = UUID()
        let source = try V2ProfileAvatarUpload(id: id, localAssetID: .init(id), displayName: "avatar", contentType: "image/png", byteCount: 10)
        try await store.seedMetadataProfileSource(source)
        let first = try await store.enqueueProfileIntent(accountID: user, expectedRevision: .init(rawValue: 1)!, patch: .init(avatar: .set(.init(mediaID: .init(uuid: id)))), avatarUpload: source, now: Date().addingTimeInterval(-86500))
        let second = try await store.enqueueProfileIntent(accountID: user, expectedRevision: .init(rawValue: 1)!, patch: .init(displayName: .set("Later")), avatarUpload: nil)
        #expect(first.workID == nil && second.workID == nil)
        #expect(try await store.firstUnfinishedProfileIntent(accountID: user)?.id == first.id)
        try await store.expireUnfrozenProfileIntent(id: first.id)
        #expect(try await store.firstUnfinishedProfileIntent(accountID: user)?.id == second.id)
        #expect(try await store.testHeldAssetIDs().contains(.init(id)))
        try await store.discardProfileIntentSource(id: first.id)
        #expect(try await store.testHeldAssetIDs().contains(.init(id)) == false)
        #expect(try await store.freezeProfileIntent(id: second.id, avatar: nil).workID != nil)
    }
    @Test func conflictRetainsSourceAndOriginalReceiptKeepsNewerSnapshot() async throws {
        let (store,user) = try fixture()
        let id = UUID()
        let source = try V2ProfileAvatarUpload(id: id, localAssetID: .init(id), displayName: "avatar", contentType: "image/png", byteCount: 10)
        try await store.seedMetadataProfileSource(source)
        let initial = try await store.enqueueProfileIntent(accountID: user, expectedRevision: .init(rawValue: 1)!, patch: .init(avatar: .set(.init(mediaID: .init(uuid: id)))), avatarUpload: source)
        try await prepareUpload(source, store: store, user: user)
        let frozen = try await store.freezeProfileIntent(id: initial.id, avatar: .init(mediaID: .init(uuid: id)))
        let workID = try #require(frozen.workID)
        guard case .claimed = try await store.claimOperationWork(id: workID, ownerID: UUID(), action: .submit, now: Date()) else { Issue.record("expected claim"); return }
        let command = try GRDBV2LocalSyncStore.profileCommand(intent: frozen)
        let receipt = try V2ProfileOperationReceipt(actorUserID: user, operationID: command.operationID, fingerprint: command.fingerprint, outcome: .rejected(.revisionConflict(current: .init(rawValue: 5)!)), resolvedAtMilliseconds: 1)
        try await store.completeProfileIntent(intent: frozen,result: .init(receipt: receipt,currentSnapshot: nil))
        #expect(try await store.operationWork(id: workID)?.execution == .conflicted)
        #expect(try await store.testHeldAssetIDs().contains(.init(id)))
        let newer = try snapshot(user: user, revision: 9)
        try await store.saveOwnProfileSnapshot(newer)
        try await store.saveOwnProfileSnapshot(snapshot(user: user, revision: 4))
        #expect(try await store.ownProfileSnapshot(accountID: user)?.revision.rawValue == 9)
    }
    @Test func committedSourceCanReleaseAndReleaseClaimBlocksNewConsumer() async throws {
        let (store,user) = try fixture()
        let id = UUID()
        let source = try V2ProfileAvatarUpload(id: id, localAssetID: .init(id), displayName: "avatar", contentType: "image/png", byteCount: 10)
        try await store.seedMetadataProfileSource(source)
        let request = try V2ResourceUploadRequest(operationID: .init(uuid: id),mediaID: .init(uuid: id),usage: .userAvatar,contentType: "image/png",byteCount: 10,checksum: .init(value: String(repeating: "a",count: 64)),clientModes: [.httpPut], displayName: .init("avatar"))
        let draft = try await store.enqueueProfileIntent(accountID: user,expectedRevision: .init(rawValue: 1)!,patch: .init(avatar: .set(.init(mediaID: .init(uuid: id)))),avatarUpload: source)
        _ = try await store.prepareMetadataResourceTransfer(id: id,request: request,localAssetID: .init(id))
        try await prepareUpload(source, store: store, user: user)
        #expect(try await store.releasableResourceAssetID(id: id) == nil)
        let frozen = try await store.freezeProfileIntent(id: draft.id,avatar: .init(mediaID: .init(uuid: id)))
        let workID = try #require(frozen.workID)
        guard case .claimed = try await store.claimOperationWork(id: workID,ownerID: UUID(),action: .submit,now: Date()) else { Issue.record("expected claim"); return }
        let command = try GRDBV2LocalSyncStore.profileCommand(intent: frozen)
        let receipt = try V2ProfileOperationReceipt(actorUserID: user,operationID: command.operationID,fingerprint: command.fingerprint,outcome: .committed(revision: .init(rawValue: 2)!,visibilityRevision: .init(rawValue: 2)!),resolvedAtMilliseconds: 1)
        try await store.completeProfileIntent(intent: frozen,result: .init(receipt: receipt,currentSnapshot: nil))
        try await store.releaseResourceSource(id: id)
        #expect(try await store.testHeldAssetIDs().contains(.init(id)) == false)
        await #expect(throws: V2ResourceStorageError.unavailable) {
            try await store.enqueueProfileIntent(accountID: user,expectedRevision: .init(rawValue: 2)!,patch: .init(avatar: .set(.init(mediaID: .init(uuid: id)))),avatarUpload: source)
        }
    }
    @Test func refreshed401RemainsRunnableAndReconcilesOriginalIdentity() async throws {
        let (store,user) = try fixture()
        let service = V2ProfileIntentService(store: store,accountID: user,manager: ProfileRefreshed401Fixture())
        let intent = try await service.enqueue(expectedRevision: .init(rawValue: 1)!,patch: .init(displayName: .set("New")))
        let workID = try #require(intent.workID)
        let owner = UUID()
        guard case .claimed(let submit) = try await store.claimOperationWork(id: workID,ownerID: owner,action: .submit,now: Date()) else { Issue.record("expected submission"); return }
        try await service.execute(submit)
        let deferred = try #require(try await store.operationWork(id: workID))
        #expect(deferred.scheduling == .backingOff)
        #expect(deferred.nextAction == .reconcile)
        guard case .claimed(let query) = try await store.claimOperationWork(id: workID,ownerID: owner,action: .reconcile,now: deferred.nextActionAt) else { Issue.record("expected reconciliation"); return }
        try await service.execute(query)
        let finished = try #require(try await store.operationWork(id: workID))
        #expect(finished.execution == .committed)
        #expect(finished.attemptCount == 2)
        #expect(finished.identity == submit.work.identity)
    }
    @Test func rebuiltServiceRecoversPersistedAttentionDraftAndSkipsCommitted() async throws {
        let user = UserID(uuid: UUID())
        let binding = V2LocalInstallationBinding(value: UUID())
        let url = FileManager.default.temporaryDirectory.appending(path: "profile-restart-\(UUID()).sqlite")
        let store = try GRDBV2LocalSyncStore(databaseURL: url,installationBinding: binding,userID: user)
        let original = V2ProfileIntentService(store: store,accountID: user,manager: ProfileRefreshed401Fixture())
        let intent = try await original.enqueue(expectedRevision: .init(rawValue: 1)!,patch: .init(displayName: .set("Durable draft")))
        let reopened = try GRDBV2LocalSyncStore(databaseURL: url,installationBinding: binding,userID: user)
        let restored = V2ProfileIntentService(store: reopened,accountID: user,manager: ProfileRefreshed401Fixture())
        #expect(try await restored.pendingIntent()?.id == intent.id)
        let workID = try #require(intent.workID)
        guard case .claimed(let claim) = try await store.claimOperationWork(id: workID,ownerID: UUID(),action: .submit,now: Date()) else { Issue.record("expected claim"); return }
        let command = try GRDBV2LocalSyncStore.profileCommand(intent: intent)
        let conflict = try V2ProfileOperationReceipt(actorUserID: user,operationID: command.operationID,fingerprint: command.fingerprint,outcome: .rejected(.revisionConflict(current: .init(rawValue: 2)!)),resolvedAtMilliseconds: 1)
        try await store.completeProfileIntent(intent: intent,result: .init(receipt: conflict,currentSnapshot: nil))
        #expect(try await restored.pendingIntent()?.patch.displayName == .set("Durable draft"))
        let next = try await restored.enqueue(expectedRevision: .init(rawValue: 2)!,patch: .init(displayName: .set("Committed draft")))
        let nextID = try #require(next.workID)
        guard case .claimed = try await store.claimOperationWork(id: nextID,ownerID: claim.ownerID,action: .submit,now: Date()) else { Issue.record("expected next claim"); return }
        let nextCommand = try GRDBV2LocalSyncStore.profileCommand(intent: next)
        let committed = try V2ProfileOperationReceipt(actorUserID: user,operationID: next.operationID,fingerprint: nextCommand.fingerprint,outcome: .committed(revision: .init(rawValue: 3)!,visibilityRevision: .init(rawValue: 3)!),resolvedAtMilliseconds: 2)
        try await store.completeProfileIntent(intent: next,result: .init(receipt: committed,currentSnapshot: nil))
        #expect(try await restored.pendingIntent() == nil)
        try await store.discardProfileIntentSource(id: intent.id)
        #expect(try await restored.pendingIntent() == nil)
    }
    private func snapshot(user: UserID,revision: UInt64) throws -> V2ProfileView {
        try .init(userID: user,publicIdentity: .init(userID: user,handle: .init("profile_test"),displayName: "Name",accountKind: .regular),avatar: nil,state: .active,revision: .init(rawValue: revision)!,visibilityRevision: .init(rawValue: revision)!)
    }
}

private struct ProfileReadyAvatar: V2ProfileAvatarPreparing {
    func ensureReady(_ source: V2ProfileAvatarUpload) async throws -> V2AvatarReference {
        .init(mediaID: .init(uuid: source.id))
    }
}

private struct ProfileRefreshed401Fixture: V2OwnProfileManaging {
    func currentProfile() async throws -> V2ProfileView { throw V2OwnProfileClientError.authorizationUnavailable }
    func patchProfile(_ command: V2ProfileUpdateCommand) async throws -> V2ProfileUpdateResult { throw V2OwnProfileClientError.authorizationUnavailable }
    func recoverProfile(_ request: V2ProfileOperationRecoveryRequest) async throws -> V2ProfileOperationRecoveryResult {
        .receipt(try .init(actorUserID: request.actorUserID,operationID: request.operationID,fingerprint: request.fingerprint,outcome: .committed(revision: .init(rawValue: 2)!,visibilityRevision: .init(rawValue: 2)!),resolvedAtMilliseconds: 1),currentSnapshot: nil)
    }
}

private actor ProfileWaitingAvatar: V2ProfileAvatarPreparing {
    var finished = false
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func ensureReady(_ upload: V2ProfileAvatarUpload) async throws -> V2AvatarReference {
        started = true; waiter?.resume(); waiter = nil
        defer { finished = true }
        try await Task.sleep(for: .seconds(60))
        return .init(mediaID: .init(uuid: upload.id))
    }
}

private struct ProfileLateSnapshotFixture: V2OwnProfileManaging {
    let snapshot: V2ProfileView
    func currentProfile() async throws -> V2ProfileView { snapshot }
    func patchProfile(_ command: V2ProfileUpdateCommand) async throws -> V2ProfileUpdateResult { throw V2OwnProfileClientError.invalidRequest }
    func recoverProfile(_ request: V2ProfileOperationRecoveryRequest) async throws -> V2ProfileOperationRecoveryResult { throw V2OwnProfileClientError.invalidRequest }
}
