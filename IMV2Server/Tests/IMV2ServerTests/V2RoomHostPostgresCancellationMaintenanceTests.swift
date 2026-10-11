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

@Suite("Room Host cancellation and maintenance takeover on PostgreSQL", .serialized,
       .timeLimit(.minutes(3)))
struct V2RoomHostPostgresCancellationMaintenanceTests {
    @Test("queued send cancellation never reaches SQL; cancellation after SQL admission retains fence and permit",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ACTOR_CANCEL_MAINT_DATABASE_IS_DISPOSABLE"] == "1"))
    func queuedAndExecutingCancellation() async throws {
        try await withCancelMaintenanceDatabase { database, sql, fixture in
            let admission = cancelMaintenanceAdmission()
            let hosted = try cancelMaintenanceHost(database: database, fixture: fixture,
                leases: PostgresV2RoomActivationStore(database: database),
                name: "cancel-host", admission: admission)
            let host = hosted.host
            let leases = PostgresV2RoomActivationStore(database: database)
            let owner = try V2RoomDataOwner(shardID: "room-a", epoch: 0)
            let gate = CancelMaintenanceGate()
            let advisoryKey: Int64 = 9_240_010
            try await sql.raw("""
                CREATE FUNCTION im_v2.test_block_message_insert() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN PERFORM pg_advisory_xact_lock(9240010); RETURN NEW; END $$
                """).run()
            try await sql.raw("""
                CREATE TRIGGER test_block_message_insert BEFORE INSERT ON im_v2.messages
                FOR EACH ROW EXECUTE FUNCTION im_v2.test_block_message_insert()
                """).run()
            let locker = Task {
                try await database.transaction { transaction in
                    let tx = try #require(transaction as? any SQLDatabase)
                    try await tx.raw("SELECT pg_advisory_xact_lock(\(bind: advisoryKey))").run()
                    await gate.hold()
                }
            }
            await host.start()
            do {
                try await gate.waitUntilHeld()
                let token = try await cancelMaintenanceActivate(host: host)
                let firstID = UUID(), queuedID = UUID()
                let firstRequest = try cancelMaintenanceSendBytes(operation: firstID, text: "first")
                let queuedRequest = try cancelMaintenanceSendBytes(operation: queuedID, text: "queued")
                let first = Task { try await host.invoke(token: token,
                    encodedRequest: firstRequest,
                    deadline: .now + .seconds(15)) }
                try await cancelMaintenanceWaitUntil {
                    let waiting = try await cancelMaintenanceAdvisoryWait(sql: sql)
                    let snapshot = await hosted.resources.sendOperationOwnerMetricsSnapshot()
                    return waiting && snapshot.inFlightBatches == 1
                }
                let queued = Task { try await host.invoke(token: token,
                    encodedRequest: queuedRequest,
                    deadline: .now + .seconds(15)) }
                try await cancelMaintenanceWaitUntil { await hosted.budget.snapshot().commandCount == 2 }
                queued.cancel()
                await cancelMaintenanceExpectFailure(.notAccepted(.cancelled), queued)
                #expect(try await cancelMaintenanceOperationCount(sql: sql, operation: queuedID) == 0)
                first.cancel()
                await cancelMaintenanceExpectFailure(.outcomeUnknown, first)
                #expect(await hosted.budget.snapshot().commandCount == 1)
                #expect((await admission.snapshot()).foregroundWrite.inFlight == 0)
                #expect((await hosted.resources.sendOperationOwnerMetricsSnapshot()).inFlightBatches == 1)
                #expect(try await cancelMaintenanceLeaseEpoch(sql: sql) == token.activationEpoch.rawValue)
                #expect(!(await host.drain(deadline: .now + .milliseconds(40))).completed)
                #expect(try await cancelMaintenanceLeaseEpoch(sql: sql) == token.activationEpoch.rawValue)

                await gate.open()
                try await locker.value
                try await cancelMaintenanceWaitUntil {
                    let budget = await hosted.budget.snapshot()
                    let snapshot = await hosted.resources.sendOperationOwnerMetricsSnapshot()
                    return budget.commandCount == 0 && snapshot.inFlightBatches == 0
                }
                #expect(try await cancelMaintenanceOperationCount(sql: sql, operation: firstID) == 1)
                #expect(try await cancelMaintenanceOperationCount(sql: sql, operation: queuedID) == 0)
                let original = try #require(try await sql.raw("""
                    SELECT message_id AS value FROM im_v2.message_send_completions
                    WHERE room_id = \(bind: roomUUID) AND sender_user_id = \(bind: senderUUID)
                      AND client_message_id = \(bind: firstID)
                    """).first(decoding: CancelMaintenanceUUIDRow.self)).value
                #expect((await host.stop(deadline: .now + .seconds(5))).completed)
                #expect(try await leases.locate(roomID: roomID, owner: owner) == nil)

                // Replaying on a fresh activation resolves the detached caller's
                // unknown result to the exact durable operation, not a second write.
                let successor = try cancelMaintenanceHost(database: database, fixture: fixture,
                    leases: leases, name: "cancel-successor", admission: admission)
                await successor.host.start()
                let fresh = try await cancelMaintenanceActivate(host: successor.host)
                #expect(fresh.activationEpoch.rawValue == token.activationEpoch.rawValue + 1)
                let replay = try await successor.host.invoke(token: fresh,
                    encodedRequest: firstRequest,
                    deadline: .now + .seconds(5))
                guard case .messaging(.sendOperation(.receipt(let proof))) = replay,
                      case .accepted(let accepted) = proof.outcome else {
                    throw CancelMaintenanceFailure.unexpectedResult
                }
                #expect(accepted.messageID.uuidValue == original)
                #expect(try await cancelMaintenanceOperationCount(sql: sql, operation: firstID) == 1)
                #expect((await successor.host.stop(deadline: .now + .seconds(5))).completed)
            } catch {
                await gate.open()
                _ = try? await locker.value
                _ = await host.stop(deadline: .now + .seconds(5))
                throw error
            }
        }
    }

    @Test("retention holds its complete activation fence until DELETE commits before another host takes over",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ACTOR_CANCEL_MAINT_DATABASE_IS_DISPOSABLE"] == "1"))
    func retentionCannotOverlapSuccessor() async throws {
        try await withCancelMaintenanceDatabase { database, sql, fixture in
            let oldDate = Date(timeIntervalSince1970: 1_750_000_000)
            try await sql.raw("""
                UPDATE im_v2.rooms SET room_sequence = 3, membership_revision = 1
                WHERE room_id = \(bind: roomUUID)
                """).run()
            try await sql.raw("UPDATE im_v2.room_memberships SET joined_revision = 1").run()
            for sequence in 1...3 {
                try await sql.raw("""
                    INSERT INTO im_v2.room_events
                        (event_id, room_id, room_sequence, event_type, actor_user_id,
                         payload, committed_membership_revision, created_at)
                    VALUES (\(bind: UUID()), \(bind: roomUUID), \(bind: Int64(sequence)),
                        'message.accepted', \(bind: senderUUID),
                        jsonb_build_object('event_type', 'message.accepted',
                            'room_id', \(bind: roomUUID.uuidString.lowercased()),
                            'message_id', \(bind: UUID().uuidString.lowercased()),
                            'message_revision', 1, 'is_withdrawn', false),
                        1, \(bind: oldDate))
                    """).run()
            }
            for user in [senderUUID, memberTwoUUID, memberThreeUUID] {
                try await sql.raw("""
                    INSERT INTO im_v2.room_read_receipts
                        (room_id, user_id, read_through_room_sequence, updated_at)
                    VALUES (\(bind: roomUUID), \(bind: user), 3, \(bind: oldDate))
                    """).run()
            }
            let gate = CancelMaintenanceGate()
            let advisoryKey: Int64 = 9_240_021
            try await sql.raw("""
                CREATE FUNCTION im_v2.test_block_retention_delete() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN PERFORM pg_advisory_xact_lock(9240021); RETURN OLD; END $$
                """).run()
            try await sql.raw("""
                CREATE TRIGGER test_block_retention_delete BEFORE DELETE ON im_v2.room_events
                FOR EACH ROW EXECUTE FUNCTION im_v2.test_block_retention_delete()
                """).run()
            let locker = Task {
                try await database.transaction { transaction in
                    let tx = try #require(transaction as? any SQLDatabase)
                    try await tx.raw("SELECT pg_advisory_xact_lock(\(bind: advisoryKey))").run()
                    await gate.hold()
                }
            }
            let leases = PostgresV2RoomActivationStore(database: database)
            let first = try cancelMaintenanceHost(database: database, fixture: fixture,
                leases: leases, name: "retention-first", admission: cancelMaintenanceAdmission(),
                now: { oldDate })
            let next = try cancelMaintenanceHost(database: database, fixture: fixture,
                leases: leases, name: "retention-next", admission: cancelMaintenanceAdmission(),
                now: { oldDate })
            await first.host.start()
            await next.host.start()
            do {
                try await gate.waitUntilHeld()
                let old = try await cancelMaintenanceActivate(host: first.host)
                let command = V2RoomRequest.maintenance(.trimLog(.init(roomID: roomID,
                    mode: .permanent, windowSeconds: 3_600)))
                let request = try JSONEncoder().encode(command)
                let trim = Task { try await first.host.invoke(token: old,
                    encodedRequest: request, deadline: .now + .seconds(15)) }
                try await cancelMaintenanceWaitUntil {
                    try await cancelMaintenanceAdvisoryWait(sql: sql)
                }
                #expect(try await cancelMaintenanceFloor(sql: sql) == 0)
                #expect(try await cancelMaintenanceRoomEventCount(sql: sql) == 3)
                let takeover = Task { try await next.host.activate(roomID: roomID,
                    owner: try .init(shardID: "room-a", epoch: 0), deadline: .now + .seconds(15)) }
                try await cancelMaintenanceWaitUntil {
                    try await cancelMaintenanceRoomLockWait(sql: sql)
                }
                #expect(try await cancelMaintenanceLeaseEpoch(sql: sql) == old.activationEpoch.rawValue)
                #expect(try await cancelMaintenanceFloor(sql: sql) == 0)
                #expect(try await cancelMaintenanceRoomEventCount(sql: sql) == 3)
                await gate.open()
                try await locker.value
                guard case .maintenance(.logTrimmed(let report)) = try await trim.value else {
                    throw CancelMaintenanceFailure.unexpectedResult
                }
                #expect(report.advancedFloor && report.deletedEvents == 2)
                guard case .occupied(let occupied) = try await takeover.value else {
                    throw CancelMaintenanceFailure.unexpectedResult
                }
                #expect(occupied.token == old)
                #expect(try await cancelMaintenanceFloor(sql: sql) == 3)
                #expect(try await cancelMaintenanceRoomEventCount(sql: sql) == 1)
                #expect((await first.host.stop(deadline: .now + .seconds(5))).completed)
                let fresh = try await cancelMaintenanceActivate(host: next.host)
                #expect(fresh.activationEpoch.rawValue == old.activationEpoch.rawValue + 1)
                await cancelMaintenanceExpectFailure(.notAccepted(.staleActivation), Task {
                    try await first.host.invoke(token: old, encodedRequest: request,
                        deadline: .now + .seconds(5))
                })
                #expect(try await leases.release(token: old) == false)
                await #expect(throws: V2RoomActivationLeaseError.activationChanged) {
                    _ = try await V2ActorRoomMaintenanceExecutor(database: database,
                        now: { oldDate }).execute(.trimLog(.init(roomID: roomID,
                            mode: .permanent, windowSeconds: 3_600)), token: old)
                }
                let freshResponse = try await next.host.invoke(token: fresh,
                    encodedRequest: request, deadline: .now + .seconds(5))
                guard case .maintenance(.logTrimmed(let noOp)) = freshResponse else {
                    throw CancelMaintenanceFailure.unexpectedResult
                }
                #expect(!noOp.advancedFloor && noOp.deletedEvents == 0)
                #expect((await next.host.stop(deadline: .now + .seconds(5))).completed)
            } catch {
                await gate.open()
                _ = try? await locker.value
                _ = await first.host.stop(deadline: .now + .seconds(5))
                _ = await next.host.stop(deadline: .now + .seconds(5))
                throw error
            }
        }
    }

    @Test("trusted review holds its room fence through commit; a successor only replays the terminal decision",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ACTOR_CANCEL_MAINT_DATABASE_IS_DISPOSABLE"] == "1"))
    func reviewCannotOverlapSuccessor() async throws {
        try await withCancelMaintenanceDatabase { database, sql, fixture in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let sender = try V2SendMessageService(store: PostgresV2RoomWriteStore(database: database),
                capacityProfile: fixture.forwardImportTestProfile(),
                limits: .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let message) = try await sender.send(.init(roomID: roomID,
                actorUserID: senderID, clientMessageID: .init(uuid: UUID()), text: "blocked review")) else {
                throw CancelMaintenanceFailure.unexpectedResult
            }
            // The production write store enqueues this job with the accepted
            // message; no test-side review row is synthesized.
            #expect(try await cancelMaintenanceCount(sql: sql,
                table: "im_v2.content_review_jobs WHERE state = 'pending'") == 1)
            let key: Int64 = 9_240_031
            try await sql.raw("""
                CREATE FUNCTION im_v2.test_block_trusted_review() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN PERFORM pg_advisory_xact_lock(9240031); RETURN NEW; END $$
                """).run()
            try await sql.raw("""
                CREATE TRIGGER test_block_trusted_review BEFORE INSERT ON im_v2.moderation_operations
                FOR EACH ROW WHEN (NEW.action = 'redact_message')
                EXECUTE FUNCTION im_v2.test_block_trusted_review()
                """).run()
            let gate = CancelMaintenanceGate()
            let locker = Task {
                try await database.transaction { transaction in
                    let tx = try #require(transaction as? any SQLDatabase)
                    try await tx.raw("SELECT pg_advisory_xact_lock(\(bind: key))").run()
                    await gate.hold()
                }
            }
            let leases = PostgresV2RoomActivationStore(database: database)
            let first = try cancelMaintenanceHost(database: database, fixture: fixture,
                leases: leases, name: "review-first", admission: cancelMaintenanceAdmission(), now: { now })
            let next = try cancelMaintenanceHost(database: database, fixture: fixture,
                leases: leases, name: "review-next", admission: cancelMaintenanceAdmission(), now: { now })
            await first.host.start()
            await next.host.start()
            do {
                try await gate.waitUntilHeld()
                let old = try await cancelMaintenanceActivate(host: first.host)
                let applicator = V2RoomContentReviewSafetyApplicator(callTimeout: .seconds(15)) {
                    request, deadline in
                    try await first.host.invoke(token: old,
                        encodedRequest: JSONEncoder().encode(request), deadline: deadline)
                }
                let worker = try V2ContentReviewWorker(
                    store: PostgresV2ContentReviewStore(database: database),
                    reviewer: V2ConfiguredContentReviewer(violatingTerms: ["blocked"]),
                    moderation: applicator, now: { now })
                let review = Task { try await worker.runOnce(limit: 1) }
                try await cancelMaintenanceWaitUntil { try await cancelMaintenanceAdvisoryWait(sql: sql) }
                #expect(try await cancelMaintenanceCount(sql: sql,
                    table: "im_v2.moderation_operations") == 0)
                #expect(try await cancelMaintenanceCount(sql: sql,
                    table: "im_v2.content_review_jobs WHERE completed_at IS NOT NULL") == 0)
                #expect(try await cancelMaintenanceCount(sql: sql,
                    table: "im_v2.content_review_decisions") == 0)
                let takeover = Task { try await next.host.activate(roomID: roomID,
                    owner: try .init(shardID: "room-a", epoch: 0), deadline: .now + .seconds(15)) }
                try await cancelMaintenanceWaitUntil { try await cancelMaintenanceRoomLockWait(sql: sql) }
                #expect(try await cancelMaintenanceLeaseEpoch(sql: sql) == old.activationEpoch.rawValue)
                #expect(try await cancelMaintenanceCount(sql: sql,
                    table: "im_v2.content_review_jobs WHERE completed_at IS NOT NULL") == 0)

                await gate.open()
                try await locker.value
                let report = try await review.value
                #expect(report.claimedCount == 1 && report.resolvedCount == 1 && report.redactedCount == 1)
                guard case .occupied(let occupied) = try await takeover.value else {
                    throw CancelMaintenanceFailure.unexpectedResult
                }
                #expect(occupied.token == old)
                #expect(try await cancelMaintenanceCount(sql: sql,
                    table: "im_v2.content_review_jobs WHERE state = 'completed' AND decision = 'violation'") == 1)
                #expect(try await cancelMaintenanceCount(sql: sql,
                    table: "im_v2.moderation_operations") == 1)
                #expect(try await cancelMaintenanceCount(sql: sql,
                    table: "im_v2.room_events WHERE event_type = 'message.redacted'") == 1)
                #expect((await first.host.stop(deadline: .now + .seconds(5))).completed)
                let fresh = try await cancelMaintenanceActivate(host: next.host)
                #expect(fresh.activationEpoch.rawValue == old.activationEpoch.rawValue + 1)
                let safety = V2RoomRequest.administration(.trustedSafety(.init(roomID: roomID,
                    operationID: try .init(message.messageID.rawValue), action: .redactMessage,
                    messageID: message.messageID, expectedMessageRevision: 1,
                    reasonCode: "content_policy_violation")))
                let encoded = try JSONEncoder().encode(safety)
                await cancelMaintenanceExpectFailure(.notAccepted(.staleActivation), Task {
                    try await first.host.invoke(token: old, encodedRequest: encoded,
                        deadline: .now + .seconds(5))
                })
                guard case .administration(.trustedSafety(.idempotent(let replay))) =
                    try await next.host.invoke(token: fresh, encodedRequest: encoded,
                        deadline: .now + .seconds(5)) else {
                    throw CancelMaintenanceFailure.unexpectedResult
                }
                #expect(replay.messageID == message.messageID)
                #expect(try await cancelMaintenanceCount(sql: sql,
                    table: "im_v2.moderation_operations") == 1)
                #expect(try await cancelMaintenanceCount(sql: sql,
                    table: "im_v2.room_events WHERE event_type = 'message.redacted'") == 1)
                #expect(try await worker.runOnce(limit: 1).claimedCount == 0)

                // A separately claimed review that reaches the retired Host
                // must remain retryable; an old turn cannot complete the job.
                guard case .accepted(let lateMessage) = try await sender.send(.init(
                    roomID: roomID, actorUserID: senderID,
                    clientMessageID: .init(uuid: UUID()), text: "blocked after takeover")),
                    let lateUUID = lateMessage.messageID.uuidValue else {
                    throw CancelMaintenanceFailure.unexpectedResult
                }
                #expect(try await cancelMaintenanceCount(sql: sql,
                    table: "im_v2.content_review_jobs WHERE state = 'pending'") == 1)
                let staleReport = try await worker.runOnce(limit: 1)
                #expect(staleReport.claimedCount == 1 && staleReport.resolvedCount == 0
                    && staleReport.releasedCount == 1)
                #expect(try await cancelMaintenanceReviewRetryable(sql: sql, message: lateUUID))
                #expect(try await cancelMaintenanceCount(sql: sql,
                    table: "im_v2.moderation_operations") == 1)
                let freshApplicator = V2RoomContentReviewSafetyApplicator {
                    request, deadline in
                    try await next.host.invoke(token: fresh,
                        encodedRequest: JSONEncoder().encode(request), deadline: deadline)
                }
                let retryAt = now.addingTimeInterval(61)
                let freshWorker = try V2ContentReviewWorker(
                    store: PostgresV2ContentReviewStore(database: database),
                    reviewer: V2ConfiguredContentReviewer(violatingTerms: ["blocked"]),
                    moderation: freshApplicator, now: { retryAt })
                let recovered = try await freshWorker.runOnce(limit: 1)
                #expect(recovered.claimedCount == 1 && recovered.resolvedCount == 1
                    && recovered.redactedCount == 1)
                #expect(try await cancelMaintenanceCount(sql: sql,
                    table: "im_v2.content_review_jobs WHERE state = 'completed'") == 2)
                #expect(try await cancelMaintenanceCount(sql: sql,
                    table: "im_v2.moderation_operations") == 2)
                #expect((await next.host.stop(deadline: .now + .seconds(5))).completed)
            } catch {
                await gate.open()
                _ = try? await locker.value
                _ = await first.host.stop(deadline: .now + .seconds(5))
                _ = await next.host.stop(deadline: .now + .seconds(5))
                throw error
            }
        }
    }

    @Test("target import holds its room fence through receive and completion before takeover",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ACTOR_CANCEL_MAINT_DATABASE_IS_DISPOSABLE"] == "1"))
    func importCannotOverlapSuccessor() async throws {
        try await withCancelMaintenanceDatabase { database, sql, fixture in
            let now = Date(timeIntervalSince1970: 1_750_000_000)
            let sourceUUID = UUID(), sourceRoom = RoomID(uuid: sourceUUID)
            try await cancelMaintenanceSeedImportSource(sql: sql, room: sourceUUID, now: now)
            let profile = try fixture.forwardImportTestProfile()
            let sourceSender = try V2SendMessageService(store: PostgresV2RoomWriteStore(database: database),
                capacityProfile: profile, limits: .init(maxUTF8Bytes: 64), now: { now })
            guard case .accepted(let sourceMessage) = try await sourceSender.send(.init(
                roomID: sourceRoom, actorUserID: senderID,
                clientMessageID: .init(uuid: UUID()), text: "forward source")) else {
                throw CancelMaintenanceFailure.unexpectedResult
            }
            let leases = PostgresV2RoomActivationStore(database: database)
            let sourceIdentity = V2ActorHostIdentity(hostID: try .init("import-source"),
                incarnationID: UUID())
            guard case .acquired(let sourceLease) = try await leases.acquire(roomID: sourceRoom,
                owner: .init(shardID: "room-b", epoch: 0), host: sourceIdentity,
                duration: .init(30_000)) else {
                throw CancelMaintenanceFailure.unexpectedResult
            }
            let exporter = try PostgresV2ForwardExportStore(database: database)
                .usingActivationToken(sourceLease.token)
            let sourceReference = try V2ForwardMessageReference(roomID: sourceRoom,
                messageID: sourceMessage.messageID, revision: .init(1))
            guard case .export(let export) = try await exporter.prepareForDelivery(
                actorUserID: senderID, operationID: .init(uuid: UUID()), source: sourceReference,
                sourceRoute: .init(shardID: "room-b", epoch: 0), targetRoomID: roomID,
                targetRoute: .init(shardID: "room-a", epoch: 0), now: now) else {
                throw CancelMaintenanceFailure.unexpectedResult
            }
            let key: Int64 = 9_240_032
            try await sql.raw("""
                CREATE FUNCTION im_v2.test_block_forward_receive() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN PERFORM pg_advisory_xact_lock(9240032); RETURN NEW; END $$
                """).run()
            try await sql.raw("""
                CREATE TRIGGER test_block_forward_receive BEFORE INSERT ON im_v2.message_forward_inbox
                FOR EACH ROW EXECUTE FUNCTION im_v2.test_block_forward_receive()
                """).run()
            let gate = CancelMaintenanceGate()
            let locker = Task {
                try await database.transaction { transaction in
                    let tx = try #require(transaction as? any SQLDatabase)
                    try await tx.raw("SELECT pg_advisory_xact_lock(\(bind: key))").run()
                    await gate.hold()
                }
            }
            let first = try cancelMaintenanceHost(database: database, fixture: fixture,
                leases: leases, name: "import-first", admission: cancelMaintenanceAdmission(), now: { now })
            let next = try cancelMaintenanceHost(database: database, fixture: fixture,
                leases: leases, name: "import-next", admission: cancelMaintenanceAdmission(), now: { now })
            await first.host.start()
            await next.host.start()
            do {
                try await gate.waitUntilHeld()
                let old = try await cancelMaintenanceActivate(host: first.host)
                let command = V2RoomRequest.forward(.importExport(.init(domain: export)))
                let request = try JSONEncoder().encode(command)
                let importing = Task { try await first.host.invoke(token: old,
                    encodedRequest: request, deadline: .now + .seconds(15)) }
                try await cancelMaintenanceWaitUntil { try await cancelMaintenanceAdvisoryWait(sql: sql) }
                #expect(try await cancelMaintenanceCount(sql: sql,
                    table: "im_v2.message_forward_inbox") == 0)
                #expect(try await cancelMaintenanceCount(sql: sql,
                    table: "im_v2.messages") == 1)
                let takeover = Task { try await next.host.activate(roomID: roomID,
                    owner: try .init(shardID: "room-a", epoch: 0), deadline: .now + .seconds(15)) }
                try await cancelMaintenanceWaitUntil { try await cancelMaintenanceRoomLockWait(sql: sql) }
                #expect(try await cancelMaintenanceLeaseEpoch(sql: sql) == old.activationEpoch.rawValue)
                #expect(try await cancelMaintenanceCount(sql: sql,
                    table: "im_v2.message_forward_inbox") == 0)

                await gate.open()
                try await locker.value
                guard case .forward(.imported(.accepted(let messageID, let sequence))) =
                    try await importing.value else {
                    throw CancelMaintenanceFailure.unexpectedResult
                }
                guard case .occupied(let occupied) = try await takeover.value else {
                    throw CancelMaintenanceFailure.unexpectedResult
                }
                #expect(occupied.token == old)
                #expect(try await cancelMaintenanceImportRow(sql: sql, export: export.intent.exportID,
                    message: try #require(messageID.uuidValue), sequence: Int64(sequence)))
                #expect(try await cancelMaintenanceCount(sql: sql,
                    table: "im_v2.message_forward_inbox") == 1)
                #expect(try await cancelMaintenanceCount(sql: sql,
                    table: "im_v2.messages") == 2)
                #expect((await first.host.stop(deadline: .now + .seconds(5))).completed)
                let fresh = try await cancelMaintenanceActivate(host: next.host)
                #expect(fresh.activationEpoch.rawValue == old.activationEpoch.rawValue + 1)
                await cancelMaintenanceExpectFailure(.notAccepted(.staleActivation), Task {
                    try await first.host.invoke(token: old, encodedRequest: request,
                        deadline: .now + .seconds(5))
                })
                let replay = try await next.host.invoke(token: fresh,
                    encodedRequest: request, deadline: .now + .seconds(5))
                #expect(replay == .forward(.imported(.accepted(messageID: messageID,
                    roomSequence: sequence))))
                #expect(try await cancelMaintenanceImportRow(sql: sql, export: export.intent.exportID,
                    message: try #require(messageID.uuidValue), sequence: Int64(sequence)))
                #expect(try await cancelMaintenanceCount(sql: sql,
                    table: "im_v2.message_forward_inbox") == 1)
                #expect(try await cancelMaintenanceCount(sql: sql,
                    table: "im_v2.messages") == 2)
                #expect((await next.host.stop(deadline: .now + .seconds(5))).completed)
                #expect(try await leases.release(token: sourceLease.token))
            } catch {
                await gate.open()
                _ = try? await locker.value
                _ = await first.host.stop(deadline: .now + .seconds(5))
                _ = await next.host.stop(deadline: .now + .seconds(5))
                throw error
            }
        }
    }
}

private struct CancelMaintenanceHosted: Sendable {
    let host: V2RoomActivationHost<V2RoomRequest, V2RoomResponse>
    let budget: V2RoomCommandBudget
    let resources: V2RoomServerOwnerResources
}

private func cancelMaintenanceHost(database: any Database,
    fixture: PostgresV2RoomWriteStoreIntegrationTests, leases: PostgresV2RoomActivationStore,
    name: String, admission: V2DatabaseWorkAdmissionController,
    now: @escaping @Sendable () -> Date = Date.init) throws -> CancelMaintenanceHosted {
    let configuration = try V2RoomRuntimeConfiguration(maximumActiveRooms: 2,
        maximumConcurrentRestores: 1, maximumPendingActivations: 2,
        maximumCommandsPerTurn: 1, maximumConcurrentReservations: 2)
    let budget = V2RoomCommandBudget(configuration: configuration)
    let writes = PostgresV2RoomWriteStore(database: database)
    let resources = try V2RoomServerOwnerResources(database: database, sendDatabase: try v2FixtureMessageWriteDatabase(database, capacity: 1), writes: writes,
        membershipIdentities: V2PostgresMembershipIdentitySnapshotValidator(database: database),
        invitationIdentities: PostgresV2GroupInvitationIdentityReader(database: database),
        invitationSecretIssuer: try .init(rawKey: Data(repeating: 0x73, count: 32)),
        receiptProjectionDelivery: CancelMaintenanceProjectionDelivery(),
        capacityProfile: fixture.forwardImportTestProfile(),
        messageLimits: .init(maxUTF8Bytes: 64), maximumEditBytes: 64,
        contentReviewMode: .disabled, queryBatchConfiguration: .init(),
        databaseWorkAdmission: admission)
    let factory = try V2RoomServerActivationFactory(owners: ["room-a": resources.usingFixturePolicyAuthorizations(endpoint: "room-a")],
        safetyActorUserID: senderID, now: now).runtimeFactory()
    let identity = V2ActorHostIdentity(hostID: try .init(name), incarnationID: UUID())
    return .init(host: .init(identity: identity, leaseStore: leases,
        configuration: configuration, budget: budget,
        classify: { $0.canShareSendTurn ? .send : .barrier }, factory: factory),
        budget: budget, resources: resources)
}

private func cancelMaintenanceAdmission() -> V2DatabaseWorkAdmissionController {
    .init(policy: .init(maximumForegroundWriteInFlight: 1,
        maximumInteractiveReadInFlight: 1, maximumSyncInFlight: 1,
        maximumForegroundWriteQueued: 2, maximumInteractiveReadQueued: 2,
        maximumSyncQueued: 1, timeout: .seconds(2)))
}

private func cancelMaintenanceActivate(
    host: V2RoomActivationHost<V2RoomRequest, V2RoomResponse>) async throws -> V2RoomActivationToken {
    guard case .ready(let token) = try await host.activate(roomID: roomID,
        owner: .init(shardID: "room-a", epoch: 0), deadline: .now + .seconds(5)) else {
        throw CancelMaintenanceFailure.unexpectedResult
    }
    return token
}

private func cancelMaintenanceSendBytes(operation: UUID, text: String) throws -> Data {
    try JSONEncoder().encode(V2RoomRequest.messaging(.sendOperation(.init(command: .init(roomID: roomID,
        senderUserID: senderID, clientMessageID: .init(uuid: operation), text: text,
        media: [], mentions: [], entities: [], replyTo: nil, limits: .init(maxUTF8Bytes: 64)), firstSubmissionDeadlineMilliseconds: UInt64(Date().timeIntervalSince1970 * 1000) + 600_000))))
}

private func cancelMaintenanceExpectFailure<T: Sendable>(_ expected: V2RoomCallFailure,
    _ task: Task<T, any Error>) async {
    do { _ = try await task.value; Issue.record("unexpected success; expected \(expected)") }
    catch { #expect(error as? V2RoomCallFailure == expected) }
}

private func cancelMaintenanceWaitUntil(
    _ condition: @escaping @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while try !(await condition()) {
        guard ContinuousClock.now < deadline else { throw CancelMaintenanceFailure.phaseTimeout }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private actor CancelMaintenanceGate {
    private var held = false
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        held = true
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func waitUntilHeld() async throws {
        try await cancelMaintenanceWaitUntil { await self.held }
    }
    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private struct CancelMaintenanceProjectionDelivery: V2UserShardProjectionDelivering {
    func deliverToCurrentShard(userID: UserID, sourceEventID: EventID,
        projectionKinds: Set<String>) async throws -> UInt64? { nil }
}

private struct CancelMaintenanceBoolRow: Decodable { let value: Bool }
private struct CancelMaintenanceCountRow: Decodable { let value: Int64 }
private struct CancelMaintenanceUUIDRow: Decodable { let value: UUID }
private enum CancelMaintenanceFailure: Error { case phaseTimeout, unexpectedResult, schemaAlreadyExists }

private func cancelMaintenanceCount(sql: any SQLDatabase, table: String) async throws -> Int64 {
    try #require(try await sql.raw("SELECT COUNT(*)::bigint AS value FROM \(unsafeRaw: table)")
        .first(decoding: CancelMaintenanceCountRow.self)).value
}

private func cancelMaintenanceReviewRetryable(sql: any SQLDatabase, message: UUID) async throws -> Bool {
    try #require(try await sql.raw("""
        SELECT COUNT(*)::bigint AS value FROM im_v2.content_review_jobs
        WHERE message_id = \(bind: message) AND state = 'pending'
          AND decision = 'violation' AND completed_at IS NULL
          AND claim_token IS NULL AND next_attempt_at IS NOT NULL
        """).first(decoding: CancelMaintenanceCountRow.self)).value == 1
}

private func cancelMaintenanceImportRow(sql: any SQLDatabase, export: UUID,
    message: UUID, sequence: Int64) async throws -> Bool {
    try #require(try await sql.raw("""
        SELECT COUNT(*)::bigint AS value
        FROM im_v2.message_forward_inbox AS inbox
        JOIN im_v2.messages AS saved ON saved.message_id = inbox.result_message_id
        JOIN im_v2.message_send_completions AS completion
          ON completion.room_id = inbox.target_room_id
         AND completion.sender_user_id = inbox.actor_user_id
         AND completion.client_message_id = inbox.target_client_message_id
        WHERE inbox.export_id = \(bind: export) AND inbox.target_room_id = \(bind: roomUUID)
          AND inbox.state = 'completed' AND inbox.result_message_id = \(bind: message)
          AND inbox.result_room_sequence = \(bind: sequence)
          AND saved.room_id = \(bind: roomUUID) AND saved.room_sequence = \(bind: sequence)
          AND completion.message_id = \(bind: message)
        """).first(decoding: CancelMaintenanceCountRow.self)).value == 1
}

private func cancelMaintenanceSeedImportSource(sql: any SQLDatabase, room: UUID,
    now: Date) async throws {
    let lease = UUID()
    try await sql.raw("""
        INSERT INTO im_v2.rooms (room_id, room_shard_id, capacity_profile_id, capacity_class)
        VALUES (\(bind: room), 'room-b', 'standard', 'standard')
        """).run()
    try await sql.raw("""
        INSERT INTO im_v2.room_owner_routes
            (room_id, room_shard_id, route_epoch, created_at, updated_at)
        VALUES (\(bind: room), 'room-b', 0, \(bind: now), \(bind: now))
        """).run()
    try await sql.raw("""
        INSERT INTO im_v2.group_rooms (room_id, owner_user_id, title, created_at)
        VALUES (\(bind: room), \(bind: senderUUID), 'Import source', \(bind: now))
        """).run()
    try await sql.raw("""
        INSERT INTO im_v2.shard_admission_pools
            (room_shard_id, capacity_profile_id, lease_id, generation, valid_until, command_window_limit)
        VALUES ('room-b', 'standard', \(bind: lease), 1, clock_timestamp() + INTERVAL '1 hour', 10)
        """).run()
    try await sql.raw("""
        INSERT INTO im_v2.room_admission
            (room_id, eligible_member_count, command_window_limit, shard_lease_id, shard_lease_generation)
        VALUES (\(bind: room), 3, 10, \(bind: lease), 1)
        """).run()
    for user in [senderUUID, memberTwoUUID, memberThreeUUID] {
        try await sql.raw("""
            INSERT INTO im_v2.room_memberships (room_id, user_id, joined_revision)
            VALUES (\(bind: room), \(bind: user), 0)
            """).run()
    }
}

private func cancelMaintenanceAdvisoryWait(sql: any SQLDatabase) async throws -> Bool {
    try await sql.raw("""
        SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid <> pg_backend_pid()
            AND wait_event_type = 'Lock' AND wait_event = 'advisory'
            AND cardinality(pg_blocking_pids(pid)) > 0) AS value
        """).first(decoding: CancelMaintenanceBoolRow.self)?.value == true
}

private func cancelMaintenanceRoomLockWait(sql: any SQLDatabase) async throws -> Bool {
    try await sql.raw("""
        SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid <> pg_backend_pid()
            AND wait_event_type = 'Lock' AND query LIKE '%FROM im_v2.rooms%'
            AND query LIKE '%FOR NO KEY UPDATE%'
            AND cardinality(pg_blocking_pids(pid)) > 0) AS value
        """).first(decoding: CancelMaintenanceBoolRow.self)?.value == true
}

private func cancelMaintenanceOperationCount(sql: any SQLDatabase, operation: UUID) async throws -> Int64 {
    try #require(try await sql.raw("""
        SELECT COUNT(*)::bigint AS value FROM im_v2.message_send_completions
        WHERE room_id = \(bind: roomUUID) AND sender_user_id = \(bind: senderUUID)
          AND client_message_id = \(bind: operation)
        """).first(decoding: CancelMaintenanceCountRow.self)).value
}

private func cancelMaintenanceFloor(sql: any SQLDatabase) async throws -> Int64 {
    try #require(try await sql.raw("""
        SELECT log_trimmed_through_room_sequence AS value FROM im_v2.rooms
        WHERE room_id = \(bind: roomUUID)
        """).first(decoding: CancelMaintenanceCountRow.self)).value
}

/// MVCC observation deliberately avoids the production owner's locking locate
/// operation while a fenced writer is paused inside its transaction.
private func cancelMaintenanceLeaseEpoch(sql: any SQLDatabase) async throws -> Int64 {
    try #require(try await sql.raw("""
        SELECT activation_epoch AS value FROM im_v2.room_activation_leases
        WHERE room_id = \(bind: roomUUID) AND expires_at > clock_timestamp()
        """).first(decoding: CancelMaintenanceCountRow.self)).value
}

private func cancelMaintenanceRoomEventCount(sql: any SQLDatabase) async throws -> Int64 {
    try #require(try await sql.raw("""
        SELECT COUNT(*)::bigint AS value FROM im_v2.room_events
        WHERE room_id = \(bind: roomUUID)
        """).first(decoding: CancelMaintenanceCountRow.self)).value
}

private func withCancelMaintenanceDatabase(_ operation: (any Database, any SQLDatabase,
    PostgresV2RoomWriteStoreIntegrationTests) async throws -> Void) async throws {
    let url = try #require(ProcessInfo.processInfo.environment["IMV2_ACTOR_CANCEL_MAINT_DATABASE_URL"])
    let resources = makeV2DatabaseTestResources()
    var installed = false
    do {
        resources.databases.use(try .postgres(url: url, maxConnectionsPerEventLoop: 6),
            as: .psql, isDefault: true)
        let database = resources.database(.psql)
        let sql = try #require(database as? any SQLDatabase)
        guard try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS value")
            .first(decoding: CancelMaintenanceBoolRow.self)?.value == false else {
            throw CancelMaintenanceFailure.schemaAlreadyExists
        }
        let fixture = PostgresV2RoomWriteStoreIntegrationTests()
        installed = true
        try await fixture.installSchema(on: sql)
        try await fixture.seedRoom(on: sql)
        try await sql.raw("UPDATE im_v2.shard_admission_pools SET valid_until = clock_timestamp() + INTERVAL '1 hour'").run()
        try await operation(database, sql, fixture)
        try await sql.raw("DROP SCHEMA im_v2 CASCADE").run()
        installed = false
        try await resources.shutdown()
    } catch {
        if installed, let sql = resources.database(.psql) as? any SQLDatabase {
            try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run()
        }
        try? await resources.shutdown()
        throw error
    }
}
