import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core
@testable import IMV2Server
import SQLKit
import Testing

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil))
struct V2RoomProfileCohortPostgresTests {
    @Test("one room statement isolates 50 viewers, rejects invalid cohorts and fences stale activations")
    func independentViewers() async throws {
        try await withRoom { database, sql, token, requests in
            let executor = try V2RoomMediaAuthorizationDomainExecutor(database: database, token: token)
            let results = try await executor.executeProfileVisibilityBatch(requests)
            try verify(results, requests: requests, token: token)
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
            #expect(changed[0] == .notVisible)
            guard case .profilesVisible(let futureMember) = changed[1] else { throw CohortFailure.unexpectedResult }
            #expect(futureMember.membershipRevision == 4 && futureMember.request == requests[47])
            #expect(try await PostgresV2RoomActivationStore(database: database).release(token: token))
            await #expect(throws: V2RoomActivationLeaseError.activationChanged) {
                _ = try await executor.executeProfileVisibilityBatch(requests)
            }
        }
    }

    @Test("production lane and factory execute 100 target items under one database admission")
    func productionComposition() async throws {
        try await withRoom { database, _, token, requests in
            let writes = PostgresV2RoomWriteStore(database: database)
            let sendBatcher = V2SendMessageAdmissionBatcher(store: writes,
                configuration: .init(maximumBatchSize: 16, maximumDelay: .milliseconds(2)), actorGrantedStore: writes)
            let admission = V2DatabaseWorkAdmissionController(policy: .init(
                maximumForegroundWriteInFlight: 1, maximumInteractiveReadInFlight: 1,
                maximumSyncInFlight: 1, maximumForegroundWriteQueued: 2,
                maximumInteractiveReadQueued: 2, maximumSyncQueued: 1, timeout: .seconds(1)))
            let owner = try V2RoomServerOwnerResources(database: database, writes: writes, sendBatcher: sendBatcher,
                membershipIdentities: V2PostgresMembershipIdentitySnapshotValidator(database: database),
                invitationIdentities: PostgresV2GroupInvitationIdentityReader(database: database),
                receiptProjectionDelivery: CohortProjectionDelivery(),
                capacityProfile: .init(id: "standard", limits: .init(maxEligibleMembers: 100,
                    maxCommandsPerWindow: 100, retryAfterSeconds: 3)),
                messageLimits: .init(maxUTF8Bytes: 64), maximumEditBytes: 64,
                contentReviewMode: .disabled, queryBatchConfiguration: .init(), databaseWorkAdmission: admission)
            let factory = try V2RoomServerActivationFactory(owners: [token.owner.shardID: owner], safetyActorUserID: nil)
            let executor = factory.runtimeFactory().make(token)
            try await executor.restore(.now + .seconds(10))
            let configuration = try V2RoomRuntimeConfiguration()
            let budget = V2RoomCommandBudget(configuration: configuration)
            let lane = V2RoomTurnLane<V2RoomRequest, V2RoomResponse>(token: token,
                configuration: configuration, budget: budget, classify: { $0.turnSchedulingClass },
                execute: executor.execute, onUncertain: { _ in })
            let reservation = try await lane.reserve(requestID: UUID(), deadline: .now + .seconds(10))
            var tasks: [Task<V2RoomResponse, any Error>] = []
            do {
                for request in requests {
                    let bytes = try JSONEncoder().encode(V2RoomRequest.mediaAuthorization(.profileVisibilityBatch(request)))
                    tasks.append(Task { try await lane.submit(encodedRequest: bytes, deadline: .now + .seconds(10)) })
                    let deadline = ContinuousClock.now + .seconds(3)
                    while await lane.snapshot().queuedCount != tasks.count {
                        guard ContinuousClock.now < deadline else { throw CohortFailure.waitExpired }
                        await Task.yield()
                    }
                }
                #expect(await admission.snapshot().interactiveRead.admittedRequests == 0)
                #expect(await lane.abortReservation(reservation))
                var results: [V2RoomMediaAuthorizationResult] = []
                for task in tasks {
                    guard case .mediaAuthorization(let result) = try await task.value else { throw CohortFailure.unexpectedResult }
                    results.append(result)
                }
                try verify(results, requests: requests, token: token)
                let snapshot = await admission.snapshot()
                #expect(snapshot.interactiveRead.admittedRequests == 1)
                #expect(snapshot.interactiveRead.inFlight == 0)
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
            if index >= 46 { #expect(result == .notVisible); continue }
            guard case .profilesVisible(let proof) = result else { throw CohortFailure.unexpectedResult }
            #expect(proof.request == requests[index] && proof.activation == token)
            #expect(proof.visibleTargetUserIDs == [requests[index].targetUserIDs[0]])
            #expect(proof.membershipRevision == 3 && proof.activationExpiresAt > proof.observedAt)
            #expect(proof.groupMembers.count == 1)
            #expect(proof.groupMembers.first?.userID == requests[index].targetUserIDs[0])
            #expect(proof.groupMembers.first?.groupNickname == "Cohort nickname")
            observations.insert(proof.observedAt)
        }
        #expect(observations.count == 1)
    }

    private func withRoom(_ body: (any Database, any SQLDatabase, V2RoomActivationToken,
                                  [V2ActorProfileVisibilityBatchWire]) async throws -> Void) async throws {
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"])),
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
            let leases = PostgresV2RoomActivationStore(database: database)
            guard case .acquired(let grant) = try await leases.acquire(roomID: room,
                owner: .init(shardID: "profile-cohort", epoch: 0),
                host: .init(hostID: .init("profile-cohort-host"), incarnationID: UUID()), duration: .init(30_000))
            else { throw CohortFailure.unexpectedResult }
            let requests = actors.enumerated().map { index, actor in
                V2ActorProfileVisibilityBatchWire(roomID: room, actorUserID: actor,
                    roomKind: index == 49 ? .direct : (index.isMultiple(of: 2) ? .group : .memberRoom),
                    targetUserIDs: [target, departed])
            }
            do { try await body(database, sql, grant.token, requests) }
            catch { _ = try? await leases.release(token: grant.token); throw error }
            _ = try? await leases.release(token: grant.token)
            try await resources.shutdown()
        } catch { try? await resources.shutdown(); throw error }
    }
}

private enum CohortFailure: Error { case waitExpired, unexpectedResult }

private struct CohortProjectionDelivery: V2UserShardProjectionDelivering {
    func deliverToCurrentShard(userID: UserID, sourceEventID: EventID, projectionKinds: Set<String>) async throws -> UInt64? { nil }
}
