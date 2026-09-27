import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2ActorContracts
import IMV2Core
import PostgresNIO
@testable import IMV2Server
import SQLKit
import Testing

@Suite(.serialized)
struct V2MessageOperationRecoveryTests {
    @Test("a closed send rolls back the atomic batch and only its own item is rejected on ordered fallback",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil))
    func closedOperationDoesNotRejectOtherBatchMembers() async throws {
        let resources=makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url:#require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"]),maxConnectionsPerEventLoop:4),as:.psql,isDefault:true)
            let database=resources.database(.psql),sql=try #require(database as? any SQLDatabase)
            let room=RoomID(uuid:UUID()),actor=UserID(uuid:UUID()),now=Date(),leaseID=UUID()
            let shard="recovery-"+UUID().uuidString.lowercased()
            let handle="r"+actor.rawValue.replacingOccurrences(of:"-",with:"").prefix(20).lowercased()
            try await sql.raw("""
                INSERT INTO im_v2.public_user_profiles(user_id,public_handle,display_name,revision,created_at,updated_at)
                VALUES(\(bind:actor.uuidValue!),\(bind:handle),'Recovery sender',1,\(bind:now),\(bind:now))
                """).run()
            try await sql.raw("INSERT INTO im_v2.rooms(room_id,room_shard_id,capacity_profile_id,capacity_class) VALUES(\(bind:room.uuidValue!),\(bind:shard),'standard','large')").run()
            try await sql.raw("INSERT INTO im_v2.group_rooms(room_id,owner_user_id,title,created_at) VALUES(\(bind:room.uuidValue!),\(bind:actor.uuidValue!),'Recovery group',\(bind:now))").run()
            try await sql.raw("""
                INSERT INTO im_v2.shard_admission_pools(room_shard_id,capacity_profile_id,lease_id,generation,valid_until,command_window_limit)
                VALUES(\(bind:shard),'standard',\(bind:leaseID),1,\(bind:now.addingTimeInterval(120)),100)
                """).run()
            try await sql.raw("""
                INSERT INTO im_v2.room_admission(room_id,eligible_member_count,command_window_limit,shard_lease_id,shard_lease_generation)
                VALUES(\(bind:room.uuidValue!),1,100,\(bind:leaseID),1)
                """).run()
            try await sql.raw("INSERT INTO im_v2.room_memberships(room_id,user_id,joined_revision) VALUES(\(bind:room.uuidValue!),\(bind:actor.uuidValue!),0)").run()
            let leases=PostgresV2RoomActivationStore(database:database)
            guard case .acquired(let grant)=try await leases.acquire(roomID:room,owner:.init(shardID:shard,epoch:0),
                host:.init(hostID:.init("recovery-batch"),incarnationID:UUID()),duration:.init(60_000)) else { throw V2RoomActivationLeaseError.activationChanged }
            let profile=try V2CapacityProfile(id:"standard",limits:.init(maxEligibleMembers:10,maxCommandsPerWindow:100,retryAfterSeconds:1))
            let limits=try V2MessageCommandLimits(maxUTF8Bytes:1_024)
            let commands=try ["Before closed","Permanently closed","After closed"].map {
                try V2SendMessageCommand(roomID:room,senderUserID:actor,clientMessageID:.init(uuid:UUID()),text:$0,limits:limits)
            }
            let recovery=PostgresV2MessageOperationRecoveryStore(database:database)
            let closed=commands[1]
            #expect(try await recovery.recover(.init(roomID:room,clientMessageID:closed.clientMessageID,fingerprint:closed.fingerprint,action:.closeIfAbsent),actorUserID:actor,token:grant.token) == .closed)
            let writes=try PostgresV2RoomWriteStore(database:database,strangerMessagePolicy:.init(maximumMessagesPerWindow:10,window:86_400),contentReviewMode:.disabled,
                shardAdmissionCommandCreditPool:.init(database:database,batchSize:10))
            let prepared=try commands.map { command in
                V2PreparedActorSend(token:grant.token,request:.init(command:command,capacityProfile:profile,identifiers:try V2AcceptanceIDFactory().make(at:now),now:now))
            }
            let scoped=writes.usingActivationScope(try .init(tokens:[grant.token]))
            do {
                _ = try await scoped.accept(command:closed,capacityProfile:profile,identifiers:V2AcceptanceIDFactory().make(at:now),now:now)
                Issue.record("Single send bypassed permanent closure")
            } catch { #expect(v2IsMessageOperationClosed(error)) }
            do {
                _ = try await scoped.acceptAtomically(requests:prepared.map(\.request))
                Issue.record("Atomic batch bypassed permanent closure")
            } catch let error as V2AtomicRoomWriteBatchError { #expect(error.reason == .preflightMismatch) }
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.messages WHERE room_id=\(bind:room.uuidValue!)").first(decoding:RecoveryCountRow.self)?.value == 0)
            let batcher=V2SendMessageAdmissionBatcher(store:writes,configuration:.init(maximumBatchSize:8,maximumDelay:.milliseconds(1)),actorGrantedStore:writes)
            let adapter=V2ActorGrantedSendBatchAdapter(batcher:batcher)
            let result=try await adapter.execute(prepared,batchDeadline:.now + .seconds(5),callDeadline:.now + .seconds(10))
            #expect(result.count==3)
            #expect(result[1] == .failure(.sendStore(.messageOperationClosed)))
            guard case .send(let before)=result[0],case .send(let after)=result[2] else { throw V2RoomWriteStoreError.corruptPersistenceState }
            #expect(try before.toDomain().acceptanceReceipt?.roomSequence == 1)
            #expect(try after.toDomain().acceptanceReceipt?.roomSequence == 2)
            let replay=try await adapter.execute(prepared,batchDeadline:.now + .seconds(5),callDeadline:.now + .seconds(10))
            #expect(replay[1] == .failure(.sendStore(.messageOperationClosed)))
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.messages WHERE room_id=\(bind:room.uuidValue!)").first(decoding:RecoveryCountRow.self)?.value == 2)
            #expect(try await sql.raw("SELECT COUNT(*) AS value FROM im_v2.message_operation_closures WHERE room_id=\(bind:room.uuidValue!)").first(decoding:RecoveryCountRow.self)?.value == 1)
            await adapter.retire(grant.token)
            _ = try await leases.release(token:grant.token)
            try await resources.shutdown()
        } catch {
            try? await resources.shutdown()
            if let postgres=error as? PSQLError {
                Issue.record("Recovery batch SQL error: state=\(postgres.serverInfo?[.sqlState] ?? "unknown"), constraint=\(postgres.serverInfo?[.constraintName] ?? "none"), message=\(postgres.serverInfo?[.message] ?? "unknown")")
            } else { throw error }
        }
    }
    @Test("query is not closure; permanent closure rejects late acceptance and accepted receipts win",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil))
    func durableRecovery() async throws {
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"]), maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
            let database = resources.database(.psql), sql = try #require(database as? any SQLDatabase)
            let room = RoomID(uuid: UUID()), actor = UserID(uuid: UUID()), operation = ClientMessageID(uuid: UUID())
            try await sql.raw("INSERT INTO im_v2.rooms(room_id,room_shard_id,capacity_profile_id) VALUES (\(bind: room.uuidValue!), 'recovery-test', 'standard')").run()
            let leases = PostgresV2RoomActivationStore(database: database)
            guard case .acquired(let grant) = try await leases.acquire(roomID: room,
                owner: .init(shardID: "recovery-test", epoch: 0), host: .init(hostID: .init("recovery-test"), incarnationID: UUID()), duration: .init(60_000))
            else { throw V2RoomActivationLeaseError.activationChanged }
            let command = try V2SendMessageCommand(roomID: room, senderUserID: actor, clientMessageID: operation,
                text: "Recover exactly this send", limits: .init(maxUTF8Bytes: 1_024))
            let query = V2MessageOperationRecoveryRequest(roomID: room, clientMessageID: operation, fingerprint: command.fingerprint, action: .query)
            let close = V2MessageOperationRecoveryRequest(roomID: room, clientMessageID: operation, fingerprint: command.fingerprint, action: .closeIfAbsent)
            let store = PostgresV2MessageOperationRecoveryStore(database: database)
            #expect(try await store.recover(query, actorUserID: actor, token: grant.token) == .unresolved)
            #expect(try await store.recover(close, actorUserID: actor, token: grant.token) == .closed)
            #expect(try await store.recover(query, actorUserID: actor, token: grant.token) == .closed)
            let wrong = try V2MessageOperationRecoveryRequest(roomID: room, clientMessageID: operation,
                fingerprint: .init(version: 3, digest: Data(repeating: 9, count: 32)), action: .closeIfAbsent)
            #expect(try await store.recover(wrong, actorUserID: actor, token: grant.token) == .fingerprintConflict)
            do {
                try await insertCompletion(command: command, message: UUID(), sql: sql)
                Issue.record("A delayed send was accepted after closure")
            } catch { #expect(v2IsMessageOperationClosed(error)) }
            await #expect(throws: (any Error).self) {
                try await sql.raw("DELETE FROM im_v2.message_operation_closures WHERE room_id = \(bind: room.uuidValue!)").run()
            }
            let acceptedCommand = try V2SendMessageCommand(roomID: room, senderUserID: actor,
                clientMessageID: .init(uuid: UUID()), text: "Already accepted", limits: .init(maxUTF8Bytes: 1_024))
            let acceptedMessage = UUID()
            try await insertCompletion(command: acceptedCommand, message: acceptedMessage, sql: sql)
            let accepted = try await store.recover(.init(roomID: room, clientMessageID: acceptedCommand.clientMessageID,
                fingerprint: acceptedCommand.fingerprint, action: .closeIfAbsent), actorUserID: actor, token: grant.token)
            #expect(accepted == .accepted(try .init(messageID: .init(uuid: acceptedMessage), roomSequence: 1)))
            try await resources.shutdown()
        } catch { try? await resources.shutdown(); throw error }
    }

    @Test("late append with an older outer statement snapshot sees the committed close after its operation lock",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil))
    func staleStatementSnapshotCannotBypassClosure() async throws {
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"]), maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
            let database = resources.database(.psql), sql = try #require(database as? any SQLDatabase)
            let room = UUID(), actor = UUID(), operation = UUID(), message = UUID()
            let command = try V2SendMessageCommand(roomID: .init(uuid: room), senderUserID: .init(uuid: actor),
                clientMessageID: .init(uuid: operation), text: "racing send", limits: .init(maxUTF8Bytes: 1_024))
            let barrier = CompletionRaceBarrier()
            let closing = Task {
                try await database.transaction { transaction in
                    let tx = try #require(transaction as? any SQLDatabase)
                    let backend = try #require(try await tx.raw("SELECT pg_backend_pid() AS pid").first(decoding: RecoveryBackendRow.self)).pid
                    try await tx.raw("SELECT pg_advisory_xact_lock(hashtextextended('v2-message-operation:' || \(bind: room)::text || ':' || \(bind: actor)::text || ':' || \(bind: operation)::text, 0))").run()
                    await barrier.locked(backend)
                    try await barrier.waitForInsertion()
                    try await tx.raw("""
                        INSERT INTO im_v2.message_operation_closures(room_id,sender_user_id,client_message_id,fingerprint_version,request_fingerprint,closed_at)
                        VALUES (\(bind: room),\(bind: actor),\(bind: operation),3,\(bind: command.fingerprint.digest),clock_timestamp())
                        """).run()
                }
            }
            let ownerPID = try await barrier.waitForLock()
            let append = Task { try await insertCompletion(command: command, message: message, sql: sql) }
            // Observe the real PostgreSQL lock wait instead of relying on a guessed scheduling delay.
            let deadline = ContinuousClock.now + .seconds(5)
            var observed = false
            while ContinuousClock.now < deadline {
                if let waiting = try await sql.raw("""
                    SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE \(bind: ownerPID) = ANY(pg_blocking_pids(pid))) AS value
                    """).first(decoding: RecoveryBoolRow.self), waiting.value { observed = true; break }
                try await Task.sleep(for: .milliseconds(10))
            }
            await barrier.insert()
            try await closing.value
            #expect(observed)
            do { try await append.value; Issue.record("Stale statement snapshot bypassed permanent closure") }
            catch { #expect(v2IsMessageOperationClosed(error)) }
            try await resources.shutdown()
        } catch { try? await resources.shutdown(); throw error }
    }

    private func insertCompletion(command: V2SendMessageCommand, message: UUID, sql: any SQLDatabase) async throws {
        try await sql.raw("""
            INSERT INTO im_v2.message_send_completions(room_id,sender_user_id,client_message_id,fingerprint_version,
                request_fingerprint,message_id,event_id,room_sequence,timeline_sequence,accepted_membership_revision,created_at)
            VALUES (\(bind: command.roomID.uuidValue!),\(bind: command.senderUserID.uuidValue!),\(bind: command.clientMessageID.uuidValue!),3,
                \(bind: command.fingerprint.digest),\(bind: message),\(bind: UUID()),1,1,0,clock_timestamp())
            """).run()
    }
}

private struct RecoveryBackendRow: Decodable { let pid: Int32 }
private struct RecoveryCountRow: Decodable { let value: Int64 }
private struct RecoveryBoolRow: Decodable { let value: Bool }
private actor CompletionRaceBarrier {
    private var pid: Int32?
    private var mayInsert = false
    func locked(_ pid: Int32) { self.pid = pid }
    func insert() { mayInsert = true }
    func waitForLock() async throws -> Int32 {
        let deadline = ContinuousClock.now + .seconds(5)
        while pid == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        return try #require(pid)
    }
    func waitForInsertion() async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !mayInsert, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(mayInsert)
    }
}
