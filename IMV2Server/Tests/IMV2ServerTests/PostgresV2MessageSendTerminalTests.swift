@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
@testable import IMV2ServerInfrastructure
import Foundation
import IMV2Core
import SQLKit
import Synchronization
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("explicit close is permanent, while an already committed acceptance wins recovery")
    func sendClosePreventsLateSubmissionAndPreservesAcceptance() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000), profile = try forwardImportTestProfile()
            let store = v2FixtureMessageSendOperationStore(database: database,
                writes: PostgresV2RoomWriteStore(database: database), clock: { now })
            func command() throws -> V2MessageSendOperationCommand {
                try .init(command: .init(roomID: roomID, senderUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: "same user content", limits: .init(maxUTF8Bytes: 64)),
                    firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
            }
            let original = try command(), replacement = try command()
            let close = try V2MessageSendOperationRecoveryRequest(identity: original.identity,
                fingerprint: original.fingerprint, domainFingerprint: original.command.fingerprint, action: .closeIfAbsent)
            let closed = try await PostgresV2MessageSendOperationStore.queryRecovery(close, database: database)
            guard case .receipt(let receipt) = closed else { throw V2MessageOperationValidationError.invalidReceipt }
            #expect(receipt.outcome == .rejected(.closedUnsubmitted))
            #expect(try await PostgresV2MessageSendOperationStore.queryRecovery(close, database: database) == closed)
            try await withRoomActivation(database: database, roomID: roomID) { token in
                #expect(try await store.send(original, token: token, capacityProfile: profile,
                    identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID()))) == closed)
                let accepted = try await store.send(replacement, token: token, capacityProfile: profile,
                    identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID())))
                guard case .receipt(let receipt) = accepted, case .accepted = receipt.outcome else {
                    throw V2MessageOperationValidationError.invalidReceipt
                }
                let lateClose = try V2MessageSendOperationRecoveryRequest(identity: replacement.identity,
                    fingerprint: replacement.fingerprint, domainFingerprint: replacement.command.fingerprint, action: .closeIfAbsent)
                #expect(try await PostgresV2MessageSendOperationStore.queryRecovery(lateClose, database: database) == accepted)
            }
            #expect(try await count("im_v2.messages", on: sql) == 1)
            #expect(try await count("im_v2.message_send_completions", on: sql) == 2)
            await #expect(throws: (any Error).self) {
                try await sql.raw("DELETE FROM im_v2.message_send_completions WHERE rejection_code IS NOT NULL").run()
            }
            await #expect(throws: (any Error).self) {
                try await sql.raw("UPDATE im_v2.message_send_completions SET rejection_code='permissionDenied' WHERE rejection_code IS NOT NULL").run()
            }
        }
    }

    @Test("an in-flight real submission cannot commit across an uncommitted close of the same identity")
    func sendCloseSerializesAgainstInFlightAcceptance() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let now = Date(timeIntervalSince1970: 1_750_000_000), profile = try forwardImportTestProfile()
            let command = try V2MessageSendOperationCommand(command: .init(roomID: roomID, senderUserID: senderID,
                clientMessageID: .init(uuid: UUID()), text: "late network retry", limits: .init(maxUTF8Bytes: 64)),
                firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)
            let gate = SendTerminalCommitGate(), senderPID = Mutex<Int32?>(nil)
            let closing = Task {
                try await v2WithRoomScopedTransaction(database: database) { transaction in
                    let tx = try #require(transaction as? any SQLDatabase)
                    let pid = try #require(try await tx.raw("SELECT pg_backend_pid() AS pid").first(decoding: SendTerminalPID.self)?.pid)
                    let result = try await PostgresV2MessageSendResults.reject(identity: command.identity,
                        fingerprint: command.fingerprint, domain: command.command.fingerprint,
                        reason: .closedUnsubmitted, now: now, sql: tx)
                    await gate.hold(pid)
                    return result
                }
            }
            do {
                try await sendTerminalObserve { await gate.pid != nil }
                let closerPID = try #require(await gate.pid)
                try await withRoomActivation(database: database, roomID: roomID) { token in
                    let store = v2FixtureMessageSendOperationStore(database: database,
                        writes: PostgresV2RoomWriteStore(database: database), clock: { now })
                        .observingOwnerTransactions { pid, _, _ in senderPID.withLock { $0 = pid } }
                    let sending = Task {
                        try await store.send(command, token: token, capacityProfile: profile,
                            identifiers: .init(messageID: .init(uuid: UUID()), eventID: .init(uuid: UUID())))
                    }
                    do {
                        try await sendTerminalObserve {
                            guard let pid = senderPID.withLock({ $0 }) else { return false }
                            return try await sql.raw("SELECT \(bind: closerPID) = ANY(pg_blocking_pids(\(bind: pid))) AS blocked")
                                .first(decoding: SendTerminalBlocked.self)?.blocked == true
                        }
                        await gate.release()
                        let closed = try await closing.value
                        if case .success(let result) = await sending.result { #expect(result == closed) }
                        let recovered = try await store.recover(.init(identity: command.identity,
                            fingerprint: command.fingerprint, domainFingerprint: command.command.fingerprint), token: token)
                        #expect(recovered == closed)
                        #expect(try await count("im_v2.messages", on: sql) == 0)
                        #expect(try await count("im_v2.message_send_completions", on: sql) == 1)
                    } catch {
                        await gate.release(); _ = await sending.result
                        throw error
                    }
                }
            } catch {
                await gate.release(); _ = await closing.result
                throw error
            }
        }
    }
}

private struct SendTerminalPID: Decodable { let pid: Int32 }
private struct SendTerminalBlocked: Decodable { let blocked: Bool }
private actor SendTerminalCommitGate {
    private(set) var pid: Int32?
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func hold(_ pid: Int32) async {
        self.pid = pid
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private func sendTerminalObserve(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw V2MessageOperationValidationError.invalidReceipt }
        try await Task.sleep(for: .milliseconds(10))
    }
}
