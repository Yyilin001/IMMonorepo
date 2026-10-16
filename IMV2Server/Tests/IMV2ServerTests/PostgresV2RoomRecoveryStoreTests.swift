@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

@Suite("Identity-indexed room recovery", .serialized)
struct PostgresV2RoomRecoveryStoreTests {
    @Test("initial membership revision zero remains visible in the server directory",
        .enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func zeroMembershipDirectory() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).rooms(room_id,room_shard_id,capacity_profile_id,membership_revision)
                VALUES (\(bind: room.uuidValue!), 'room-a', 'standard', 0)
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).room_memberships(room_id,user_id,joined_revision)
                VALUES (\(bind: room.uuidValue!), \(bind: user.uuidValue!), 0)
                """).run()
            let store = try PostgresV2RoomRecoveryStore(database: database, schema: schema)
            let page = try await store.rooms(actorUserID: user, after: nil, limit: 100)
            #expect(page.entries.map(\.roomID) == [room])
            #expect(page.entries.first?.viewerMembershipRevision == 0)
            #expect(!page.hasMore)
        }
    }
    @Test("one owner state SQL isolates different viewers and a stale room token")
    func multiViewerOwnerBatch() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let room = RoomID(uuid: UUID()), staleRoom = RoomID(uuid: UUID())
            let viewerA = UserID(uuid: UUID()), viewerB = UserID(uuid: UUID()), outsider = UserID(uuid: UUID())
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).rooms(room_id,room_shard_id,capacity_profile_id,membership_revision,room_sequence)
                VALUES (\(bind: room.uuidValue!),'room-a','standard',1,4),
                       (\(bind: staleRoom.uuidValue!),'room-a','standard',1,0)
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).room_memberships(room_id,user_id,joined_revision)
                VALUES (\(bind: room.uuidValue!),\(bind: viewerA.uuidValue!),1),
                       (\(bind: room.uuidValue!),\(bind: viewerB.uuidValue!),1),
                       (\(bind: staleRoom.uuidValue!),\(bind: viewerA.uuidValue!),1)
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).room_read_receipts(room_id,user_id,read_through_room_sequence,updated_at)
                VALUES (\(bind: room.uuidValue!),\(bind: viewerA.uuidValue!),1,clock_timestamp()),
                       (\(bind: room.uuidValue!),\(bind: viewerB.uuidValue!),2,clock_timestamp())
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).messages(message_id,room_id,room_sequence,sender_user_id,client_message_id,text_body,created_at,timeline_sequence)
                VALUES (\(bind: UUID()),\(bind: room.uuidValue!),1,\(bind: viewerA.uuidValue!),\(bind: UUID()),'A1',clock_timestamp(),1),
                       (\(bind: UUID()),\(bind: room.uuidValue!),2,\(bind: viewerB.uuidValue!),\(bind: UUID()),'B1',clock_timestamp(),2),
                       (\(bind: UUID()),\(bind: room.uuidValue!),3,\(bind: viewerA.uuidValue!),\(bind: UUID()),'A2',clock_timestamp(),3)
                """).run()
            try await withRoomActivations(database: database, roomIDs: [room, staleRoom]) { tokens in
                let live = try #require(tokens.first { $0.roomID == room })
                let old = try #require(tokens.first { $0.roomID == staleRoom })
                try await sql.raw("UPDATE \(unsafeRaw: schema).rooms SET owner_epoch=1 WHERE room_id=\(bind: staleRoom.uuidValue!)").run()
                let observed = try V2EventLoopBalancedDatabase(databases: [database], loanPolicy: .init(
                    maximumConnections: 4, reservedRenewalConnections: 1, maximumQueued: 4, maximumWait: .seconds(5)))
                let deadline = ContinuousClock.now + .seconds(5)
                let turns = [(live, viewerA), (live, viewerB), (live, outsider), (old, viewerA)].map {
                    V2GrantedRoomReadTurn(token: $0.0, actorUserID: $0.1, batchDeadline: deadline, callDeadline: deadline)
                }
                let executor = V2ActorRoomQueryExecutor(database: observed)
                let batcher = V2HostRoomRecoveryQueryBatcher(configuration: try .init(),
                    executeStates: { try await executor.recoveryStates($0, schema: schema) },
                    execute: { _, _ in throw V2HostRoomRecoveryBatchError.corruptResult })
                let result = try await batcher.states(turns)
                await observed.shutdownLoans()
                let a = try #require(result[.init(roomID: room, viewerUserID: viewerA)]).get()
                let b = try #require(result[.init(roomID: room, viewerUserID: viewerB)]).get()
                guard case .state(let stateA) = a, case .state(let stateB) = b else {
                    Issue.record("authorized viewers missing"); return
                }
                #expect(stateA.head == 4 && stateB.head == 4)
                #expect(stateA.readThrough == 1 && stateA.latestOwnMessageSequence == 3)
                #expect(stateB.readThrough == 2 && stateB.latestOwnMessageSequence == 2)
                #expect(try result[.init(roomID: room, viewerUserID: outsider)]?.get() == .unavailable)
                if case .failure(let error)? = result[.init(roomID: staleRoom, viewerUserID: viewerA)] {
                    #expect(error as? V2RoomActorStateError == .ownerChanged)
                } else { Issue.record("stale token must retain its precise data owner failure") }
                let sample = observed.loanMetricsSnapshot().observations[.roomRecovery]!
                #expect(sample.sqlPhases[.readBody]!.count == 1)
                // Timeout setup and one setwise durable-owner validation.
                #expect(sample.sqlPhases[.fence]!.count == 2)
                #expect(sample.sqlPhases[.transactionControl]!.count == 2)
            }
        }
    }

    @Test("snapshot data-owner share fences coexist and hold ownership until the actual read settles")
    func snapshotReadFenceLocks() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let room = RoomID(uuid: UUID())
            try await sql.raw("INSERT INTO \(unsafeRaw: schema).rooms(room_id,room_shard_id,capacity_profile_id) VALUES (\(bind: room.uuidValue!), 'snapshot-owner','standard')").run()
            try await withRoomActivation(database: database, roomID: room, shardID: "snapshot-owner") { token in
                let end = ContinuousClock.now + .seconds(5)
                let gate = SnapshotReadGate()
                let reader = Task {
                    try await V2RoomSQLDeadline.withDeadline(end) {
                        try await v2WithRoomScopedTransaction(database: database) { transaction in
                            let connection = try #require(transaction as? any SQLDatabase)
                            let pid = try #require(try await connection.raw("SELECT pg_backend_pid()::bigint AS value").first(decoding: SnapshotCount.self))
                            let result = try await v2RoomSnapshotReadActivationFences(tokens: [token], sql: connection, schema: schema)
                            try #require(result[room]).get()
                            await gate.hold(pid.value)
                        }
                    }
                }
                var writer: Task<Void, any Error>?
                do {
                    let pid = try await gate.waitForHolder(end)
                    try await V2RoomSQLDeadline.withDeadline(end) {
                        try await v2WithRoomScopedTransaction(database: database) { transaction in
                            let connection = try #require(transaction as? any SQLDatabase)
                            let result = try await v2RoomSnapshotReadActivationFences(tokens: [token], sql: connection, schema: schema)
                            try #require(result[room]).get()
                        }
                    }
                    writer = Task {
                        try await V2RoomSQLDeadline.withDeadline(end) {
                            try await v2WithRoomScopedTransaction(database: database) { transaction in
                                let connection = try #require(transaction as? any SQLDatabase)
                                try await connection.raw("UPDATE \(unsafeRaw: schema).rooms SET owner_epoch=owner_epoch+1 WHERE room_id=\(bind: room.uuidValue!)").run()
                            }
                        }
                    }
                    var blocked = false
                    while ContinuousClock.now < end {
                        let count = try #require(try await sql.raw("SELECT count(*)::bigint AS value FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND \(bind: pid)::int=ANY(pg_blocking_pids(pid))").first(decoding: SnapshotCount.self))
                        if count.value > 0 { blocked = true; break }
                        await Task.yield()
                    }
                    try #require(blocked, "data-owner mutation must wait for the actual snapshot transaction")
                    await gate.open()
                    try await reader.value
                    try await writer!.value
                    try await v2WithRoomScopedTransaction(database: database) { transaction in
                        let connection = try #require(transaction as? any SQLDatabase)
                        let result = try await v2RoomSnapshotReadActivationFences(tokens: [token], sql: connection, schema: schema)
                        if case .failure(let error)? = result[room] {
                            #expect(error as? V2RoomActorStateError == .ownerChanged)
                        } else { Issue.record("old data owner must fail after the committed mutation") }
                    }
                } catch {
                    await gate.open()
                    _ = await reader.result
                    _ = await writer?.result
                    throw error
                }
            }
        }
    }

    @Test("parameterized membership lookup must not hide duplicate active revisions")
    func duplicateActiveMembership() async throws {
        try await withUserEventDatabase { database, sql, schema in
            let user = UUID(), room = UUID()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).rooms(room_id,room_shard_id,capacity_profile_id,membership_revision)
                VALUES (\(bind: room),'room-a','standard',2)
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).room_memberships(room_id,user_id,joined_revision)
                VALUES (\(bind: room),\(bind: user),1),(\(bind: room),\(bind: user),2)
                """).run()
            let store = try PostgresV2RoomRecoveryStore(database: database, schema: schema)
            await #expect(throws: V2RoomRecoveryReadError.corruptPersistence) {
                try await store.states(roomIDs: [.init(uuid: room)], actorUserID: .init(uuid: user))
            }
        }
    }

    @Test("large identity directories recover every room while activity changes", arguments: [1000, 10000])
    func largeDirectory(count: Int) async throws {
        try await withUserEventDatabase { db, sql, schema in
            let user = UUID(), actor = UserID(uuid: user)
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).rooms
                    (room_id, room_shard_id, capacity_profile_id, membership_revision)
                SELECT ('00000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid,
                       'room-a', 'standard', 1
                FROM generate_series(1, \(bind: count)) AS n
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).room_memberships(room_id, user_id, joined_revision)
                SELECT room_id, \(bind: user), 1 FROM \(unsafeRaw: schema).rooms
                """).run()
            try await sql.raw("ANALYZE \(unsafeRaw: schema).room_memberships").run()
            try await sql.raw("ANALYZE \(unsafeRaw: schema).rooms").run()
            let store = try PostgresV2RoomRecoveryStore(database: db, schema: schema)
            var after: RoomID?, seen: Set<RoomID> = []
            var pages = 0, stateBatches = 0
            let start = ContinuousClock.now
            while true {
                let page = try await store.rooms(actorUserID: actor, after: after, limit: 100)
                pages += 1
                #expect(page.entries.count <= 100)
                #expect(pages <= count / 100)
                guard pages <= count / 100 else { throw V2RoomRecoveryReadError.corruptPersistence }
                let ids = page.entries.map(\.roomID)
                #expect(ids.count == 100)
                #expect(Set(ids).isDisjoint(with: seen))
                seen.formUnion(ids)
                let states = try await store.states(roomIDs: ids, actorUserID: actor)
                stateBatches += 1
                #expect(states.count == ids.count)
                for id in ids {
                    guard case .state(let state)? = states[id] else {
                        Issue.record("authorized room missing from state batch")
                        continue
                    }
                    #expect(state.head == 0 && state.viewerMembershipRevision == 1)
                }
                if pages == 1 {
                    // Ranking changes both before and after the scan cursor.
                    // Identity pagination must neither repeat nor omit rooms.
                    try await sql.raw("""
                        UPDATE \(unsafeRaw: schema).rooms
                        SET last_event_at = TIMESTAMPTZ '2026-01-01' + random() * INTERVAL '1 day'
                        """).run()
                }
                if !page.hasMore { break }
                let next = try #require(page.scannedThrough)
                #expect(next != after)
                after = next
            }
            #expect(seen.count == count)
            #expect(pages == count / 100 && stateBatches == pages)
            print("ROOM_RECOVERY_DATABASE_SCALE rooms=\(count) directoryPages=\(pages) stateBatches=\(stateBatches) elapsed=\(start.duration(to: .now))")
        }
    }

    @Test("directory order ignores activity and advances across invisible candidates")
    func directoryPages() async throws {
        try await withUserEventDatabase { db, sql, schema in
            let user = UUID()
            let rooms = (1...3).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))! }
            for (index, room) in rooms.enumerated() {
                try await sql.raw("""
                    INSERT INTO \(unsafeRaw: schema).rooms
                        (room_id, room_shard_id, capacity_profile_id, membership_revision, last_event_at)
                    VALUES (\(bind: room), 'room-a', 'standard', 1, \(bind: Date(timeIntervalSince1970: Double(100 - index))))
                    """).run()
                // A candidate ahead of the room's committed revision must not become authorized.
                try await sql.raw("""
                    INSERT INTO \(unsafeRaw: schema).room_memberships(room_id, user_id, joined_revision)
                    VALUES (\(bind: room), \(bind: user), \(bind: index == 1 ? 2 : 1))
                    """).run()
            }
            let store = try PostgresV2RoomRecoveryStore(database: db, schema: schema)
            let first = try await store.rooms(actorUserID: .init(uuid: user), after: nil, limit: 1)
            #expect(first.entries.map(\.roomID) == [.init(uuid: rooms[0])])
            #expect(first.hasMore)
            let second = try await store.rooms(actorUserID: .init(uuid: user), after: first.scannedThrough, limit: 1)
            #expect(second.entries.isEmpty)
            #expect(second.scannedThrough == .init(uuid: rooms[1]))
            #expect(second.hasMore)
            let third = try await store.rooms(actorUserID: .init(uuid: user), after: second.scannedThrough, limit: 1)
            #expect(third.entries.map(\.roomID) == [.init(uuid: rooms[2])])
            #expect(!third.hasMore)
            let stranger = try await store.rooms(actorUserID: .init(uuid: UUID()), after: nil, limit: 100)
            #expect(stranger.entries.isEmpty && !stranger.hasMore)
        }
    }

    @Test("state batches distinguish unavailable from authorized zero and reject invalid bounds")
    func stateAuthorization() async throws {
        try await withUserEventDatabase { db, sql, schema in
            let user = UUID(), room = UUID(), missing = RoomID(uuid: UUID())
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).rooms(room_id, room_shard_id, capacity_profile_id, membership_revision)
                VALUES (\(bind: room), 'room-a', 'standard', 1)
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).room_memberships(room_id, user_id, joined_revision)
                VALUES (\(bind: room), \(bind: user), 1)
                """).run()
            let id = RoomID(uuid: room), actor = UserID(uuid: user)
            let store = try PostgresV2RoomRecoveryStore(database: db, schema: schema)
            let result = try await store.states(roomIDs: [id, missing, id], actorUserID: actor)
            #expect(result.count == 2)
            #expect(result[missing] == .unavailable)
            let expected = try V2RoomSynchronizationState(roomID: id, ownerEpoch: 0, viewerMembershipRevision: 1,
                head: 0, trimmedThrough: 0, readThrough: 0, latestOwnMessageSequence: 0)
            #expect(result[id] == .state(expected))
            try await sql.raw("UPDATE \(unsafeRaw: schema).room_memberships SET left_revision = 2 WHERE room_id = \(bind: room)").run()
            #expect(try await store.states(roomIDs: [id], actorUserID: actor)[id] == .unavailable)
            await #expect(throws: V2RoomRecoveryReadError.invalidRequest) {
                try await store.states(roomIDs: [], actorUserID: actor)
            }
            await #expect(throws: V2RoomRecoveryReadError.invalidRequest) {
                try await store.rooms(actorUserID: actor, after: nil, limit: 101)
            }
        }
    }
}

private struct SnapshotCount: Decodable { let value: Int64 }
private actor SnapshotReadGate {
    private var pid: Int64?
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?
    func hold(_ value: Int64) async {
        pid = value
        if !opened { await withCheckedContinuation { waiter = $0 } }
    }
    func waitForHolder(_ deadline: ContinuousClock.Instant) async throws -> Int64 {
        while pid == nil {
            guard ContinuousClock.now < deadline else { throw V2RoomRecoveryReadError.corruptPersistence }
            await Task.yield()
        }
        return pid!
    }
    func open() { opened = true; waiter?.resume(); waiter = nil }
}


extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("pure pull validates the actual member and activation while coexisting with another snapshot")
    func purePullSnapshotPreservesAuthority() async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let room = RoomID(uuid: UUID()), viewer = UserID(uuid: UUID())
            try await sql.raw("INSERT INTO im_v2.rooms(room_id,room_shard_id,capacity_profile_id,membership_revision) VALUES (\(bind: room.uuidValue!), 'room-a','standard',1)").run()
            try await sql.raw("INSERT INTO im_v2.room_memberships(room_id,user_id,joined_revision) VALUES (\(bind: room.uuidValue!),\(bind: viewer.uuidValue!),1)").run()
            try await withRoomActivation(database: database, roomID: room) { token in
                let executor = V2ActorRoomQueryExecutor(database: database)
                let request = try V2ActorRoomLogPullWire(roomID: room, actorUserID: viewer, afterRoomSequence: 0, pageSize: 100)
                let deadline = ContinuousClock.now + .seconds(5)
                let gate = SnapshotReadGate()
                let holder = Task {
                    try await V2RoomSQLDeadline.withDeadline(deadline) {
                        try await v2WithRoomScopedTransaction(database: database) { transaction in
                            let connection = try #require(transaction as? any SQLDatabase)
                            let pid = try #require(try await connection.raw("SELECT pg_backend_pid()::bigint AS value").first(decoding: SnapshotCount.self))
                            let fenced = try await v2RoomSnapshotReadActivationFences(tokens: [token], sql: connection)
                            try #require(fenced[room]).get()
                            await gate.hold(pid.value)
                        }
                    }
                }
                do {
                    _ = try await gate.waitForHolder(deadline)
                    let result = try await V2RoomSQLDeadline.withDeadline(deadline) {
                        try await executor.pullSnapshot(request, token: token)
                    }
                    guard case .page = result else { throw V2RoomRecoveryReadError.corruptPersistence }
                    let unauthorized = try V2ActorRoomLogPullWire(roomID: room, actorUserID: .init(uuid: UUID()), afterRoomSequence: 0, pageSize: 100)
                    await #expect(throws: V2GroupEventLogError.actorNotMember) {
                        _ = try await executor.pullSnapshot(unauthorized, token: token)
                    }
                    await gate.open(); try await holder.value
                    try await sql.raw("UPDATE im_v2.rooms SET owner_epoch=owner_epoch+1 WHERE room_id=\(bind: room.uuidValue!)").run()
                    await #expect(throws: V2RoomActorStateError.ownerChanged) {
                        _ = try await executor.pullSnapshot(request, token: token)
                    }
                } catch {
                    await gate.open(); _ = try? await holder.value; throw error
                }
            }
        }
    }
}

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("setwise pull preserves each viewer/cursor and splits legal complete pages inside one actual loan", arguments: [false, true])
    func purePullCollectionPreservesPagesAndBudget(overflow: Bool) async throws {
        try await withForwardOwnerDatabases(mode: .standard) { database, _, sql, _, _ in
            let base = Date(timeIntervalSince1970: 1_750_000_000)
            let writer = V2SendMessageService(store: V2PolicyAuthorizedTestWriteStore(
                database: database, controlDatabase: database,
                store: PostgresV2RoomWriteStore(database: database), shardID: "room-a", epoch: 0),
                capacityProfile: try forwardImportTestProfile(), limits: try .init(maxUTF8Bytes: 60_000), now: { base })
            for index in 0..<4 {
                let text = overflow ? String(repeating: "x", count: 59_999) + String(index) : "page-\(index)"
                guard case .accepted = try await writer.send(.init(roomID: roomID, actorUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: text)) else {
                    Issue.record("expected actual accepted message"); return
                }
            }
            let staleRoom = RoomID(uuid: UUID())
            try await sql.raw("INSERT INTO im_v2.rooms(room_id,room_shard_id,capacity_profile_id) VALUES (\(bind: staleRoom.uuidValue!),'room-a','standard')").run()
            try await withRoomActivations(database: database, roomIDs: [roomID, staleRoom]) { tokens in
                let live = try #require(tokens.first { $0.roomID == roomID })
                let old = try #require(tokens.first { $0.roomID == staleRoom })
                try await sql.raw("UPDATE im_v2.rooms SET owner_epoch=1 WHERE room_id=\(bind: staleRoom.uuidValue!)").run()
                let observed = try V2EventLoopBalancedDatabase(databases: [database], loanPolicy: .init(
                    maximumConnections: 4, reservedRenewalConnections: 1, maximumQueued: 4, maximumWait: .seconds(5)))
                let executor = V2ActorRoomQueryExecutor(database: observed)
                let deadline = ContinuousClock.now + .seconds(10)
                var requests: [V2GrantedRoomLogPull] = try (0..<4).map { index in
                    try .init(token: live, query: .init(roomID: roomID,
                        actorUserID: index.isMultiple(of: 2) ? senderID : .init(uuid: memberTwoUUID),
                        afterRoomSequence: UInt64(index), pageSize: 1), callDeadline: deadline)
                }
                let denied = try V2GrantedRoomLogPull(token: live,
                    query: .init(roomID: roomID, actorUserID: .init(uuid: UUID()), afterRoomSequence: 0, pageSize: 1), callDeadline: deadline)
                let stale = try V2GrantedRoomLogPull(token: old,
                    query: .init(roomID: staleRoom, actorUserID: senderID, afterRoomSequence: 0, pageSize: 1), callDeadline: deadline)
                requests += [denied, stale]
                let replies = PullCollectionReplies()
                do {
                    let responseBudget = overflow ? 128 * 1024 : 256 * 1024
                    try await executor.pullSnapshots(requests, maximumResponseBytes: responseBudget) { id, result in
                        await replies.record(id, result)
                    }
                    let values = await replies.snapshot()
                    #expect(values.count == requests.count)
                    var encodedWholePages = 0
                    for (index, request) in requests.prefix(4).enumerated() {
                        let result = try #require(values[request.id]).get()
                        guard case .page(let page) = result else { Issue.record("expected complete authorized page"); continue }
                        #expect(page.events.count == 1)
                        #expect(page.events.first?.roomSequence == UInt64(index + 1))
                        #expect(page.nextRoomSequence == UInt64(index + 1))
                        #expect(page.hasMore == (index < 3))
                        // Compare against the unchanged scalar authority/template,
                        // rather than expecting synthetic payloads from the batch.
                        let original = try await PostgresV2GroupEventLogStore(database: database).pull(
                            roomID: roomID, actorUserID: request.query.actorUserID,
                            afterRoomSequence: UInt64(index), pageSize: 1)
                        let originalWire = try V2ActorRoomLogPageWire(original)
                        #expect(page == originalWire)
                        encodedWholePages += try page.protobufResponseByteCount() + 64
                    }
                    #expect(try values[denied.id]?.get() == .failure(.actorNotMember))
                    if case .failure(let failure)? = values[stale.id] {
                        #expect(failure as? V2RoomActorStateError == .ownerChanged)
                    } else { Issue.record("stale sibling must fail without rejecting healthy viewers") }
                    let first = try #require(observed.loanMetricsSnapshot().observations[.groupEventPull])
                    // Each subgroup scans once; no row-lock fence or explicit
                    // transaction. Overflow keeps complete pages in two subgroups.
                    #expect(first.sqlPhases[.readBody]?.count == (overflow ? 2 : 1))
                    #expect((first.sqlPhases[.fence]?.count ?? 0) == 0)
                    #expect((first.sqlPhases[.transactionControl]?.count ?? 0) == 0)
                    #expect(first.actualHeldCount == 1)
                    if overflow {
                        #expect(encodedWholePages > responseBudget)
                        let singleton = try V2GrantedRoomLogPull(token: live,
                            query: .init(roomID: roomID, actorUserID: senderID, afterRoomSequence: 0, pageSize: 4),
                            callDeadline: deadline)
                        let large = PullCollectionReplies()
                        try await executor.pullSnapshots([singleton], maximumResponseBytes: responseBudget) { id, result in
                            await large.record(id, result)
                        }
                        let singleResults = await large.snapshot()
                        let result = try #require(singleResults[singleton.id]).get()
                        guard case .page(let page) = result else { throw V2RoomRecoveryReadError.corruptPersistence }
                        #expect(page.events.count == 4 && page.nextRoomSequence == 4 && !page.hasMore)
                        let bytes = try page.protobufResponseByteCount()
                        #expect(bytes > responseBudget && bytes < 8 * 1024 * 1024)
                        // The conservative internal bound must not reject this
                        // legal native page or manufacture a smaller partial page.
                        let after = try #require(observed.loanMetricsSnapshot().observations[.groupEventPull])
                        #expect(after.sqlPhases[.readBody]?.count == first.sqlPhases[.readBody]!.count + 2)
                        #expect(after.actualHeldCount == 2)
                    }
                    await observed.shutdownLoans()
                } catch {
                    await observed.shutdownLoans(); throw error
                }
            }
        }
    }
}

private actor PullCollectionReplies {
    private var values: [UUID: Result<V2RoomLogQueryResult, any Error>] = [:]
    func record(_ id: UUID, _ value: Result<V2RoomLogQueryResult, any Error>) { values[id] = value }
    func snapshot() -> [UUID: Result<V2RoomLogQueryResult, any Error>] { values }
}
