@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core
import FluentKit
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("durableSendBatch prepares every direct authorization before the first owner write")
    func durableSendBatchPreparesEveryAuthorizationBeforeOwnerWrites() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let direct = try await V2DirectRoomOperationTestFixture(database: database,
                capacityProfile: profile, roomShardID: "room-a", roomID: .init(uuid: UUID()), now: { now })
                .openedIdentity(actorUserID: senderID, operationID: .init(uuid: UUID()),
                    targetUserID: .init(uuid: memberTwoUUID), firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
            let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000041")!
            let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
            let deadline = UInt64(now.timeIntervalSince1970 * 1000) + 60_000
            func command(_ id: UUID, _ text: String) throws -> V2MessageSendOperationCommand {
                try .init(command: .init(roomID: direct.roomID, senderUserID: senderID,
                    clientMessageID: .init(uuid: id), text: text, limits: .init(maxUTF8Bytes: 64)),
                    firstSubmissionDeadlineMilliseconds: deadline)
            }
            let first = try command(firstID, "first authorization")
            let second = try command(secondID, "second authorization")
            try await sql.raw("""
                CREATE FUNCTION im_v2.fixture_require_batch_authorizations() RETURNS trigger
                LANGUAGE plpgsql AS $$
                BEGIN
                    IF (SELECT count(*) FROM im_v2.direct_authorization_intents
                        WHERE room_id = NEW.room_id AND sender_user_id = NEW.sender_user_id
                          AND client_message_id IN (
                            '00000000-0000-0000-0000-000000000041'::uuid,
                            '00000000-0000-0000-0000-000000000042'::uuid)) <> 2 THEN
                        RAISE EXCEPTION 'batch authorization intents are incomplete' USING ERRCODE = '23514';
                    END IF;
                    RETURN NEW;
                END
                $$
                """).run()
            try await sql.raw("""
                CREATE TRIGGER fixture_require_batch_authorizations BEFORE INSERT ON im_v2.messages
                FOR EACH ROW EXECUTE FUNCTION im_v2.fixture_require_batch_authorizations()
                """).run()
            let store = PostgresV2MessageSendOperationStore(database: database,
                writes: PostgresV2RoomWriteStore(database: database,
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 100, window: 86_400),
                    contentReviewMode: .disabled).usingControlDatabase(database), clock: { now })
            let results = try await withRoomActivation(database: database, roomID: direct.roomID) { token in
                try await store.sendBatch([first, second], token: token, capacityProfile: profile,
                    identifiers: .init(), now: { now })
            }
            #expect(results.count == 2)
            for result in results {
                guard case .sendOperation(.receipt(let receipt)) = result,
                      case .accepted = receipt.outcome else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
            }
            let intentCount = try await sql.raw("""
                SELECT count(*) AS count FROM im_v2.direct_authorization_intents
                WHERE room_id = \(bind: direct.roomID.uuidValue!) AND sender_user_id = \(bind: senderUUID)
                  AND client_message_id IN (\(bind: firstID), \(bind: secondID))
                """).first(decoding: OperationLockCount.self)
            #expect(intentCount?.count == 2)
            try await sql.raw("DROP TRIGGER fixture_require_batch_authorizations ON im_v2.messages").run()
            try await sql.raw("DROP FUNCTION im_v2.fixture_require_batch_authorizations()").run()
        }
    }

    @Test("durableSendBatch reserves direct authorization before taking owner operation locks")
    func durableSendBatchReservesAuthorizationOutsideOwnerTransaction() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let direct = try await V2DirectRoomOperationTestFixture(database: database,
                capacityProfile: profile, roomShardID: "room-a", roomID: .init(uuid: UUID()), now: { now })
                .openedIdentity(actorUserID: senderID, operationID: .init(uuid: UUID()),
                    targetUserID: .init(uuid: memberTwoUUID), firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
            let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000031")!
            let deadline = UInt64(now.timeIntervalSince1970 * 1000) + 60_000
            let command = try V2MessageSendOperationCommand(command: .init(roomID: direct.roomID,
                senderUserID: senderID, clientMessageID: .init(uuid: operationID), text: "authorization boundary",
                limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: deadline)
            let recovery = try V2MessageSendOperationRecoveryRequest(identity: command.identity,
                fingerprint: command.fingerprint, domainFingerprint: command.command.fingerprint,
                action: .closeIfAbsent)
            let activationStore = PostgresV2RoomActivationStore(database: database)
            guard case .acquired(let lease) = try await activationStore.acquire(roomID: direct.roomID,
                owner: try .init(shardID: "room-a", epoch: 0),
                host: .init(hostID: try .init("auth-lock-test"), incarnationID: UUID()), duration: try .init(30_000)) else {
                throw V2RoomActivationLeaseError.activationChanged
            }
            let gate = OperationLockTestGate()
            let controlHolder = Task {
                try await database.transaction { transaction in
                    guard let controlSQL = transaction as? any SQLDatabase else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    let key = "account-state:" + senderUUID.uuidString
                    try await controlSQL.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: key), 0))").run()
                    let pid = try await controlSQL.raw("SELECT pg_backend_pid() AS pid").first(decoding: OperationLockPID.self)
                    await gate.hold(try #require(pid).pid)
                }
            }
            let holderPID = await gate.waitUntilHeld()
            let store = PostgresV2MessageSendOperationStore(database: database,
                writes: PostgresV2RoomWriteStore(database: database,
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 100, window: 86_400),
                    contentReviewMode: .disabled).usingControlDatabase(database), clock: { now })
            let send = Task {
                try await store.sendBatch([command], token: lease.token, capacityProfile: profile,
                    identifiers: .init(), now: { now })
            }
            var waitingForControlLock = false
            for _ in 0..<200 {
                let row = try? await sql.raw("""
                    SELECT EXISTS (
                        SELECT 1 FROM pg_stat_activity
                        WHERE \(bind: holderPID) = ANY(pg_blocking_pids(pid))
                    ) AS value
                """).first(decoding: OperationLockBool.self)
                if row?.value == true { waitingForControlLock = true; break }
                try await Task.sleep(for: .milliseconds(10))
            }

            let close = Task {
                try await store.recover(recovery, token: lease.token)
            }
            var closeCommittedBeforeControlRelease = false
            for _ in 0..<200 {
                let row = try? await sql.raw("""
                    SELECT count(*) AS count FROM im_v2.message_send_operation_receipts
                    WHERE room_id = \(bind: direct.roomID.uuidValue!) AND actor_user_id = \(bind: senderUUID)
                      AND operation_id = \(bind: operationID)
                """).first(decoding: OperationLockCount.self)
                if row?.count == 1 { closeCommittedBeforeControlRelease = true; break }
                try await Task.sleep(for: .milliseconds(10))
            }
            await gate.release()
            try await controlHolder.value
            let closed = try await close.value
            let sent = try await send.value
            _ = try await activationStore.release(token: lease.token)
            #expect(waitingForControlLock)
            #expect(closeCommittedBeforeControlRelease)
            guard case .receipt(let closedReceipt) = closed else { throw V2RoomWriteStoreError.corruptPersistenceState }
            #expect(closedReceipt.outcome == .closed)
            #expect(sent == [.sendOperation(.receipt(closedReceipt))])
        }
    }

    @Test("durableSendBatch acquires all operation locks before the room fence")
    func durableSendBatchLocksOperationsBeforeRoomFence() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
            let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!
            let deadline = UInt64(now.timeIntervalSince1970 * 1000) + 60_000
            func command(_ id: UUID, _ text: String) throws -> V2MessageSendOperationCommand {
                try .init(command: .init(roomID: roomID, senderUserID: senderID,
                    clientMessageID: .init(uuid: id), text: text, limits: .init(maxUTF8Bytes: 64)),
                    firstSubmissionDeadlineMilliseconds: deadline)
            }
            let first = try command(firstID, "first operation")
            let second = try command(secondID, "second operation")
            let tokenGate = OperationLockTestGate()
            let holder = Task {
                try await database.transaction { transaction in
                    guard let lockSQL = transaction as? any SQLDatabase else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    try await lockSQL.raw("""
                        SELECT pg_advisory_xact_lock(hashtextextended(
                            'v2-message-operation:' || \(bind: roomUUID)::text || ':' || \(bind: senderUUID)::text || ':' || \(bind: secondID)::text, 0))
                        """).run()
                    let pid = try await lockSQL.raw("SELECT pg_backend_pid() AS pid").first(decoding: OperationLockPID.self)
                    await tokenGate.hold(try #require(pid).pid)
                }
            }
            let holderPID = await tokenGate.waitUntilHeld()
            let store = PostgresV2MessageSendOperationStore(database: database,
                writes: PostgresV2RoomWriteStore(database: database,
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 100, window: 86_400),
                    contentReviewMode: .disabled), clock: { now })
            let batch = Task {
                try await withRoomActivation(database: database, roomID: roomID) { token in
                    try await store.sendBatch([second, first], token: token, capacityProfile: profile,
                        identifiers: .init(), now: { now })
                }
            }

            var waitingForSecondOperation = false
            for _ in 0..<200 {
                let row = try? await sql.raw("""
                    SELECT EXISTS (
                        SELECT 1 FROM pg_stat_activity
                        WHERE \(bind: holderPID) = ANY(pg_blocking_pids(pid))
                    ) AS value
                """).first(decoding: OperationLockBool.self)
                if row?.value == true { waitingForSecondOperation = true; break }
                try await Task.sleep(for: .milliseconds(10))
            }

            // If the batch takes the room row while waiting for its second
            // operation lock, this NOWAIT probe fails and recreates the old
            // wait cycle deterministically.
            let roomFenceWasFree: Bool
            do {
                try await database.transaction { transaction in
                    guard let probeSQL = transaction as? any SQLDatabase else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    try await probeSQL.raw("""
                        SELECT room_id FROM im_v2.rooms
                        WHERE room_id = \(bind: roomUUID)
                        FOR NO KEY UPDATE NOWAIT
                        """).run()
                }
                roomFenceWasFree = true
            } catch {
                roomFenceWasFree = false
            }
            await tokenGate.release()
            try await holder.value
            let results = try await batch.value
            #expect(waitingForSecondOperation)
            #expect(roomFenceWasFree)
            #expect(results.count == 2)
            for result in results {
                guard case .sendOperation(.receipt(let receipt)) = result,
                      case .accepted = receipt.outcome else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
            }
        }
    }
}

private actor OperationLockTestGate {
    private var heldPID: Int32?
    private var heldContinuation: CheckedContinuation<Int32, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func hold(_ pid: Int32) async {
        heldPID = pid
        heldContinuation?.resume(returning: pid)
        heldContinuation = nil
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilHeld() async -> Int32 {
        if let heldPID { return heldPID }
        return await withCheckedContinuation { heldContinuation = $0 }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private struct OperationLockPID: Decodable { let pid: Int32 }
private struct OperationLockBool: Decodable { let value: Bool }
private struct OperationLockCount: Decodable { let count: Int64 }
