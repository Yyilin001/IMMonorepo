@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil))
struct V2RoomProfileCohortPostgresTests {
    @Test("profile reads observe one committed room cut without waiting for an uncommitted writer",
          arguments: [false, true])
    func committedSnapshotDuringWrite(ownerChanges: Bool) async throws {
        try await withRoom { database, _, token, lifetime, requests in
            let executor = try V2RoomMediaAuthorizationDomainExecutor(database: database, token: token, lifetime: lifetime)
            let gate = CohortWriteGate(), room = try #require(token.roomID.uuidValue)
            let viewer = try #require(requests[0].actorUserID.uuidValue)
            let writer = Task {
                try await database.transaction { transaction in
                    let sql = try #require(transaction as? any SQLDatabase)
                    try await sql.raw("UPDATE im_v2.rooms SET membership_revision=4 WHERE room_id=\(bind: room)").run()
                    try await sql.raw("UPDATE im_v2.room_memberships SET left_revision=4 WHERE room_id=\(bind: room) AND user_id=\(bind: viewer)").run()
                    if ownerChanges {
                        try await sql.raw("UPDATE im_v2.rooms SET owner_epoch=owner_epoch+1 WHERE room_id=\(bind: room)").run()
                    }
                    await gate.hold()
                }
            }
            do {
                let waitingUntil = ContinuousClock.now + .seconds(2)
                while !(await gate.entered) {
                    guard .now < waitingUntil else { throw CohortFailure.waitExpired }
                    try await Task.sleep(for: .milliseconds(1))
                }
                let before = try await V2RoomSQLDeadline.withDeadline(.now + .milliseconds(200)) {
                    try await executor.executeProfileVisibilityBatch([requests[0]])
                }
                guard case .profilesVisible(let snapshot) = try #require(before.first) else { throw CohortFailure.unexpectedResult }
                #expect(snapshot.membershipRevision == 3 && snapshot.activation == token)
                #expect(snapshot.visibleTargetUserIDs == [requests[0].targetUserIDs[0]])
                #expect(snapshot.groupMembers.first?.groupNickname == "Cohort nickname")
                await gate.open(); try await writer.value
                if ownerChanges {
                    await #expect(throws: V2RoomActorStateError.ownerChanged) {
                        _ = try await executor.executeProfileVisibilityBatch([requests[0]])
                    }
                } else {
                    let after = try await executor.executeProfileVisibilityBatch([requests[0]])
                    guard case .profilesVisible(let snapshot) = try #require(after.first) else { throw CohortFailure.unexpectedResult }
                    #expect(snapshot.membershipRevision == 4)
                    #expect(snapshot.visibleTargetUserIDs.isEmpty && snapshot.groupMembers.isEmpty)
                }
            } catch { await gate.open(); _ = await writer.result; throw error }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_PROFILE_ROOM_BENCHMARK"] == "1"))
    func profileCohortReadCosts() async throws {
        try await withRoom { database, _, token, lifetime, fixture in
            // Match the 100 single-target envelopes in the cold fanout, while
            // retaining independently allowed and denied viewer/target pairs.
            let requests = fixture.flatMap { request in
                request.targetUserIDs.map { target in
                    V2ActorProfileVisibilityBatchWire(roomID: request.roomID, actorUserID: request.actorUserID,
                        roomKind: request.roomKind, targetUserIDs: [target])
                }
            }
            let executor = try V2RoomMediaAuthorizationDomainExecutor(database: database, token: token, lifetime: lifetime)
            let port = V2ActorRoomMediaAuthorizationPort { query, deadline in
                try await V2RoomSQLDeadline.withDeadline(deadline) { try await executor.execute(query) }
            }
            let cohort = V2ActorProfileVisibilityCohortWire(roomID: token.roomID, requests: requests)
            let snapshots = try await port.captureProfiles(cohort, deadline: .now + .seconds(1))
            #expect(snapshots.map(\.request) == requests)
            #expect(snapshots.count == 100)
            #expect(snapshots.filter { !$0.visibleTargetUserIDs.isEmpty }.count == 46)

            @Sendable func measure(_ name: String, _ body: @Sendable () async throws -> Int) async throws {
                for _ in 0..<10 { _ = try await body() }
                var samples: [Double] = [], checksum = 0
                for _ in 0..<100 {
                    let started = ContinuousClock.now
                    checksum &+= try await body()
                    let duration = started.duration(to: .now).components
                    samples.append(Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
                }
                samples.sort()
                print("Profile room benchmark: \(name), meanMilliseconds=\(samples.reduce(0, +) / Double(samples.count)), p50Milliseconds=\(samples[49]), p95Milliseconds=\(samples[94]), maxMilliseconds=\(samples[99]), checksum=\(checksum)")
            }
            try await measure("database adapter") {
                try await V2RoomSQLDeadline.withDeadline(.now + .seconds(1)) {
                    try await executor.executeProfileVisibilityBatch(requests).count
                }
            }
            try await measure("database adapter and validating port") {
                try await port.captureProfiles(cohort, deadline: .now + .seconds(1)).count
            }
            try await measure("snapshot JSON size guard") { try JSONEncoder().encode(snapshots).count }
            let results = snapshots.map(V2RoomMediaAuthorizationResult.profilesVisible)
            try await measure("result JSON size guard") { try JSONEncoder().encode(results).count }
            let response = V2RoomResponse.mediaAuthorization(.profilesVisibleCohort(snapshots))
            try await measure("fixed Protobuf reply size guard") { try V2ActorProtobuf.encode(response).count }
        }
    }

    @Test("one room statement isolates 50 viewers, rejects invalid cohorts and fences stale data owners")
    func independentViewers() async throws {
        try await withRoom { database, sql, token, lifetime, requests in
            let observations = V2DatabaseLoanObservationRegistry()
            let loan = observations.make(source: .query, at: .now)
            loan.granted(at: .now); loan.driverEntered()
            defer { loan.finish() }
            let observed = v2ObserveBorrowedDatabase(database, observation: loan)
            let executor = try V2RoomMediaAuthorizationDomainExecutor(database: observed, token: token, lifetime: lifetime)
            let results = try await V2RoomSQLDeadline.withDeadline(.now + .seconds(1)) {
                try await executor.executeProfileVisibilityBatch(requests)
            }
            try verify(results, requests: requests, token: token)
            #expect(observations.snapshot()[.query]?.sqlPhases[.other]?.count == 1)
            #expect(observations.snapshot()[.query]?.sqlPhases[.transactionControl]?.count == 0)
            let port = V2ActorRoomMediaAuthorizationPort { query, deadline in
                try await V2RoomSQLDeadline.withDeadline(deadline) { try await executor.execute(query) }
            }
            let snapshots = try await port.captureProfiles(.init(roomID: token.roomID, requests: requests),
                deadline: .now + .seconds(1))
            try verify(snapshots.map(V2RoomMediaAuthorizationResult.profilesVisible), requests: requests, token: token)
            #expect(Set(snapshots.map(\.activationExpiresAt)).count == 1)
            await #expect(throws: V2RoomCallFailure.notAccepted(.invalidRequest)) {
                _ = try await executor.executeProfileVisibilityBatch(requests + [requests[0]])
            }
            await #expect(throws: V2RoomCallFailure.notAccepted(.invalidRequest)) {
                _ = try await executor.executeProfileVisibilityBatch([])
            }
            let duplicate = V2ActorProfileVisibilityBatchWire(roomID: token.roomID,
                actorUserID: requests[0].actorUserID, roomKind: .group,
                targetUserIDs: [requests[0].targetUserIDs[0], requests[0].targetUserIDs[0]])
            await #expect(throws: V2RoomCallFailure.notAccepted(.invalidRequest)) {
                _ = try await executor.executeProfileVisibilityBatch([duplicate])
            }
            // Re-read current room state, with no authorization reuse from the earlier cohort.
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision=4 WHERE room_id=\(bind: token.roomID.uuidValue!)").run()
            try await sql.raw("UPDATE im_v2.room_memberships SET left_revision=4 WHERE room_id=\(bind: token.roomID.uuidValue!) AND user_id=\(bind: requests[0].actorUserID.uuidValue!)").run()
            let changed = try await executor.executeProfileVisibilityBatch([requests[0], requests[47]])
            guard case .profilesVisible(let departed) = changed[0] else { throw CohortFailure.unexpectedResult }
            #expect(departed.request == requests[0] && departed.activation == token)
            #expect(departed.visibleTargetUserIDs.isEmpty && departed.groupMembers.isEmpty)
            #expect(departed.membershipRevision == 4 && departed.permissionRevision == 1)
            guard case .profilesVisible(let futureMember) = changed[1] else { throw CohortFailure.unexpectedResult }
            #expect(futureMember.membershipRevision == 4 && futureMember.request == requests[47])
            try await sql.raw("UPDATE im_v2.rooms SET owner_epoch=owner_epoch+1 WHERE room_id=\(bind: token.roomID.uuidValue!)").run()
            await #expect(throws: V2RoomActorStateError.ownerChanged) {
                _ = try await executor.executeProfileVisibilityBatch(requests)
            }
        }
    }

    @Test("keyed membership reads preserve incarnation selection and reject overlapping active memberships",
          arguments: ["viewer", "target"])
    func membershipIncarnations(mode: String) async throws {
        try await withRoom { database, sql, token, lifetime, requests in
            let request = requests[0]
            let user = try #require((mode == "viewer" ? request.actorUserID : request.targetUserIDs[0]).uuidValue)
            let room = try #require(token.roomID.uuidValue)
            let executor = try V2RoomMediaAuthorizationDomainExecutor(database: database, token: token, lifetime: lifetime)
            try await sql.raw("UPDATE im_v2.room_memberships SET left_revision=2 WHERE room_id=\(bind: room) AND user_id=\(bind: user)").run()
            try await sql.raw("INSERT INTO im_v2.room_memberships(room_id,user_id,joined_revision) VALUES (\(bind: room),\(bind: user),2)").run()
            let values = try await executor.executeProfileVisibilityBatch([request])
            guard case .profilesVisible(let proof) = try #require(values.first) else { throw CohortFailure.unexpectedResult }
            #expect(proof.visibleTargetUserIDs == [request.targetUserIDs[0]])
            #expect(proof.groupMembers.first?.groupNickname == "Cohort nickname")
            // Three eligible rows must remain corruption, even though the
            // bounded SQL lookup needs only two rows to prove ambiguity.
            try await sql.raw("INSERT INTO im_v2.room_memberships(room_id,user_id,joined_revision) VALUES (\(bind: room),\(bind: user),0),(\(bind: room),\(bind: user),3)").run()
            await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) {
                _ = try await executor.executeProfileVisibilityBatch([request])
            }
        }
    }

    @Test("production lane and factory execute 100 targets with scalar, cohort and mixed envelopes",
          arguments: ["scalar", "cohort", "mixed"])
    func productionComposition(mode: String) async throws {
        try await withRoom { database, _, token, lifetime, requests in
            let writes = PostgresV2RoomWriteStore(database: database)
            let admission = V2DatabaseWorkAdmissionController(policy: .init(
                maximumForegroundWriteInFlight: 1, maximumInteractiveReadInFlight: 1,
                maximumSyncInFlight: 1, maximumForegroundWriteQueued: 2,
                maximumInteractiveReadQueued: 2, maximumSyncQueued: 1, timeout: .seconds(1)))
            let owner = try V2RoomServerOwnerResources(database: database, initializationDatabase: database, sendDatabase: try v2FixtureMessageWriteDatabase(database, capacity: 1), writes: writes, membershipIdentities: V2PostgresMembershipIdentitySnapshotValidator(database: database),
                invitationIdentities: PostgresV2GroupInvitationIdentityReader(database: database),
                invitationSecretIssuer: try .init(rawKey: Data(repeating: 0x73, count: 32)),
                receiptProjectionDelivery: CohortProjectionDelivery(),
                capacityProfile: .init(id: "standard", limits: .init(maxEligibleMembers: 100,
                    maxCommandsPerWindow: 100, retryAfterSeconds: 3)),
                messageLimits: .init(maxUTF8Bytes: 64), maximumEditBytes: 64,
                contentReviewMode: .disabled, queryBatchConfiguration: .init(), databaseWorkAdmission: admission)
            let factory = try V2RoomServerActivationFactory(owners: [token.owner.shardID: owner.usingFixturePolicyAuthorizations(endpoint: token.owner.shardID)], safetyActorUserID: nil)
            let executor = factory.runtimeFactory().make(token)
            let restorationDeadline = ContinuousClock.now + .seconds(10)
            try await executor.restore(.init(token: token, deadline: restorationDeadline,
                                             lifetime: lifetime, check: {
                try await lifetime.withPin(deadline: restorationDeadline) { _ in }
            }))
            let configuration = try V2RoomRuntimeConfiguration()
            let budget = V2RoomCommandBudget(configuration: configuration)
            let lane = V2RoomTurnLane<V2RoomRequest, V2RoomResponse>(token: token,
                configuration: configuration, budget: budget, classify: { $0.turnSchedulingClass },
                execute: executor.execute, onUncertain: { _ in })
            let reservation = try await lane.reserve(requestID: UUID(), deadline: .now + .seconds(10))
            var tasks: [Task<V2RoomResponse, any Error>] = []
            do {
                let commands: [V2RoomRequest]
                switch mode {
                case "scalar": commands = requests.map { .mediaAuthorization(.profileVisibilityBatch($0)) }
                case "cohort": commands = [Array(requests.prefix(25)), Array(requests.dropFirst(25))].map {
                    .mediaAuthorization(.profileVisibilityCohort(.init(roomID: token.roomID, requests: $0)))
                }
                default: commands = [
                    .mediaAuthorization(.profileVisibilityCohort(.init(roomID: token.roomID, requests: Array(requests.prefix(25))))),
                    .mediaAuthorization(.profileVisibilityBatch(requests[25])),
                    .mediaAuthorization(.profileVisibilityCohort(.init(roomID: token.roomID, requests: Array(requests.dropFirst(26)))))
                ]
                }
                for command in commands {
                    tasks.append(Task { try await lane.submit(request: command, deadline: .now + .seconds(10)) })
                    let deadline = ContinuousClock.now + .seconds(3)
                    while await lane.snapshot().queuedCount != tasks.count {
                        guard ContinuousClock.now < deadline else { throw CohortFailure.waitExpired }
                        await Task.yield()
                    }
                }
                #expect(await admission.snapshot().interactiveRead.admittedRequests == 0)
                #expect(await lane.abortReservation(reservation))
                var results: [V2RoomMediaAuthorizationResult] = []
                for (command, task) in zip(commands, tasks) {
                    guard case .mediaAuthorization(let result) = try await task.value else { throw CohortFailure.unexpectedResult }
                    if case .mediaAuthorization(.profileVisibilityCohort(let request)) = command {
                        guard case .profilesVisibleCohort(let snapshots) = result else { throw CohortFailure.unexpectedResult }
                        #expect(snapshots.map(\.request) == request.requests)
                        results.append(contentsOf: snapshots.map(V2RoomMediaAuthorizationResult.profilesVisible))
                    } else { results.append(result) }
                }
                try verify(results, requests: requests, token: token)
                let snapshot = await admission.snapshot()
                #expect(snapshot.interactiveRead.admittedRequests == 1)
                #expect(snapshot.interactiveRead.inFlight == 0)
                let profileCosts = owner.profileReadDiagnostics.snapshot()
                for stage in [V2ProfilePresentationReadDiagnostics.Stage.roomOwnerQueue, .roomOwnerRead, .roomOwnerExecution] {
                    #expect(profileCosts.stages[stage]?.calls == 1)
                    #expect(profileCosts.stages[stage]?.failures == 0)
                }
                #expect(try #require(profileCosts.stages[.roomOwnerRead]).totalMilliseconds
                    >= #require(profileCosts.stages[.roomOwnerExecution]).totalMilliseconds)
                let deadline = ContinuousClock.now + .seconds(3)
                while await budget.snapshot().commandCount != 0 {
                    guard ContinuousClock.now < deadline else { throw CohortFailure.waitExpired }
                    await Task.yield()
                }
                await lane.beginDrain()
                await executor.close()
            } catch {
                _ = await lane.abortReservation(reservation)
                for task in tasks { task.cancel() }
                for task in tasks { _ = await task.result }
                await executor.close()
                throw error
            }
        }
    }

    private func verify(_ results: [V2RoomMediaAuthorizationResult], requests: [V2ActorProfileVisibilityBatchWire],
                        token: V2RoomActivationToken) throws {
        #expect(results.count == 50)
        var observations: Set<Date> = []
        for (index, result) in results.enumerated() {
            guard case .profilesVisible(let proof) = result else { throw CohortFailure.unexpectedResult }
            #expect(proof.request == requests[index] && proof.activation == token)
            #expect(proof.membershipRevision == 3 && proof.permissionRevision == 1)
            let leaseSeconds = proof.activationExpiresAt.timeIntervalSince(proof.observedAt)
            #expect(leaseSeconds > 1 && leaseSeconds <= 30)
            observations.insert(proof.observedAt)
            if index >= 46 {
                // Negative observations carry authority versions too, but no
                // target or nickname may leak from another viewer in the cohort.
                #expect(proof.visibleTargetUserIDs.isEmpty && proof.groupMembers.isEmpty)
                continue
            }
            #expect(proof.visibleTargetUserIDs == [requests[index].targetUserIDs[0]])
            #expect(proof.membershipRevision == 3 && proof.activationExpiresAt > proof.observedAt)
            #expect(proof.groupMembers.count == 1)
            #expect(proof.groupMembers.first?.userID == requests[index].targetUserIDs[0])
            #expect(proof.groupMembers.first?.groupNickname == "Cohort nickname")
        }
        #expect(observations.count == 1)
    }

    private func withRoom(_ body: @escaping @Sendable (any Database, any SQLDatabase, V2RoomActivationToken, V2RoomActivationLifetime,
                                  [V2ActorProfileVisibilityBatchWire]) async throws -> Void) async throws {
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"]), maxConnectionsPerEventLoop: 4),
                                    as: .psql, isDefault: true)
            let database = resources.database(.psql), sql = try #require(database as? any SQLDatabase)
            let room = RoomID(uuid: UUID()), target = UserID(uuid: UUID()), departed = UserID(uuid: UUID())
            let actors = (0..<50).map { _ in UserID(uuid: UUID()) }
            try await sql.raw("INSERT INTO im_v2.rooms(room_id, room_shard_id, capacity_profile_id, membership_revision) VALUES (\(bind: room.uuidValue!), 'profile-cohort', 'standard', 3)").run()
            for (index, actor) in actors.enumerated() where index != 48 {
                let joined: Int64 = index == 47 ? 4 : 1
                let left: Int64? = index == 46 ? 3 : nil
                try await sql.raw("INSERT INTO im_v2.room_memberships(room_id,user_id,joined_revision,left_revision) VALUES (\(bind: room.uuidValue!),\(bind: actor.uuidValue!),\(bind: joined),\(bind: left))").run()
            }
            try await sql.raw("INSERT INTO im_v2.room_memberships(room_id,user_id,joined_revision) VALUES (\(bind: room.uuidValue!),\(bind: target.uuidValue!),1)").run()
            try await sql.raw("INSERT INTO im_v2.room_memberships(room_id,user_id,joined_revision,left_revision) VALUES (\(bind: room.uuidValue!),\(bind: departed.uuidValue!),1,3)").run()
            for user in [target, departed] {
                let handle = "cohort" + user.rawValue.replacingOccurrences(of: "-", with: "").lowercased().prefix(24)
                try await sql.raw("INSERT INTO im_v2.public_user_profiles(user_id,public_handle,display_name,created_at,updated_at) VALUES(\(bind: user.uuidValue!),\(bind: handle),'Cohort user',clock_timestamp(),clock_timestamp())").run()
                try await sql.raw("INSERT INTO im_v2.room_member_nicknames(room_id,user_id,nickname,revision,updated_at) VALUES(\(bind: room.uuidValue!),\(bind: user.uuidValue!),'Cohort nickname',1,clock_timestamp())").run()
            }
            let requests = actors.enumerated().map { index, actor in
                V2ActorProfileVisibilityBatchWire(roomID: room, actorUserID: actor,
                    roomKind: index == 49 ? .direct : (index.isMultiple(of: 2) ? .group : .memberRoom),
                    targetUserIDs: [target, departed])
            }
            try await withRoomActivationLifetime(database: database, roomID: room,
                                         shardID: "profile-cohort") { token, lifetime in
                try await body(database, sql, token, lifetime, requests)
            }
            try await resources.shutdown()
        } catch { try? await resources.shutdown(); throw error }
    }
}

private enum CohortFailure: Error { case waitExpired, unexpectedResult }

private actor CohortWriteGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func hold() async {
        entered = true
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func open() { released = true; continuation?.resume(); continuation = nil }
}

private struct CohortProjectionDelivery: V2UserShardProjectionDelivering {
    func deliverToCurrentShard(userID: UserID, sourceEventID: EventID, projectionKinds: Set<String>) async throws -> UInt64? { nil }
}
