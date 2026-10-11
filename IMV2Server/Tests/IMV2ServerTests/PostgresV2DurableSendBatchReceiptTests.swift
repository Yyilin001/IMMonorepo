@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("current accepted send writes one completion and no legacy authorization proof")
    func durableAcceptedReceiptWithoutAttemptUsesCombinedWrite() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(), profile = try forwardImportTestProfile()
            try await sql.raw("UPDATE im_v2.shard_admission_pools SET valid_until=clock_timestamp()+interval '10 minutes'").run()
            let command = try V2MessageSendOperationCommand(command: .init(roomID: roomID,
                senderUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "current group fact",
                limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: UInt64(now.timeIntervalSince1970 * 1000) + 60_000)
            try await sql.raw("CREATE TABLE im_v2.fixture_nil_proof_writes (table_name text NOT NULL)").run()
            try await sql.raw("""
                CREATE FUNCTION im_v2.fixture_nil_proof_write() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN INSERT INTO im_v2.fixture_nil_proof_writes VALUES (TG_TABLE_NAME); RETURN NULL; END $$
                """).run()
            try await assertRetiredDirectAuthorizationSchemaAbsent(on: sql)
            try await sql.raw("CREATE TRIGGER fixture_nil_proof_write AFTER INSERT ON im_v2.message_send_completions FOR EACH STATEMENT EXECUTE FUNCTION im_v2.fixture_nil_proof_write()").run()
            let store = v2FixtureMessageSendOperationStore(database: database,
                writes: PostgresV2RoomWriteStore(database: database, contentReviewMode: .disabled))
            try await withRoomActivation(database: database, roomID: roomID) { token in
                let result = try await store.send(command, token: token, capacityProfile: profile,
                    identifiers: V2AcceptanceIDFactory().make(at: now))
                guard case .receipt(let receipt) = result, case .accepted = receipt.outcome else {
                    Issue.record("Current send must persist an accepted completion")
                    return
                }
                let helper = PostgresV2DurableSendBatchReceipts()
                let inputs: [V2DurableSendBatchReceiptInput] = [.init(command: command)]
                let existing = try await helper.existing(inputs, sql: sql)
                #expect(existing.values.first == result)
                let snapshot = try await helper.snapshot(inputs, sql: sql)
                #expect(snapshot.existing.values.first == result)
                let rejected = try V2MessageSendOperationReceipt(identity: command.identity, fingerprint: command.fingerprint,
                    outcome: .rejected(.directPolicyDenied), resolvedAtMilliseconds: receipt.resolvedAtMilliseconds)
                #expect(throws: V2MessageOperationValidationError.invalidReceipt) {
                    try helper.validateAcknowledgments([.init(receipt: rejected, domainFingerprint: command.command.fingerprint)], messages: [])
                }
            }
            #expect(try await count("im_v2.message_send_completions", on: sql) == 1)
            try await assertRetiredDirectAuthorizationSchemaAbsent(on: sql)
            #expect(try await count("im_v2.fixture_nil_proof_writes", on: sql) == 1)
            #expect(try await sql.raw("SELECT table_name AS value FROM im_v2.fixture_nil_proof_writes").first(decoding: StringValueRow.self)?.value == "message_send_completions")
        }
    }

}
