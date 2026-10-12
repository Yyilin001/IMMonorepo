import Foundation
@testable import IMV2ActorCluster
import IMV2ActorContracts
import NIOPosix
import Testing
@testable import IMV2ActorApplication

@Suite("Recovery intent survives supervisor restart")
struct V2RoomHostRecoveryJournalTests {
    @Test("Exclusive disk journal retains one operation across retries and rejects corrupt or mismatched history")
    func recoveryJournalRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("imv2-recovery-journal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("recovery.pb")
        let pool = NIOThreadPool(numberOfThreads: 2); pool.start()
        let supervisor = try V2ActorServiceID("supervisor"), hostID = try V2ActorHostID("host-a")
        let host = V2ActorHostIdentity(hostID: hostID, incarnationID: UUID())
        let successor = V2ActorHostIdentity(hostID: hostID, incarnationID: UUID())
        var current: V2RoomHostRecoveryJournal?
        do {
            let journal = try await V2RoomHostRecoveryJournal.provision(at: path,
                supervisorID: supervisor, hostIDs: [hostID], pool: pool); current = journal
            #expect(try await journal.existingOperation(for: host) == nil)
            #expect(try await journal.pendingHosts().isEmpty)
            let operation = try await journal.operation(for: host)
            #expect(try await journal.pendingHosts() == [host])
            #expect(try await journal.existingOperation(for: host) == operation)
            let retries = try await withThrowingTaskGroup(of: UUID.self) { group in
                for _ in 0..<16 { group.addTask { try await journal.operation(for: host) } }
                var values: [UUID] = []
                for try await value in group { values.append(value) }
                return values
            }
            #expect(retries.count == 16 && retries.allSatisfy { $0 == operation })
            await #expect(throws: (any Error).self) {
                _ = try await V2RoomHostRecoveryJournal.open(at: path, supervisorID: supervisor, hostIDs: [hostID], pool: pool)
            }
            await #expect(throws: V2RoomHostRecoveryJournalError.pendingIncarnation) { _ = try await journal.operation(for: successor) }
            await #expect(throws: V2RoomHostRecoveryJournalError.conflictingOperation) { try await journal.complete(host: host, operationID: UUID()) }
            try await journal.close(); current = nil
            await #expect(throws: (any Error).self) {
                _ = try await V2RoomHostRecoveryJournal.open(at: path,
                    supervisorID: V2ActorServiceID("other"), hostIDs: [hostID], pool: pool)
            }
            let reopened = try await V2RoomHostRecoveryJournal.open(at: path,
                supervisorID: supervisor, hostIDs: [hostID], pool: pool); current = reopened
            #expect(try await reopened.operation(for: host) == operation)
            #expect(try await reopened.pendingHosts() == [host])
            try await reopened.complete(host: host, operationID: operation)
            try await reopened.complete(host: host, operationID: operation)
            #expect(try await reopened.pendingHosts().isEmpty)
            let next = try await reopened.operation(for: successor)
            #expect(next != operation)
            #expect(try await reopened.existingOperation(for: host) == nil)
            try await reopened.close(); current = nil
            let final = try await V2RoomHostRecoveryJournal.open(at: path,
                supervisorID: supervisor, hostIDs: [hostID], pool: pool); current = final
            #expect(try await final.operation(for: successor) == next)
            #expect(try await final.pendingHosts() == [successor])
            try await final.close(); current = nil
            var bytes = try Data(contentsOf: path); bytes[bytes.count - 1] ^= 1
            try bytes.write(to: path)
            await #expect(throws: (any Error).self) {
                _ = try await V2RoomHostRecoveryJournal.open(at: path, supervisorID: supervisor, hostIDs: [hostID], pool: pool)
            }
            try FileManager.default.removeItem(at: path)
            await #expect(throws: (any Error).self) {
                _ = try await V2RoomHostRecoveryJournal.open(at: path, supervisorID: supervisor, hostIDs: [hostID], pool: pool)
            }
            #expect(!FileManager.default.fileExists(atPath: path.path))
            try await pool.shutdownGracefully()
            try FileManager.default.removeItem(at: directory)
        } catch {
            try? await current?.close()
            try? await pool.shutdownGracefully()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
