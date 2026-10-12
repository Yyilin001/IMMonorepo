@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core
import PostgresNIO
import SQLKit
import Testing
@testable import IMV2Server
@testable import IMV2ServerInfrastructure

extension V2ResourceGroupAvatarPostgresTests {
    @Test("a new structural owner can retain or replace the bound avatar, but cannot adopt the former owner's unused upload")
    func structuralOwnerTransition() async throws {
        try await withFixture { f in
            let media = try await f.media(), unused = try await f.media(), original = try f.command(media: media)
            guard case .applied(let receipt) = try await f.apply(original) else { throw AvatarConcurrencyFailure.unexpectedOutcome }
            try await f.database.transaction { transaction in
                let sql = try #require(transaction as? any SQLDatabase)
                try await v2RequireRoomActivation(token: f.token, sql: sql)
                try await sql.raw("UPDATE im_v2.group_rooms SET owner_user_id=\(bind:f.member.uuidValue!) WHERE room_id=\(bind:f.room.uuidValue!)").run()
                try await sql.raw("""
                    UPDATE im_v2.room_memberships SET role=CASE WHEN user_id=\(bind:f.member.uuidValue!) THEN 'owner' ELSE 'member' END
                    WHERE room_id=\(bind:f.room.uuidValue!)
                    """).run()
                try await sql.raw("UPDATE im_v2.rooms SET membership_revision=membership_revision+1 WHERE room_id=\(bind:f.room.uuidValue!)").run()
            }
            try await f.sql.raw("UPDATE im_v2.media_objects SET expires_at=\(bind:f.now.addingTimeInterval(-1)) WHERE media_id=\(bind:media.uuidValue!)").run()
            await #expect(throws: V2GroupCapabilitiesStoreError.actorNotAuthorized) {
                _ = try await f.apply(f.command(media: unused, revision: 1))
            }
            await #expect(throws: V2GroupCapabilitiesStoreError.resourceUnavailable) {
                _ = try await f.apply(f.command(media: unused, revision: 1), actor: f.member)
            }
            #expect(try await f.apply(original) == .idempotent(receipt))
            guard case .applied(let retained) = try await f.apply(f.command(media: media, revision: 1), actor: f.member) else {
                throw AvatarConcurrencyFailure.unexpectedOutcome
            }
            #expect(retained.state.mediaID == media && retained.state.revision == 2)
            guard case .applied(let removed) = try await f.apply(f.command(media: nil, revision: 2), actor: f.member) else {
                throw AvatarConcurrencyFailure.unexpectedOutcome
            }
            #expect(removed.state.mediaID == nil && removed.state.revision == 3)
            let replacement = try await f.media()
            try await f.sql.raw("UPDATE im_v2.media_objects SET owner_user_id=\(bind:f.member.uuidValue!) WHERE media_id=\(bind:replacement.uuidValue!)").run()
            guard case .applied(let changed) = try await f.apply(f.command(media: replacement, revision: 3), actor: f.member) else {
                throw AvatarConcurrencyFailure.unexpectedOutcome
            }
            #expect(changed.state.mediaID == replacement && changed.state.revision == 4)
            #expect(try await avatarEventCount(f) == 4)
            #expect(try await f.apply(original) == .idempotent(receipt))
        }
    }

    @Test("a room owner epoch committed during lock wait rejects the old activation and preserves recovery on its successor",
          arguments: [false, true])
    func dataOwnerEpochTransition(hadReceipt: Bool) async throws {
        try await withAvatarDatabase { seed in
            let prior = try await seed.withActivation { f in
                let media = try await f.media(), command = try f.command(media: media), gate = AvatarMediaLockGate()
                let oldReceipt: V2GroupAvatarChange?
                if hadReceipt {
                    guard case .applied(let receipt) = try await f.apply(command) else { throw AvatarConcurrencyFailure.unexpectedOutcome }
                    oldReceipt = receipt
                } else { oldReceipt = nil }
                let moving = Task {
                    try await avatarHeldTransaction(f.database, gate: gate) { transaction in
                        let sql = try #require(transaction as? any SQLDatabase)
                        try await sql.raw("UPDATE im_v2.rooms SET owner_epoch=1 WHERE room_id=\(bind:f.room.uuidValue!)").run()
                    }
                }
                let pid = try await gate.waitUntilHeld()
                let stale = Task { try await f.apply(command) }
                do {
                    try await requireAvatarLockWait(blocker: pid, sql: f.sql)
                    await gate.release(); try await moving.value
                    await #expect(throws: V2RoomActorStateError.ownerChanged) { _ = try await stale.value }
                    return (f, command, oldReceipt, media)
                } catch { await gate.release(); _ = await moving.result; _ = await stale.result; throw error }
            }
            let f = prior.0, command = prior.1, oldReceipt = prior.2, media = prior.3
            let closed = try await seed.withActivation(epoch: 1) { successor in
                let store = try PostgresV2GroupCapabilitiesStore(database: f.database, activationScope: .init(tokens: [successor.token]))
                let recovery = try await store.recoverAvatar(actorUserID: f.owner, request: .init(command: command, action: .query))
                if let oldReceipt { #expect(recovery == .committed(oldReceipt)) }
                else { #expect(recovery == .unresolved) }
                let result = try await store.setAvatar(actorUserID: f.owner, command: command, capacityProfile: f.profile,
                    eventID: .init(uuid: UUID()), now: Date())
                if let oldReceipt { #expect(result == .idempotent(oldReceipt)) }
                else {
                    guard case .applied(let receipt) = result else { throw AvatarConcurrencyFailure.unexpectedOutcome }
                    #expect(receipt.state.mediaID == media && receipt.state.revision == 1)
                }
                #expect(try await avatarOperationCount(f, command) == 1)
                #expect(try await avatarEventCount(f) == 1)
                // A closure recorded by the new owner also survives another
                // activation handoff; replay cannot create a second terminal fact.
                let closed = try f.command(media: nil, revision: 1)
                #expect(try await store.recoverAvatar(actorUserID: f.owner, request: .init(command: closed, action: .closeIfAbsent)) == .closed)
                return closed
            }
            try await seed.withActivation(epoch: 1) { next in
                let recovered = try PostgresV2GroupCapabilitiesStore(database: f.database, activationScope: .init(tokens: [next.token]))
                #expect(try await recovered.recoverAvatar(actorUserID: f.owner, request: .init(command: closed, action: .query)) == .closed)
                await #expect(throws: V2GroupCapabilitiesStoreError.operationClosed) {
                    _ = try await recovered.setAvatar(actorUserID: f.owner, command: closed, capacityProfile: f.profile,
                        eventID: .init(uuid: UUID()), now: Date())
                }
            }
        }
    }

    @Test("GC skips an in-flight binding, then observes its commit or rollback", arguments: [false, true])
    func bindingWinsMediaLock(commits: Bool) async throws {
        try await withFixture { f in
            let media = try await f.media(), command = try f.command(media: media), gate = AvatarMediaLockGate()
            let other = try await AvatarFixture.seed(database: f.database), eventID = UUID()
            // The real room transaction owns BEGIN/COMMIT. Block its late event
            // insert on a unique event ID held by another connection; wrapping
            // it in an outer transaction would not establish a commit barrier.
            let holder = Task {
                try await avatarHeldTransaction(f.database, gate: gate, rollbackAfterRelease: commits) { transaction in
                    let sql = try #require(transaction as? any SQLDatabase)
                    try await sql.raw("""
                        INSERT INTO im_v2.room_events(event_id,room_id,room_sequence,event_type,actor_user_id,payload,committed_membership_revision,created_at)
                        VALUES(\(bind:eventID),\(bind:other.room.uuidValue!),1,'group.avatar_changed',\(bind:other.owner.uuidValue!),
                            '{}'::jsonb,0,clock_timestamp())
                        """).run()
                }
            }
            let pid = try await gate.waitUntilHeld()
            let binding = Task {
                try await PostgresV2GroupCapabilitiesStore(database: f.database, activationScope: .init(tokens: [f.token]))
                    .setAvatar(actorUserID: f.owner, command: command, capacityProfile: f.profile, eventID: .init(uuid: eventID), now: f.now)
            }
            do {
                try await requireAvatarLockWait(blocker: pid, sql: f.sql)
                let retention = PostgresV2MediaRetentionStore(database: f.database)
                // Move the GC clock beyond the upload bind window while the
                // earlier accepted binding is still uncommitted on its connection.
                let gcNow = f.now.addingTimeInterval(601)
                _ = try await retention.expireEligibleMedia(now: gcNow, withdrawnRetention: 60, limit: 100_000)
                #expect(try await f.state(media) == "available")
                #expect(try await avatarPurgeCount(f, media) == 0)
                #expect(try await avatarEventCount(f) == 0)
                await gate.release()
                if commits {
                    await #expect(throws: AvatarConcurrencyFailure.rollback) { try await holder.value }
                    guard case .applied = try await binding.value else { throw AvatarConcurrencyFailure.unexpectedOutcome }
                } else {
                    try await holder.value
                    do { _ = try await binding.value; Issue.record("duplicate room event did not roll back the binding") }
                    catch let error as PSQLError {
                        #expect(error.serverInfo?[.sqlState] == "23505")
                        #expect(error.serverInfo?[.constraintName] == "room_events_pkey")
                    }
                }
                _ = try await retention.expireEligibleMedia(now: gcNow, withdrawnRetention: 60, limit: 100_000)
                #expect(try await f.state(media) == (commits ? "available" : "expired"))
                #expect(try await avatarPurgeCount(f, media) == (commits ? 0 : 1))
                #expect(try await avatarEventCount(f) == (commits ? 1 : 0))
                #expect(try await avatarOperationCount(f, command) == (commits ? 1 : 0))
            } catch { await gate.release(); _ = await holder.result; _ = await binding.result; throw error }
        }
    }

    @Test("a binding blocked behind committed GC rechecks state and rolls back all room effects")
    func gcWinsMediaLock() async throws {
        try await withFixture { f in
            let media = try await f.media(), command = try f.command(media: media), gate = AvatarMediaLockGate()
            let collector = Task {
                try await avatarHeldTransaction(f.database, gate: gate) { transaction in
                    _ = try await PostgresV2MediaRetentionStore(database: transaction)
                        .expireEligibleMedia(now: f.now.addingTimeInterval(601), withdrawnRetention: 60, limit: 100_000)
                }
            }
            let pid = try await gate.waitUntilHeld()
            let binding = Task { try await f.apply(command) }
            do {
                try await requireAvatarLockWait(blocker: pid, sql: f.sql)
                #expect(try await f.state(media) == "available")
                await gate.release(); try await collector.value
                await #expect(throws: V2GroupCapabilitiesStoreError.resourceUnavailable) { _ = try await binding.value }
                #expect(try await f.state(media) == "expired")
                #expect(try await avatarPurgeCount(f, media) == 1)
                #expect(try await avatarEventCount(f) == 0)
                #expect(try await avatarOperationCount(f, command) == 0)
            } catch { await gate.release(); _ = await collector.result; _ = await binding.result; throw error }
        }
    }

    @Test("binding expiry and removal grace use a fresh database clock after the media-lock wait", arguments: [false, true])
    func resourceClockAfterLock(removing: Bool) async throws {
        try await withFixture { f in
            let media = try await f.media(), gate = AvatarMediaLockGate()
            if removing { _ = try await f.apply(f.command(media: media)) }
            let command = try f.command(media: removing ? nil : media, revision: removing ? 1 : 0)
            // Keep the original request timestamp before the new bind deadline.
            // The database clock will be beyond it before the lock is released.
            let expiredAt = f.now.addingTimeInterval(0.001)
            let holder = Task {
                try await avatarHeldTransaction(f.database, gate: gate) { transaction in
                    let sql = try #require(transaction as? any SQLDatabase)
                    try await sql.raw("UPDATE im_v2.media_objects SET expires_at=\(bind:expiredAt) WHERE media_id=\(bind:media.uuidValue!)").run()
                }
            }
            let pid = try await gate.waitUntilHeld()
            let mutation = Task { try await f.apply(command) }
            do {
                try await requireAvatarLockWait(blocker: pid, sql: f.sql)
                let beforeRelease = try await v2RoomActivationDatabaseClock(sql: f.sql)
                #expect(beforeRelease > expiredAt)
                await gate.release(); try await holder.value
                if removing {
                    guard case .applied = try await mutation.value else { throw AvatarConcurrencyFailure.unexpectedOutcome }
                    let expiry = try #require(try await f.sql.raw("SELECT expires_at AS value FROM im_v2.media_objects WHERE media_id=\(bind:media.uuidValue!)")
                        .first(decoding: AvatarConcurrencyDate.self)).value
                    #expect(expiry >= beforeRelease.addingTimeInterval(120))
                    let retention = PostgresV2MediaRetentionStore(database: f.database)
                    _ = try await retention.expireEligibleMedia(now: expiry.addingTimeInterval(-0.01), withdrawnRetention: 60, limit: 100_000)
                    #expect(try await f.state(media) == "available")
                    _ = try await retention.expireEligibleMedia(now: expiry.addingTimeInterval(0.01), withdrawnRetention: 60, limit: 100_000)
                    #expect(try await f.state(media) == "expired")
                } else {
                    await #expect(throws: V2GroupCapabilitiesStoreError.resourceUnavailable) { _ = try await mutation.value }
                    #expect(try await avatarEventCount(f) == 0)
                    #expect(try await avatarOperationCount(f, command) == 0)
                }
            } catch { await gate.release(); _ = await holder.result; _ = await mutation.result; throw error }
        }
    }
}

