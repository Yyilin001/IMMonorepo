import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Durable forward chunk completion", .timeLimit(.minutes(1)))
struct V2ForwardChunkCompletionTests {
    @Test("new forward plans must match their immutable audience and start without completion", arguments: ["sources", "targets", "total", "succeeded", "failed", "state", "terminal"])
    func initialPlanShape(field: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-forward-plan-shape-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()))
        let now = Date(timeIntervalSince1970: 1_000)
        do {
            let operation = MessageForwardOperationID(uuid: UUID())
            let source = try testForwardReference(.init(uuid: UUID()))
            let target = RoomID(uuid: UUID())
            let invalid = V2ForwardMessagesPlan(operationID: operation,
                sourceMessageCount: field == "sources" ? Int.max : 1,
                targetRoomCount: field == "targets" ? Int.max : 1,
                totalForwardCount: field == "total" ? Int.max : 1,
                succeededCount: field == "succeeded" ? 1 : 0, failedCount: field == "failed" ? 1 : 0,
                state: field == "state" ? .completed : .active, terminalCode: field == "terminal" ? "UNAVAILABLE" : nil)
            await #expect(throws: V2ClientCommandError.commandConflict) {
                try await store.enqueueForwardPlan(invalid, sources: [source], targetRoomIDs: [target], now: now)
            }
            let pool = await store.databasePool
            #expect(try await pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_forward_message_plans") } == 0)
            let valid = V2ForwardMessagesPlan(operationID: operation, sourceMessageCount: 1, targetRoomCount: 1, totalForwardCount: 1, succeededCount: 0, failedCount: 0, state: .active, terminalCode: nil)
            #expect(try await store.enqueueForwardPlan(valid, sources: [source], targetRoomIDs: [target], now: now) == valid)
            #expect(try await store.forwardPlan(operationID: operation) == valid)
            let chunk = try #require(try await store.nextReadyForwardPlanChunk(now: now))
            #expect(chunk.command.sources == [source] && chunk.command.targetRoomIDs == [target])
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("forward result counters cannot exceed the plan during completion", arguments: ["succeeded_count", "failed_count"], [Int64.min, -1, 1, 2, 3, Int64.max])
    func resultCounterBounds(column: String, count: Int64) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-forward-result-count-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()))
        let now = Date(timeIntervalSince1970: 1_000)
        do {
            let target = RoomID(uuid: UUID())
            let engine = V2BulkForwardMessagesOutboxEngine(store: store, transport: UnusedTransport(), now: { now })
            let plan = try await engine.enqueue(sources: (0..<2).map { _ in try testForwardReference(.init(uuid: UUID())) }, targetRoomIDs: [target])
            let chunk = try #require(try await store.nextReadyForwardPlanChunk(now: now))
            let results = try chunk.command.sources.map { try V2ForwardMessageResult(sourceMessageID: $0.messageID, targetRoomID: target, messageID: $0.messageID, roomSequence: 1, errorCode: nil) }
            let pool = await store.databasePool
            try await pool.write { db in
                try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
                defer { try? db.execute(sql: "PRAGMA ignore_check_constraints = OFF") }
                try db.execute(sql: "UPDATE v2_forward_message_plans SET \(column) = ?", arguments: [count])
            }
            await #expect(throws: V2ClientCommandError.commandConflict) { try await store.forwardPlan(operationID: plan.operationID) }
            await #expect(throws: V2ClientCommandError.commandConflict) { try await store.nextReadyForwardPlanChunk(now: now) }
            await #expect(throws: V2ClientCommandError.commandConflict) { try await store.markForwardPlanChunkAcknowledged(operationID: chunk.command.operationID, results: results, now: now) }
            #expect(try await pool.read { try String.fetchOne($0, sql: "SELECT state FROM v2_forward_message_chunks") } == "pending")
            #expect(try await pool.read { try Int.fetchOne($0, sql: "SELECT next_chunk_index FROM v2_forward_message_plans") } == 0)
            #expect(try await pool.read { try String.fetchOne($0, sql: "SELECT CAST(\(column) AS TEXT) FROM v2_forward_message_plans") } == String(count))
            try await pool.write { try $0.execute(sql: "UPDATE v2_forward_message_plans SET \(column) = 0") }
            _ = try await store.markForwardPlanChunkAcknowledged(operationID: chunk.command.operationID, results: results, now: now)
            let completed = try #require(try await store.forwardPlan(operationID: plan.operationID))
            #expect(completed.state == .completed && completed.succeededCount == 2 && completed.failedCount == 0)
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("pending chunk indices reject truncation and mismatched progress before retry or completion", arguments: [-1.0, 0.5, 1.0, Double(Int64.max)])
    func pendingChunkIndexBounds(value: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-forward-pending-index-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()))
        let now = Date(timeIntervalSince1970: 1_000)
        do {
            let target = RoomID(uuid: UUID())
            let engine = V2BulkForwardMessagesOutboxEngine(store: store, transport: UnusedTransport(), now: { now })
            let plan = try await engine.enqueue(sources: [testForwardReference(.init(uuid: UUID()))], targetRoomIDs: [target])
            let chunk = try #require(try await store.nextReadyForwardPlanChunk(now: now))
            let results = try chunk.command.sources.map { try V2ForwardMessageResult(sourceMessageID: $0.messageID, targetRoomID: target, messageID: $0.messageID, roomSequence: 1, errorCode: nil) }
            let pool = await store.databasePool
            try await pool.write { db in
                try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
                defer { try? db.execute(sql: "PRAGMA ignore_check_constraints = OFF") }
                try db.execute(sql: "UPDATE v2_forward_message_chunks SET chunk_index = ?", arguments: [value])
            }
            await #expect(throws: V2ClientCommandError.commandConflict) { try await store.nextReadyForwardPlanChunk(now: now) }
            await #expect(throws: V2ClientCommandError.commandConflict) { try await store.markForwardPlanChunkAcknowledged(operationID: chunk.command.operationID, results: results, now: now) }
            await #expect(throws: V2ClientCommandError.commandConflict) { try await store.rejectForwardPlanChunk(operationID: chunk.command.operationID, code: "UNAVAILABLE", now: now) }
            #expect(try await store.forwardPlan(operationID: plan.operationID) == plan)
            #expect(try await pool.read { try String.fetchOne($0, sql: "SELECT state FROM v2_forward_message_chunks") } == "pending")
            #expect(try await pool.read { try Double.fetchOne($0, sql: "SELECT chunk_index FROM v2_forward_message_chunks") } == value)
            try await pool.write { try $0.execute(sql: "UPDATE v2_forward_message_chunks SET chunk_index = 0") }
            #expect(try await store.nextReadyForwardPlanChunk(now: now) == chunk)
            _ = try await store.markForwardPlanChunkAcknowledged(operationID: chunk.command.operationID, results: results, now: now)
            #expect(try await store.forwardPlan(operationID: plan.operationID)?.succeededCount == 1)
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("an empty restored target list fails before division and can be repaired")
    func emptyRestoredTargets() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-forward-empty-targets-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()))
        let now = Date(timeIntervalSince1970: 1_000)
        do {
            let target = RoomID(uuid: UUID())
            let engine = V2BulkForwardMessagesOutboxEngine(store: store, transport: UnusedTransport(), now: { now })
            let plan = try await engine.enqueue(sources: [testForwardReference(.init(uuid: UUID()))], targetRoomIDs: [target])
            let pool = await store.databasePool
            let original = try await pool.read { try #require(try String.fetchOne($0, sql: "SELECT target_room_ids FROM v2_forward_message_plans")) }
            try await pool.write { try $0.execute(sql: "UPDATE v2_forward_message_plans SET target_room_ids = '[]'") }
            await #expect(throws: V2ClientCommandError.commandConflict) { try await store.forwardPlan(operationID: plan.operationID) }
            await #expect(throws: V2ClientCommandError.commandConflict) { try await store.nextReadyForwardPlanChunk(now: now) }
            #expect(try await pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_forward_message_chunks") } == 0)
            try await pool.write { try $0.execute(sql: "UPDATE v2_forward_message_plans SET target_room_ids = ?", arguments: [original]) }
            #expect(try await store.forwardPlan(operationID: plan.operationID) == plan)
            let chunk = try #require(try await store.nextReadyForwardPlanChunk(now: now))
            #expect(chunk.command.targetRoomIDs == [target])
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("restored forward chunk bounds reject inconsistent progress without creating work", arguments: ["indexNegative", "indexPartial", "indexEnd", "indexPastEnd", "indexMax", "totalZero", "totalShort", "totalLong", "totalMax"])
    func restoredChunkBounds(scenario: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-forward-progress-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()))
        let now = Date(timeIntervalSince1970: 1_000)
        do {
            let engine = V2BulkForwardMessagesOutboxEngine(store: store, transport: UnusedTransport(), now: { now })
            let plan = try await engine.enqueue(sources: (0..<21).map { _ in try testForwardReference(.init(uuid: UUID())) }, targetRoomIDs: [.init(uuid: UUID())])
            let column = scenario.hasPrefix("index") ? "next_chunk_index" : "total_chunk_count"
            let value: Int64 = switch scenario {
            case "indexNegative": -1
            case "indexPartial": 1
            case "indexEnd": 2
            case "indexPastEnd", "totalLong": 3
            case "totalZero": 0
            case "totalShort": 1
            default: Int64.max
            }
            let pool = await store.databasePool
            try await pool.write { db in
                try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
                defer { try? db.execute(sql: "PRAGMA ignore_check_constraints = OFF") }
                try db.execute(sql: "UPDATE v2_forward_message_plans SET \(column) = ?", arguments: [value])
            }
            await #expect(throws: V2ClientCommandError.commandConflict) { try await store.forwardPlan(operationID: plan.operationID) }
            await #expect(throws: V2ClientCommandError.commandConflict) { try await store.nextReadyForwardPlanChunk(now: now) }
            #expect(try await pool.read { try String.fetchOne($0, sql: "SELECT state FROM v2_forward_message_plans") } == "active")
            #expect(try await pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_forward_message_chunks") } == 0)
            #expect(try await pool.read { try Int64.fetchOne($0, sql: "SELECT \(column) FROM v2_forward_message_plans") } == value)
            try await pool.write { try $0.execute(sql: "UPDATE v2_forward_message_plans SET next_chunk_index = 0, total_chunk_count = 2") }
            #expect(try await store.forwardPlan(operationID: plan.operationID) == plan)
            let chunk = try #require(try await store.nextReadyForwardPlanChunk(now: now))
            #expect(chunk.command.sources.count == 20)
            #expect(try await store.nextReadyForwardPlanChunk(now: now) == chunk)
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("forward plan creation rejects invalid dates before persistence", arguments: [Double.nan, .infinity, -.infinity, -1, 0, 2_000])
    func planCreationClockBounds(seconds: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-forward-plan-clock-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()))
        do {
            let identifier = UUID()
            let source = try testForwardReference(.init(uuid: UUID()))
            let target = RoomID(uuid: UUID())
            let engine = V2BulkForwardMessagesOutboxEngine(store: store, transport: UnusedTransport(), makeUUID: { identifier }, now: { Date(timeIntervalSince1970: seconds) })
            let pool = await store.databasePool
            if seconds.isFinite {
                _ = try await engine.enqueue(sources: [source], targetRoomIDs: [target])
                #expect(try await pool.read { try Double.fetchOne($0, sql: "SELECT created_at FROM v2_forward_message_plans") } == seconds)
                #expect(try await pool.read { try Double.fetchOne($0, sql: "SELECT updated_at FROM v2_forward_message_plans") } == seconds)
            } else {
                await #expect(throws: V2ClientCommandError.commandConflict) { try await engine.enqueue(sources: [source], targetRoomIDs: [target]) }
                #expect(try await pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_forward_message_plans") } == 0)
            }
            let recovered = V2BulkForwardMessagesOutboxEngine(store: store, transport: UnusedTransport(), makeUUID: { identifier }, now: { Date(timeIntervalSince1970: 1_000) })
            let plan = try await recovered.enqueue(sources: [source], targetRoomIDs: [target])
            #expect(plan.operationID == MessageForwardOperationID(uuid: identifier))
            let chunk = try #require(try await store.nextReadyForwardPlanChunk(now: Date(timeIntervalSince1970: 1_000)))
            #expect(chunk.command.sources == [source])
            #expect(chunk.command.targetRoomIDs == [target])
            #expect(try await pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_forward_message_plans") } == 1)
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("forward clock failures preserve plan and chunk progress", arguments: ["chunk", "ack", "reject", "cancel"], [Double.nan, .infinity, -.infinity])
    func forwardClockBounds(stage: String, seconds: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "im-forward-clock-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "state.sqlite"), installationBinding: .init(value: UUID()))
        let now = Date(timeIntervalSince1970: 1_000)
        do {
            let source = try testForwardReference(.init(uuid: UUID()))
            let target = RoomID(uuid: UUID())
            let engine = V2BulkForwardMessagesOutboxEngine(store: store, transport: UnusedTransport(), now: { now })
            let plan = try await engine.enqueue(sources: [source], targetRoomIDs: [target])
            let chunk = stage == "chunk" ? nil : try await store.nextReadyForwardPlanChunk(now: now)
            let pool = await store.databasePool
            func snapshot() async throws -> [String] {
                try await pool.read { db in
                    let plans = try String.fetchAll(db, sql: "SELECT quote(state) || ':' || quote(next_chunk_index) || ':' || quote(succeeded_count) || ':' || quote(failed_count) || ':' || quote(updated_at) FROM v2_forward_message_plans ORDER BY plan_id")
                    let chunks = try String.fetchAll(db, sql: "SELECT quote(state) || ':' || quote(attempt_count) || ':' || quote(next_attempt_at) || ':' || quote(completion_digest) FROM v2_forward_message_chunks ORDER BY operation_id")
                    return plans + chunks
                }
            }
            func perform(at date: Date) async throws {
                switch stage {
                case "chunk": _ = try await store.nextReadyForwardPlanChunk(now: date)
                case "cancel": try await store.cancelForwardPlan(operationID: plan.operationID, now: date)
                case "reject": _ = try await store.rejectForwardPlanChunk(operationID: #require(chunk).command.operationID, code: "UNAVAILABLE", now: date)
                default:
                    let result = try V2ForwardMessageResult(sourceMessageID: source.messageID, targetRoomID: target, messageID: source.messageID, roomSequence: 1, errorCode: nil)
                    _ = try await store.markForwardPlanChunkAcknowledged(operationID: #require(chunk).command.operationID, results: [result], now: date)
                }
            }
            let before = try await snapshot()
            await #expect(throws: V2ClientCommandError.commandConflict) { try await perform(at: Date(timeIntervalSince1970: seconds)) }
            #expect(try await snapshot() == before)
            try await perform(at: now)
            if stage == "chunk" {
                #expect(try await store.nextReadyForwardPlanChunk(now: now) != nil)
            } else {
                #expect(try await store.forwardPlan(operationID: plan.operationID)?.state == (stage == "cancel" ? .cancelled : .completed))
            }
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    @Test("concurrent reordered replays and a closed-store restart count each chunk once")
    func repeatedCompletion() async throws {
        let fixture = try await Fixture(sourceCount: 21)
        let chunk = try #require(await fixture.store.nextReadyForwardPlanChunk(now: fixture.now))
        let results = try fixture.results(chunk, failedLast: true)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    let receipt = try await fixture.store.markForwardPlanChunkAcknowledged(
                        operationID: chunk.command.operationID, results: index.isMultiple(of: 2) ? results : results.reversed(), now: fixture.now
                    )
                    #expect(receipt == fixture.plan.operationID)
                }
            }
            try await group.waitForAll()
        }
        let before = try #require(await fixture.store.forwardPlan(operationID: fixture.plan.operationID))
        #expect(before.succeededCount == 19 && before.failedCount == 1 && before.state == .active)
        try await fixture.store.close()
        let reopened = try GRDBV2LocalSyncStore(databaseURL: fixture.url, installationBinding: fixture.binding)
        _ = try await reopened.markForwardPlanChunkAcknowledged(operationID: chunk.command.operationID, results: results.reversed(), now: fixture.now.addingTimeInterval(30))
        #expect(try await reopened.forwardPlan(operationID: fixture.plan.operationID) == before)
        let next = try #require(await reopened.nextReadyForwardPlanChunk(now: fixture.now))
        #expect(next.command.sourceMessageIDs.count == 1)
        let finalResults = try fixture.results(next)
        _ = try await reopened.markForwardPlanChunkAcknowledged(operationID: next.command.operationID, results: finalResults, now: fixture.now)
        _ = try await reopened.markForwardPlanChunkAcknowledged(operationID: chunk.command.operationID, results: results, now: fixture.now)
        _ = try await reopened.markForwardPlanChunkAcknowledged(operationID: next.command.operationID, results: finalResults, now: fixture.now)
        let completed = try #require(await reopened.forwardPlan(operationID: fixture.plan.operationID))
        #expect(completed.succeededCount == 20 && completed.failedCount == 1 && completed.state == .completed)
        #expect(try await reopened.nextReadyForwardPlanChunk(now: fixture.now) == nil)
        await #expect(throws: V2ClientCommandError.commandNotPending) {
            try await reopened.scheduleForwardPlanChunkRetry(operationID: next.command.operationID, nextAttemptAt: fixture.now)
        }
        try await reopened.close()
    }

    @Test("every result identity, sequence, outcome and error participates in completion consistency", arguments: ["source", "target", "message", "sequence", "outcome", "error", "duplicate", "missing"])
    func changedCompletion(kind: String) async throws {
        let fixture = try await Fixture()
        let chunk = try #require(await fixture.store.nextReadyForwardPlanChunk(now: fixture.now))
        let original = try fixture.results(chunk, failedLast: true)
        _ = try await fixture.store.markForwardPlanChunkAcknowledged(operationID: chunk.command.operationID, results: original, now: fixture.now)
        let before = try await fixture.store.forwardPlan(operationID: fixture.plan.operationID)
        let first = original[0]
        var changed = original
        switch kind {
        case "source": changed[0] = try .init(sourceMessageID: .init(uuid: UUID()), targetRoomID: first.targetRoomID, messageID: first.messageID, roomSequence: first.roomSequence, errorCode: nil)
        case "target": changed[0] = try .init(sourceMessageID: first.sourceMessageID, targetRoomID: .init(uuid: UUID()), messageID: first.messageID, roomSequence: first.roomSequence, errorCode: nil)
        case "message": changed[0] = try .init(sourceMessageID: first.sourceMessageID, targetRoomID: first.targetRoomID, messageID: .init(uuid: UUID()), roomSequence: first.roomSequence, errorCode: nil)
        case "sequence": changed[0] = try .init(sourceMessageID: first.sourceMessageID, targetRoomID: first.targetRoomID, messageID: first.messageID, roomSequence: 2, errorCode: nil)
        case "outcome": changed[0] = try .init(sourceMessageID: first.sourceMessageID, targetRoomID: first.targetRoomID, messageID: nil, roomSequence: nil, errorCode: "FORBIDDEN")
        case "error": changed[1] = try .init(sourceMessageID: original[1].sourceMessageID, targetRoomID: first.targetRoomID, messageID: nil, roomSequence: nil, errorCode: "NOT_FOUND")
        case "duplicate": changed[1] = first
        default: changed.removeLast()
        }
        let conflicting = changed
        await #expect(throws: V2ClientCommandError.commandConflict) {
            try await fixture.store.markForwardPlanChunkAcknowledged(operationID: chunk.command.operationID, results: conflicting, now: fixture.now)
        }
        #expect(try await fixture.store.forwardPlan(operationID: fixture.plan.operationID) == before)
        try await fixture.store.close()
    }

    @Test("terminal rejection repeats once and cannot turn into a different failure or success")
    func repeatedRejection() async throws {
        let fixture = try await Fixture()
        let chunk = try #require(await fixture.store.nextReadyForwardPlanChunk(now: fixture.now))
        for _ in 0..<2 {
            #expect(try await fixture.store.rejectForwardPlanChunk(operationID: chunk.command.operationID, code: "FORBIDDEN", now: fixture.now) == fixture.plan.operationID)
        }
        await #expect(throws: V2ClientCommandError.commandConflict) {
            try await fixture.store.rejectForwardPlanChunk(operationID: chunk.command.operationID, code: "NOT_FOUND", now: fixture.now)
        }
        await #expect(throws: V2ClientCommandError.commandConflict) {
            try await fixture.store.markForwardPlanChunkAcknowledged(operationID: chunk.command.operationID, results: fixture.results(chunk), now: fixture.now)
        }
        let completed = try #require(await fixture.store.forwardPlan(operationID: fixture.plan.operationID))
        #expect(completed.failedCount == 2 && completed.succeededCount == 0 && completed.state == .completed)
        try await fixture.store.close()
    }

    @Test("cancelled pending chunks refuse late ACK while earlier completed chunks remain replayable")
    func cancelledPlan() async throws {
        let fixture = try await Fixture(sourceCount: 21)
        let first = try #require(await fixture.store.nextReadyForwardPlanChunk(now: fixture.now))
        _ = try await fixture.store.markForwardPlanChunkAcknowledged(operationID: first.command.operationID, results: fixture.results(first), now: fixture.now)
        let pending = try #require(await fixture.store.nextReadyForwardPlanChunk(now: fixture.now))
        try await fixture.store.cancelForwardPlan(operationID: fixture.plan.operationID, now: fixture.now)
        _ = try await fixture.store.markForwardPlanChunkAcknowledged(operationID: first.command.operationID, results: fixture.results(first), now: fixture.now)
        await #expect(throws: V2ClientCommandError.commandConflict) {
            try await fixture.store.markForwardPlanChunkAcknowledged(operationID: pending.command.operationID, results: fixture.results(pending), now: fixture.now)
        }
        await #expect(throws: V2ClientCommandError.commandConflict) {
            try await fixture.store.rejectForwardPlanChunk(operationID: pending.command.operationID, code: "FORBIDDEN", now: fixture.now)
        }
        let plan = try #require(await fixture.store.forwardPlan(operationID: fixture.plan.operationID))
        #expect(plan.succeededCount == 20 && plan.failedCount == 0 && plan.state == .cancelled)
        try await fixture.store.close()
    }

    @Test("parent update failure rolls back both the chunk digest and its completion")
    func transactionRollback() async throws {
        let fixture = try await Fixture()
        let chunk = try #require(await fixture.store.nextReadyForwardPlanChunk(now: fixture.now))
        try await fixture.store.databasePool.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_plan_update BEFORE UPDATE ON v2_forward_message_plans BEGIN SELECT RAISE(ABORT, 'injected parent write failure'); END")
        }
        await #expect(throws: DatabaseError.self) {
            try await fixture.store.markForwardPlanChunkAcknowledged(operationID: chunk.command.operationID, results: fixture.results(chunk), now: fixture.now)
        }
        try await fixture.store.databasePool.write { db in
            let row = try #require(try Row.fetchOne(db, sql: "SELECT state, completion_digest FROM v2_forward_message_chunks"))
            #expect((row["state"] as String) == "pending")
            #expect((row["completion_digest"] as String?) == nil)
            try db.execute(sql: "DROP TRIGGER fail_plan_update")
        }
        _ = try await fixture.store.markForwardPlanChunkAcknowledged(operationID: chunk.command.operationID, results: fixture.results(chunk), now: fixture.now)
        #expect(try await fixture.store.forwardPlan(operationID: fixture.plan.operationID)?.succeededCount == 2)
        try await fixture.store.close()
    }

    @Test("reopening preserves completion receipts and pending work")
    func reopensExistingOutbox() async throws {
        let fixture = try await Fixture(sourceCount: 21)
        let completed = try #require(await fixture.store.nextReadyForwardPlanChunk(now: fixture.now))
        _ = try await fixture.store.markForwardPlanChunkAcknowledged(operationID: completed.command.operationID, results: fixture.results(completed), now: fixture.now)
        let pending = try #require(await fixture.store.nextReadyForwardPlanChunk(now: fixture.now))
        try await fixture.store.close()
        let reopened = try GRDBV2LocalSyncStore(databaseURL: fixture.url, installationBinding: fixture.binding)
        #expect(try await reopened.nextReadyForwardPlanChunk(now: fixture.now) == pending)
        #expect(try await reopened.markForwardPlanChunkAcknowledged(operationID: completed.command.operationID, results: fixture.results(completed), now: fixture.now) == fixture.plan.operationID)
        _ = try await reopened.markForwardPlanChunkAcknowledged(operationID: pending.command.operationID, results: fixture.results(pending), now: fixture.now)
        #expect(try await reopened.forwardPlan(operationID: fixture.plan.operationID)?.succeededCount == 21)
        try await reopened.close()
    }

    @Test("an existing plan ID cannot silently reuse different sources with identical counts")
    func differentPlanInputConflicts() async throws {
        let fixture = try await Fixture()
        await #expect(throws: V2ClientCommandError.commandConflict) {
            try await fixture.store.enqueueForwardPlan(fixture.plan, sources: [try testForwardReference(.init(uuid: UUID())), try testForwardReference(.init(uuid: UUID()))], targetRoomIDs: [fixture.target], now: fixture.now)
        }
        try await fixture.store.close()
    }

    @Test("the engine exposes invalid local completion without converting it into a retry", arguments: [UInt64(0), UInt64.max])
    func invalidCompletionIsNotRetryable(sequence: UInt64) async throws {
        let fixture = try await Fixture()
        let chunk = try #require(await fixture.store.nextReadyForwardPlanChunk(now: fixture.now))
        let engine = V2BulkForwardMessagesOutboxEngine(store: fixture.store, transport: FixedTransport(sequence: sequence), now: { fixture.now })
        await #expect(throws: V2ClientCommandError.commandConflict) { try await engine.flushOnce() }
        #expect(try await fixture.store.nextReadyForwardPlanChunk(now: fixture.now) == chunk)
        #expect(try await fixture.store.forwardPlan(operationID: fixture.plan.operationID) == fixture.plan)
        try await fixture.store.close()
    }

    private struct FixedTransport: V2ClientForwardMessagesTransport {
        let sequence: UInt64
        func forwardMessages(command: V2ForwardMessagesCommand) async throws -> [V2ForwardMessageResult] {
            try command.sourceMessageIDs.map { try .init(sourceMessageID: $0, targetRoomID: command.targetRoomIDs[0], messageID: $0, roomSequence: sequence, errorCode: nil) }
        }
    }

    private struct Fixture: Sendable {
        let url: URL
        let binding = V2LocalInstallationBinding(value: UUID())
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let store: GRDBV2LocalSyncStore
        let plan: V2ForwardMessagesPlan
        let target = RoomID(uuid: UUID())

        init(sourceCount: Int = 2) async throws {
            url = FileManager.default.temporaryDirectory.appending(path: "im-forward-completion-\(UUID().uuidString).sqlite")
            store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
            let timestamp = now
            let engine = V2BulkForwardMessagesOutboxEngine(store: store, transport: UnusedTransport(), now: { timestamp })
            plan = try await engine.enqueue(sources: (0..<sourceCount).map { _ in try testForwardReference(.init(uuid: UUID())) }, targetRoomIDs: [target])
        }

        func results(_ chunk: V2PendingForwardMessagesCommand, failedLast: Bool = false) throws -> [V2ForwardMessageResult] {
            try chunk.command.sourceMessageIDs.enumerated().map { index, source in
                let failed = failedLast && index == chunk.command.sourceMessageIDs.count - 1
                return try .init(sourceMessageID: source, targetRoomID: target, messageID: failed ? nil : source, roomSequence: failed ? nil : 1, errorCode: failed ? "FORBIDDEN" : nil)
            }
        }
    }

    private struct UnusedTransport: V2ClientForwardMessagesTransport {
        func forwardMessages(command: V2ForwardMessagesCommand) async throws -> [V2ForwardMessageResult] {
            Issue.record("storage fixture must not send")
            throw V2ClientCommandError.commandConflict
        }
    }
}
