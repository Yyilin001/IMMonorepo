#if os(macOS)
import Darwin
import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2Core
@testable import IMV2Server
import SQLKit
import Testing

private final class ForwardCompactionCrashBundleMarker: NSObject {}

@Suite(.serialized)
struct PostgresV2ForwardCompactionCrashTests {
    private static let now = Date(timeIntervalSince1970: 1_750_000_000)
    private static let resultID = UUID(uuidString: "A5000000-0000-0000-0000-000000000001")!
    private struct Flag: Decodable { let value: Bool }
    private struct PID: Decodable { let value: Int32 }
    private struct Body: Decodable { let payload: Data?; let digest: Data; let compacted: Bool }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1" && ProcessInfo.processInfo.environment["IMV2_FORWARD_CRASH_MODE"] == nil),
          arguments: ["source-before", "source-after", "target-before", "target-after"], [false, true])
    func forwardCompactionKilledRecovery(scenario: String, rejected: Bool) async throws {
        let url = try #require(ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"])
        let root = FileManager.default.temporaryDirectory.appending(path: "im-forward-crash-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = makeV2DatabaseTestResources()
        var ownsSchema = false
        do {
            resources.databases.use(try .postgres(url: url), as: .psql, isDefault: true)
            let sql = try #require(resources.database(.psql) as? any SQLDatabase)
            try #require(try await sql.raw("SELECT to_regnamespace('im_v2') IS NULL AS value").first(decoding: Flag.self)?.value == true)
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let schema = try String(contentsOf: repo.appending(path: "IMV2/sql/schema.sql"), encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }.joined(separator: "\n")
            ownsSchema = true
            for statement in postgresStatements(in: schema) where !statement.isEmpty && statement != "BEGIN" && statement != "COMMIT" {
                try await sql.raw("\(unsafeRaw: statement)").run()
            }
            let export = try V2ForwardExport(intent: .init(version: 1, exportID: UUID(), actorUserID: UUID(),
                operationID: UUID(), sourceRoomID: UUID(), sourceMessageID: UUID(), sourceRevision: 1,
                sourceSenderUserID: UUID(), sourceShardID: "source", sourceEpoch: 0,
                targetRoomID: UUID(), targetClientMessageID: UUID(), targetShardID: "target", targetEpoch: 0,
                text: "crash retained identity", entities: [], media: []))
            try await Self.seed(export, rejected: rejected, sql: sql)
            try export.payload.write(to: root.appending(path: "payload"))
            try export.digest.write(to: root.appending(path: "digest"))
            for mode in ["crash", "recover"] {
                try await Self.child(root: root, scenario: scenario, rejected: rejected, mode: mode)
            }
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            ownsSchema = false
            try await resources.shutdown()
        } catch {
            if ownsSchema, let sql = resources.database(.psql) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA im_v2 CASCADE").run() }
            try? await resources.shutdown()
            throw error
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_FORWARD_CRASH_MODE"] != nil))
    func forwardCompactionCrashChild() async throws {
        let environment = ProcessInfo.processInfo.environment
        try #require(environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1")
        let root = URL(fileURLWithPath: try #require(environment["IMV2_FORWARD_CRASH_ROOT"]))
        try #require(root.lastPathComponent.hasPrefix("im-forward-crash-"))
        let mode = try #require(environment["IMV2_FORWARD_CRASH_MODE"])
        let scenario = try #require(environment["IMV2_FORWARD_CRASH_SCENARIO"])
        let source = scenario.hasPrefix("source"), before = scenario.hasSuffix("before")
        let rejected = environment["IMV2_FORWARD_CRASH_REJECTED"] == "1"
        let export = try V2ForwardExport(payload: Data(contentsOf: root.appending(path: "payload")), digest: Data(contentsOf: root.appending(path: "digest")))
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: #require(environment["IMV2_POSTGRES_TEST_DATABASE_URL"])), as: .psql, isDefault: true)
            let database = resources.database(.psql), sql = try #require(database as? any SQLDatabase)
            let at = Self.now.addingTimeInterval(PostgresV2ForwardExportCompactor.retentionSeconds)
            @Sendable func compact(_ database: any Database) async throws -> Int {
                if source { return try await PostgresV2ForwardExportCompactor(database: database).runOnce(now: at, limit: 1) }
                return try await PostgresV2ForwardInboxCompactor(database: database).runOnce(now: at, limit: 1)
            }
            @Sendable func killAtCheckpoint(pid: Int32) throws -> Never {
                try String(pid).write(to: root.appending(path: "backend"), atomically: true, encoding: .utf8)
                try scenario.write(to: root.appending(path: "crash.checkpoint"), atomically: true, encoding: .utf8)
                kill(getpid(), SIGKILL)
                fatalError("SIGKILL must stop the child")
            }
            if mode == "crash" {
                if before {
                    try await database.transaction { transaction in
                        try #require(try await compact(transaction) == 1)
                        let tx = try #require(transaction as? any SQLDatabase)
                        let pid = try #require(try await tx.raw("SELECT pg_backend_pid() AS value").first(decoding: PID.self)).value
                        try killAtCheckpoint(pid: pid)
                    }
                } else {
                    try #require(try await compact(database) == 1)
                    try killAtCheckpoint(pid: 0)
                }
            } else {
                if before {
                    let pid = try #require(Int32(try String(contentsOf: root.appending(path: "backend"), encoding: .utf8)))
                    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                    while try await sql.raw("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE pid = \(bind: pid)) AS value").first(decoding: Flag.self)?.value == true {
                        try #require(ContinuousClock.now < deadline)
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
                let table = source ? "message_forward_exports" : "message_forward_inbox"
                let other = source ? "message_forward_inbox" : "message_forward_exports"
                let row = try #require(try await sql.raw("SELECT payload, payload_digest AS digest, payload_compacted_at IS NOT NULL AS compacted FROM im_v2.\(unsafeRaw: table) WHERE export_id = \(bind: export.intent.exportID)").first(decoding: Body.self))
                #expect(row.digest == export.digest && row.compacted == !before)
                #expect(before ? row.payload == export.payload : row.payload == nil)
                #expect(try await sql.raw("SELECT payload IS NOT NULL AS value FROM im_v2.\(unsafeRaw: other) WHERE export_id = \(bind: export.intent.exportID)").first(decoding: Flag.self)?.value == true)
                #expect(try await compact(database) == (before ? 1 : 0))
                #expect(try await compact(database) == 0)
                let expected: V2ForwardImportOutcome = rejected ? .rejected(code: "FORBIDDEN") : .accepted(messageID: .init(uuid: Self.resultID), roomSequence: 7)
                let receipts = PostgresV2ForwardReceiptStore(database: database)
                #expect(try await receipts.status(exportID: export.intent.exportID) == expected)
                try await receipts.record(.init(export: export, outcome: expected), now: at)
                let prepared = try await PostgresV2ForwardExportStore(database: database).prepareForDelivery(
                    actorUserID: .init(uuid: export.intent.actorUserID), operationID: .init(uuid: export.intent.operationID),
                    source: .init(roomID: .init(uuid: export.intent.sourceRoomID), messageID: .init(uuid: export.intent.sourceMessageID), revision: .init(1)),
                    sourceRoute: .init(shardID: "source", epoch: 0), targetRoomID: .init(uuid: export.intent.targetRoomID),
                    targetRoute: .init(shardID: "target", epoch: 0), now: at)
                guard case .terminal(let outcome) = prepared else { throw V2ForwardExportError.corruptPersistenceState }
                #expect(outcome == expected)
                let inbox = PostgresV2ForwardInboxStore(database: database)
                try await inbox.receive(export, now: at)
                #expect(try await inbox.terminalReceipt(exportID: export.intent.exportID)?.outcome == expected)
                let profile = try V2CapacityProfile(id: "crash", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10, retryAfterSeconds: 1))
                #expect(try await PostgresV2RoomWriteStore(database: database).importForwardExport(export, capacityProfile: profile,
                    limits: .init(maxUTF8Bytes: 64), identifiers: V2AcceptanceIDFactory().make(at: at), now: at) == expected)
                try scenario.write(to: root.appending(path: "recover.checkpoint"), atomically: true, encoding: .utf8)
            }
            try await resources.shutdown()
        } catch { try? await resources.shutdown(); throw error }
    }

    private static func seed(_ export: V2ForwardExport, rejected: Bool, sql: any SQLDatabase) async throws {
        let intent = export.intent
        try await sql.raw("""
            INSERT INTO im_v2.rooms(room_id,room_shard_id,capacity_profile_id)
            VALUES (\(bind: intent.sourceRoomID), 'source', 'crash'), (\(bind: intent.targetRoomID), 'target', 'crash')
            """).run()
        let message: UUID? = rejected ? nil : resultID, sequence: Int64? = rejected ? nil : 7
        let error: String? = rejected ? "FORBIDDEN" : nil, state = rejected ? "rejected" : "completed"
        try await sql.raw("""
            INSERT INTO im_v2.message_forward_exports VALUES
            (\(bind: intent.exportID), \(bind: intent.actorUserID), \(bind: intent.operationID), \(bind: intent.sourceRoomID),
             \(bind: intent.sourceMessageID), 1, 'source', 0, \(bind: intent.targetRoomID), \(bind: intent.targetClientMessageID),
             'target', 0, \(bind: export.payload), \(bind: export.digest), '{}', \(bind: now), NULL, NULL)
            """).run()
        try await sql.raw("""
            INSERT INTO im_v2.message_forward_export_receipts VALUES
            (\(bind: intent.exportID), \(bind: export.digest), \(bind: state), \(bind: message), \(bind: sequence), \(bind: error), \(bind: now))
            """).run()
        try await sql.raw("""
            INSERT INTO im_v2.message_forward_delivery_jobs(export_id, state, created_at, completed_at)
            VALUES (\(bind: intent.exportID), 'completed', \(bind: now), \(bind: now))
            """).run()
        try await sql.raw("""
            INSERT INTO im_v2.message_forward_inbox
                (export_id, actor_user_id, operation_id, source_message_id, target_room_id, target_client_message_id,
                 target_shard_id, target_epoch, payload, payload_digest, state, result_message_id, result_room_sequence,
                 error_code, created_at, accepted_at, completed_at)
            VALUES (\(bind: intent.exportID), \(bind: intent.actorUserID), \(bind: intent.operationID), \(bind: intent.sourceMessageID),
                    \(bind: intent.targetRoomID), \(bind: intent.targetClientMessageID), 'target', 0, \(bind: export.payload),
                    \(bind: export.digest), \(bind: state), \(bind: message), \(bind: sequence), \(bind: error),
                    \(bind: now), \(bind: rejected ? nil : Optional(now)), \(bind: now))
            """).run()
    }

    private static func child(root: URL, scenario: String, rejected: Bool, mode: String) async throws {
        let host = URL(fileURLWithPath: CommandLine.arguments[0]), process = Process()
        let binary = try #require(Bundle(for: ForwardCompactionCrashBundleMarker.self).executableURL)
        try #require(host.lastPathComponent == "swiftpm-testing-helper")
        process.executableURL = host
        process.arguments = ["--test-bundle-path", binary.path, binary.path, "--testing-library", "swift-testing", "--filter", "forwardCompactionCrashChild"]
        var environment = ProcessInfo.processInfo.environment
        environment["IMV2_FORWARD_CRASH_MODE"] = mode
        environment["IMV2_FORWARD_CRASH_ROOT"] = root.path
        environment["IMV2_FORWARD_CRASH_SCENARIO"] = scenario
        environment["IMV2_FORWARD_CRASH_REJECTED"] = rejected ? "1" : "0"
        process.environment = environment
        let log = root.appending(path: mode + ".log")
        try Data().write(to: log)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        process.standardOutput = output; process.standardError = output
        let timeout = Task { try await Task.sleep(for: .seconds(30)); if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        let expected = mode == "crash" ? process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL
            : process.terminationReason == .exit && process.terminationStatus == 0
        if !expected { Issue.record("\(try String(contentsOf: log, encoding: .utf8))") }
        try #require(expected)
        #expect(try String(contentsOf: root.appending(path: mode + ".checkpoint"), encoding: .utf8) == scenario)
    }
}
#endif
