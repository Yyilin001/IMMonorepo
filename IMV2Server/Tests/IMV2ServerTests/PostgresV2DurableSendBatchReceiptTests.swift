@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("accepted permanent receipt without a control attempt writes no authorization proof")
    func durableAcceptedReceiptWithoutAttemptUsesCombinedWrite() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let command = try V2MessageSendOperationCommand(command: .init(roomID: roomID,
                senderUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "local group fact",
                limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
            // Produce a real group-domain acceptance through the legacy domain
            // API; it has no cross-database direct authorization attempt.
            let service = try V2SendMessageService(store: PostgresV2RoomWriteStore(database: database),
                capacityProfile: profile, limits: .init(maxUTF8Bytes: 64), now: { now })
            let outcome = try await service.send(.init(roomID: roomID, actorUserID: senderID,
                clientMessageID: command.command.clientMessageID, text: "local group fact"))
            guard let accepted = outcome.acceptanceReceipt else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let receipt = try V2MessageSendOperationReceipt(identity: command.identity, fingerprint: command.fingerprint,
                outcome: .accepted(.init(messageID: accepted.messageID, roomSequence: accepted.roomSequence)),
                resolvedAtMilliseconds: 1_750_000_000_000)
            try await sql.raw("CREATE TABLE im_v2.fixture_nil_proof_writes (table_name text NOT NULL)").run()
            try await sql.raw("""
                CREATE FUNCTION im_v2.fixture_nil_proof_write() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN INSERT INTO im_v2.fixture_nil_proof_writes VALUES (TG_TABLE_NAME); RETURN NULL; END $$
                """).run()
            for table in ["direct_authorization_receipts", "message_send_completions"] {
                try await sql.raw("CREATE TRIGGER fixture_nil_proof_write AFTER INSERT ON im_v2.\(unsafeRaw: table) FOR EACH STATEMENT EXECUTE FUNCTION im_v2.fixture_nil_proof_write()").run()
            }
            try await database.transaction { transaction in
                let connection = try #require(transaction as? any SQLDatabase)
                try await v2AcquireDurableOwnerBatchOperationLocks([
                    .init(roomID: roomID.uuidValue!, senderID: senderUUID,
                          clientMessageID: command.command.clientMessageID.uuidValue!)
                ], sql: connection)
                let helper = PostgresV2DurableSendBatchReceipts()
                let prepared = try await helper.prepareProofs([.init(command: command, attempt: nil)], now: now, sql: connection)
                try await helper.persistAccepted([.init(receipt: receipt, domainFingerprint: command.command.fingerprint)],
                    proofs: prepared, sql: connection)
            }
            // Statement triggers also detect a dummy zero-row proof INSERT.
            #expect(try await count("im_v2.fixture_nil_proof_writes", on: sql) == 0)
            #expect(try await count("im_v2.direct_authorization_receipts", on: sql) == 0)
            #expect(try await count("im_v2.message_send_completions", on: sql) == 1)
            let recovered = try await PostgresV2DurableSendBatchReceipts().existing([
                .init(command: command, attempt: nil)
            ], sql: sql)
            #expect(recovered[try V2DurableSendBatchReceiptInput(command: command, attempt: nil).key] == .receipt(receipt))
        }
    }

    @Test("set-wise authorization proof checks preserve exact, generation, identity and aborted semantics")
    func durableBatchAttemptChecksUseIndexedExactAndLatest() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, _, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let opened = try await V2DirectRoomOperationTestFixture(database: database, capacityProfile: profile,
                roomShardID: "room-a", roomID: .init(uuid: UUID()), now: { now }).openedIdentity(
                    actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID),
                    firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
            let commands = try (0..<6).map { index in
                try V2MessageSendOperationCommand(command: .init(roomID: opened.roomID, senderUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: "immutable batch attempt \(index)",
                    limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
            }
            @Sendable func attempt(_ command: V2MessageSendOperationCommand, generation: Int64,
                         recipient: UUID? = nil, shard: String = "room-a", epoch: Int64 = 0) throws -> V2DirectAuthorizationAttempt {
                .init(roomID: try #require(command.command.roomID.uuidValue),
                    senderID: try #require(command.command.senderUserID.uuidValue),
                    clientMessageID: try #require(command.command.clientMessageID.uuidValue), generation: generation,
                    recipientID: recipient ?? memberTwoUUID, ownerShardID: shard, ownerEpoch: epoch,
                    fingerprint: command.command.fingerprint.digest)
            }
            // Genuine owner aborts create immutable proofs using the ordinary
            // locks/owner/pair checks. No fixture writes fake receipt state.
            let scalar = PostgresV2DirectAuthorizationReceiptStore()
            for (index, generations) in [(0, [Int64(1), 4]), (1, [1]), (2, [4]), (3, [1]), (4, [1])] {
                for generation in generations {
                    let value = try attempt(commands[index], generation: generation)
                    #expect(try await scalar.abort(value, now: now, database: database)
                        == .init(disposition: .aborted, eventID: nil))
                }
            }
            let inputs: [V2DurableSendBatchReceiptInput] = [
                .init(command: commands[0], attempt: try attempt(commands[0], generation: 1)), // exact old wins over 4
                .init(command: commands[1], attempt: try attempt(commands[1], generation: 2, shard: "next-owner", epoch: 1)),
                .init(command: commands[2], attempt: try attempt(commands[2], generation: 3)), // future 4 conflicts
                .init(command: commands[3], attempt: try attempt(commands[3], generation: 1, recipient: memberThreeUUID)),
                .init(command: commands[4], attempt: try attempt(commands[4], generation: 1)), // aborted stays terminal
                .init(command: commands[5], attempt: try attempt(commands[5], generation: 1)) // no proof is ready
            ]
            try await database.transaction { transaction in
                let sql = try #require(transaction as? any SQLDatabase)
                try await v2AcquireDurableOwnerBatchOperationLocks(try commands.map {
                    .init(roomID: try #require($0.command.roomID.uuidValue), senderID: try #require($0.command.senderUserID.uuidValue),
                          clientMessageID: try #require($0.command.clientMessageID.uuidValue))
                }, sql: sql)
                let snapshot = try await PostgresV2DurableSendBatchReceipts().snapshot(inputs, sql: sql)
                #expect(snapshot.existing.isEmpty)
                #expect(snapshot.completions.isEmpty)
                #expect(snapshot.closedKeys.isEmpty)
                let result = snapshot.checks
                #expect(result.count == 6)
                for index in [0, 4] {
                    guard case .terminal(let receipt)? = result[try inputs[index].key] else {
                        Issue.record("exact aborted attempt must remain terminal at index \(index)"); continue
                    }
                    #expect(receipt == .init(disposition: .aborted, eventID: nil))
                }
                for index in [1, 5] {
                    guard case .ready? = result[try inputs[index].key] else {
                        Issue.record("missing exact legal advance/no proof must be ready at index \(index)"); continue
                    }
                }
                for index in [2, 3] {
                    guard case .identityConflict? = result[try inputs[index].key] else {
                        Issue.record("future generation or changed recipient must conflict at index \(index)"); continue
                    }
                }
                // Bind the changed payload to its real v3 digest, rather than
                // supplying a malformed attempt/command combination that fails
                // before the LATERAL query. The stored exact proof must conflict.
                let changed = try V2MessageSendOperationCommand(command: .init(roomID: opened.roomID,
                    senderUserID: senderID, clientMessageID: commands[3].command.clientMessageID,
                    text: "changed immutable payload", limits: .init(maxUTF8Bytes: 64)),
                    firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
                let changedInput = V2DurableSendBatchReceiptInput(command: changed,
                    attempt: try attempt(changed, generation: 1))
                let changedResult = try await PostgresV2DurableSendBatchReceipts().snapshot([changedInput], sql: sql).checks
                guard case .identityConflict? = changedResult[try changedInput.key] else {
                    Issue.record("an exact proof with a different genuine command fingerprint must conflict"); return
                }
            }
        }
    }

    @Test("coherent receipt snapshot keeps mixed facts, missing rows and immutable proofs distinct")
    func durableBatchSnapshotPreservesMixedFactsAndProofs() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let profile = try forwardImportTestProfile()
            let opened = try await V2DirectRoomOperationTestFixture(database: database, capacityProfile: profile,
                roomShardID: "room-a", roomID: .init(uuid: UUID()), now: { now }).openedIdentity(
                    actorUserID: senderID, operationID: .init(uuid: UUID()), targetUserID: .init(uuid: memberTwoUUID),
                    firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
            let commands = try (0..<4).map { index in
                try V2MessageSendOperationCommand(command: .init(roomID: opened.roomID, senderUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: "snapshot fact \(index)", limits: .init(maxUTF8Bytes: 64)),
                    firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
            }
            @Sendable func attempt(_ command: V2MessageSendOperationCommand, recipient: UUID? = nil) throws -> V2DirectAuthorizationAttempt {
                .init(roomID: try #require(command.command.roomID.uuidValue), senderID: senderUUID,
                    clientMessageID: try #require(command.command.clientMessageID.uuidValue), generation: 1,
                    recipientID: recipient ?? memberTwoUUID, ownerShardID: "room-a", ownerEpoch: 0,
                    fingerprint: command.command.fingerprint.digest)
            }
            let inputs = try commands.enumerated().map { index, command in
                V2DurableSendBatchReceiptInput(command: command, attempt: index == 2 ? nil : try attempt(command))
            }
            let store = PostgresV2MessageSendOperationStore(database: database,
                writes: PostgresV2RoomWriteStore(database: database,
                    strangerMessagePolicy: try .init(maximumMessagesPerWindow: 100, window: 86_400),
                    contentReviewMode: .disabled).usingControlDatabase(database), clock: { now })
            try await withRoomActivation(database: database, roomID: opened.roomID) { token in
                let accepted = try await store.send(commands[0], token: token, capacityProfile: profile,
                    identifiers: try V2AcceptanceIDFactory().make(at: now))
                guard case .receipt(let acceptedReceipt) = accepted, case .accepted = acceptedReceipt.outcome else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                // The second domain outcome is produced through real control
                // preparation and the normal owner policy denial path.
                try await sql.raw("INSERT INTO im_v2.user_blocks (blocker_user_id,blocked_user_id,created_at) VALUES (\(bind: memberTwoUUID),\(bind: senderUUID),\(bind: now))").run()
                let denied = try await store.send(commands[1], token: token, capacityProfile: profile,
                    identifiers: try V2AcceptanceIDFactory().make(at: now))
                guard case .receipt(let deniedReceipt) = denied, case .rejected(.directPolicyDenied) = deniedReceipt.outcome else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                // A legacy closure has no invented permanent envelope/proof.
                try await sql.raw("""
                    INSERT INTO im_v2.message_operation_closures
                      (room_id,sender_user_id,client_message_id,fingerprint_version,request_fingerprint,closed_at)
                    VALUES (\(bind: opened.roomID.uuidValue!),\(bind: senderUUID),
                      \(bind: commands[2].command.clientMessageID.uuidValue!),3,\(bind: commands[2].command.fingerprint.digest),\(bind: now))
                    """).run()
                let helper = PostgresV2DurableSendBatchReceipts()
                try await database.transaction { transaction in
                    let connection = try #require(transaction as? any SQLDatabase)
                    try await v2AcquireDurableOwnerBatchOperationLocks(try commands.map {
                        .init(roomID: try #require($0.command.roomID.uuidValue), senderID: senderUUID,
                              clientMessageID: try #require($0.command.clientMessageID.uuidValue))
                    }, sql: connection)
                    let snapshot = try await helper.snapshot(inputs, sql: connection)
                    #expect(snapshot.existing.count == 2)
                    guard case .receipt(let loadedAccepted)? = snapshot.existing[try inputs[0].key],
                          case .receipt(let loadedDenied)? = snapshot.existing[try inputs[1].key] else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    #expect(loadedAccepted == acceptedReceipt)
                    #expect(loadedDenied == deniedReceipt)
                    #expect(snapshot.completions.count == 2)
                    #expect(snapshot.completions[try inputs[0].key]?.disposition == .accepted)
                    #expect(snapshot.completions[try inputs[1].key]?.disposition == .denied)
                    #expect(snapshot.checks.count == 3) // Nil attempt does not shift the missing input's key.
                    for index in [0, 1] {
                        guard case .terminal(let proof)? = snapshot.checks[try inputs[index].key] else {
                            throw V2RoomWriteStoreError.corruptPersistenceState
                        }
                        #expect(proof.disposition == (index == 0 ? .accepted : .denied))
                        #expect(proof.eventID == snapshot.completions[try inputs[index].key]?.eventID)
                    }
                    #expect(snapshot.closedKeys.contains(try inputs[1].key))
                    #expect(snapshot.closedKeys.contains(try inputs[2].key))
                    #expect(!snapshot.closedKeys.contains(try inputs[3].key))
                    #expect(snapshot.existing[try inputs[3].key] == nil)
                    #expect(snapshot.completions[try inputs[3].key] == nil)
                    guard case .ready? = snapshot.checks[try inputs[3].key] else {
                        throw V2RoomWriteStoreError.corruptPersistenceState
                    }
                    let proofs = try await helper.finishProofs(Array(inputs.prefix(2)), now: now, sql: connection)
                    #expect(proofs[try inputs[0].key]?.disposition == .accepted)
                    #expect(proofs[try inputs[1].key]?.disposition == .denied)
                    #expect(try await count("im_v2.direct_authorization_receipts", on: connection) == 2)
                }
                let changed = V2DurableSendBatchReceiptInput(command: commands[0],
                    attempt: try attempt(commands[0], recipient: memberThreeUUID))
                await #expect(throws: V2DirectAuthorizationReceiptError.identityConflict) {
                    try await database.transaction { transaction in
                        let connection = try #require(transaction as? any SQLDatabase)
                        try await v2AcquireDurableOwnerBatchOperationLocks([
                            .init(roomID: opened.roomID.uuidValue!, senderID: senderUUID,
                                  clientMessageID: commands[0].command.clientMessageID.uuidValue!)
                        ], sql: connection)
                        return try await helper.finishProofs([changed], now: now, sql: connection)
                    }
                }
                // Persistent proofs themselves remain protected by the actual
                // schema trigger, not just the Swift reader's comparison.
                await #expect(throws: (any Error).self) {
                    try await sql.raw("UPDATE im_v2.direct_authorization_receipts SET owner_epoch=99 WHERE client_message_id=\(bind: commands[0].command.clientMessageID.uuidValue!)").run()
                }
                #expect(try await count("im_v2.direct_authorization_receipts", on: sql) == 2)
                // Deliberately corrupt only this disposable transaction: an
                // accepted and denied domain fact for one identity must never
                // be collapsed by UNION/join decoding. Always roll it back.
                do {
                    try await database.transaction { transaction in
                        let connection = try #require(transaction as? any SQLDatabase)
                        try await v2AcquireDurableOwnerBatchOperationLocks(try commands.map {
                            .init(roomID: try #require($0.command.roomID.uuidValue), senderID: senderUUID,
                                  clientMessageID: try #require($0.command.clientMessageID.uuidValue))
                        }, sql: connection)
                        // Accepted messages do not normally have restricted
                        // timeline activities. Supply the deliberately corrupt
                        // restriction fact using the real accepted event/seq,
                        // solely inside this transaction that must roll back.
                        try await connection.raw("""
                            INSERT INTO im_v2.room_timeline_activities
                              (source_event_id,room_id,timeline_sequence,activity_type,recipient_user_id,created_at)
                            SELECT event_id,room_id,timeline_sequence,'direct_message_restricted',sender_user_id,created_at
                            FROM im_v2.message_send_completions
                            WHERE room_id=\(bind: opened.roomID.uuidValue!) AND sender_user_id=\(bind: senderUUID)
                              AND client_message_id=\(bind: commands[0].command.clientMessageID.uuidValue!)
                            """).run()
                        try await connection.raw("""
                            INSERT INTO im_v2.direct_message_denials
                              (sender_user_id,client_message_id,room_id,source_event_id,timeline_sequence,created_at,
                               fingerprint_version,request_fingerprint)
                            SELECT completion.sender_user_id,completion.client_message_id,completion.room_id,
                              completion.event_id,activity.timeline_sequence,completion.created_at,
                              completion.fingerprint_version,completion.request_fingerprint
                            FROM im_v2.message_send_completions AS completion
                            JOIN im_v2.room_timeline_activities AS activity
                              ON activity.source_event_id=completion.event_id AND activity.room_id=completion.room_id
                            WHERE completion.room_id=\(bind: opened.roomID.uuidValue!)
                              AND completion.sender_user_id=\(bind: senderUUID)
                              AND completion.client_message_id=\(bind: commands[0].command.clientMessageID.uuidValue!)
                            """).run()
                        #expect(try await count("im_v2.direct_message_denials", on: connection) == 2)
                        await #expect(throws: V2DirectAuthorizationReceiptError.identityConflict) {
                            try await helper.snapshot(inputs, sql: connection)
                        }
                        throw ReceiptSnapshotProbeError.rollback
                    }
                    Issue.record("the deliberately corrupted snapshot transaction must roll back")
                } catch ReceiptSnapshotProbeError.rollback {
                    // Only the intentional rollback is consumed. Other errors
                    // propagate and cannot masquerade as the expected probe.
                }
                #expect(try await count("im_v2.direct_message_denials", on: sql) == 1)
            }
        }
    }

}


private enum ReceiptSnapshotProbeError: Error { case rollback }
