@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2ActorContracts
import IMV2ActorCluster
import IMV2ActorRuntime
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import SQLKit
import Testing

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("nickname handoff waits for accepted SQL and stale Actor calls cannot mutate administration state",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ACTOR_D2_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func v2ActorAdministrationOldTokenNicknameFence() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["IMV2_ACTOR_D2_TEST_DATABASE_URL"])
        let resources = makeV2DatabaseTestResources()
        resources.databases.use(try .postgres(url: url, maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
        let database = resources.database(.psql)
        let sql = try #require(database as? any SQLDatabase)
        do {
            guard try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS value")
                .first(decoding: D2ExistsRow.self)?.value != true else { throw TestConfigurationError.schemaAlreadyExists }
            try await installSchema(on: sql)
            try await seedRoom(on: sql)
            try await sql.raw("UPDATE im_v2.shard_admission_pools SET valid_until=clock_timestamp()+interval '1 hour'").run()
            let room = RoomID(uuid: roomUUID), actor = UserID(uuid: senderUUID), confirmedAt = Date()
            let nameDeadline = try V2DirectRoomOperationTestFixture.deadline(confirmedAt)
            let moderationDeadline = UInt64(try v2GatewayMilliseconds(confirmedAt)) + 120_000
            let profile = try forwardImportTestProfile(), eventID = EventID(uuid: UUID())
            let a = V2ActorHostIdentity(hostID: try .init("d2-host-a"), incarnationID: UUID())
            let b = V2ActorHostIdentity(hostID: try .init("d2-host-b"), incarnationID: UUID())
            try await withNativePlacementTestControl(hosts: [a, b], initialHost: a, shardID: "room-a") { control in
                let first = try await d2Host(identity: a, control: control)
                let next = try await d2Host(identity: b, control: control)
                await first.host.start(); await next.host.start()
                let gate = D2NicknameOperationGate()
                var holder: Task<Void, any Error>?
                var writing: Task<V2GroupNicknameUpdateReceipt, any Error>?
                var transfer: Task<Void, any Error>?
                do {
                    let old = try await first.activate(room)
                    let initialCommand = try V2GroupNicknameUpdateCommand(actorUserID: actor, roomID: room,
                        operationID: .init(uuid: UUID()), expectedRevision: nil, nickname: "Alice",
                        firstSubmissionDeadlineMilliseconds: nameDeadline)
                    @Sendable func nickname(_ hosted: D2Hosted, _ token: V2RoomActivationToken,
                        _ command: V2GroupNicknameUpdateCommand) async throws -> V2GroupNicknameUpdateReceipt {
                        let result = try await hosted.host.invoke(token: token, request: .init { token in
                            let store = PostgresV2ProfilePresentationStore(database: database,
                                activationScope: try .init(tokens: [token]), nicknameCapacityProfile: profile)
                            return .groupNickname(try await store.updateOwnGroupNickname(command))
                        }, deadline: .now + .seconds(15))
                        guard case .groupNickname(let receipt) = result else { throw V2RoomActorStateError.activationChanged }
                        return receipt
                    }
                    let original = try await nickname(first, old, initialCommand)
                    #expect(try original.committedValue.groupNickname == "Alice")
                    #expect(try await nickname(first, old, initialCommand) == original)
                    let pending = try V2GroupNicknameUpdateCommand(actorUserID: actor, roomID: room,
                        operationID: .init(uuid: UUID()), expectedRevision: original.committedValue.revision,
                        nickname: "Draining", firstSubmissionDeadlineMilliseconds: nameDeadline)
                    let key = senderUUID.uuidString + ":presentation-operation:groupNickname:" + pending.operationID.uuidValue!.uuidString
                    holder = Task {
                        try await database.transaction { transaction in
                            let tx = try #require(transaction as? any SQLDatabase)
                            try await tx.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: key), 0))").run()
                            await gate.signalHeld(); await gate.waitForRelease()
                        }
                    }
                    await gate.waitUntilHeld()
                    writing = Task { try await nickname(first, old, pending) }
                    try await d2Wait {
                        try await sql.raw("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname=current_database() AND wait_event='advisory' AND cardinality(pg_blocking_pids(pid))>0) AS value")
                            .first(decoding: D2ExistsRow.self)?.value == true
                    }
                    transfer = Task { try await control.transfer(from: first.host, placement: first.placement,
                        to: b, deadline: .now + .seconds(15)) }
                    try await d2Wait { await first.host.snapshot().retiringRooms == 1 }
                    let withdrawn = try await control.snapshot()
                    #expect(withdrawn.slots[0].owner.host == a && withdrawn.slots[0].transfer != nil)
                    #expect(await next.host.readyTokens().isEmpty)
                    await gate.release(); try await holder!.value
                    let drained = try await writing!.value
                    #expect(try drained.committedValue.groupNickname == "Draining")
                    try await transfer!.value
                    try await next.placement.refresh()
                    let current = try await next.activate(room)
                    #expect(current.host == b && current != old)
                    await #expect(throws: V2RoomCallFailure.notAccepted(.staleActivation)) {
                        try await nickname(first, old, initialCommand)
                    }
                    #expect(try await nickname(next, current, initialCommand) == original)
                    try await sql.raw("UPDATE im_v2.room_memberships SET role='owner' WHERE room_id=\(bind: roomUUID) AND user_id=\(bind: senderUUID)").run()
                    let membership = PostgresV2MembershipOperationStore(database: database, clock: { confirmedAt })
                    let identity = try await V2PostgresMembershipIdentitySnapshotValidator(database: database)
                        .snapshot(actorUserID: actor, targetUserID: .init(uuid: memberTwoUUID))
                    let intent = try V2MembershipIntent(roomID: room, actorUserID: actor, operationID: .init(uuid: UUID()),
                        targetUserID: .init(uuid: memberTwoUUID), action: .remove, expectedMembershipRevision: 0,
                        confirmedUntilMilliseconds: moderationDeadline)
                    let admitted = try await next.host.invoke(token: current, request: .init { token in
                        .membershipAdmission(try await membership.admit(intent, identitySnapshot: identity, token: token))
                    }, deadline: .now + .seconds(5))
                    guard case .membershipAdmission(.admitted(let admission)) = admitted else { throw V2MembershipOperationValidationError.invalidAdmission }
                    let memberCommand = try V2MembershipOperationCommand(intent: intent, admission: admission)
                    await #expect(throws: V2RoomCallFailure.notAccepted(.staleActivation)) {
                        try await first.host.invoke(token: old, request: .init { token in
                            _ = try await membership.submit(memberCommand, token: token, capacityProfile: profile,
                                eventID: eventID, identitySnapshot: identity)
                            return .groupNickname(original)
                        }, deadline: .now + .seconds(5))
                    }
                    let capabilities = PostgresV2GroupCapabilityOperationStore(database: database, clock: { confirmedAt })
                    let intent2 = try V2GroupCapabilityIntent(identity: .init(accountID: actor, scope: .room(room),
                        operation: .groupAnnouncement(.init(uuid: UUID()))), action: .announcement(body: "stale", expectedRevision: 0),
                        confirmedUntilMilliseconds: moderationDeadline)
                    let admission2 = try await next.host.invoke(token: current, request: .init { token in
                        .groupCapabilityAdmission(try await capabilities.admit(intent2, token: token))
                    }, deadline: .now + .seconds(5))
                    guard case .groupCapabilityAdmission(.admitted(let grant2)) = admission2 else { throw V2GroupCapabilityValidationError.invalidAdmission }
                    let announcement = try V2GroupCapabilityCommand(intent: intent2, admission: grant2)
                    await #expect(throws: V2RoomCallFailure.notAccepted(.staleActivation)) {
                        try await first.host.invoke(token: old, request: .init { token in
                            _ = try await capabilities.submit(announcement, token: token, capacityProfile: profile, eventID: eventID)
                            return .groupNickname(original)
                        }, deadline: .now + .seconds(5))
                    }
                    let freeze = try V2ModerationCommand(roomID: room, actorUserID: actor,
                        operationID: .init(uuid: UUID()), action: .freezeRoom, reasonCode: .init("review"))
                    await #expect(throws: V2RoomCallFailure.notAccepted(.staleActivation)) {
                        try await first.host.invoke(token: old, request: .init { token in
                            _ = try await PostgresV2ModerationStore(database: database, activationScope: .init(tokens: [token]))
                                .applyTrustedSafety(command: freeze, capacityProfile: profile, eventID: eventID, now: confirmedAt)
                            return .groupNickname(original)
                        }, deadline: .now + .seconds(5))
                    }
                    let update = V2RoomAdministrationCommand.groupNickname(.init(command: try .init(actorUserID: actor, roomID: room,
                        operationID: .init(uuid: UUID()), expectedRevision: drained.committedValue.revision,
                        nickname: "Alice B", firstSubmissionDeadlineMilliseconds: nameDeadline)))
                    let changed = try await next.host.invoke(token: current, request: .init { token in
                        let executor = try V2RoomAdministrationDomainExecutor(database: database,
                            invitationSecretIssuer: .init(rawKey: Data(repeating: 0x73, count: 32)),
                            invitationIdentities: PostgresV2GroupInvitationIdentityReader(database: database),
                            token: token, capacityProfile: profile, membershipIdentities: D2IdentityReader(), makeEventID: { eventID })
                        return try await executor.executeUser(update)
                    }, deadline: .now + .seconds(5))
                    guard case .groupNickname(let changedReceipt) = changed else { throw V2RoomActorStateError.activationChanged }
                    #expect(try changedReceipt.committedValue.groupNickname == "Alice B")
                    #expect(try await count("im_v2.group_nickname_operation_receipts", on: sql) == 3)
                    #expect(try await sql.raw("SELECT EXISTS(SELECT 1 FROM im_v2.room_events WHERE event_id=\(bind: eventID.uuidValue!) AND room_id=\(bind: roomUUID) AND event_type='group.nickname_changed') AS value")
                        .first(decoding: D2ExistsRow.self)?.value == true)
                    try await first.stop(); try await next.stop()
                } catch {
                    await gate.release()
                    _ = await holder?.result; _ = await writing?.result
                    transfer?.cancel(); _ = await transfer?.result
                    try await first.stop(); try await next.stop()
                    throw error
                }
            }
            try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
            try await resources.shutdown()
        } catch {
            try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
            try? await resources.shutdown()
            throw error
        }
    }
}

