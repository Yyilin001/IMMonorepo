@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
import Synchronization
import SwiftProtobuf
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("V2 Core NATS group wake broker")
struct V2NATSGroupEventWakeBrokerTests {
    @Test("NATS client-affecting payloads require an intact deployment-key MAC")
    func authenticatedPayloadRejectsForgery() throws {
        let body = Data("durable-room-event".utf8)
        let subject = "imv2.test.group.room-a"
        let envelope = V2NATSAuthenticatedPayloadCodec.seal(
            body,
            subject: subject,
            routingKey: Self.routingKey
        )
        #expect(authenticatedBody(envelope, subject: subject) == body)
        #expect(V2NATSAuthenticatedPayloadCodec.open(
            body,
            subject: subject,
            routingKey: Self.routingKey
        ) == nil)
        #expect(V2NATSAuthenticatedPayloadCodec.open(
            envelope,
            subject: subject,
            routingKey: Data(repeating: 8, count: 32)
        ) == nil)
        #expect(authenticatedBody(envelope, subject: "imv2.test.group.room-b") == nil)

        var modified = envelope
        modified[modified.index(after: modified.startIndex)] ^= 0x01
        #expect(authenticatedBody(modified, subject: subject) == nil)
    }

    @Test("configuration bounds broker acknowledgement latency")
    func rejectsInvalidAcknowledgementTimeout() throws {
        let url = try #require(URL(string: "nats://127.0.0.1:4222"))
        let key = Data(repeating: 7, count: 32)
        #expect(throws: V2NATSGroupEventWakeBrokerError.invalidConfiguration) {
            _ = try V2NATSGroupEventWakeConfiguration(
                url: url,
                subjectPrefix: "imv2.test.group",
                routingKey: key,
                acknowledgementTimeout: 0
            )
        }
        #expect(throws: V2NATSGroupEventWakeBrokerError.invalidConfiguration) {
            _ = try V2NATSGroupEventWakeConfiguration(
                url: url,
                subjectPrefix: "imv2.test.group",
                routingKey: key,
                acknowledgementTimeout: 31
            )
        }
        #expect(throws: V2NATSGroupEventWakeBrokerError.invalidConfiguration) {
            _ = try V2NATSGroupEventWakeConfiguration(
                url: URL(string: "nats://nats.internal:4222")!,
                subjectPrefix: "imv2.test.group",
                token: "shared-token",
                routingKey: key
            )
        }
        #expect(throws: V2NATSGroupEventWakeBrokerError.invalidConfiguration) {
            _ = try V2NATSGroupEventWakeConfiguration(
                url: URL(string: "tls://nats.internal:4222")!,
                subjectPrefix: "imv2.test.group",
                routingKey: key
            )
        }
        #expect(try V2NATSGroupEventWakeConfiguration(
            url: URL(string: "tls://nats.internal:4222")!,
            subjectPrefix: "imv2.test.group",
            token: "shared-token",
            routingKey: key
        ).usesTLS)
    }

    @Test("a silent broker cannot indefinitely retain durable wake work")
    func timesOutWithoutPong() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in channel.pipeline.addHandler(V2NATSSilentGroupWakeTestHandler()) }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        do {
            let broker = try makeBroker(port: try #require(server.localAddress?.port), timeout: 0.05)
            let startedAt = Date()
            await #expect(throws: V2NATSGroupEventWakeBrokerError.unavailable) {
                try await broker.publish(.init(
                    roomID: try RoomID("00000000-0000-0000-0000-000000000901"),
                    highWatermark: 4
                ))
            }
            #expect(Date().timeIntervalSince(startedAt) < 2)
            await broker.shutdown()
            try await server.close().get()
            try await group.shutdownGracefully()
        } catch {
            try? await server.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    @Test("broker rejection fails activation instead of installing a phantom interest")
    func rejectsBrokerError() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in channel.pipeline.addHandler(V2NATSRejectingGroupWakeTestHandler()) }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        do {
            let broker = try makeBroker(
                port: try #require(server.localAddress?.port),
                timeout: 1,
                token: "test-auth-token"
            )
            await #expect(throws: V2NATSGroupEventWakeBrokerError.unavailable) {
                try await broker.activate(roomID: try RoomID("00000000-0000-0000-0000-000000000902"))
            }
            await broker.shutdown()
            try await server.close().get()
            try await group.shutdownGracefully()
        } catch {
            try? await server.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    @Test("concurrent interests share one confirmed connection and publishing waits for PONG")
    func serializesConnectionAndConfirmsCommands() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let recorder = V2NATSGroupWakeTestRecorder()
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(V2NATSConfirmingGroupWakeTestHandler(recorder: recorder))
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        do {
            let broker = try makeBroker(
                port: try #require(server.localAddress?.port),
                timeout: 1,
                token: "test-auth-token"
            )
            let first = try RoomID("00000000-0000-0000-0000-000000000903")
            let second = try RoomID("00000000-0000-0000-0000-000000000904")
            async let firstActivation: Void = broker.activate(roomID: first)
            async let secondActivation: Void = broker.activate(roomID: second)
            _ = try await (firstActivation, secondActivation)
            try await broker.publish(.init(roomID: first, highWatermark: 9))

            let observation = recorder.observation()
            #expect(observation.connectionCount == 1)
            #expect(observation.subscriptionCount == 2)
            #expect(observation.publishCount == 1)
            #expect(observation.authenticationTokens == ["test-auth-token"])
            #expect(observation.legacyTokenFieldCount == 0)
            // Both interests may be coalesced into the initial confirmed
            // replay, or the second may become one incremental SUB.
            #expect((2...3).contains(observation.pingCount))
            await broker.shutdown()
            try await server.close().get()
            try await group.shutdownGracefully()
        } catch {
            try? await server.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    @Test("ordered group microbatch crosses NATS in one publication")
    func publishesOneOrderedGroupMicrobatch() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let recorder = V2NATSGroupWakeTestRecorder()
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(
                    V2NATSConfirmingGroupWakeTestHandler(recorder: recorder)
                )
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        do {
            let broker = try makeBroker(
                port: try #require(server.localAddress?.port),
                timeout: 1
            )
            let roomID = try RoomID("00000000-0000-0000-0000-000000000906")
            let first = try natsGroupEvent(roomID: roomID, sequence: 1, revision: 7)
            let second = try natsGroupEvent(roomID: roomID, sequence: 2, revision: 7)

            await broker.publishForegroundGroupEvents([second, first])
            try await recorder.waitForPublishes(1)

            let observation = recorder.observation()
            #expect(observation.connectionCount == 1)
            #expect(observation.publishCount == 1)
            // The only PING confirms connection setup. Foreground live
            // publications are advisory and must not add a broker round trip.
            #expect(observation.pingCount == 1)
            let payload = try #require(observation.publishedPayloads.first)
            let subject = try #require(observation.publishedSubjects.first)
            let verifiedPayload = try #require(authenticatedBody(payload, subject: subject))
            #expect(
                V2NATSGroupEventWakeBroker.decodeNotificationPayload(verifiedPayload)
                    == .groupEvents([first, second])
            )

            // A missing membership epoch must never become a live audience.
            // It degrades to a durable room-log cursor wake instead.
            var wire = try IMV2InternalGroupEventNotification(serializedBytes: verifiedPayload.dropFirst(5))
            wire.groupEvents.membershipRevision = 0
            let invalidPayload = Data([0x49, 0x4D, 0x4E, 0x47, 0x01]) + (try wire.serializedData())
            #expect(
                V2NATSGroupEventWakeBroker.decodeNotificationPayload(invalidPayload)
                    == .wake(.init(roomID: roomID, highWatermark: 2))
            )

            await broker.shutdown()
            try await server.close().get()
            try await group.shutdownGracefully()
        } catch {
            try? await server.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    @Test("group microbatch splits before the Core NATS payload ceiling")
    func splitsLargeGroupMicrobatch() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let recorder = V2NATSGroupWakeTestRecorder()
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(
                    V2NATSConfirmingGroupWakeTestHandler(recorder: recorder)
                )
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        do {
            let broker = try makeBroker(
                port: try #require(server.localAddress?.port),
                timeout: 1
            )
            let roomID = try RoomID("00000000-0000-0000-0000-000000000907")
            let first = try natsGroupEvent(
                roomID: roomID,
                sequence: 1,
                revision: 9,
                payload: Data(repeating: 1, count: 300 * 1_024)
            )
            let second = try natsGroupEvent(
                roomID: roomID,
                sequence: 2,
                revision: 9,
                payload: Data(repeating: 2, count: 300 * 1_024)
            )

            await broker.publishForegroundGroupEvents([first, second])
            try await recorder.waitForPublishes(2)

            let observation = recorder.observation()
            #expect(observation.publishCount == 2)
            #expect(observation.pingCount == 1)
            #expect(observation.publishedPayloads.allSatisfy { $0.count < 1_024 * 1_024 })
            #expect(
                zip(observation.publishedSubjects, observation.publishedPayloads).compactMap { subject, payload in
                    authenticatedBody(payload, subject: subject).flatMap(
                        V2NATSGroupEventWakeBroker.decodeNotificationPayload
                    )
                } == [.groupEvents([first]), .groupEvents([second])]
            )

            await broker.shutdown()
            try await server.close().get()
            try await group.shutdownGracefully()
        } catch {
            try? await server.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    @Test("protobuf group microbatch is compact, ordered, and fail-closed")
    func protobufGroupMicrobatchContract() throws {
        let roomID = try RoomID("00000000-0000-0000-0000-000000000916")
        let first = try natsGroupEvent(
            roomID: roomID,
            sequence: 1,
            revision: 17,
            payload: Data(repeating: 1, count: 128)
        )
        let second = try natsGroupEvent(
            roomID: roomID,
            sequence: 2,
            revision: 17,
            payload: Data(repeating: 2, count: 128)
        )
        let notification = V2ForegroundGroupEventNotification.groupEvents([
            first, second,
        ])
        let binary = try V2NATSGroupEventProtobufCodec.encode(notification)
        #expect(V2NATSGroupEventProtobufCodec.recognizes(binary))
        #expect(
            V2NATSGroupEventWakeBroker.decodeNotificationPayload(binary)
                == notification
        )

        #expect(V2NATSGroupEventWakeBroker.decodeNotificationPayload(Data("{\"room_id\":\"old\"}".utf8)) == nil)

        let mixedRevision = try natsGroupEvent(
            roomID: roomID,
            sequence: 3,
            revision: 18
        )
        #expect(throws: V2NATSGroupEventWakeBrokerError.invalidPayload) {
            _ = try V2NATSGroupEventProtobufCodec.encode(.groupEvents([
                second, mixedRevision,
            ]))
        }

        var wire = try IMV2InternalGroupEventNotification(
            serializedBytes: binary.dropFirst(5)
        )
        wire.groupEvents.events[0].sourceEventID.removeLast()
        let invalidBody = Data([0x49, 0x4D, 0x4E, 0x47, 0x01])
            + (try wire.serializedData())
        #expect(
            V2NATSGroupEventWakeBroker.decodeNotificationPayload(invalidBody)
                == .wake(.init(roomID: roomID, highWatermark: 2))
        )

        var unknownVersion = binary
        unknownVersion[4] = 2
        #expect(
            V2NATSGroupEventWakeBroker.decodeNotificationPayload(unknownVersion)
                == nil
        )
    }

    @Test("protobuf exact-audience direct event preserves recipient and exclusion fences")
    func protobufExactAudienceDirectEventContract() throws {
        let roomID = try RoomID("00000000-0000-0000-0000-000000000917")
        let firstUser = try UserID("00000000-0000-0000-0001-000000000917")
        let secondUser = try UserID("00000000-0000-0000-0002-000000000917")
        let excluded = try #require(UUID(uuidString: "00000000-0000-0000-0003-000000000917"))
        let event = try V2DirectRoomLiveEvent(
            roomID: roomID,
            highWatermark: 4,
            sourceEventID: .init("00000000-0000-0000-0004-000000000917"),
            roomSequence: 4,
            projectionKind: "message",
            payload: Data("private-event".utf8),
            recipientUserIDs: [firstUser, secondUser],
            groupMembershipRevision: nil,
            acceptedMembershipRevision: nil,
            excludedConnectionID: excluded
        )
        let notification = V2ForegroundGroupEventNotification.directEvent(event)
        let binary = try V2NATSGroupEventProtobufCodec.encode(notification)
        #expect(
            V2NATSGroupEventWakeBroker.decodeNotificationPayload(binary)
                == notification
        )
    }

    @Test("broker publishes configured protobuf payload without a per-batch PONG")
    func publishesConfiguredProtobufPayload() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let recorder = V2NATSGroupWakeTestRecorder()
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(
                    V2NATSConfirmingGroupWakeTestHandler(recorder: recorder)
                )
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        do {
            let broker = try makeBroker(
                port: try #require(server.localAddress?.port),
                timeout: 1
            )
            let roomID = try RoomID("00000000-0000-0000-0000-000000000918")
            let events = [
                try natsGroupEvent(roomID: roomID, sequence: 1, revision: 19),
                try natsGroupEvent(roomID: roomID, sequence: 2, revision: 19),
            ]
            await broker.publishForegroundGroupEvents(events)
            try await recorder.waitForPublishes(1)

            let observation = recorder.observation()
            #expect(observation.pingCount == 1)
            let payload = try #require(observation.publishedPayloads.first)
            let subject = try #require(observation.publishedSubjects.first)
            let verifiedPayload = try #require(authenticatedBody(payload, subject: subject))
            #expect(V2NATSGroupEventProtobufCodec.recognizes(verifiedPayload))
            #expect(
                V2NATSGroupEventWakeBroker.decodeNotificationPayload(verifiedPayload)
                    == .groupEvents(events)
            )

            await broker.shutdown()
            try await server.close().get()
            try await group.shutdownGracefully()
        } catch {
            try? await server.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    @Test("sharded notification dispatch repairs bounded cross-publisher inversions")
    func shardedNotificationDispatchRepairsRoomOrder() async throws {
        let firstRoom = try RoomID("00000000-0000-0000-0000-000000000908")
        let secondRoom = try RoomID("00000000-0000-0000-0000-000000000909")
        let recorder = V2NATSNotificationDispatchRecorder()
        let dispatcher = V2NATSGroupNotificationDispatcher(
            laneCount: 8,
            capacityPerLane: 128,
            receiveNotification: { notification in
                recorder.record(notification)
            }
        )

        for lower in stride(from: 1, through: 49, by: 2) {
            let higher = lower + 1
            dispatcher.submit(try natsGroupPayload(
                roomID: firstRoom,
                sequence: UInt64(higher),
                revision: 11
            ))
            dispatcher.submit(try natsGroupPayload(
                roomID: secondRoom,
                sequence: UInt64(higher),
                revision: 13
            ))
            dispatcher.submit(try natsGroupPayload(
                roomID: firstRoom,
                sequence: UInt64(lower),
                revision: 11
            ))
            dispatcher.submit(try natsGroupPayload(
                roomID: secondRoom,
                sequence: UInt64(lower),
                revision: 13
            ))
        }

        try await recorder.waitForCount(100)
        #expect(dispatcher.droppedPayloadCount() == 0)
        #expect(recorder.sequences(for: firstRoom) == Array(1...50).map(UInt64.init))
        #expect(recorder.sequences(for: secondRoom) == Array(1...50).map(UInt64.init))
    }

    @Test("a live window suppresses only metadata wakes it fully covers")
    func coalescedLiveWindowSuppressesCoveredWake() async throws {
        let roomID = try RoomID("00000000-0000-0000-0000-000000000912")
        let recorder = V2NATSNotificationDispatchRecorder()
        let dispatcher = V2NATSGroupNotificationDispatcher(
            laneCount: 1,
            capacityPerLane: 8,
            reorderingDelay: .milliseconds(10),
            receiveNotification: { notification in
                recorder.record(notification)
            }
        )

        dispatcher.submit(try natsWakePayload(roomID: roomID, highWatermark: 2))
        dispatcher.submit(try natsGroupPayload(
            roomID: roomID,
            sequence: 2,
            revision: 17
        ))
        dispatcher.submit(try natsGroupPayload(
            roomID: roomID,
            sequence: 1,
            revision: 17
        ))

        try await recorder.waitForCount(2)
        #expect(recorder.sequences(for: roomID) == [1, 2])
        #expect(recorder.wakeHighWatermarks(for: roomID).isEmpty)
    }

    @Test("completed live fanout suppresses a covered wake from a later window")
    func completedLiveFanoutSuppressesLateCoveredWake() async throws {
        let roomID = try RoomID("00000000-0000-0000-0000-000000000913")
        let recorder = V2NATSNotificationDispatchRecorder()
        let suppressed = Atomic<Int>(0)
        let dispatcher = V2NATSGroupNotificationDispatcher(
            laneCount: 1,
            capacityPerLane: 8,
            reorderingDelay: .milliseconds(5),
            coveredWakeSuppressedObserver: {
                _ = suppressed.wrappingAdd(1, ordering: .relaxed)
            },
            receiveNotification: { recorder.record($0) }
        )

        dispatcher.submit(try natsGroupPayload(
            roomID: roomID,
            sequence: 4,
            revision: 17
        ))
        try await recorder.waitForCount(1)
        dispatcher.submit(try natsWakePayload(
            roomID: roomID,
            highWatermark: 4
        ))

        try await waitForAtomic(suppressed, toReach: 1)
        #expect(recorder.wakeHighWatermarks(for: roomID).isEmpty)
    }

    @Test("a wake beyond completed live fanout is still delivered")
    func futureWakeIsNotSuppressed() async throws {
        let roomID = try RoomID("00000000-0000-0000-0000-000000000914")
        let recorder = V2NATSNotificationDispatchRecorder()
        let suppressed = Atomic<Int>(0)
        let dispatcher = V2NATSGroupNotificationDispatcher(
            laneCount: 1,
            capacityPerLane: 8,
            reorderingDelay: .milliseconds(5),
            coveredWakeSuppressedObserver: {
                _ = suppressed.wrappingAdd(1, ordering: .relaxed)
            },
            receiveNotification: { recorder.record($0) }
        )

        dispatcher.submit(try natsGroupPayload(
            roomID: roomID,
            sequence: 4,
            revision: 17
        ))
        try await recorder.waitForCount(1)
        dispatcher.submit(try natsWakePayload(
            roomID: roomID,
            highWatermark: 5
        ))

        try await recorder.waitForWakeCount(1)
        #expect(recorder.wakeHighWatermarks(for: roomID) == [5])
        #expect(suppressed.load(ordering: .relaxed) == 0)
    }

    @Test("an early durable wake is covered by live fanout during deferral")
    func earlyWakeIsCoveredDuringDeferral() async throws {
        let roomID = try RoomID("00000000-0000-0000-0000-000000000917")
        let instant = ContinuousClock().now
        let recorder = V2NATSNotificationDispatchRecorder()
        let deferred = Atomic<Int>(0)
        let suppressed = Atomic<Int>(0)
        let delivered = Atomic<Int>(0)
        let dispatcher = V2NATSGroupNotificationDispatcher(
            laneCount: 1,
            capacityPerLane: 8,
            reorderingDelay: .milliseconds(5),
            coveredWakeSuppressedObserver: {
                _ = suppressed.wrappingAdd(1, ordering: .relaxed)
            },
            wakeDeferralDelay: .milliseconds(80),
            monotonicNow: { instant },
            wakeDeferredObserver: {
                _ = deferred.wrappingAdd(1, ordering: .relaxed)
            },
            deferredWakeDeliveredObserver: {
                _ = delivered.wrappingAdd(1, ordering: .relaxed)
            },
            receiveNotification: { recorder.record($0) }
        )

        dispatcher.submit(try natsWakePayload(
            roomID: roomID,
            highWatermark: 11
        ))
        try await waitForAtomic(deferred, toReach: 1)
        // Simulate a delayed test task without advancing the deferral clock.
        // Coverage before the deadline must not depend on CPU scheduling.
        try await Task.sleep(for: .milliseconds(120))
        dispatcher.submit(try natsGroupPayload(
            roomID: roomID,
            sequence: 11,
            revision: 17
        ))

        try await recorder.waitForCount(1)
        try await waitForAtomic(suppressed, toReach: 1)
        #expect(recorder.wakeHighWatermarks(for: roomID).isEmpty)
        #expect(delivered.load(ordering: .relaxed) == 0)
    }

    @Test("a deferred wake waits for its monotonic deadline and delivers exactly at it")
    func deferredWakeMonotonicDeadline() async throws {
        let roomID = try RoomID("00000000-0000-0000-0000-000000000918")
        let otherRoomID = try RoomID("00000000-0000-0000-0000-000000000919")
        let instant = ContinuousClock().now
        let clock = Mutex(instant)
        let recorder = V2NATSNotificationDispatchRecorder()
        let deferred = Atomic<Int>(0)
        let delivered = Atomic<Int>(0)
        let dispatcher = V2NATSGroupNotificationDispatcher(
            laneCount: 1,
            capacityPerLane: 8,
            reorderingDelay: .zero,
            wakeDeferralDelay: .milliseconds(20),
            monotonicNow: { clock.withLock { $0 } },
            wakeDeferredObserver: {
                _ = deferred.wrappingAdd(1, ordering: .relaxed)
            },
            deferredWakeDeliveredObserver: {
                _ = delivered.wrappingAdd(1, ordering: .relaxed)
            },
            receiveNotification: { recorder.record($0) }
        )
        dispatcher.submit(try natsWakePayload(roomID: roomID, highWatermark: 12))
        try await waitForAtomic(deferred, toReach: 1)
        // Real timer signals cannot expire a deadline on a frozen clock.
        try await Task.sleep(for: .milliseconds(40))
        #expect(recorder.wakeHighWatermarks(for: roomID).isEmpty)
        #expect(delivered.load(ordering: .relaxed) == 0)

        clock.withLock { $0 = instant.advanced(by: .milliseconds(20)) }
        // Wake the lane independently of the real timer so the exact
        // deadline boundary is checked even if that timer already fired.
        dispatcher.submit(try natsGroupPayload(roomID: otherRoomID, sequence: 1, revision: 17))
        try await recorder.waitForWakeCount(1)
        try await waitForAtomic(delivered, toReach: 1)
        #expect(recorder.wakeHighWatermarks(for: roomID) == [12])
        #expect(delivered.load(ordering: .relaxed) == 1)
        #expect(deferred.load(ordering: .relaxed) == 1)
    }

    @Test("live watermark advances only after local fanout returns")
    func liveWatermarkWaitsForFanoutCompletion() async throws {
        let roomID = try RoomID("00000000-0000-0000-0000-000000000915")
        let recorder = V2NATSNotificationDispatchRecorder()
        let gate = V2NATSNotificationDispatchGate()
        let suppressed = Atomic<Int>(0)
        let dispatcher = V2NATSGroupNotificationDispatcher(
            laneCount: 1,
            capacityPerLane: 8,
            reorderingDelay: .milliseconds(5),
            coveredWakeSuppressedObserver: {
                _ = suppressed.wrappingAdd(1, ordering: .relaxed)
            },
            receiveNotification: { notification in
                recorder.record(notification)
                if case .groupEvents = notification { await gate.wait() }
            }
        )

        dispatcher.submit(try natsGroupPayload(
            roomID: roomID,
            sequence: 7,
            revision: 17
        ))
        try await recorder.waitForCount(1)
        dispatcher.submit(try natsWakePayload(
            roomID: roomID,
            highWatermark: 7
        ))
        #expect(suppressed.load(ordering: .relaxed) == 0)

        await gate.release()
        try await waitForAtomic(suppressed, toReach: 1)
        #expect(recorder.wakeHighWatermarks(for: roomID).isEmpty)
    }

    @Test("a live notification evicted before fanout cannot suppress recovery wake")
    func droppedLiveNotificationDoesNotSuppressWake() async throws {
        let roomID = try RoomID("00000000-0000-0000-0000-000000000916")
        let recorder = V2NATSNotificationDispatchRecorder()
        let suppressed = Atomic<Int>(0)
        let dispatcher = V2NATSGroupNotificationDispatcher(
            laneCount: 1,
            capacityPerLane: 1,
            reorderingDelay: .milliseconds(30),
            coveredWakeSuppressedObserver: {
                _ = suppressed.wrappingAdd(1, ordering: .relaxed)
            },
            receiveNotification: { recorder.record($0) }
        )

        dispatcher.submit(try natsGroupPayload(
            roomID: roomID,
            sequence: 9,
            revision: 17
        ))
        dispatcher.submit(try natsWakePayload(
            roomID: roomID,
            highWatermark: 9
        ))

        try await recorder.waitForWakeCount(1)
        #expect(dispatcher.droppedPayloadCount() == 1)
        #expect(recorder.sequences(for: roomID).isEmpty)
        #expect(recorder.wakeHighWatermarks(for: roomID) == [9])
        #expect(suppressed.load(ordering: .relaxed) == 0)
    }

    @Test("recovery ingestion is not blocked or dropped with slow socket fan-out")
    func recoveryIngestionPrecedesLossySocketFanout() throws {
        let roomID = try RoomID("00000000-0000-0000-0000-000000000911")
        let recoveryCount = Atomic<Int>(0)
        let observedDrops = Atomic<Int>(0)
        let dispatcher = V2NATSGroupNotificationDispatcher(
            laneCount: 1,
            capacityPerLane: 1,
            recordRecoveryNotification: { _ in
                _ = recoveryCount.wrappingAdd(1, ordering: .relaxed)
            },
            droppedPayloadObserver: {
                _ = observedDrops.wrappingAdd(1, ordering: .relaxed)
            },
            receiveNotification: { _ in
                try? await Task.sleep(for: .seconds(1))
            }
        )

        for sequence in 1...100 {
            dispatcher.submit(try natsGroupPayload(
                roomID: roomID,
                sequence: UInt64(sequence),
                revision: 17
            ))
        }

        #expect(recoveryCount.load(ordering: .relaxed) == 100)
        #expect(dispatcher.droppedPayloadCount() > 0)
        #expect(
            observedDrops.load(ordering: .relaxed)
                == Int(dispatcher.droppedPayloadCount())
        )
    }

    @Test("an interested broker reconnects and replays subscriptions after socket loss")
    func reconnectsAndReplaysSubscriptions() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let recorder = V2NATSGroupWakeTestRecorder()
        let losses = Mutex(0)
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(
                    V2NATSReconnectGroupWakeTestHandler(recorder: recorder)
                )
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        do {
            let broker = try makeBroker(
                port: try #require(server.localAddress?.port),
                timeout: 1,
                coverageLost: { losses.withLock { $0 += 1 } }
            )
            let roomID = try RoomID("00000000-0000-0000-0000-000000000910")
            try await broker.activate(roomID: roomID)

            // The first test socket closes itself after confirming activation.
            // No publish or duplicate activation is allowed to trigger healing.
            try await recorder.waitForConnections(2)
            try await recorder.waitForSubscriptions(2)
            let observation = recorder.observation()
            #expect(observation.connectionCount == 2)
            #expect(observation.subscriptionCount == 2)
            #expect(losses.withLock { $0 } == 1)

            await broker.shutdown()
            try await server.close().get()
            try await group.shutdownGracefully()
        } catch {
            try? await server.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    @Test("deactivation during connection replay removes the broker subscription")
    func deactivationDuringReplayCompensatesSubscription() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let recorder = V2NATSDelayedConfirmationRecorder()
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(
                    V2NATSDelayedConfirmationTestHandler(recorder: recorder)
                )
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        do {
            let broker = try makeBroker(port: try #require(server.localAddress?.port), timeout: 1)
            let roomID = try RoomID("00000000-0000-0000-0000-000000000905")
            let activation = Task { try await broker.activate(roomID: roomID) }
            try await recorder.waitForInitialPing()

            await broker.deactivate(roomID: roomID)
            recorder.releaseInitialPong()
            await #expect(throws: CancellationError.self) { try await activation.value }
            try await recorder.waitForUnsubscribe()

            let observation = recorder.observation()
            #expect(observation.subscriptionCount == 1)
            #expect(observation.unsubscribeCount >= 1)
            await broker.shutdown()
            try await server.close().get()
            try await group.shutdownGracefully()
        } catch {
            try? await server.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    private func makeBroker(
        port: Int,
        timeout: TimeInterval,
        token: String? = nil,
        coverageLost: @escaping @Sendable () async -> Void = {}
    ) throws -> V2NATSGroupEventWakeBroker {
        let url = try #require(URL(string: "nats://127.0.0.1:\(port)"))
        return V2NATSGroupEventWakeBroker(
            configuration: try .init(
                url: url,
                subjectPrefix: "imv2.test.group",
                token: token,
                routingKey: Self.routingKey,
                acknowledgementTimeout: timeout
            ),
            coverageLost: coverageLost,
            receiveWake: { _ in }
        )
    }

    private static let routingKey = Data(repeating: 9, count: 32)

    private func authenticatedBody(_ payload: Data, subject: String) -> Data? {
        V2NATSAuthenticatedPayloadCodec.open(
            payload,
            subject: subject,
            routingKey: Self.routingKey
        )
    }
}

private final class V2NATSDelayedConfirmationRecorder: Sendable {
    struct Observation: Sendable {
        var subscriptionCount = 0
        var unsubscribeCount = 0
        var pingCount = 0
    }

    private struct State {
        var observation = Observation()
        var initialChannel: (any Channel)?
        var released = false
    }

    private let state = Mutex(State())

    func record(commands: String, channel: any Channel) -> Int {
        state.withLock { state in
            for line in commands.components(separatedBy: "\r\n") {
                if line.hasPrefix("SUB ") { state.observation.subscriptionCount += 1 }
                if line.hasPrefix("UNSUB ") { state.observation.unsubscribeCount += 1 }
                if line == "PING" { state.observation.pingCount += 1 }
            }
            if state.initialChannel == nil {
                state.initialChannel = channel
                return 0
            }
            return commands.components(separatedBy: "PING\r\n").count - 1
        }
    }

    func releaseInitialPong() {
        let channel = state.withLock { state -> (any Channel)? in
            state.released = true
            return state.initialChannel
        }
        guard let channel else { return }
        var response = channel.allocator.buffer(capacity: 6)
        response.writeString("PONG\r\n")
        channel.writeAndFlush(response, promise: nil)
    }

    func waitForInitialPing() async throws {
        for _ in 0..<100 {
            if state.withLock({ $0.observation.pingCount > 0 }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw V2NATSDelayedConfirmationTestError.timeout
    }

    func waitForUnsubscribe() async throws {
        for _ in 0..<100 {
            if state.withLock({ $0.observation.unsubscribeCount > 0 }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw V2NATSDelayedConfirmationTestError.timeout
    }

    func observation() -> Observation { state.withLock { $0.observation } }
}

private final class V2NATSDelayedConfirmationTestHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private let recorder: V2NATSDelayedConfirmationRecorder

    init(recorder: V2NATSDelayedConfirmationRecorder) { self.recorder = recorder }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let commands = buffer.readString(length: buffer.readableBytes) ?? ""
        let pings = recorder.record(commands: commands, channel: context.channel)
        guard pings > 0 else { return }
        var response = context.channel.allocator.buffer(capacity: pings * 6)
        for _ in 0..<pings { response.writeString("PONG\r\n") }
        context.writeAndFlush(wrapOutboundOut(response), promise: nil)
    }
}

private enum V2NATSDelayedConfirmationTestError: Error { case timeout }

private final class V2NATSSilentGroupWakeTestHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    func channelRead(context _: ChannelHandlerContext, data _: NIOAny) {}
}

private final class V2NATSRejectingGroupWakeTestHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data _: NIOAny) {
        var response = context.channel.allocator.buffer(capacity: 34)
        response.writeString("-ERR 'Authorization Violation'\r\n")
        context.writeAndFlush(wrapOutboundOut(response), promise: nil)
    }
}

private final class V2NATSGroupWakeTestRecorder: Sendable {
    struct Observation: Sendable {
        var connectionCount = 0
        var subscriptionCount = 0
        var publishCount = 0
        var pingCount = 0
        var publishedSubjects: [String] = []
        var publishedPayloads: [Data] = []
        var authenticationTokens: [String] = []
        var legacyTokenFieldCount = 0
    }

    private struct State: Sendable {
        var observation = Observation()
        var pendingBytes: [UInt8] = []
    }

    private let state = Mutex(State())

    func recordConnection() -> Int {
        state.withLock { state in
            state.observation.connectionCount += 1
            return state.observation.connectionCount
        }
    }

    func record(bytes: [UInt8]) -> Int {
        state.withLock { state in
            state.pendingBytes.append(contentsOf: bytes)
            var pings = 0
            while let lineEnd = Self.firstCRLF(in: state.pendingBytes) {
                let lineBytes = state.pendingBytes[..<lineEnd]
                guard let line = String(bytes: lineBytes, encoding: .utf8) else {
                    state.pendingBytes.removeFirst(lineEnd + 2)
                    continue
                }
                if line.hasPrefix("PUB ") {
                    let parts = line.split(separator: " ")
                    guard parts.count == 3,
                          let subject = parts.dropFirst().first.map(String.init),
                          let lengthText = parts.last,
                          let payloadLength = Int(lengthText),
                          payloadLength >= 0
                    else {
                        state.pendingBytes.removeFirst(lineEnd + 2)
                        continue
                    }
                    let payloadStart = lineEnd + 2
                    let commandEnd = payloadStart + payloadLength + 2
                    guard state.pendingBytes.count >= commandEnd else { break }
                    let payload = Data(
                        state.pendingBytes[payloadStart..<(payloadStart + payloadLength)]
                    )
                    state.observation.publishCount += 1
                    state.observation.publishedSubjects.append(subject)
                    state.observation.publishedPayloads.append(payload)
                    state.pendingBytes.removeFirst(commandEnd)
                    continue
                }
                state.pendingBytes.removeFirst(lineEnd + 2)
                if line.hasPrefix("CONNECT "),
                   let jsonStart = line.firstIndex(of: "{") {
                    let encoded = Data(line[jsonStart...].utf8)
                    if let object = try? JSONSerialization.jsonObject(with: encoded)
                        as? [String: Any] {
                        if let token = object["auth_token"] as? String {
                            state.observation.authenticationTokens.append(token)
                        }
                        if object["token"] != nil {
                            state.observation.legacyTokenFieldCount += 1
                        }
                    }
                }
                if line.hasPrefix("SUB ") {
                    state.observation.subscriptionCount += 1
                }
                if line == "PING" {
                    state.observation.pingCount += 1
                    pings += 1
                }
            }
            return pings
        }
    }

    func observation() -> Observation { state.withLock { $0.observation } }

    func waitForConnections(_ expected: Int) async throws {
        try await waitUntil { $0.connectionCount >= expected }
    }

    func waitForSubscriptions(_ expected: Int) async throws {
        try await waitUntil { $0.subscriptionCount >= expected }
    }

    func waitForPublishes(_ expected: Int) async throws {
        try await waitUntil { $0.publishCount >= expected }
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable (Observation) -> Bool
    ) async throws {
        for _ in 0..<400 {
            if predicate(observation()) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw V2NATSDelayedConfirmationTestError.timeout
    }

    private static func firstCRLF(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 2 else { return nil }
        for index in 0..<(bytes.count - 1)
        where bytes[index] == 13 && bytes[index + 1] == 10 {
            return index
        }
        return nil
    }
}

private final class V2NATSConfirmingGroupWakeTestHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private let recorder: V2NATSGroupWakeTestRecorder

    init(recorder: V2NATSGroupWakeTestRecorder) { self.recorder = recorder }

    func channelActive(context: ChannelHandlerContext) {
        _ = recorder.recordConnection()
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        let pings = recorder.record(bytes: bytes)
        guard pings > 0 else { return }
        var response = context.channel.allocator.buffer(capacity: pings * 6)
        for _ in 0..<pings { response.writeString("PONG\r\n") }
        context.writeAndFlush(wrapOutboundOut(response), promise: nil)
    }
}

private final class V2NATSReconnectGroupWakeTestHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let recorder: V2NATSGroupWakeTestRecorder
    private let connectionIndex = Mutex(0)

    init(recorder: V2NATSGroupWakeTestRecorder) { self.recorder = recorder }

    func channelActive(context: ChannelHandlerContext) {
        connectionIndex.withLock { $0 = recorder.recordConnection() }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        let pings = recorder.record(bytes: bytes)
        guard pings > 0 else { return }
        var response = context.channel.allocator.buffer(capacity: pings * 6)
        for _ in 0..<pings { response.writeString("PONG\r\n") }
        let closeFirstConnection = connectionIndex.withLock { $0 == 1 }
        let channel = context.channel
        context.writeAndFlush(wrapOutboundOut(response)).whenComplete { _ in
            guard closeFirstConnection else { return }
            channel.eventLoop.scheduleTask(in: .milliseconds(10)) {
                channel.close(promise: nil)
            }
        }
    }
}