private enum AvatarConcurrencyFailure: Error { case rollback, unexpectedOutcome, missingLockWait }
private struct AvatarConcurrencyPID: Decodable { let pid: Int32 }
private struct AvatarConcurrencyBool: Decodable { let value: Bool }
private struct AvatarConcurrencyCount: Decodable { let value: Int64 }
private struct AvatarConcurrencyDate: Decodable { let value: Date }

func avatarHeldTransaction(_ database: any Database, gate: AvatarMediaLockGate, rollbackAfterRelease: Bool = false,
                                   _ prepare: @escaping @Sendable (any Database) async throws -> Void) async throws {
    do {
        try await database.transaction { transaction in
            try await prepare(transaction)
            let sql = try #require(transaction as? any SQLDatabase)
            await gate.held(try await avatarBackendPID(sql))
            await gate.waitForRelease()
            if rollbackAfterRelease { throw AvatarConcurrencyFailure.rollback }
        }
    } catch { await gate.fail(error); throw error }
}
private func avatarBackendPID(_ sql: any SQLDatabase) async throws -> Int32 {
    try #require(try await sql.raw("SELECT pg_backend_pid() AS pid").first(decoding: AvatarConcurrencyPID.self)).pid
}
func requireAvatarLockWait(blocker: Int32, sql: any SQLDatabase) async throws {
    let deadline = ContinuousClock.now + .seconds(1)
    while ContinuousClock.now < deadline {
        if try await sql.raw("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE \(bind:blocker)=ANY(pg_blocking_pids(pid))) AS value")
            .first(decoding: AvatarConcurrencyBool.self)?.value == true { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw AvatarConcurrencyFailure.missingLockWait
}
private func avatarPurgeCount(_ f: AvatarFixture, _ media: MediaID) async throws -> Int64 {
    try #require(try await f.sql.raw("SELECT count(*) AS value FROM im_v2.media_purge_outbox WHERE media_id=\(bind:media.uuidValue!)")
        .first(decoding: AvatarConcurrencyCount.self)).value
}
private func avatarEventCount(_ f: AvatarFixture) async throws -> Int64 {
    try #require(try await f.sql.raw("SELECT count(*) AS value FROM im_v2.room_events WHERE room_id=\(bind:f.room.uuidValue!)")
        .first(decoding: AvatarConcurrencyCount.self)).value
}
private func avatarOperationCount(_ f: AvatarFixture, _ command: V2GroupAvatarCommand) async throws -> Int64 {
    try #require(try await f.sql.raw("SELECT count(*) AS value FROM im_v2.resource_group_avatar_operations WHERE actor_user_id=\(bind:f.owner.uuidValue!) AND operation_id=\(bind:command.operationID.uuidValue!)")
        .first(decoding: AvatarConcurrencyCount.self)).value
}
actor AvatarMediaLockGate {
    private var result: Result<Int32, any Error>?, released = false
    private var heldWaiter: CheckedContinuation<Int32, any Error>?, releaseWaiter: CheckedContinuation<Void, Never>?
    func held(_ pid: Int32) { result = .success(pid); heldWaiter?.resume(returning: pid); heldWaiter = nil }
    func fail(_ error: any Error) {
        guard result == nil else { return }
        result = .failure(error); heldWaiter?.resume(throwing: error); heldWaiter = nil
    }
    func waitUntilHeld() async throws -> Int32 {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { heldWaiter = $0 }
    }
    func waitForRelease() async { if !released { await withCheckedContinuation { releaseWaiter = $0 } } }
    func release() { released = true; releaseWaiter?.resume(); releaseWaiter = nil }
}