private struct D2AdministrationCall: Sendable {
    let run: @Sendable (V2RoomActivationToken) async throws -> V2RoomAdministrationResult
}
private struct D2Hosted: Sendable {
    let host: V2RoomActivationHost<D2AdministrationCall, V2RoomAdministrationResult>
    let placement: V2RoomActorPlacementRuntime
    func activate(_ room: RoomID) async throws -> V2RoomActivationToken {
        guard case .ready(let token) = try await host.activate(roomID: room, owner: .init(shardID: "room-a", epoch: 0),
            deadline: .now + .seconds(5)) else { throw V2RoomActorStateError.activationChanged }
        return token
    }
    func stop() async throws {
        let proof = try #require(await host.stop(deadline: .now + .seconds(30)).proof)
        try await placement.retireAfterDrain(proof, shards: ["room-a"])
    }
}
private func d2Host(identity: V2ActorHostIdentity, control: V2NativePlacementTestControl) async throws -> D2Hosted {
    let placement = try await control.register(identity, shard: "room-a")
    let configuration = try V2RoomRuntimeConfiguration()
    let host = V2RoomActivationHost<D2AdministrationCall, V2RoomAdministrationResult>(identity: identity, placement: placement,
        configuration: configuration, budget: .init(configuration: configuration), classify: { _ in .barrier },
        factory: .init { token in
            .init(restore: { try await $0.validate() }, execute: { turn in
                do {
                    var results: [V2RoomAdministrationResult] = []
                    for item in turn.items { results.append(try await item.request.run(token)) }
                    return .committed(results)
                } catch { return v2RoomDomainCompletion(error) }
            }, invalidateReservation: { _ in }, close: {})
        })
    return .init(host: host, placement: placement)
}
private func d2Wait(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(try await predicate()) {
        guard .now < deadline else { throw V2ActorPlacementError.unavailable }
        try await Task.sleep(for: .milliseconds(5))
    }
}
private struct D2ExistsRow: Decodable { let value: Bool }
private struct D2IdentityReader: V2MembershipIdentitySnapshotValidating {
    func snapshot(actorUserID: UserID, targetUserID: UserID) async throws -> V2MembershipIdentitySnapshot {
        .init(actorUserID: actorUserID, targetUserID: targetUserID, actorIsActive: true, targetIsActive: true)
    }
}
private actor D2NicknameOperationGate {
    private var held = false, released = false
    private var heldWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func signalHeld() { held = true; heldWaiter?.resume(); heldWaiter = nil }
    func waitUntilHeld() async { if !held { await withCheckedContinuation { heldWaiter = $0 } } }
    func waitForRelease() async { if !released { await withCheckedContinuation { releaseWaiter = $0 } } }
    func release() { released = true; releaseWaiter?.resume(); releaseWaiter = nil }
}
