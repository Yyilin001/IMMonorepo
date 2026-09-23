import Foundation
import FluentKit
import IMV2Core
@testable import IMV2Server
import SQLKit
import Testing

@Suite("PostgreSQL state during real NATS installation", .timeLimit(.minutes(1)))
struct PostgresV2NATSInstallationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_REAL_NATS_URL"] != nil
        && ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func committedHeadIsReadBeforeInstallationReturns() async throws {
        let address = try #require(ProcessInfo.processInfo.environment["IMV2_REAL_NATS_URL"])
        let url = try #require(URL(string: address))
        try await withUserEventDatabase { database, sql, schema in
            let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).rooms(room_id,room_shard_id,capacity_profile_id,membership_revision)
                VALUES (\(bind: room.uuidValue!),'room-a','standard',1)
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).room_memberships(room_id,user_id,joined_revision)
                VALUES (\(bind: room.uuidValue!),\(bind: user.uuidValue!),1)
                """).run()
            try await Self.verifyInstallation(database: database, schema: schema, user: user, room: room, url: url) { _ in
                try await sql.raw("UPDATE \(unsafeRaw: schema).rooms SET room_sequence = 8 WHERE room_id = \(bind: room.uuidValue!)").run()
                return 8
            }
        }
    }

    static func verifyInstallation(database: any Database, schema: String = "im_v2", user: UserID,
                                   room: RoomID, url: URL, beforeSubscription: Bool = false,
                                   awaitForegroundPublication: Bool = false,
                                   publish: ((any V2GroupEventWakePublishing) async throws -> Void)? = nil,
                                   commit: (any V2ForegroundGroupEventHintSubmitting) async throws -> UInt64) async throws {
        let states = try PostgresV2RoomRecoveryStore(database: database, schema: schema)
        guard case .state(let initial)? = try await states.states(roomIDs: [room], actorUserID: user)[room] else {
            throw V2RoomRecoveryReadError.corruptPersistence
        }
        let entry = try V2UserRoomDirectoryEntry(roomID: room, roomKind: .group,
            viewerMembershipRevision: initial.viewerMembershipRevision, ownerEpoch: initial.ownerEpoch)
        let registry = V2DeviceConnectionRegistry()
        let config = try V2NATSGroupEventWakeConfiguration(url: url,
            subjectPrefix: "imv2.pg.install." + UUID().uuidString.lowercased(),
            routingKey: Data(repeating: 31, count: 32), acknowledgementTimeout: 2)
        let broker = V2NATSGroupEventWakeBroker(configuration: config, receiveWake: { event in
            if case .wake(let wake) = event {
                await registry.notifyForegroundGroupAvailable(roomID: wake.roomID, highWatermark: wake.highWatermark)
            }
        })
        let barrier = CommittedHeadInstallationBarrier(broker: broker, beforeSubscription: beforeSubscription)
        let interests = V2SharedGroupEventWakeInterests(underlying: barrier)
        let service = try V2AccountRoomChangeService(states: states, interests: interests)
        await registry.configureAccountRoomChanges(service)
        let sink = CommittedHeadNotificationSink()
        let ticket = try await service.begin(userID: user, connectionID: UUID(),
            send: { await sink.receive($0) }, close: {})
        await service.resume(ticket)
        let publication = InstallationHintPublicationProbe(broker: broker)
        let publicationSink: any V2ForegroundGroupEventHintPublishing
        if awaitForegroundPublication { publicationSink = publication }
        else { publicationSink = broker }
        let dispatcher = V2ForegroundGroupEventHintDispatcher(publisher: publicationSink)
        let dispatchTask = Task { await dispatcher.run() }
        let installation = Task { try await service.install([entry], ticket: ticket) }
        do {
            try await waitUntil { await barrier.paused }
            let head = try await commit(dispatcher)
            if let publish { try await publish(broker) }
            else { try await broker.publish(.init(roomID: room, highWatermark: head)) }
            if beforeSubscription {
                if awaitForegroundPublication {
                    try await waitUntil { await publication.completed }
                    // Confirm a later command on the same broker connection.
                    // Its unrelated room cannot generate the target room wake.
                    try await broker.publish(.init(roomID: .init(uuid: UUID()), highWatermark: 1))
                }
                #expect(await sink.notifications.isEmpty)
            } else {
                try await waitUntil { await !sink.notifications.isEmpty }
                #expect(await sink.notifications == [.changed(epoch: ticket.epoch, sequence: 1,
                    roomID: room, highWatermark: head)])
            }
            #expect(await barrier.paused)
            await barrier.release()
            try await installation.value
            if beforeSubscription {
                guard case .state(let recovered)? = try await states.states(roomIDs: [room], actorUserID: user)[room] else {
                    throw V2RoomRecoveryReadError.corruptPersistence
                }
                #expect(recovered.head == head)
                let page = try await V2GroupEventLogService(store: PostgresV2GroupEventLogStore(database: database))
                    .pull(roomID: room, actorUserID: user, afterRoomSequence: initial.head, pageSize: 100)
                #expect(page.nextRoomSequence == head && !page.hasMore)
                #expect(page.events.count == 1 && page.events.first?.roomSequence == head)
                let event = try #require(page.events.first)
                let payload = try #require(JSONSerialization.jsonObject(with: event.payload) as? [String: Any])
                #expect(payload["text"] as? String == "installation-body")
                #expect(await sink.notifications.isEmpty)
            }
            dispatchTask.cancel()
            await dispatchTask.value
            await service.stop(ticket)
            await service.shutdown()
            await interests.shutdown()
            await broker.shutdown()
        } catch {
            dispatchTask.cancel()
            await dispatchTask.value
            installation.cancel()
            await barrier.release()
            _ = try? await installation.value
            await service.shutdown()
            await interests.shutdown()
            await broker.shutdown()
            throw error
        }
    }

    private static func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()) {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw InstallationFailure.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum InstallationFailure: Error { case timeout }

private actor CommittedHeadInstallationBarrier: V2GroupEventWakeInterestManaging {
    let broker: V2NATSGroupEventWakeBroker
    private(set) var paused = false
    private var continuation: CheckedContinuation<Void, Never>?
    let beforeSubscription: Bool
    init(broker: V2NATSGroupEventWakeBroker, beforeSubscription: Bool) {
        self.broker = broker; self.beforeSubscription = beforeSubscription
    }
    func activate(roomID: RoomID) async throws {
        if !beforeSubscription { try await broker.activate(roomID: roomID) }
        await withCheckedContinuation { continuation = $0; paused = true }
        try Task.checkCancellation()
        if beforeSubscription { try await broker.activate(roomID: roomID) }
    }
    func release() { paused = false; continuation?.resume(); continuation = nil }
    func deactivate(roomID: RoomID) async { await broker.deactivate(roomID: roomID) }
}

private actor CommittedHeadNotificationSink {
    private(set) var notifications: [V2AccountRoomNotification] = []
    func receive(_ value: V2AccountRoomNotification) -> Bool { notifications.append(value); return true }
}

private actor InstallationHintPublicationProbe: V2ForegroundGroupEventHintPublishing {
    let broker: V2NATSGroupEventWakeBroker
    private(set) var completed = false
    init(broker: V2NATSGroupEventWakeBroker) { self.broker = broker }
    func publishForegroundHint(_ hint: V2GroupEventWake) async {
        await broker.publishForegroundHint(hint)
        completed = true
    }
    func publishForegroundDirectEvent(_ event: V2DirectRoomLiveEvent) async {
        await broker.publishForegroundDirectEvent(event)
        completed = true
    }
    func publishForegroundGroupEvents(_ events: [V2DirectRoomLiveEvent]) async {
        await broker.publishForegroundGroupEvents(events)
        completed = true
    }
}
