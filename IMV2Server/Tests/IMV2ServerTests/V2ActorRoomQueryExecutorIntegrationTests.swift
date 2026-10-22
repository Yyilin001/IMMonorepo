@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import FluentKit
import FluentPostgresDriver
import Foundation
import Synchronization
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

@Suite("Room actor query and receipt executors on PostgreSQL", .serialized)
struct V2ActorRoomQueryExecutorIntegrationTests {
    @Test("packed pull reads each page once and does not wait for a room row lock")
    func packedPullSnapshot() async throws {
        try await withActorQueryDatabase { database, sql in
            let room = UUID(), actor = UUID()
            try await seedRoom(sql: sql, room: room, actor: actor, sequence: 2)
            for sequence in 1...2 {
                try await sql.raw("""
                    INSERT INTO im_v2.room_events(event_id,room_id,room_sequence,event_type,payload,committed_membership_revision,created_at)
                    VALUES (\(bind: UUID()),\(bind: room),\(bind: sequence),'room.created','{}'::jsonb,1,now())
                    """).run()
            }
            try await withRoomActivation(database: database, roomID: .init(uuid: room),
                                             shardID: "owner-a") { token in
                let executor = V2ActorRoomQueryExecutor(database: database)
                let query = try V2ActorRoomLogPullWire(roomID: .init(uuid: room), actorUserID: .init(uuid: actor),
                    afterRoomSequence: 0, pageSize: 1)
                let input = try V2GroupEventPullBatchInput(ordinal: 0, query: query)
                let packed = try await v2PackedGroupEventPulls([input], tokens: [token.roomID: token], maximumBytes: 1024, sql: sql)
                #expect(packed.selected == [0])
                #expect(packed.rows[0]?.count == 1)
                #expect(packed.metadata[0]?.hasMore == true)
                guard case .page(let first) = try await executor.pullSnapshot(query, token: token) else {
                    Issue.record("missing first page"); return
                }
                #expect(first.events.count == 1 && first.nextRoomSequence == 1 && first.hasMore)
                let occupied = ActorQueryGate()
                let blocker = Task {
                    try await database.transaction { transaction in
                        let lockedSQL = try #require(transaction as? any SQLDatabase)
                        try await lockedSQL.raw("SELECT room_id FROM im_v2.rooms WHERE room_id=\(bind: room) FOR UPDATE").run()
                        await occupied.signal()
                        try await ContinuousClock().sleep(for: .milliseconds(500))
                    }
                }
                await occupied.wait()
                let start = ContinuousClock.now
                _ = try await executor.pullSnapshot(query, token: token)
                #expect(start.duration(to: .now) < .milliseconds(350))
                try await blocker.value
                try await sql.raw("UPDATE im_v2.rooms SET owner_epoch=1 WHERE room_id=\(bind: room)").run()
                await #expect(throws: V2RoomActorStateError.ownerChanged) {
                    _ = try await executor.pullSnapshot(query, token: token)
                }
            }
        }
    }

    @Test("packed pull bounds whole pages and keeps authority failures separate")
    func packedPullBounds() async throws {
        try await withActorQueryDatabase { database, sql in
            let actor = UUID(), roomA = UUID(), roomB = UUID()
            var inputs: [V2GroupEventPullBatchInput] = []
            for (ordinal, room) in [roomA, roomB].enumerated() {
                try await seedRoom(sql: sql, room: room, actor: actor, sequence: 1)
                let payload = "{\"text\":\"" + String(repeating: "x", count: 1000) + "\"}"
                try await sql.raw("""
                    INSERT INTO im_v2.room_events(event_id,room_id,room_sequence,event_type,payload,committed_membership_revision,created_at)
                    VALUES (\(bind: UUID()),\(bind: room),1,'room.created',\(bind: payload)::jsonb,1,now())
                    """).run()
                inputs.append(try .init(ordinal: ordinal, query: .init(roomID: .init(uuid: room),
                    actorUserID: .init(uuid: actor), afterRoomSequence: 0, pageSize: 10)))
            }
            let selectedInputs = inputs
            try await withRoomActivations(database: database,
                roomIDs: [.init(uuid: roomA), .init(uuid: roomB)], shardID: "owner-a") { references in
                let inputs = selectedInputs
                let tokens = Dictionary(uniqueKeysWithValues: references.map { ($0.roomID, $0) })
                let packed = try await v2PackedGroupEventPulls(inputs, tokens: tokens, maximumBytes: 1500, sql: sql)
                #expect(packed.selected == [0])
                #expect(packed.rows[0]?.count == 1 && packed.rows[1] == nil)
                #expect(packed.byteHints.count == 2)
                try await sql.raw("UPDATE im_v2.rooms SET owner_epoch=1 WHERE room_id=\(bind: roomA)").run()
                let mixed = try await v2PackedGroupEventPulls(inputs, tokens: tokens, maximumBytes: 4000, sql: sql)
                #expect(mixed.failures[0] != nil && mixed.rows[0] == nil)
                #expect(mixed.rows[1]?.count == 1)
                let stranger = try V2ActorRoomLogPullWire(roomID: .init(uuid: roomB), actorUserID: .init(uuid: UUID()),
                    afterRoomSequence: 0, pageSize: 10)
                await #expect(throws: V2GroupEventLogError.actorNotMember) {
                    _ = try await V2ActorRoomQueryExecutor(database: database).pullSnapshot(stranger,
                        token: tokens[RoomID(uuid: roomB)]!)
                }
            }
        }
    }

    @Test("receipt replay is fenced before reading the operation record")
    func receiptReplayFence() async throws {
        try await withActorQueryDatabase { database, sql in
            let room = UUID(), actor = UUID()
            try await seedRoom(sql: sql, room: room, actor: actor, sequence: 1)
            let receipt = V2ActorRoomReceiptExecutor(database: database,
                projectionDelivery: SuccessfulProjectionDelivery())
            let operation = ReadReceiptOperationID(uuid: UUID())
            let request = try V2ActorRecordReadReceiptWire(roomID: .init(uuid: room),
                actorUserID: .init(uuid: actor), operationID: operation, readThroughRoomSequence: 1)
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            try await withRoomActivation(database: database, roomID: .init(uuid: room),
                                         shardID: "owner-a") { old in
                let first = try await receipt.command(.record(request), token: old, ingressAt: now)
                guard case .record(.recorded(let recorded)) = first else {
                    Issue.record("first receipt did not record"); return
                }
                #expect(recorded.readThroughRoomSequence == 1)
                let replay = try await receipt.command(.record(request), token: old, ingressAt: now)
                guard case .record(.idempotent(let prior)) = replay else {
                    Issue.record("receipt replay was not idempotent"); return
                }
                #expect(prior.readThroughRoomSequence == 1)
                let readers = try V2ActorReadReceiptReadersQueryWire(roomID: .init(uuid: room),
                    messageID: .init(uuid: UUID()), actorUserID: .init(uuid: actor), cursor: nil, pageSize: 10)
                let missing = try await receipt.query(.readerCandidates(readers), token: old)
                #expect(missing == .readersFailure(.messageNotFound))
                try await sql.raw("UPDATE im_v2.rooms SET owner_epoch=1 WHERE room_id=\(bind: room)").run()
                await #expect(throws: V2RoomActorStateError.activationChanged) {
                    _ = try await receipt.command(.record(request), token: old, ingressAt: now)
                }
            }
            try await withRoomActivation(database: database, roomID: .init(uuid: room),
                                         shardID: "owner-a", epoch: 1) { successor in
                let retry = try await receipt.command(.record(request), token: successor, ingressAt: now)
                guard case .record(.idempotent) = retry else { Issue.record("successor did not recover replay"); return }
                let row = try #require(try await sql.raw("SELECT count(*) AS value FROM im_v2.read_receipt_operations")
                    .first(decoding: ActorQueryCountRow.self))
                #expect(row.value == 1)
            }
        }
    }

    @Test("mixed stale and valid receipt batch preserves per-row results and zero stale writes")
    func mixedReceiptBatch() async throws {
        try await withActorQueryDatabase { database, sql in
            let roomA = UUID(), roomB = UUID(), actor = UUID()
            try await seedRoom(sql: sql, room: roomA, actor: actor, sequence: 1)
            try await seedRoom(sql: sql, room: roomB, actor: actor, sequence: 1)
            try await withRoomActivations(database: database,
                roomIDs: [.init(uuid: roomA), .init(uuid: roomB)], shardID: "owner-a") { tokens in
                let oldA = try #require(tokens.first { $0.roomID == .init(uuid: roomA) })
                let currentB = try #require(tokens.first { $0.roomID == .init(uuid: roomB) })
                let executor = V2ActorRoomReceiptExecutor(database: database,
                    projectionDelivery: SuccessfulProjectionDelivery())
                let user = UserID(uuid: actor), now = Date(timeIntervalSince1970: 1_750_000_000)
                let oldOperation = try V2ActorRecordReadReceiptWire(roomID: .init(uuid: roomA),
                    actorUserID: user, operationID: .init(uuid: UUID()), readThroughRoomSequence: 1)
                _ = try await executor.command(.record(oldOperation), token: oldA, ingressAt: now)
                try await sql.raw("UPDATE im_v2.rooms SET owner_epoch=1 WHERE room_id=\(bind: roomA)").run()
                let staleNewOperation = try V2ActorRecordReadReceiptWire(roomID: .init(uuid: roomA),
                    actorUserID: user, operationID: .init(uuid: UUID()), readThroughRoomSequence: 1)
                let validOperation = try V2ActorRecordReadReceiptWire(roomID: .init(uuid: roomB),
                    actorUserID: user, operationID: .init(uuid: UUID()), readThroughRoomSequence: 1)
                let batch = try V2ActorReadReceiptRecordBatchWire(requests: [oldOperation, staleNewOperation, validOperation])
                let result = try await executor.recordBatch(batch, scope: .init(tokens: [oldA, currentB]), ingressAt: now)
                #expect(result.results.count == 3)
                #expect(result.results[0] == .failure(.ownerChanged))
                #expect(result.results[1] == .failure(.ownerChanged))
                guard case .success(.recorded) = result.results[2] else {
                    Issue.record("valid receipt did not commit beside stale rows"); return
                }
                let operationCount = try #require(try await sql.raw("SELECT count(*) AS value FROM im_v2.read_receipt_operations")
                    .first(decoding: ActorQueryCountRow.self))
                #expect(operationCount.value == 2)
                let staleCount = try #require(try await sql.raw("""
                    SELECT count(*) AS value FROM im_v2.read_receipt_operations
                    WHERE operation_id = \(bind: staleNewOperation.operationID.uuidValue!)
                    """).first(decoding: ActorQueryCountRow.self))
                #expect(staleCount.value == 0)
            }
        }
    }

    @Test("receipt lock timeout remains an infrastructure failure, not a per-row owner denial")
    func receiptLockTimeout() async throws {
        try await withActorQueryDatabase { database, sql in
            let room = UUID(), actor = UUID()
            try await seedRoom(sql: sql, room: room, actor: actor, sequence: 1)
            try await withRoomActivation(database: database, roomID: .init(uuid: room),
                                             shardID: "owner-a") { token in
                let locked = ActorQueryGate()
                let blocker = Task {
                    defer { Task { await locked.signal() } }
                    try await database.transaction { transaction in
                        let txSQL = try #require(transaction as? any SQLDatabase)
                        try await txSQL.raw("SELECT room_id FROM im_v2.rooms WHERE room_id = \(bind: room) FOR UPDATE").run()
                        await locked.signal()
                        try await Task.sleep(for: .milliseconds(300))
                    }
                }
                await locked.wait()
                let executor = V2ActorRoomReceiptExecutor(database: database,
                    projectionDelivery: SuccessfulProjectionDelivery(),
                    timeouts: try .init(lockMilliseconds: 75, statementMilliseconds: 1_000,
                        idleTransactionMilliseconds: 1_000))
                let request = try V2ActorRecordReadReceiptWire(roomID: .init(uuid: room),
                    actorUserID: .init(uuid: actor), operationID: .init(uuid: UUID()),
                    readThroughRoomSequence: 1)
                await #expect(throws: V2RoomCallFailure.rolledBack(.unavailable)) {
                    _ = try await executor.command(.record(request), token: token,
                        ingressAt: Date(timeIntervalSince1970: 1_750_000_000))
                }
                try await blocker.value
                let rows = try #require(try await sql.raw("SELECT count(*) AS value FROM im_v2.read_receipt_operations")
                    .first(decoding: ActorQueryCountRow.self))
                #expect(rows.value == 0)
            }
        }
    }

    @Test("collection state/latest queries and per-room directory/log stay database-authoritative")
    func queryFamilies() async throws {
        try await withActorQueryDatabase { database, sql in
            let actor = UUID(), roomA = UUID(), roomB = UUID()
            try await seedRoom(sql: sql, room: roomA, actor: actor, sequence: 0)
            try await seedRoom(sql: sql, room: roomB, actor: actor, sequence: 0)
            try await withRoomActivations(database: database,
                roomIDs: [.init(uuid: roomA), .init(uuid: roomB)], shardID: "owner-a") { tokens in
                let tokenA = try #require(tokens.first { $0.roomID == .init(uuid: roomA) })
                let tokenB = try #require(tokens.first { $0.roomID == .init(uuid: roomB) })
                let executor = V2ActorRoomQueryExecutor(database: database)
                let ids = [RoomID(uuid: roomA), RoomID(uuid: roomB)]
                let user = UserID(uuid: actor)
                let wire = try V2ActorRoomRecoveryBatchQueryWire(roomIDs: ids, actorUserID: user)
                let stateResult = try await executor.recovery(.states(wire), tokens: [tokenA, tokenB])
                guard case .states(let stateBatch) = stateResult else { Issue.record("state batch missing"); return }
                let states = try stateBatch.domainValue(expectedRoomIDs: ids)
                #expect(states.count == 2)
                for id in ids {
                    guard case .state(let state)? = states[id] else { Issue.record("state unavailable"); continue }
                    #expect(state.ownerEpoch == 0 && state.head == 0 && state.viewerMembershipRevision == 1)
                }
                let latestResult = try await executor.recovery(.latestVisible(wire), tokens: [tokenA, tokenB])
                guard case .latestVisible(let latestBatch) = latestResult else { Issue.record("latest batch missing"); return }
                let latest = try latestBatch.domainValue(expectedRoomIDs: ids)
                #expect(latest.count == 2)
                for id in ids {
                    guard case .snapshot(let snapshot)? = latest[id] else { Issue.record("latest unavailable"); continue }
                    #expect(snapshot.latest == nil && snapshot.head == 0)
                }
                let subscription = try await executor.log(.subscribe(.init(roomID: ids[0], actorUserID: user)), token: tokenA)
                guard case .subscription(let sub) = subscription else { Issue.record("subscription missing"); return }
                #expect(sub.highWatermark == 0 && sub.membershipRevision == 1)
                let pull = try V2ActorRoomLogPullWire(roomID: ids[0], actorUserID: user,
                    afterRoomSequence: 0, pageSize: 10)
                let logPage = try await executor.log(.pull(pull), token: tokenA)
                guard case .page(let pageWire) = logPage else { Issue.record("log page missing"); return }
                #expect(pageWire.events.isEmpty && pageWire.nextRoomSequence == 0)
                let membership = try V2ActorMembershipDirectoryQueryWire(roomID: ids[0], actorUserID: user,
                    cursor: nil, pageSize: 10)
                let directory = try await executor.directory(.membership(membership), token: tokenA)
                guard case .membership(let page) = directory else { Issue.record("directory missing"); return }
                #expect(page.entries.map(\.userID) == [user])
                let baseline = try await executor.directory(.roleBaseline(.init(roomID: ids[0], actorUserID: user)), token: tokenA)
                guard case .roleBaseline(let policy) = baseline else { Issue.record("baseline missing"); return }
                #expect(policy.permissionRevision == 1 && policy.membershipRevision == 1)
                try await sql.raw("UPDATE im_v2.rooms SET owner_epoch=1 WHERE room_id=\(bind: roomA)").run()
                await #expect(throws: V2RoomActorStateError.ownerChanged) {
                    _ = try await executor.recovery(.states(wire), tokens: [tokenA, tokenB])
                }
            }
        }
    }

    @Test("host batcher accepts granted turns, releases results independently, and honors original deadline")
    func grantedBatcher() async throws {
        try await withActorQueryDatabase { database, sql in
            let actor = UUID(), roomA = UUID(), roomB = UUID()
            try await seedRoom(sql: sql, room: roomA, actor: actor, sequence: 0)
            try await seedRoom(sql: sql, room: roomB, actor: actor, sequence: 0)
            try await withRoomActivations(database: database,
                roomIDs: [.init(uuid: roomA), .init(uuid: roomB)], shardID: "owner-a") { tokens in
                let tokenA = try #require(tokens.first { $0.roomID == .init(uuid: roomA) })
                let tokenB = try #require(tokens.first { $0.roomID == .init(uuid: roomB) })
                let batcher = V2HostRoomRecoveryQueryBatcher(executor: .init(database: database),
                    configuration: try .init(maximumItems: 2))
                let batchDeadline = ContinuousClock.now.advanced(by: .milliseconds(50))
                let callDeadline = ContinuousClock.now.advanced(by: .seconds(2)), user = UserID(uuid: actor)
                let first = Task { try await batcher.state(.init(token: tokenA, actorUserID: user,
                    batchDeadline: batchDeadline, callDeadline: callDeadline)) }
                let second = Task { try await batcher.state(.init(token: tokenB, actorUserID: user,
                    batchDeadline: batchDeadline, callDeadline: callDeadline)) }
                let a = await first.result
                let b = await second.result
                guard case .state(let stateA) = try a.get(),
                      case .state(let stateB) = try b.get() else {
                    Issue.record("granted batch did not return both states"); return
                }
                #expect(stateA.roomID == .init(uuid: roomA) && stateB.roomID == .init(uuid: roomB))
                guard case .snapshot(let latest) = try await batcher.latestVisible(.init(token: tokenA,
                    actorUserID: user, batchDeadline: ContinuousClock.now.advanced(by: .milliseconds(-1)),
                    callDeadline: ContinuousClock.now.advanced(by: .seconds(2)))) else {
                    Issue.record("granted latest-visible turn did not complete"); return
                }
                #expect(latest.roomID == .init(uuid: roomA) && latest.latest == nil)
                await #expect(throws: V2HostRoomRecoveryBatchError.deadlineExceeded) {
                    _ = try await batcher.state(.init(token: tokenA, actorUserID: user,
                        batchDeadline: ContinuousClock.now.advanced(by: .milliseconds(-1)),
                        callDeadline: ContinuousClock.now.advanced(by: .milliseconds(-1))))
                }
            }
        }
    }

    @Test("expired batch cutoff dispatches a still-live granted call")
    func expiredBatchCutoff() async throws {
        try await withActorQueryDatabase { database, sql in
            let actor = UUID(), room = UUID()
            try await seedRoom(sql: sql, room: room, actor: actor, sequence: 0)
            try await withRoomActivation(database: database, roomID: .init(uuid: room),
                                             shardID: "owner-a") { token in
                let batcher = V2HostRoomRecoveryQueryBatcher(executor: .init(database: database),
                    configuration: try .init(maximumItems: 2))
                let result = try await batcher.state(.init(token: token, actorUserID: .init(uuid: actor),
                    batchDeadline: ContinuousClock.now.advanced(by: .seconds(-1)),
                    callDeadline: ContinuousClock.now.advanced(by: .seconds(2))))
                guard case .state(let state) = result else { Issue.record("state was not dispatched"); return }
                #expect(state.roomID == .init(uuid: room))
            }
        }
    }

    @Test("saturated batcher bounds queued plus actual items, separates epochs and byte groups, and honors call deadlines")
    func saturatedBatcher() async throws {
        let actor = UserID(uuid: UUID())
        let owner = try V2RoomDataOwner(shardID: "owner-a", epoch: 0)
        let host = V2ActorHostIdentity(hostID: try .init("host-a"), incarnationID: UUID())
        func token(_ room: UUID, epoch: Int64 = 1) throws -> V2RoomActivationToken {
            .init(roomID: .init(uuid: room), owner: owner,
                activationEpoch: try .init(epoch), host: host)
        }
        let roomA = UUID(), roomB = UUID(), roomC = UUID(), roomD = UUID()
        let occupied = ActorQueryGate(), release = ActorQueryGate()
        let actualTokens = Mutex<[[V2RoomActivationToken]]>([])
        let batcher = V2HostRoomRecoveryQueryBatcher(configuration: try .init(maximumItems: 2,
            maximumPendingItems: 6, maximumInFlightBatches: 1)) { _, tokens in
            actualTokens.withLock { $0.append(tokens) }
            await occupied.signal()
            await release.wait()
            throw CancellationError()
        }
        defer { Task { await release.signal() } }
        let first = Task { try await batcher.state(.init(token: try token(roomA), actorUserID: actor,
            batchDeadline: .now, callDeadline: .now.advanced(by: .seconds(2)))) }
        await occupied.wait()
        let pendingDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        let queued = Task { try await batcher.state(.init(token: try token(roomB), actorUserID: actor,
            batchDeadline: pendingDeadline, callDeadline: .now.advanced(by: .seconds(2)))) }
        try await waitForPending(batcher, count: 1)
        // A successor token remains a distinct queued input; it cannot merge
        // with the predecessor even after the actual slot becomes available.
        let replacement = Task { try await batcher.state(.init(token: try token(roomB, epoch: 2), actorUserID: actor,
            batchDeadline: pendingDeadline, callDeadline: .now.advanced(by: .seconds(2)))) }
        try await waitForPending(batcher, count: 2)
        let third = Task { try await batcher.state(.init(token: try token(roomC), actorUserID: actor,
            batchDeadline: pendingDeadline, callDeadline: .now.advanced(by: .seconds(2)))) }
        try await waitForPending(batcher, count: 3)
        let held = await batcher.collectorSnapshot()
        #expect(held.retainedItems == 4 && held.ordinaryRetainedItems == 4 && held.actualBatches == 1)
        // Six total inputs reserve a complete two-item trusted cohort; ordinary
        // already owns four (including the executing input), so this is full.
        await #expect(throws: V2HostRoomRecoveryBatchError.busy) {
            _ = try await batcher.state(.init(token: token(roomD), actorUserID: actor,
                batchDeadline: pendingDeadline, callDeadline: .now.advanced(by: .seconds(2))))
        }
        await release.signal()
        _ = try? await first.value
        _ = try? await queued.value
        _ = try? await third.value
        _ = try? await replacement.value
        let executions = actualTokens.withLock { $0 }
        #expect(executions.count == 3)
        #expect(executions[1] == [try token(roomB)])
        #expect(Set(executions[2]) == Set([try token(roomB, epoch: 2), try token(roomC)]))

        let byteOccupied = ActorQueryGate(), byteRelease = ActorQueryGate()
        // The envelope budget follows retained memory accounting. One input
        // fits, while two inputs must execute as separate byte groups.
        let byteOwner = try V2RoomDataOwner(shardID: String(repeating: "b", count: 300), epoch: 0)
        func byteToken() -> V2RoomActivationToken {
            .init(roomID: .init(uuid: UUID()), owner: byteOwner, activationEpoch: try! .init(1), host: host)
        }
        let sample = byteToken(), byteTokens = Mutex<[[V2RoomActivationToken]]>([])
        let byteLimit = V2ActorPayloadBudget.retainedBytes(of: sample)
            + V2ActorPayloadBudget.retainedBytes(of: actor) + 96
        let byteBatcher = V2HostRoomRecoveryQueryBatcher(configuration: try .init(maximumItems: 3,
            maximumBytes: byteLimit, maximumPendingItems: 6,
            maximumInFlightBatches: 1)) { _, tokens in
            byteTokens.withLock { $0.append(tokens) }
            await byteOccupied.signal()
            await byteRelease.wait()
            throw CancellationError()
        }
        defer { Task { await byteRelease.signal() } }
        let byteFirst = Task { try await byteBatcher.state(.init(token: sample, actorUserID: actor,
            batchDeadline: .now, callDeadline: .now.advanced(by: .seconds(2)))) }
        await byteOccupied.wait()
        let byteQueued = Task { try await byteBatcher.state(.init(token: byteToken(), actorUserID: actor,
            batchDeadline: .now.advanced(by: .seconds(1)), callDeadline: .now.advanced(by: .seconds(2)))) }
        try await waitForPending(byteBatcher, count: 1)
        let byteThird = Task { try await byteBatcher.state(.init(token: byteToken(), actorUserID: actor,
            batchDeadline: .now.advanced(by: .seconds(1)), callDeadline: .now.advanced(by: .seconds(2)))) }
        try await waitForPending(byteBatcher, count: 2)
        await #expect(throws: V2HostRoomRecoveryBatchError.busy) {
            _ = try await byteBatcher.state(.init(token: byteToken(), actorUserID: actor,
                batchDeadline: .now.advanced(by: .seconds(1)), callDeadline: .now.advanced(by: .seconds(2))))
        }
        let oversized = V2RoomActivationToken(roomID: .init(uuid: UUID()),
            owner: try .init(shardID: String(repeating: "x", count: 2048), epoch: 0),
            activationEpoch: try .init(1), host: host)
        await #expect(throws: V2HostRoomRecoveryBatchError.oversized) {
            _ = try await byteBatcher.state(.init(token: oversized, actorUserID: actor,
                batchDeadline: .now, callDeadline: .now.advanced(by: .seconds(2))))
        }
        await byteRelease.signal()
        _ = try? await byteFirst.value
        _ = try? await byteQueued.value
        _ = try? await byteThird.value
        #expect(byteTokens.withLock { $0.count == 3 && $0.allSatisfy { $0.count == 1 } })

        let timedOccupied = ActorQueryGate(), timedRelease = ActorQueryGate()
        let timedBatcher = V2HostRoomRecoveryQueryBatcher(configuration: try .init(maximumItems: 1,
            maximumPendingItems: 3, maximumInFlightBatches: 1)) { _, _ in
            await timedOccupied.signal()
            await timedRelease.wait()
            throw CancellationError()
        }
        defer { Task { await timedRelease.signal() } }
        let timedFirst = Task { try await timedBatcher.state(.init(token: try token(UUID()), actorUserID: actor,
            batchDeadline: .now, callDeadline: .now.advanced(by: .seconds(2)))) }
        await timedOccupied.wait()
        let started = ContinuousClock.now
        await #expect(throws: V2HostRoomRecoveryBatchError.deadlineExceeded) {
            _ = try await timedBatcher.state(.init(token: token(UUID()), actorUserID: actor,
                batchDeadline: .now.advanced(by: .milliseconds(-1)),
                callDeadline: started.advanced(by: .milliseconds(120))))
        }
        #expect(ContinuousClock.now - started < .seconds(1))
        await timedRelease.signal()
        _ = try? await timedFirst.value
    }
}

private struct ActorQueryCountRow: Decodable { let value: Int64 }

private func waitForPending(_ batcher: V2HostRoomRecoveryQueryBatcher, count: Int) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while await batcher.pendingCount != count {
        guard ContinuousClock.now < deadline else { throw V2HostRoomRecoveryBatchError.deadlineExceeded }
        await Task.yield()
    }
}

private actor ActorQueryGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        open = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private func seedRoom(sql: any SQLDatabase, room: UUID, actor: UUID, sequence: Int64) async throws {
    try await sql.raw("""
        INSERT INTO im_v2.rooms(room_id, room_shard_id, capacity_profile_id, membership_revision, room_sequence)
        VALUES (\(bind: room), 'owner-a', 'standard', 1, \(bind: sequence))
        """).run()
    try await sql.raw("""
        INSERT INTO im_v2.room_memberships(room_id, user_id, joined_revision)
        VALUES (\(bind: room), \(bind: actor), 1)
        """).run()
    try await sql.raw("""
        INSERT INTO im_v2.public_user_profiles(user_id, public_handle, display_name, created_at, updated_at)
        VALUES (\(bind: actor), \(bind: "actor_" + actor.uuidString.prefix(8).lowercased()), 'Actor', now(), now())
        ON CONFLICT (user_id) DO NOTHING
        """).run()
}

private func withActorQueryDatabase(
    _ operation: (any Database, any SQLDatabase) async throws -> Void
) async throws {
    guard let url = ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_URL"],
          ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1" else { return }
    let resources = makeV2DatabaseTestResources()
    resources.databases.use(try .postgres(url: url, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
    let database = resources.database(.psql)
    let sql = try #require(database as? any SQLDatabase)
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(contentsOf: root.appending(path: "IMV2/sql/schema.sql"), encoding: .utf8)
    do {
        let executable = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }.joined(separator: "\n")
        for statement in postgresStatements(in: executable) where !statement.isEmpty && statement != "BEGIN" && statement != "COMMIT" {
            try await sql.raw("\(unsafeRaw: statement)").run()
        }
        try await operation(database, sql)
        try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
        try await resources.shutdown()
    } catch {
        try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
        try? await resources.shutdown()
        throw error
    }
}
