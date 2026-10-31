import Foundation
import IMV2Core
import GRDB
import Testing
@testable import IMV2ClientKit

@Suite("Account-local profile display", .timeLimit(.minutes(1)))
struct V2LocalProfileDisplayTests {
    @Test func expiredLeaseAndPageReentryKeepNamesButNeverKeepByteAuthority() async throws {
        let f = try await Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let reader = Reader(actor: f.actor, device: f.device, lifetime: 0.1)
        let repository = f.repository(reader)
        let activation = await repository.activate()
        _ = try await repository.presentation(for: f.key, activation: activation)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await repository.cachedSnapshot(for: f.key, activation: activation) == nil)
        #expect(try await repository.restoreLocalDisplay().value(for: f.key)?.name == "Original")
        await repository.deactivate(activation)
        await repository.close()
        await reader.setOffline()
        let restored = f.repository(reader)
        let local = try await restored.restoreLocalDisplay()
        #expect(local.value(for: f.key)?.name == "Original")
        #expect(local.value(for: .init(userID: f.key.userID, context: .relationship))?.name == "Original")
        #expect(await reader.calls == 1)
        let next = await restored.activate()
        #expect(await restored.cachedSnapshot(for: f.key, activation: next) == nil)
        await restored.close(); try await f.store.close()
    }

    @Test func ownRemarksShareAcrossContactScreensButGroupNicknamesStayInTheirRoom() async throws {
        let f = try await Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let reader = Reader(actor: f.actor, device: f.device)
        let repository = f.repository(reader), activation = await repository.activate()
        let room = RoomID(uuid: UUID()), otherRoom = RoomID(uuid: UUID())
        let groupKey = V2ProfileViewLookupKey(userID: f.key.userID, context: .room(room))
        let contactKey = V2ProfileViewLookupKey(userID: f.key.userID, context: .relationship)
        await reader.setNames(alias: "My remark", nickname: "Group nickname")
        _ = try await repository.presentation(for: groupKey, activation: activation)
        _ = try await repository.presentation(for: contactKey, activation: activation)
        let local = try await repository.restoreLocalDisplay()
        #expect(local.value(for: groupKey)?.name == "Group nickname")
        #expect(local.value(for: contactKey)?.name == "My remark")
        #expect(local.value(for: f.key)?.name == "My remark")
        #expect(local.value(for: .init(userID: f.key.userID, context: .room(otherRoom)))?.name == "Original")
        let json = try await f.store.databasePool.read { db in
            try Data.fetchAll(db, sql: "SELECT value_json FROM v2_local_profile_display WHERE value_json IS NOT NULL")
        }.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(!json.contains("validUntil") && !json.contains("lease") && !json.contains("https://"))
        await repository.close(); try await f.store.close()
    }

    @Test func contextDenialSurvivesRestartWithoutRevokingAnotherContext() async throws {
        let f = try await Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let reader = Reader(actor: f.actor, device: f.device), repository = f.repository(Reader(actor: f.actor, device: f.device))
        let activation = await repository.activate()
        _ = try await repository.presentation(for: f.key, activation: activation)
        let other = V2ProfileViewLookupKey(userID: f.key.userID, context: .relationship)
        _ = try await repository.presentation(for: other, activation: activation)
        await repository.close()
        await reader.deny(f.key)
        let denying = f.repository(reader), page = await denying.activate()
        #expect(try await denying.presentation(for: f.key, activation: page) == nil)
        let snapshot = try await denying.restoreLocalDisplay()
        #expect(snapshot.value(for: f.key) == nil)
        #expect(snapshot.value(for: other)?.name == "Original")
        await denying.close()
        let restored = f.repository(reader), restoredSnapshot = try await restored.restoreLocalDisplay()
        #expect(restoredSnapshot.value(for: f.key) == nil)
        #expect(restoredSnapshot.value(for: other)?.name == "Original")
        await restored.close(); try await f.store.close()
    }

    @Test func contextDenialCannotRollOtherScreensBackToAnOlderNameOrRemark() async throws {
        let f = try await Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let reader = Reader(actor: f.actor, device: f.device), repository = f.repository(reader)
        let page = await repository.activate()
        _ = try await repository.presentation(for: f.key, activation: page)
        let contact = V2ProfileViewLookupKey(userID: f.key.userID, context: .relationship)
        await reader.setRevision(2)
        await reader.setNames(alias: "Latest remark", nickname: nil)
        _ = try await repository.presentation(for: contact, activation: page)
        #expect(try await repository.restoreLocalDisplay().value(for: f.key)?.name == "Latest remark")
        await repository.close()
        try f.journal.deny(contact)
        let local = try f.journal.load()
        #expect(local.value(for: contact) == nil)
        #expect(local.value(for: f.key)?.name == "Latest remark")
        #expect(local.value(for: f.key)?.identity.displayName == "Updated")
        try await f.store.close()
    }

    @Test func hiddenProjectionAtomicallyPurgesFactsAndRejectsLateOldHTTP() async throws {
        let f = try await Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let reader = Reader(actor: f.actor, device: f.device), repository = f.repository(Reader(actor: f.actor, device: f.device))
        let page = await repository.activate()
        _ = try await repository.presentation(for: f.key, activation: page)
        let old = try #require(try await repository.restoreLocalDisplay().records[f.key])
        try await f.store.databasePool.write { db in
            try db.execute(sql: "INSERT INTO v2_profile_invalidations VALUES(?,2,'hidden',?)", arguments: [f.key.userID.rawValue, Date().timeIntervalSince1970])
        }
        #expect(try f.journal.load().value(for: f.key) == nil)
        #expect(throws: V2ProfilePresentationError.staleResponse) { try f.journal.save(old) }
        #expect(try f.journal.load().value(for: .init(userID: f.key.userID, context: .relationship)) == nil)
        await repository.close()
        await reader.setRevision(3)
        let fresh = f.repository(reader), freshPage = await fresh.activate()
        _ = try await fresh.presentation(for: f.key, activation: freshPage)
        #expect(try await fresh.restoreLocalDisplay().value(for: f.key)?.name == "Updated")
        await fresh.close(); try await f.store.close()
    }

    @Test func unscopedProfileFactsNeverPopulateDisplayAndClearCannotReimportThem() async throws {
        let f = try await Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let rev = try #require(V2ProfileRevision(rawValue: 1))
        try await f.store.saveProfileView(.init(userID: f.key.userID, publicIdentity: .init(userID: f.key.userID,
            handle: .init("unscoped"), displayName: "Unscoped local fact", accountKind: .regular), avatar: nil,
            state: .active, revision: rev, visibilityRevision: rev))
        #expect(try f.journal.load().value(for: f.key) == nil)
        let repository = f.repository(Reader(actor: f.actor, device: f.device))
        let page = await repository.activate()
        _ = try await repository.presentation(for: f.key, activation: page)
        #expect(try f.journal.load().value(for: f.key)?.name == "Original")
        await repository.close()
        try await f.store.clearLocalProfileDisplays()
        #expect(try f.journal.load().value(for: f.key) == nil)
        #expect(try await f.store.profileView(userID: f.key.userID)?.publicIdentity?.displayName == "Unscoped local fact")
        await #expect(throws: V2ProfilePresentationError.inactive) {
            try await f.store.localProfileDisplayJournal(accountID: .init(uuid: UUID()))
        }
        try await f.store.close()
    }

    @Test func lateSecurityInvalidationCannotEraseNewerAcceptedDisplayOrIdentity() async throws {
        let f = try await Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let reader = Reader(actor: f.actor, device: f.device), repository = f.repository(reader)
        await reader.setRevision(3)
        let page = await repository.activate()
        let accepted = try #require(try await repository.presentation(for: f.key, activation: page))
        let room = RoomID(uuid: UUID())
        try await f.store.saveProfileView(accepted.view)
        try await f.store.cacheDirectRoomIdentity(roomID: room, publicIdentity: #require(accepted.view.publicIdentity),
            roomCreatedAt: Date(timeIntervalSince1970: 1000))
        _ = try await f.store.apply(invalidationBatch(f.key.userID, revision: 2))
        #expect(try f.journal.load().value(for: f.key)?.name == "Updated")
        #expect(try await f.store.directRoomIdentities().map(\.roomID) == [room])
        await repository.close(); try await f.store.close()
    }

    @Test func lateInvalidationWithoutUnscopedProfileCannotEraseNewerDisplay() async throws {
        let f = try await Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let reader = Reader(actor: f.actor, device: f.device), repository = f.repository(reader)
        await reader.setRevision(3)
        let page = await repository.activate()
        _ = try await repository.presentation(for: f.key, activation: page)
        #expect(try await f.store.profileView(userID: f.key.userID) == nil)
        _ = try await f.store.apply(invalidationBatch(f.key.userID, revision: 2))
        #expect(try f.journal.load().value(for: f.key)?.name == "Updated")
        await repository.close(); try await f.store.close()
    }

    @Test(arguments: [false, true])
    func snapshotSecurityInvalidationTakesEffectOnlyAtActivation(newerReadAfterPreparation: Bool) async throws {
        let f = try await Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let reader = Reader(actor: f.actor, device: f.device), repository = f.repository(reader)
        let activation = await repository.activate()
        _ = try await repository.presentation(for: f.key, activation: activation)
        let old = try #require(try f.journal.load().records[f.key])
        let record = try #require(try invalidationBatch(f.key.userID, revision: 2).records.first)
        let reset = try V2ClientResetRequired(snapshotID: .init("display-security-snapshot"), generation: 2,
            baseSequence: 1, expiresAt: .distantFuture)
        let page = try V2SnapshotProjectionV3Page(items: [.init(
            key: .init(projectionKind: record.projectionKind, entityKey: f.key.userID.rawValue),
            sourceEventID: record.sourceEventID, sequence: 1, payload: record.payload)])
        let payload = try V2SnapshotProjectionV3Codec.encode(page), digest = V2SnapshotV3Digest.page(payload)
        let initial = V2SnapshotV3Digest.initial(baseSequence: 1, capabilityProfile: "base")
        let root = V2SnapshotV3Digest.next(previous: initial, pageIndex: 0, pageDigest: digest,
            firstKey: page.firstKey, lastKey: page.lastKey, itemCount: 1)
        let manifest = try V2ClientSnapshotManifest(reset: reset, rootDigest: root, pageCount: 1, totalItems: 1,
            totalBytes: UInt64(payload.count), nextSyncToken: .init("display-snapshot-next"),
            receipt: .init("display-snapshot-receipt"), capabilityProfile: "base")
        try await f.store.beginReset(reset)
        try await f.store.beginSnapshotImport(manifest, initialDigest: initial)
        try await f.store.applySnapshotPage(.init(index: 0, digest: digest, firstKey: page.firstKey,
            lastKey: page.lastKey, itemCount: 1, payload: payload), for: manifest)
        try await f.store.prepareSnapshotActivation(manifest)
        #expect(try f.journal.load().value(for: f.key)?.name == "Original")
        // An independent HTTP read can finish between preparation and ACK.
        // Its newer fact must survive the later activation of an older floor.
        if newerReadAfterPreparation {
            await reader.setRevision(3)
            let fresh = f.repository(reader), page = await fresh.activate()
            _ = try await fresh.presentation(for: f.key, activation: page)
            await fresh.close()
        }
        try await f.store.activateAcknowledgedSnapshot(manifest)
        #expect(try f.journal.load().value(for: f.key)?.name == (newerReadAfterPreparation ? "Updated" : nil))
        #expect(throws: V2ProfilePresentationError.staleResponse) { try f.journal.save(old) }
        await repository.close(); try await f.store.close()
    }

    private func invalidationBatch(_ user: UserID, revision: UInt64) throws -> V2ClientSyncBatch {
        try .init(generation: 1, records: [.init(sequence: 1, sourceEventID: .init(uuid: UUID()),
            projectionKind: "profile_invalidation", payload: JSONSerialization.data(withJSONObject: [
                "user_id": user.rawValue, "minimum_profile_revision": revision, "profile_state": "hidden"
            ]))], nextSyncToken: .init("security-next"), receipt: .init("security-receipt"),
            hasMore: false, capabilityProfile: "base")
    }

    @Test func securityFloorSurvivesNewContentUnavailableResultAndCacheClear() async throws {
        let f = try await Fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let reader = Reader(actor: f.actor, device: f.device), repository = f.repository(reader)
        let page = await repository.activate()
        let old = try #require(try await repository.presentation(for: f.key, activation: page))
        let oldDisplay = try #require(V2LocalProfileDisplay(old))
        _ = try await f.store.apply(invalidationBatch(f.key.userID, revision: 2))
        await reader.setRevision(3)
        let newRepository = f.repository(reader), newPage = await newRepository.activate()
        let fresh = try #require(try await newRepository.presentation(for: f.key, activation: newPage))
        try await f.store.saveProfileView(fresh.view)
        try await f.store.applyProfileViewResults([.unavailable(key: f.key)])
        try await f.store.clearLocalProfileDisplays()
        let reset = try V2ClientResetRequired(snapshotID: .init("retain-security-floor"), generation: 2,
            baseSequence: 1, expiresAt: .distantFuture)
        let digest = V2SnapshotV3Digest.initial(baseSequence: 1, capabilityProfile: "base")
        let manifest = try V2ClientSnapshotManifest(reset: reset, rootDigest: digest, pageCount: 0, totalItems: 0,
            totalBytes: 0, nextSyncToken: .init("floor-snapshot-next"), receipt: .init("floor-snapshot-receipt"), capabilityProfile: "base")
        try await f.store.beginReset(reset)
        try await f.store.beginSnapshotImport(manifest, initialDigest: digest)
        try await f.store.prepareSnapshotActivation(manifest)
        try await f.store.activateAcknowledgedSnapshot(manifest)
        #expect(throws: V2ProfilePresentationError.staleResponse) { try f.journal.save(oldDisplay) }
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) {
            try await f.store.saveProfileView(old.view)
        }
        #expect(try await f.store.profileView(userID: f.key.userID) == nil)
        #expect(try f.journal.load().value(for: f.key) == nil)
        await newRepository.close(); await repository.close(); try await f.store.close()
        let restarted = try GRDBV2LocalSyncStore(databaseURL: f.directory.appending(path: "V2.sqlite"),
            installationBinding: f.binding, userID: f.actor)
        let journal = try await restarted.localProfileDisplayJournal(accountID: f.actor)
        #expect(throws: V2ProfilePresentationError.staleResponse) { try journal.save(oldDisplay) }
        try await restarted.close()
    }

    private struct Fixture {
        let actor = UserID(uuid: UUID()), device = DeviceID(uuid: UUID())
        let binding = V2LocalInstallationBinding(value: UUID())
        let directory: URL, store: GRDBV2LocalSyncStore, journal: V2LocalProfileDisplayJournal
        let key = V2ProfileViewLookupKey(userID: .init(uuid: UUID()), context: .directConversation)
        init() async throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "local-profile-\(UUID())")
            store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "V2.sqlite"),
                installationBinding: binding, userID: actor)
            journal = try await store.localProfileDisplayJournal(accountID: actor)
        }
        func repository(_ reader: Reader) -> V2ProfilePresentationRepository {
            .init(actorUserID: actor, deviceID: device, reader: reader, localDisplayJournal: journal)
        }
    }
    private actor Reader: V2ProfilePresentationReading {
        let actor: UserID, device: DeviceID, lifetime: TimeInterval
        var calls = 0, revision: UInt64 = 1
        var offline = false, denied: Set<V2ProfileViewLookupKey> = []
        var alias: String?, nickname: String?
        init(actor: UserID, device: DeviceID, lifetime: TimeInterval = 300) { self.actor = actor; self.device = device; self.lifetime = lifetime }
        func setOffline() { offline = true }
        func deny(_ key: V2ProfileViewLookupKey) { denied.insert(key) }
        func setNames(alias: String?, nickname: String?) { self.alias = alias; self.nickname = nickname }
        func setRevision(_ value: UInt64) { revision = value }
        func readPresentations(_ keys: [V2ProfileViewLookupKey]) throws -> V2ProfilePresentationBatch {
            calls += 1
            if offline { throw URLError(.notConnectedToInternet) }
            let now = Date(), rev = try #require(V2ProfileRevision(rawValue: revision))
            var values: [V2ProfileViewLookupKey: V2AuthorizedProfilePresentation] = [:]
            for key in keys where !denied.contains(key) {
                let view = try V2ProfileView(userID: key.userID, publicIdentity: .init(userID: key.userID,
                    handle: .init("local_user"), displayName: revision == 1 ? "Original" : "Updated", accountKind: .regular),
                    avatar: nil, state: .active, revision: rev, visibilityRevision: rev)
                let member: V2GroupMemberPresentation? = if case .room(let room) = key.context {
                    try .init(roomID: room, userID: key.userID, groupNickname: nickname, revision: rev)
                } else { nil }
                let contactAlias: V2ContactAlias? = if key.context == .relationship {
                    try .init(ownerUserID: actor, targetUserID: key.userID, remarkName: alias, revision: rev)
                } else { nil }
                values[key] = try .init(view: view, lease: .init(actorUserID: actor, deviceID: device, key: key,
                    profileRevision: rev, visibilityRevision: rev, contextRevision: revision, observedAt: now,
                    validUntil: now.addingTimeInterval(lifetime)), groupMember: member, contactAlias: contactAlias)
            }
            return .init(presentations: values, unavailable: Set(keys).intersection(denied), serverNow: now)
        }
    }
}