private final class V2NATSNotificationDispatchRecorder: Sendable {
    private struct State: Sendable {
        var sequencesByRoom: [RoomID: [UInt64]] = [:]
        var wakeHighWatermarksByRoom: [RoomID: [UInt64]] = [:]
        var count = 0
    }

    private let state = Mutex(State())

    func record(_ notification: V2ForegroundGroupEventNotification) {
        switch notification {
        case .wake(let wake):
            state.withLock {
                $0.wakeHighWatermarksByRoom[wake.roomID, default: []]
                    .append(wake.highWatermark)
            }
        case .groupEvents(let events):
            guard let roomID = events.first?.roomID else { return }
            state.withLock { state in
                state.sequencesByRoom[roomID, default: []].append(
                    contentsOf: events.map(\.roomSequence)
                )
                state.count += events.count
            }
        case .directEvent:
            break
        }
    }

    func waitForCount(_ expected: Int) async throws {
        for _ in 0..<400 {
            if state.withLock({ $0.count >= expected }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw V2NATSDelayedConfirmationTestError.timeout
    }

    func waitForWakeCount(_ expected: Int) async throws {
        for _ in 0..<400 {
            let count = state.withLock {
                $0.wakeHighWatermarksByRoom.values.reduce(0) {
                    $0 + $1.count
                }
            }
            if count >= expected { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw V2NATSDelayedConfirmationTestError.timeout
    }

    func sequences(for roomID: RoomID) -> [UInt64] {
        state.withLock { $0.sequencesByRoom[roomID] ?? [] }
    }

    func wakeHighWatermarks(for roomID: RoomID) -> [UInt64] {
        state.withLock { $0.wakeHighWatermarksByRoom[roomID] ?? [] }
    }
}

private actor V2NATSNotificationDispatchGate {
    private var isReleased = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        isReleased = true
        waiter?.resume()
        waiter = nil
    }
}

private func waitForAtomic(
    _ value: borrowing Atomic<Int>,
    toReach expected: Int
) async throws {
    for _ in 0..<400 {
        if value.load(ordering: .relaxed) >= expected { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw V2NATSDelayedConfirmationTestError.timeout
}

private func natsGroupEvent(
    roomID: RoomID,
    sequence: UInt64,
    revision: UInt64,
    payload: Data? = nil
) throws -> V2DirectRoomLiveEvent {
    try .init(
        roomID: roomID,
        highWatermark: sequence,
        sourceEventID: .init(String(
            format: "00000000-0000-0000-0006-%012llx", sequence
        )),
        roomSequence: sequence,
        projectionKind: "message",
        payload: payload ?? Data("event-\(sequence)".utf8),
        recipientUserIDs: [],
        groupMembershipRevision: revision,
        acceptedMembershipRevision: revision
    )
}

private func natsGroupPayload(
    roomID: RoomID,
    sequence: UInt64,
    revision: UInt64
) throws -> Data {
    try natsGroupBatchPayload(events: [natsGroupEvent(
        roomID: roomID,
        sequence: sequence,
        revision: revision
    )])
}

private func natsGroupBatchPayload(
    events: [V2DirectRoomLiveEvent]
) throws -> Data {
    try V2NATSGroupEventProtobufCodec.encode(.groupEvents(events))
}

private func natsWakePayload(
    roomID: RoomID,
    highWatermark: UInt64
) throws -> Data {
    try V2NATSGroupEventProtobufCodec.encode(.wake(.init(roomID: roomID, highWatermark: highWatermark)))
}
