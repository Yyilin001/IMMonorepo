import Foundation
import IMV2Core
import Synchronization
@testable import IMV2Server
import Testing

@Suite("V2 room write service")
struct V2SendMessageServiceTests {
    @Test("secure process identifiers are concurrent-safe and accepted identifiers are UUIDv7")
    func secureProcessIdentifiersAreUniqueAndOrdered() async {
        let generator = V2SecureProcessUUIDGenerator()
        let values = await withTaskGroup(of: [UUID].self, returning: [UUID].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    (0..<256).map { _ in generator.makeOne() }
                }
            }
            var result: [UUID] = []
            result.reserveCapacity(2_048)
            for await batch in group { result.append(contentsOf: batch) }
            return result
        }

        #expect(Set(values).count == values.count)
        for value in values {
            var uuid = value.uuid
            withUnsafeBytes(of: &uuid) { bytes in
                #expect(bytes[6] >> 4 == 4)
                #expect(bytes[8] & 0xc0 == 0x80)
            }
        }
        let acceptedAt = Date(timeIntervalSince1970: 1_645_557_742)
        let triple = generator.makeOrderedTriple(at: acceptedAt)
        #expect(Set([triple.0, triple.1, triple.2]).count == 3)
        for value in [triple.0, triple.1, triple.2] {
            var uuid = value.uuid
            withUnsafeBytes(of: &uuid) { bytes in
                #expect(bytes[6] >> 4 == 7)
                #expect(bytes[8] & 0xc0 == 0x80)
                let milliseconds = bytes.prefix(6).reduce(UInt64(0)) {
                    ($0 << 8) | UInt64($1)
                }
                #expect(milliseconds == 1_645_557_742_000)
            }
        }

        // A local wall-clock correction cannot move subsequently generated
        // identifiers into an older B-tree range.
        let afterClockRollback = generator.makeOrderedTriple(
            at: acceptedAt.addingTimeInterval(-60)
        ).0
        var rollbackUUID = afterClockRollback.uuid
        let rollbackMilliseconds = withUnsafeBytes(of: &rollbackUUID) { bytes in
            bytes.prefix(6).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
        #expect(rollbackMilliseconds == 1_645_557_742_000)

        // The production path expands one 256-bit HMAC result into three
        // disjoint UUIDv7 random regions. Exercise that shared generator under
        // contention so a future layout change cannot overlap regions or
        // reuse a counter value unnoticed.
        let triples = await withTaskGroup(
            of: [(UUID, UUID, UUID)].self,
            returning: [(UUID, UUID, UUID)].self
        ) { group in
            for _ in 0..<8 {
                group.addTask {
                    (0..<256).map { _ in
                        generator.makeOrderedTriple(at: acceptedAt)
                    }
                }
            }
            var result: [(UUID, UUID, UUID)] = []
            result.reserveCapacity(2_048)
            for await batch in group { result.append(contentsOf: batch) }
            return result
        }
        let flattened = triples.flatMap { [$0.0, $0.1, $0.2] }
        #expect(Set(flattened).count == flattened.count)
        for value in flattened {
            var uuid = value.uuid
            withUnsafeBytes(of: &uuid) { bytes in
                #expect(bytes[6] >> 4 == 7)
                #expect(bytes[8] & 0xc0 == 0x80)
            }
        }
    }

    @Test("authenticated actor is persisted as the message sender and retry is idempotent")
    func authenticatedActorAndRetry() async throws {
        let fixture = try Fixture()
        let store = InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.senderID])
        let service = V2SendMessageService(
            store: store,
            capacityProfile: try .init(id: "standard", limits: fixture.profile),
            limits: try V2MessageCommandLimits(maxUTF8Bytes: 64),
            idFactory: V2AcceptanceIDFactory(makeUUID: fixture.nextUUID),
            now: { fixture.now }
        )
        let request = V2AuthenticatedSendMessage(
            roomID: fixture.roomID,
            actorUserID: fixture.senderID,
            clientMessageID: fixture.clientMessageID,
            text: "hello V2"
        )

        let first = try await service.send(request)
        let retry = try await service.send(request)

        guard case .accepted(let accepted) = first else {
            Issue.record("first send must be accepted")
            return
        }
        #expect(accepted.senderUserID == fixture.senderID)
        #expect(retry == .idempotent(accepted))
        let state = try #require(await store.state(for: fixture.roomID))
        #expect(state.0.nextRoomSequence == 2)
        #expect(state.0.admission.commandWindow.used == 1)
    }

    @Test("a rejected admission leaves the room state untouched")
    func rateLimitDoesNotMutateState() async throws {
        var fixture = try Fixture()
        fixture.profile = try RoomCapacityProfile(
            maxEligibleMembers: 10,
            maxCommandsPerWindow: 0,
            maxFanoutUnitsPerWindow: 10,
            maxOutstandingFanoutUnits: 10,
            maxOutstandingPlans: 10,
            maxEnumerationPageSize: 10,
            maxPlannerConcurrency: 1,
            maxDeliveryConcurrency: 1,
            retryAfterSeconds: 7
        )
        let store = InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.senderID])
        let fixedNow = fixture.now
        let service = V2SendMessageService(store: store, capacityProfile: try .init(id: "standard", limits: fixture.profile), limits: try .init(maxUTF8Bytes: 64), now: { fixedNow })

        let outcome = try await service.send(.init(roomID: fixture.roomID, actorUserID: fixture.senderID, clientMessageID: fixture.clientMessageID, text: "blocked"))
        #expect(outcome == .rateLimited(retryAfterSeconds: 7))
        let state = try #require(await store.state(for: fixture.roomID))
        #expect(state.0.nextRoomSequence == 1)
        #expect(state.0.admission.commandWindow.used == 0)
    }

    @Test("a new command from a non-member is rejected before capacity is consumed")
    func nonMemberCannotSend() async throws {
        let fixture = try Fixture()
        let store = InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [])
        let service = V2SendMessageService(
            store: store,
            capacityProfile: try .init(id: "standard", limits: fixture.profile),
            limits: try .init(maxUTF8Bytes: 64),
            now: { fixture.now }
        )

        await #expect(throws: V2RoomWriteStoreError.actorNotEligible) {
            _ = try await service.send(.init(roomID: fixture.roomID, actorUserID: fixture.senderID, clientMessageID: fixture.clientMessageID, text: "forbidden"))
        }
        let state = try #require(await store.state(for: fixture.roomID))
        #expect(state.0.nextRoomSequence == 1)
        #expect(state.0.admission.commandWindow.used == 0)
    }

    @Test("a room cannot use a process-wide profile with the wrong persisted identifier")
    func capacityProfileMustMatchRoomBinding() async throws {
        let fixture = try Fixture()
        let store = InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.senderID], capacityProfileID: "standard")
        let service = V2SendMessageService(
            store: store,
            capacityProfile: try .init(id: "premium", limits: fixture.profile),
            limits: try .init(maxUTF8Bytes: 64),
            now: { fixture.now }
        )
        let request = V2AuthenticatedSendMessage(roomID: fixture.roomID, actorUserID: fixture.senderID, clientMessageID: fixture.clientMessageID, text: "wrong profile")

        await #expect(throws: V2RoomWriteStoreError.capacityProfileMismatch) {
            try await service.send(request)
        }
        let state = try #require(await store.state(for: fixture.roomID))
        #expect(state.0.nextRoomSequence == 1)
    }

    @Test("admission batching waits for an atomic batch and aligns each result")
    func admissionBatchingUsesAtomicStoreAndAlignsResults() async throws {
        let profile = try V2CapacityProfile(id: "standard", limits: Fixture().profile)
        let store = AtomicBatchTestStore()
        let batcher = V2SendMessageAdmissionBatcher(
            store: store,
            configuration: .init(maximumBatchSize: 2, maximumDelay: .seconds(5))
        )
        let service = V2SendMessageService(
            store: store,
            capacityProfile: profile,
            limits: try .init(maxUTF8Bytes: 64),
            batcher: batcher,
            now: { Date(timeIntervalSince1970: 1_750_000_000) }
        )
        let roomID = try RoomID("00000000-0000-0000-0000-000000000111")
        let secondRoomID = try RoomID("00000000-0000-0000-0000-000000000115")
        let senderID = try UserID("00000000-0000-0000-0000-000000000112")
        let firstID = try ClientMessageID("00000000-0000-0000-0000-000000000113")
        let secondID = try ClientMessageID("00000000-0000-0000-0000-000000000114")

        async let first = service.send(.init(
            roomID: roomID,
            actorUserID: senderID,
            clientMessageID: firstID,
            text: "one"
        ))
        async let second = service.send(.init(
            roomID: secondRoomID,
            actorUserID: senderID,
            clientMessageID: secondID,
            text: "two"
        ))
        let outcomes = try await [first, second]

        #expect(outcomes == [
            .rateLimited(retryAfterSeconds: 7),
            .rateLimited(retryAfterSeconds: 8),
        ])
        #expect(await store.normalAcceptCallCount() == 0)
        let batches = await store.batches()
        #expect(batches.count == 1)
        #expect(Set(batches[0]) == Set([firstID, secondID]))
        let snapshot = await batcher.snapshot()
        #expect(snapshot.atomicBatchAttempts == 1)
        #expect(snapshot.atomicBatchCommitted == 1)
        #expect(snapshot.atomicBatchCommittedRequests == 2)
        #expect(snapshot.atomicBatchFallbacks == 0)
        #expect(snapshot.singletonDispatches == 0)
    }

    @Test("hot rooms use ordered unique-room waves without abandoning atomic batches")
    func admissionBatchingUsesOrderedUniqueRoomWaves() async throws {
        let profile = try V2CapacityProfile(id: "standard", limits: Fixture().profile)
        let store = AtomicBatchTestStore()
        let batcher = V2SendMessageAdmissionBatcher(
            store: store,
            configuration: .init(maximumBatchSize: 4, maximumDelay: .seconds(5))
        )
        let service = V2SendMessageService(
            store: store,
            capacityProfile: profile,
            limits: try .init(maxUTF8Bytes: 64),
            batcher: batcher,
            now: { Date(timeIntervalSince1970: 1_750_000_000) }
        )
        let firstRoomID = try RoomID("00000000-0000-0000-0000-000000000116")
        let secondRoomID = try RoomID("00000000-0000-0000-0000-000000000120")
        let senderID = try UserID("00000000-0000-0000-0000-000000000117")
        let firstID = try ClientMessageID("00000000-0000-0000-0000-000000000118")
        let secondID = try ClientMessageID("00000000-0000-0000-0000-000000000119")
        let thirdID = try ClientMessageID("00000000-0000-0000-0000-000000000121")
        let fourthID = try ClientMessageID("00000000-0000-0000-0000-000000000122")

        let first = Task { try await service.send(.init(
            roomID: firstRoomID, actorUserID: senderID,
            clientMessageID: firstID, text: "one"
        )) }
        while await batcher.snapshot().pendingRequests != 1 {
            await Task.yield()
        }
        let second = Task { try await service.send(.init(
            roomID: firstRoomID, actorUserID: senderID,
            clientMessageID: secondID, text: "two"
        )) }
        while await batcher.snapshot().pendingRequests != 2 {
            await Task.yield()
        }
        let third = Task { try await service.send(.init(
            roomID: secondRoomID, actorUserID: senderID,
            clientMessageID: thirdID, text: "three"
        )) }
        while await batcher.snapshot().pendingRequests != 3 {
            await Task.yield()
        }
        let fourth = Task { try await service.send(.init(
            roomID: secondRoomID, actorUserID: senderID,
            clientMessageID: fourthID, text: "four"
        )) }
        _ = try await [first.value, second.value, third.value, fourth.value]

        #expect(await store.normalAcceptCallCount() == 0)
        #expect(await store.batches() == [
            [firstID, thirdID],
            [secondID, fourthID],
        ])
        let snapshot = await batcher.snapshot()
        #expect(snapshot.atomicBatchCommitted == 2)
        #expect(snapshot.atomicBatchCommittedRequests == 4)
        #expect(snapshot.sameRoomDeferredRequests == 2)
        #expect(snapshot.activeRooms == 0)
    }

    @Test("an opt-in partition batches repeated hot rooms in arrival order")
    func admissionBatchingUsesOneRepeatedRoomAtomicPartition() async throws {
        let profile = try V2CapacityProfile(id: "standard", limits: Fixture().profile)
        let store = AtomicBatchTestStore(repeatedRoomBatchingEnabled: true)
        let batcher = V2SendMessageAdmissionBatcher(
            store: store,
            configuration: .init(maximumBatchSize: 4, maximumDelay: .seconds(5))
        )
        let service = V2SendMessageService(
            store: store,
            capacityProfile: profile,
            limits: try .init(maxUTF8Bytes: 64),
            batcher: batcher
        )
        let firstRoomID = try RoomID("00000000-0000-0000-0000-000000000216")
        let secondRoomID = try RoomID("00000000-0000-0000-0000-000000000220")
        let senderID = try UserID("00000000-0000-0000-0000-000000000217")
        let ids = try (1 ... 4).map {
            try ClientMessageID(String(format: "00000000-0000-0000-0005-%012x", $0))
        }
        let rooms = [firstRoomID, firstRoomID, secondRoomID, secondRoomID]

        var tasks: [Task<V2SendMessageOutcome, any Error>] = []
        for index in ids.indices {
            tasks.append(Task {
                try await service.send(.init(
                    roomID: rooms[index], actorUserID: senderID,
                    clientMessageID: ids[index], text: "message \(index)"
                ))
            })
            if index < ids.count - 1 {
                while await batcher.snapshot().pendingRequests != index + 1 {
                    await Task.yield()
                }
            }
        }
        for task in tasks { _ = try await task.value }

        #expect(await store.normalAcceptCallCount() == 0)
        // The fairness pass selects one request per room before filling with
        // hot-room followers; order within each room remains FIFO.
        #expect(await store.batches() == [[ids[0], ids[2], ids[1], ids[3]]])
        let snapshot = await batcher.snapshot()
        #expect(snapshot.atomicBatchCommitted == 1)
        #expect(snapshot.atomicBatchCommittedRequests == 4)
    }

    @Test("a cache transition retains same-room FIFO across unique-room waves")
    func admissionBatchingKeepsOneRoomFIFOAcrossPartitionChanges() async throws {
        let profile = try V2CapacityProfile(id: "standard", limits: Fixture().profile)
        let acceleratedID = try ClientMessageID("00000000-0000-0000-0000-000000000209")
        let store = AtomicBatchTestStore(
            acceleratedClientMessageIDs: [acceleratedID]
        )
        let batcher = V2SendMessageAdmissionBatcher(
            store: store,
            configuration: .init(maximumBatchSize: 2, maximumDelay: .seconds(5))
        )
        let service = V2SendMessageService(
            store: store,
            capacityProfile: profile,
            limits: try .init(maxUTF8Bytes: 64),
            batcher: batcher
        )
        let roomID = try RoomID("00000000-0000-0000-0000-000000000207")
        let senderID = try UserID("00000000-0000-0000-0000-000000000208")
        let standardID = try ClientMessageID("00000000-0000-0000-0000-000000000210")

        let accelerated = Task { try await service.send(.init(
            roomID: roomID, actorUserID: senderID,
            clientMessageID: acceleratedID, text: "accelerated"
        )) }
        while await batcher.snapshot().pendingRequests != 1 {
            await Task.yield()
        }
        let standard = Task { try await service.send(.init(
            roomID: roomID, actorUserID: senderID,
            clientMessageID: standardID, text: "standard"
        )) }
        _ = try await [accelerated.value, standard.value]

        let batches = await store.batches()
        #expect(batches.isEmpty)
        #expect(await store.normalAcceptedClientMessageIDs() == [acceleratedID, standardID])
    }

    @Test("adaptive batching keeps the short delay until sustained arrivals are observed")
    func admissionBatchingUsesHighActivityDelayOnlyAfterArrivalThreshold() async throws {
        let profile = try V2CapacityProfile(id: "standard", limits: Fixture().profile)
        let store = AtomicBatchTestStore()
        let batcher = V2SendMessageAdmissionBatcher(
            store: store,
            configuration: .init(
                maximumBatchSize: 2,
                maximumDelay: .seconds(5),
                adaptiveDelayPolicy: .init(
                    highActivityMaximumDelay: .seconds(6),
                    minimumRequestsInWindow: 2,
                    observationWindow: .seconds(1)
                )
            )
        )
        let service = V2SendMessageService(
            store: store,
            capacityProfile: profile,
            limits: try .init(maxUTF8Bytes: 64),
            batcher: batcher
        )
        let senderID = try UserID("00000000-0000-0000-0000-000000000192")

        async let first = service.send(.init(
            roomID: try RoomID("00000000-0000-0000-0000-000000000191"),
            actorUserID: senderID,
            clientMessageID: try ClientMessageID("00000000-0000-0000-0000-000000000193"),
            text: "one"
        ))
        async let second = service.send(.init(
            roomID: try RoomID("00000000-0000-0000-0000-000000000194"),
            actorUserID: senderID,
            clientMessageID: try ClientMessageID("00000000-0000-0000-0000-000000000195"),
            text: "two"
        ))
        _ = try await [first, second]
        #expect(await batcher.snapshot().baseDelayFlushes == 0)
        #expect(await batcher.snapshot().highActivityDelayFlushes == 0)

        let waiting = Task {
            try await service.send(.init(
                roomID: try RoomID("00000000-0000-0000-0000-000000000196"),
                actorUserID: senderID,
                clientMessageID: try ClientMessageID("00000000-0000-0000-0000-000000000197"),
                text: "three"
            ))
        }
        while await batcher.snapshot().pendingRequests != 1 {
            await Task.yield()
        }
        let snapshot = await batcher.snapshot()
        #expect(snapshot.highActivityDelayScheduled)
        #expect(snapshot.baseDelayFlushes == 0)
        #expect(snapshot.highActivityDelayFlushes == 0)

        waiting.cancel()
        await #expect(throws: CancellationError.self) {
            try await waiting.value
        }
    }

    @Test("an in-flight batch cannot bypass its successor aggregation timer")
    func admissionBatchingRetainsSuccessorAggregationWindow() async throws {
        let profile = try V2CapacityProfile(id: "standard", limits: Fixture().profile)
        let store = AtomicBatchTestStore(
            repeatedRoomBatchingEnabled: true,
            atomicBatchDelay: .milliseconds(40)
        )
        let batcher = V2SendMessageAdmissionBatcher(
            store: store,
            configuration: .init(
                maximumBatchSize: 2,
                maximumDelay: .milliseconds(80),
                adaptiveDelayPolicy: .init(
                    highActivityMaximumDelay: .milliseconds(500),
                    minimumRequestsInWindow: 2,
                    observationWindow: .seconds(1)
                )
            )
        )
        let service = V2SendMessageService(
            store: store,
            capacityProfile: profile,
            limits: try .init(maxUTF8Bytes: 64),
            batcher: batcher
        )
        let roomID = try RoomID("00000000-0000-0000-0000-000000000198")
        let senderID = try UserID("00000000-0000-0000-0000-000000000199")
        let ids = try (1 ... 3).map {
            try ClientMessageID(String(format: "00000000-0000-0000-0006-%012x", $0))
        }

        let first = Task { try await service.send(.init(
            roomID: roomID, actorUserID: senderID,
            clientMessageID: ids[0], text: "one"
        )) }
        while await batcher.snapshot().pendingRequests != 1 {
            await Task.yield()
        }
        let second = Task { try await service.send(.init(
            roomID: roomID, actorUserID: senderID,
            clientMessageID: ids[1], text: "two"
        )) }
        while await store.batches().isEmpty {
            await Task.yield()
        }
        let successor = Task { try await service.send(.init(
            roomID: roomID, actorUserID: senderID,
            clientMessageID: ids[2], text: "three"
        )) }

        _ = try await [first.value, second.value]
        // The first transaction completed well before the successor's 500 ms
        // high-activity deadline. It must retain the bounded 80 ms successor
        // opportunity instead of becoming a singleton at DB completion.
        #expect(await batcher.snapshot().pendingRequests == 1)
        #expect(await store.normalAcceptCallCount() == 0)
        #expect(await batcher.snapshot().highActivityDelayScheduled)

        _ = try await successor.value
        #expect(await store.normalAcceptCallCount() == 1)
        #expect(await batcher.snapshot().highActivityDelayFlushes == 1)
    }

    @Test("one atomic batch owns one foreground database admission")
    func admissionBatchingOwnsOneDatabasePermitPerAtomicBatch() async throws {
        let profile = try V2CapacityProfile(id: "standard", limits: Fixture().profile)
        let store = AtomicBatchTestStore()
        let admission = V2DatabaseWorkAdmissionController(policy: .init(
            maximumForegroundWriteInFlight: 1,
            maximumInteractiveReadInFlight: 1,
            maximumSyncInFlight: 1,
            maximumForegroundWriteQueued: 4,
            maximumInteractiveReadQueued: 1,
            maximumSyncQueued: 1,
            timeout: .seconds(1)
        ))
        let batcher = V2SendMessageAdmissionBatcher(
            store: store,
            configuration: .init(maximumBatchSize: 2, maximumDelay: .seconds(5)),
            databaseWorkAdmission: admission
        )
        let service = V2SendMessageService(
            store: store,
            capacityProfile: profile,
            limits: try .init(maxUTF8Bytes: 64),
            batcher: batcher
        )
        let senderID = try UserID("00000000-0000-0000-0000-000000000152")
        async let first = service.send(.init(
            roomID: try RoomID("00000000-0000-0000-0000-000000000151"),
            actorUserID: senderID,
            clientMessageID: try ClientMessageID("00000000-0000-0000-0000-000000000153"),
            text: "one"
        ))
        async let second = service.send(.init(
            roomID: try RoomID("00000000-0000-0000-0000-000000000154"),
            actorUserID: senderID,
            clientMessageID: try ClientMessageID("00000000-0000-0000-0000-000000000155"),
            text: "two"
        ))

        _ = try await [first, second]
        let snapshot = await admission.snapshot()
        #expect(snapshot.foregroundWrite.admittedRequests == 1)
        #expect(snapshot.foregroundWrite.inFlight == 0)
        #expect(await store.batches().count == 1)
    }

    @Test("batch staging queue is bounded and pending cancellation removes its request")
    func admissionBatchingBoundsAndCancelsStagedRequests() async throws {
        let profile = try V2CapacityProfile(id: "standard", limits: Fixture().profile)
        let store = AtomicBatchTestStore()
        let batcher = V2SendMessageAdmissionBatcher(
            store: store,
            configuration: .init(
                maximumBatchSize: 2,
                maximumDelay: .seconds(5),
                maximumPendingRequests: 1
            )
        )
        let service = V2SendMessageService(
            store: store,
            capacityProfile: profile,
            limits: try .init(maxUTF8Bytes: 64),
            batcher: batcher
        )
        let senderID = try UserID("00000000-0000-0000-0000-000000000162")
        let waiting = Task {
            try await service.send(.init(
                roomID: try RoomID("00000000-0000-0000-0000-000000000161"),
                actorUserID: senderID,
                clientMessageID: try ClientMessageID("00000000-0000-0000-0000-000000000163"),
                text: "one"
            ))
        }
        while await batcher.snapshot().pendingRequests != 1 {
            await Task.yield()
        }
        await #expect(throws: V2SendMessageAdmissionBatcherError.serverBusy) {
            try await service.send(.init(
                roomID: try RoomID("00000000-0000-0000-0000-000000000164"),
                actorUserID: senderID,
                clientMessageID: try ClientMessageID("00000000-0000-0000-0000-000000000165"),
                text: "two"
            ))
        }
        #expect(await batcher.snapshot().stagingQueueFullRejections == 1)

        waiting.cancel()
        await #expect(throws: CancellationError.self) {
            try await waiting.value
        }
        while await batcher.snapshot().pendingRequests != 0 {
            await Task.yield()
        }
        #expect(await batcher.snapshot().cancelledPendingRequests == 1)
    }

    @Test("an atomic batch failure is returned to each waiting command")
    func admissionBatchingPropagatesAtomicFailure() async throws {
        let profile = try V2CapacityProfile(id: "standard", limits: Fixture().profile)
        let store = AtomicBatchTestStore(shouldFail: true)
        let observer = RecordingCommittedMessageObserver()
        let batcher = V2SendMessageAdmissionBatcher(
            store: store,
            configuration: .init(maximumBatchSize: 2, maximumDelay: .seconds(5)),
            committedMessageObserver: observer
        )
        let service = V2SendMessageService(
            store: store,
            capacityProfile: profile,
            limits: try .init(maxUTF8Bytes: 64),
            batcher: batcher
        )
        let roomID = try RoomID("00000000-0000-0000-0000-000000000121")
        let secondRoomID = try RoomID("00000000-0000-0000-0000-000000000125")
        let senderID = try UserID("00000000-0000-0000-0000-000000000122")

        async let first = captureSendOutcome { try await service.send(.init(
            roomID: roomID,
            actorUserID: senderID,
            clientMessageID: try ClientMessageID("00000000-0000-0000-0000-000000000123"),
            text: "one"
        )) }
        async let second = captureSendOutcome { try await service.send(.init(
            roomID: secondRoomID,
            actorUserID: senderID,
            clientMessageID: try ClientMessageID("00000000-0000-0000-0000-000000000124"),
            text: "two"
        )) }

        let outcomes = await [first, second]
        for outcome in outcomes {
            guard case .failure(let error) = outcome else {
                Issue.record("an atomic batch failure must fail every request")
                continue
            }
            #expect(error as? V2RoomWriteStoreError == .corruptPersistenceState)
        }
        #expect(await store.normalAcceptCallCount() == 0)
        #expect(await store.batches().count == 1)
        #expect(observer.roomSequences().isEmpty)
    }

    @Test("an unsupported batch shape falls back without exposing an optimisation failure")
    func admissionBatchingFallsBackToOrdinaryAcceptance() async throws {
        let profile = try V2CapacityProfile(id: "standard", limits: Fixture().profile)
        let store = AtomicBatchTestStore(shouldDeclineBatch: true)
        let observer = RecordingCommittedMessageObserver()
        let batcher = V2SendMessageAdmissionBatcher(
            store: store,
            configuration: .init(maximumBatchSize: 2, maximumDelay: .seconds(5)),
            committedMessageObserver: observer
        )
        let service = V2SendMessageService(
            store: store,
            capacityProfile: profile,
            limits: try .init(maxUTF8Bytes: 64),
            batcher: batcher
        )
        let roomID = try RoomID("00000000-0000-0000-0000-000000000131")
        let secondRoomID = try RoomID("00000000-0000-0000-0000-000000000135")
        let senderID = try UserID("00000000-0000-0000-0000-000000000132")

        async let first = service.send(.init(
            roomID: roomID,
            actorUserID: senderID,
            clientMessageID: try ClientMessageID("00000000-0000-0000-0000-000000000133"),
            text: "rich one"
        ))
        async let second = service.send(.init(
            roomID: secondRoomID,
            actorUserID: senderID,
            clientMessageID: try ClientMessageID("00000000-0000-0000-0000-000000000134"),
            text: "rich two"
        ))

        #expect(try await [first, second] == [
            .unavailable(.missingShardLease),
            .unavailable(.missingShardLease),
        ])
        #expect(await store.batches().count == 1)
        #expect(await store.normalAcceptCallCount() == 2)
        let snapshot = await batcher.snapshot()
        #expect(snapshot.atomicBatchAttempts == 1)
        #expect(snapshot.atomicBatchCommitted == 0)
        #expect(snapshot.atomicBatchFallbacks == 1)
        #expect(snapshot.atomicBatchFallbackRequests == 2)
        #expect(snapshot.atomicBatchFallbackReasons[.requestShape] == 1)
        #expect(observer.roomSequences().isEmpty)
    }

    @Test("fallback returns each independent command's own result")
    func admissionBatchingFallbackDoesNotSpreadOneCommandFailure() async throws {
        let profile = try V2CapacityProfile(id: "standard", limits: Fixture().profile)
        let failedID = try ClientMessageID("00000000-0000-0000-0000-000000000174")
        let store = AtomicBatchTestStore(
            shouldDeclineBatch: true,
            failingNormalClientMessageIDs: [failedID]
        )
        let batcher = V2SendMessageAdmissionBatcher(
            store: store,
            configuration: .init(maximumBatchSize: 2, maximumDelay: .seconds(5))
        )
        let service = V2SendMessageService(
            store: store,
            capacityProfile: profile,
            limits: try .init(maxUTF8Bytes: 64),
            batcher: batcher
        )
        let senderID = try UserID("00000000-0000-0000-0000-000000000171")
        async let first = captureSendOutcome { try await service.send(.init(
            roomID: try RoomID("00000000-0000-0000-0000-000000000172"),
            actorUserID: senderID,
            clientMessageID: try ClientMessageID("00000000-0000-0000-0000-000000000173"),
            text: "one"
        )) }
        async let second = captureSendOutcome { try await service.send(.init(
            roomID: try RoomID("00000000-0000-0000-0000-000000000175"),
            actorUserID: senderID,
            clientMessageID: failedID,
            text: "two"
        )) }

        let firstResult = await first
        guard case .success(let firstOutcome) = firstResult else {
            Issue.record("the unrelated fallback command must complete")
            return
        }
        #expect(firstOutcome == .unavailable(.missingShardLease))
        let secondResult = await second
        guard case .failure(let error) = secondResult else {
            Issue.record("the failing command must keep its own error")
            return
        }
        #expect(error as? V2RoomWriteStoreError == .actorNotEligible)
    }

    @Test("one incompatible room is isolated without abandoning the compatible batch")
    func admissionBatchingIsolatesKnownIncompatibleRequest() async throws {
        let profile = try V2CapacityProfile(id: "standard", limits: Fixture().profile)
        let isolatedID = try ClientMessageID(
            "00000000-0000-0000-0000-000000000179"
        )
        let store = AtomicBatchTestStore(
            isolatedBatchClientMessageIDs: [isolatedID]
        )
        let batcher = V2SendMessageAdmissionBatcher(
            store: store,
            configuration: .init(maximumBatchSize: 3, maximumDelay: .seconds(5))
        )
        let service = V2SendMessageService(
            store: store,
            capacityProfile: profile,
            limits: try .init(maxUTF8Bytes: 64),
            batcher: batcher
        )
        let senderID = try UserID("00000000-0000-0000-0000-000000000176")
        let firstID = try ClientMessageID("00000000-0000-0000-0000-000000000177")
        let thirdID = try ClientMessageID("00000000-0000-0000-0000-000000000180")

        async let first = service.send(.init(
            roomID: try RoomID("00000000-0000-0000-0000-000000000181"),
            actorUserID: senderID, clientMessageID: firstID, text: "one"
        ))
        async let isolated = service.send(.init(
            roomID: try RoomID("00000000-0000-0000-0000-000000000182"),
            actorUserID: senderID, clientMessageID: isolatedID, text: "isolated"
        ))
        async let third = service.send(.init(
            roomID: try RoomID("00000000-0000-0000-0000-000000000183"),
            actorUserID: senderID, clientMessageID: thirdID, text: "three"
        ))

        #expect(try await [first, isolated, third] == [
            .rateLimited(retryAfterSeconds: 7),
            .unavailable(.missingShardLease),
            .rateLimited(retryAfterSeconds: 8),
        ])
        let batches = await store.batches()
        #expect(batches.count == 2)
        #expect(Set(batches[0]) == Set([firstID, isolatedID, thirdID]))
        #expect(Set(batches[1]) == Set([firstID, thirdID]))
        #expect(await store.normalAcceptedClientMessageIDs() == [isolatedID])
        let snapshot = await batcher.snapshot()
        #expect(snapshot.atomicBatchAttempts == 2)
        #expect(snapshot.atomicBatchCommitted == 1)
        #expect(snapshot.atomicBatchFallbacks == 1)
        #expect(snapshot.atomicBatchCommittedRequests == 2)
        #expect(snapshot.atomicBatchFallbackRequests == 3)
        #expect(snapshot.atomicPreclassifiedIndividualRequests == 1)
        #expect(snapshot.atomicBatchFallbackReasons[.capacityProfileMismatch] == 1)
    }

    @Test("preclassified requests do not make compatible rooms abandon their atomic append")
    func admissionBatchingSeparatesPreclassifiedRequests() async throws {
        let profile = try V2CapacityProfile(id: "standard", limits: Fixture().profile)
        let individuallyAcceptedID = try ClientMessageID("00000000-0000-0000-0000-000000000184")
        let store = AtomicBatchTestStore(
            preclassifiedClientMessageIDs: [individuallyAcceptedID]
        )
        let batcher = V2SendMessageAdmissionBatcher(
            store: store,
            configuration: .init(maximumBatchSize: 3, maximumDelay: .seconds(5))
        )
        let service = V2SendMessageService(
            store: store,
            capacityProfile: profile,
            limits: try .init(maxUTF8Bytes: 64),
            batcher: batcher
        )
        let senderID = try UserID("00000000-0000-0000-0000-000000000181")

        async let first = service.send(.init(
            roomID: try RoomID("00000000-0000-0000-0000-000000000182"),
            actorUserID: senderID,
            clientMessageID: try ClientMessageID("00000000-0000-0000-0000-000000000183"),
            text: "first"
        ))
        async let individual = service.send(.init(
            roomID: try RoomID("00000000-0000-0000-0000-000000000185"),
            actorUserID: senderID,
            clientMessageID: individuallyAcceptedID,
            text: "individual"
        ))
        async let third = service.send(.init(
            roomID: try RoomID("00000000-0000-0000-0000-000000000186"),
            actorUserID: senderID,
            clientMessageID: try ClientMessageID("00000000-0000-0000-0000-000000000187"),
            text: "third"
        ))

        #expect(try await [first, individual, third] == [
            .rateLimited(retryAfterSeconds: 8),
            .unavailable(.missingShardLease),
            .rateLimited(retryAfterSeconds: 8),
        ])
        #expect(await store.batches().count == 1)
        #expect(await store.batches().first?.count == 2)
        #expect(await store.normalAcceptCallCount() == 1)
        let snapshot = await batcher.snapshot()
        #expect(snapshot.atomicBatchAttempts == 1)
        #expect(snapshot.atomicBatchCommitted == 1)
        #expect(snapshot.atomicBatchCommittedRequests == 2)
        #expect(snapshot.atomicPreclassifiedIndividualRequests == 1)
    }

    @Test("independent compatibility classes retain separate atomic batches")
    func admissionBatchingSeparatesCompatibilityClasses() async throws {
        let profile = try V2CapacityProfile(id: "standard", limits: Fixture().profile)
        let acceleratedIDs: Set<ClientMessageID> = [
            try .init("00000000-0000-0000-0000-000000000204"),
            try .init("00000000-0000-0000-0000-000000000206"),
        ]
        let store = AtomicBatchTestStore(acceleratedClientMessageIDs: acceleratedIDs)
        let batcher = V2SendMessageAdmissionBatcher(
            store: store,
            configuration: .init(maximumBatchSize: 4, maximumDelay: .seconds(5))
        )
        let service = V2SendMessageService(
            store: store, capacityProfile: profile,
            limits: try .init(maxUTF8Bytes: 64), batcher: batcher
        )
        let senderID = try UserID("00000000-0000-0000-0000-000000000200")
        let tasks = (1...4).map { value in
            Task {
                try await service.send(.init(
                    roomID: try .init(String(format:
                        "00000000-0000-0000-0000-%012d", 200 + value
                    )),
                    actorUserID: senderID,
                    clientMessageID: try .init(String(format:
                        "00000000-0000-0000-0000-%012d", 202 + value
                    )),
                    text: "message-\(value)"
                ))
            }
        }
        for task in tasks { _ = try await task.value }

        let batches = await store.batches()
        #expect(batches.count == 2)
        #expect(batches.allSatisfy { $0.count == 2 })
        #expect(await store.normalAcceptCallCount() == 0)
        let snapshot = await batcher.snapshot()
        #expect(snapshot.atomicBatchAttempts == 2)
        #expect(snapshot.atomicBatchCommitted == 2)
        #expect(snapshot.atomicBatchCommittedRequests == 4)
    }

    @Test("independent room batches use bounded parallelism")
    func admissionBatchingUsesBoundedParallelismAcrossIndependentRooms() async throws {
        let profile = try V2CapacityProfile(id: "standard", limits: Fixture().profile)
        let store = ConcurrentAtomicBatchTestStore()
        let batcher = V2SendMessageAdmissionBatcher(
            store: store,
            configuration: .init(
                maximumBatchSize: 2,
                maximumDelay: .seconds(5),
                maximumInFlightBatches: 2
            )
        )
        let service = V2SendMessageService(
            store: store,
            capacityProfile: profile,
            limits: try .init(maxUTF8Bytes: 64),
            batcher: batcher
        )
        let senderID = try UserID("00000000-0000-0000-0000-000000000141")

        async let first = service.send(.init(
            roomID: try RoomID("00000000-0000-0000-0000-000000000142"),
            actorUserID: senderID,
            clientMessageID: try ClientMessageID("00000000-0000-0000-0000-000000000143"),
            text: "one"
        ))
        async let second = service.send(.init(
            roomID: try RoomID("00000000-0000-0000-0000-000000000144"),
            actorUserID: senderID,
            clientMessageID: try ClientMessageID("00000000-0000-0000-0000-000000000145"),
            text: "two"
        ))
        async let third = service.send(.init(
            roomID: try RoomID("00000000-0000-0000-0000-000000000146"),
            actorUserID: senderID,
            clientMessageID: try ClientMessageID("00000000-0000-0000-0000-000000000147"),
            text: "three"
        ))
        async let fourth = service.send(.init(
            roomID: try RoomID("00000000-0000-0000-0000-000000000148"),
            actorUserID: senderID,
            clientMessageID: try ClientMessageID("00000000-0000-0000-0000-000000000149"),
            text: "four"
        ))

        _ = try await [first, second, third, fourth]
        #expect(await store.maximumInFlightBatchCount() == 2)
    }

    @Test("room-keyed lanes are stable and execute independent rooms concurrently")
    func shardedAdmissionKeepsRoomAffinityAndRunsLanesConcurrently() async throws {
        let profile = try V2CapacityProfile(id: "standard", limits: Fixture().profile)
        let store = ConcurrentAtomicBatchTestStore()
        let batcher = V2ShardedSendMessageAdmissionBatcher(
            store: store,
            configuration: .init(
                maximumBatchSize: 2,
                maximumDelay: .seconds(5),
                maximumInFlightBatches: 2,
                maximumPendingRequests: 4
            ),
            laneCount: 2
        )
        let service = V2SendMessageService(
            store: store,
            capacityProfile: profile,
            limits: try .init(maxUTF8Bytes: 64),
            batcher: batcher
        )
        var roomsByLane = [[RoomID](), [RoomID]()]
        var candidate = 1
        while roomsByLane.contains(where: { $0.count < 2 }) {
            let roomID = try RoomID(String(format:
                "10000000-0000-0000-0000-%012d", candidate
            ))
            let lane = V2ShardedSendMessageAdmissionBatcher.laneIndex(
                for: roomID, laneCount: 2
            )
            if roomsByLane[lane].count < 2 {
                roomsByLane[lane].append(roomID)
            }
            candidate += 1
        }
        for room in roomsByLane.joined() {
            #expect(V2ShardedSendMessageAdmissionBatcher.laneIndex(
                for: room, laneCount: 2
            ) == V2ShardedSendMessageAdmissionBatcher.laneIndex(
                for: room, laneCount: 2
            ))
        }
        let senderID = try UserID("10000000-0000-0000-0000-000000000100")
        let rooms = roomsByLane.joined().map { $0 }
        let tasks = rooms.enumerated().map { index, roomID in
            Task {
                try await service.send(.init(
                    roomID: roomID,
                    actorUserID: senderID,
                    clientMessageID: try ClientMessageID(String(format:
                        "20000000-0000-0000-0000-%012d", index + 1
                    )),
                    text: "message-\(index)"
                ))
            }
        }
        for task in tasks {
            _ = try await task.value
        }

        #expect(await store.maximumInFlightBatchCount() == 2)
        let snapshot = await batcher.snapshot()
        #expect(snapshot.laneCount == 2)
        #expect(snapshot.pendingRequests == 0)
        #expect(snapshot.inFlightBatches == 0)
        #expect(snapshot.atomicBatchCommitted == 2)
        #expect(snapshot.atomicBatchCommittedRequests == 4)
    }

    @Test("sharded lanes share one bounded pending budget and cancellation returns capacity")
    func shardedAdmissionSharesPendingCapacityWithoutLeakingIt() async throws {
        let profile = try V2CapacityProfile(id: "standard", limits: Fixture().profile)
        let store = AtomicBatchTestStore()
        let batcher = V2ShardedSendMessageAdmissionBatcher(
            store: store,
            configuration: .init(
                maximumBatchSize: 4,
                maximumDelay: .seconds(30),
                maximumInFlightBatches: 2,
                maximumPendingRequests: 3
            ),
            laneCount: 2
        )
        let service = V2SendMessageService(
            store: store,
            capacityProfile: profile,
            limits: try .init(maxUTF8Bytes: 64),
            batcher: batcher
        )
        var roomByLane: [RoomID?] = [nil, nil]
        var candidate = 1
        while roomByLane.contains(where: { $0 == nil }) {
            let roomID = try RoomID(String(format:
                "30000000-0000-0000-0000-%012d", candidate
            ))
            let lane = V2ShardedSendMessageAdmissionBatcher.laneIndex(
                for: roomID, laneCount: 2
            )
            roomByLane[lane] = roomByLane[lane] ?? roomID
            candidate += 1
        }
        let hotRoomID = try #require(roomByLane[0])
        let otherRoomID = try #require(roomByLane[1])
        let senderID = try UserID("30000000-0000-0000-0000-000000000100")

        func stagedSend(
            roomID: RoomID,
            clientMessageSuffix: Int
        ) -> Task<V2SendMessageOutcome, any Error> {
            Task {
                try await service.send(.init(
                    roomID: roomID,
                    actorUserID: senderID,
                    clientMessageID: try ClientMessageID(String(format:
                        "40000000-0000-0000-0000-%012d", clientMessageSuffix
                    )),
                    text: "message-\(clientMessageSuffix)"
                ))
            }
        }

        let first = stagedSend(roomID: hotRoomID, clientMessageSuffix: 1)
        while await batcher.snapshot().pendingRequests != 1 { await Task.yield() }
        let second = stagedSend(roomID: hotRoomID, clientMessageSuffix: 2)
        while await batcher.snapshot().pendingRequests != 2 { await Task.yield() }
        let third = stagedSend(roomID: hotRoomID, clientMessageSuffix: 3)
        while await batcher.snapshot().pendingRequests != 3 { await Task.yield() }

        // All three requests may borrow the process-wide budget even though
        // they hash to one lane. A fourth request must still be rejected.
        await #expect(throws: V2SendMessageAdmissionBatcherError.serverBusy) {
            try await service.send(.init(
                roomID: otherRoomID,
                actorUserID: senderID,
                clientMessageID: try ClientMessageID(
                    "40000000-0000-0000-0000-000000000004"
                ),
                text: "over-capacity"
            ))
        }
        #expect(await batcher.snapshot().stagingQueueFullRejections == 1)

        third.cancel()
        await #expect(throws: CancellationError.self) { try await third.value }
        while await batcher.snapshot().pendingRequests != 2 { await Task.yield() }

        // Cancellation must return the shared reservation so another lane
        // can consume it; otherwise production traffic would slowly lose all
        // queue capacity after client disconnects and timeouts.
        let replacement = stagedSend(roomID: otherRoomID, clientMessageSuffix: 5)
        while await batcher.snapshot().pendingRequests != 3 { await Task.yield() }

        first.cancel()
        second.cancel()
        replacement.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await second.value }
        await #expect(throws: CancellationError.self) { try await replacement.value }
        while await batcher.snapshot().pendingRequests != 0 { await Task.yield() }

        let snapshot = await batcher.snapshot()
        #expect(snapshot.cancelledPendingRequests == 4)
        #expect(snapshot.stagingQueueFullRejections == 1)
    }

    @Test("shared pending capacity remains exact under concurrent reservations")
    func sharedPendingCapacityIsAtomicallyBounded() async {
        let capacity = V2SharedSendMessagePendingCapacity(maximum: 17)
        let accepted = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0 ..< 256 {
                group.addTask { capacity.tryReserve() }
            }
            var accepted = 0
            for await reserved in group where reserved { accepted += 1 }
            return accepted
        }
        #expect(accepted == 17)

        for _ in 0 ..< accepted { capacity.release() }
        for _ in 0 ..< 17 { #expect(capacity.tryReserve()) }
        #expect(!capacity.tryReserve())
        for _ in 0 ..< 17 { capacity.release() }
    }

    @Test("accepted batches reach the post-commit observer before callers resume")
    func committedObserverRunsBeforeAcceptanceReturns() async throws {
        let profile = try V2CapacityProfile(id: "standard", limits: Fixture().profile)
        let store = AcceptedAtomicBatchTestStore()
        let observer = RecordingCommittedMessageObserver()
        let batcher = V2SendMessageAdmissionBatcher(
            store: store,
            configuration: .init(maximumBatchSize: 2, maximumDelay: .seconds(5)),
            committedMessageObserver: observer
        )
        let service = V2SendMessageService(
            store: store,
            capacityProfile: profile,
            limits: try .init(maxUTF8Bytes: 64),
            batcher: batcher
        )
        let roomID = try RoomID("50000000-0000-0000-0000-000000000001")
        let senderID = try UserID("50000000-0000-0000-0000-000000000002")

        async let first = service.send(.init(
            roomID: roomID,
            actorUserID: senderID,
            clientMessageID: try ClientMessageID(
                "50000000-0000-0000-0000-000000000003"
            ),
            text: "one"
        ))
        async let second = service.send(.init(
            roomID: roomID,
            actorUserID: senderID,
            clientMessageID: try ClientMessageID(
                "50000000-0000-0000-0000-000000000004"
            ),
            text: "two"
        ))
        _ = try await [first, second]

        #expect(service.publishesCommittedGroupEvents)
        #expect(observer.roomSequences() == [1, 2])
    }
}

private final class RecordingCommittedMessageObserver:
    V2CommittedMessageBatchObserving,
    Sendable
{
    private let values = Mutex<[UInt64]>([])

    func observeCommittedMessages(_ outcomes: [V2SendMessageOutcome]) {
        values.withLock { values in
            values.append(contentsOf: outcomes.compactMap { outcome in
                guard case .accepted(let message) = outcome else { return nil }
                return message.roomSequence
            })
        }
    }

    func roomSequences() -> [UInt64] { values.withLock { $0 } }
}

private actor AcceptedAtomicBatchTestStore: V2AtomicRoomWriteBatchStore {
    func atomicBatchPartitions(
        requests: [V2RoomWriteRequest]
    ) -> [V2AtomicRoomWriteBatchPartition?] {
        requests.map { _ in .largeGroupHybrid }
    }

    func atomicBatchSupportsRepeatedRooms(
        in partition: V2AtomicRoomWriteBatchPartition
    ) -> Bool { partition == .largeGroupHybrid }

    func accept(
        command: V2SendMessageCommand,
        capacityProfile _: V2CapacityProfile,
        identifiers: V2AcceptanceIdentifiers,
        now: Date
    ) throws -> V2SendMessageOutcome {
        .accepted(try acceptedMessage(
            command: command,
            identifiers: identifiers,
            roomSequence: 1,
            now: now
        ))
    }

    func acceptAtomically(
        requests: [V2RoomWriteRequest]
    ) throws -> [V2SendMessageOutcome] {
        try requests.enumerated().map { index, request in
            .accepted(try acceptedMessage(
                command: request.command,
                identifiers: request.identifiers,
                roomSequence: UInt64(index + 1),
                now: request.now
            ))
        }
    }

    private func acceptedMessage(
        command: V2SendMessageCommand,
        identifiers: V2AcceptanceIdentifiers,
        roomSequence: UInt64,
        now: Date
    ) throws -> V2AcceptedMessage {
        .init(
            messageID: identifiers.messageID,
            roomID: command.roomID,
            roomSequence: roomSequence,
            senderUserID: command.senderUserID,
            clientMessageID: command.clientMessageID,
            text: command.text,
            mediaPresentations: [],
            groupDeliveryMode: .largeGroupHybrid,
            usesRoomEventLog: true,
            sourceEventID: identifiers.eventID,
            acceptedMembershipRevision: 1,
            createdAt: now
        )
    }
}

private actor AtomicBatchTestStore: V2AtomicRoomWriteBatchStore {
    private let shouldFail: Bool
    private let shouldDeclineBatch: Bool
    private let failingNormalClientMessageIDs: Set<ClientMessageID>
    private let preclassifiedClientMessageIDs: Set<ClientMessageID>
    private let acceleratedClientMessageIDs: Set<ClientMessageID>
    private let isolatedBatchClientMessageIDs: Set<ClientMessageID>
    private let repeatedRoomBatchingEnabled: Bool
    private let atomicBatchDelay: Duration?
    private var recordedBatches: [[ClientMessageID]] = []
    private var recordedNormalClientMessageIDs: [ClientMessageID] = []
    private var normalCalls = 0

    init(
        shouldFail: Bool = false,
        shouldDeclineBatch: Bool = false,
        failingNormalClientMessageIDs: Set<ClientMessageID> = [],
        preclassifiedClientMessageIDs: Set<ClientMessageID> = [],
        acceleratedClientMessageIDs: Set<ClientMessageID> = [],
        isolatedBatchClientMessageIDs: Set<ClientMessageID> = [],
        repeatedRoomBatchingEnabled: Bool = false,
        atomicBatchDelay: Duration? = nil
    ) {
        self.shouldFail = shouldFail
        self.shouldDeclineBatch = shouldDeclineBatch
        self.failingNormalClientMessageIDs = failingNormalClientMessageIDs
        self.preclassifiedClientMessageIDs = preclassifiedClientMessageIDs
        self.acceleratedClientMessageIDs = acceleratedClientMessageIDs
        self.isolatedBatchClientMessageIDs = isolatedBatchClientMessageIDs
        self.repeatedRoomBatchingEnabled = repeatedRoomBatchingEnabled
        self.atomicBatchDelay = atomicBatchDelay
    }

    func atomicBatchEligibility(requests: [V2RoomWriteRequest]) -> [Bool] {
        requests.map { !preclassifiedClientMessageIDs.contains($0.command.clientMessageID) }
    }


    func atomicBatchPartitions(
        requests: [V2RoomWriteRequest]
    ) -> [V2AtomicRoomWriteBatchPartition?] {
        requests.map { request in
            guard !preclassifiedClientMessageIDs.contains(request.command.clientMessageID)
            else { return nil }
            if repeatedRoomBatchingEnabled { return .largeGroupHybrid }
            return acceleratedClientMessageIDs.contains(request.command.clientMessageID)
                ? .accelerated : .standard
        }
    }

    func atomicBatchSupportsRepeatedRooms(
        in partition: V2AtomicRoomWriteBatchPartition
    ) -> Bool {
        repeatedRoomBatchingEnabled && partition == .largeGroupHybrid
    }

    func accept(
        command: V2SendMessageCommand,
        capacityProfile: V2CapacityProfile,
        identifiers: V2AcceptanceIdentifiers,
        now: Date
    ) throws -> V2SendMessageOutcome {
        normalCalls += 1
        recordedNormalClientMessageIDs.append(command.clientMessageID)
        if failingNormalClientMessageIDs.contains(command.clientMessageID) {
            throw V2RoomWriteStoreError.actorNotEligible
        }
        return .unavailable(.missingShardLease)
    }

    func acceptAtomically(
        requests: [V2RoomWriteRequest]
    ) async throws -> [V2SendMessageOutcome] {
        recordedBatches.append(requests.map(\.command.clientMessageID))
        if let atomicBatchDelay {
            try await Task.sleep(for: atomicBatchDelay)
        }
        let isolatedIndices = requests.indices.filter {
            isolatedBatchClientMessageIDs.contains(
                requests[$0].command.clientMessageID
            )
        }
        if !isolatedIndices.isEmpty {
            throw V2AtomicRoomWriteBatchError(
                reason: .capacityProfileMismatch,
                isolatedRequestIndices: isolatedIndices
            )
        }
        if shouldDeclineBatch {
            throw V2AtomicRoomWriteBatchError(reason: .requestShape)
        }
        if shouldFail {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return requests.map {
            .rateLimited(retryAfterSeconds: $0.command.text == "one" ? 7 : 8)
        }
    }

    func normalAcceptCallCount() -> Int { normalCalls }
    func normalAcceptedClientMessageIDs() -> [ClientMessageID] {
        recordedNormalClientMessageIDs
    }
    func batches() -> [[ClientMessageID]] { recordedBatches }
}

private actor ConcurrentAtomicBatchTestStore: V2AtomicRoomWriteBatchStore {
    private var inFlightBatchCount = 0
    private var maximumInFlightBatchCountValue = 0

    func accept(
        command: V2SendMessageCommand,
        capacityProfile: V2CapacityProfile,
        identifiers: V2AcceptanceIdentifiers,
        now: Date
    ) -> V2SendMessageOutcome {
        .unavailable(.missingShardLease)
    }

    func acceptAtomically(requests: [V2RoomWriteRequest]) async throws -> [V2SendMessageOutcome] {
        inFlightBatchCount += 1
        maximumInFlightBatchCountValue = max(maximumInFlightBatchCountValue, inFlightBatchCount)
        try await Task.sleep(for: .milliseconds(50))
        inFlightBatchCount -= 1
        return requests.map { _ in .rateLimited(retryAfterSeconds: 1) }
    }

    func maximumInFlightBatchCount() -> Int { maximumInFlightBatchCountValue }
}

private func captureSendOutcome(
    _ operation: @escaping @Sendable () async throws -> V2SendMessageOutcome
) async -> Result<V2SendMessageOutcome, any Error> {
    do {
        return .success(try await operation())
    } catch {
        return .failure(error)
    }
}

private struct Fixture: Sendable {
    let roomID = try! RoomID("00000000-0000-0000-0000-000000000001")
    let senderID = try! UserID("00000000-0000-0000-0000-000000000002")
    let clientMessageID = try! ClientMessageID("00000000-0000-0000-0000-000000000003")
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    var profile: RoomCapacityProfile
    let roomState: V2RoomCommandState
    let shardState: ShardAdmissionState

    init() throws {
        profile = try RoomCapacityProfile(maxEligibleMembers: 10, maxCommandsPerWindow: 10, maxFanoutUnitsPerWindow: 10, maxOutstandingFanoutUnits: 10, maxOutstandingPlans: 10, maxEnumerationPageSize: 10, maxPlannerConcurrency: 1, maxDeliveryConcurrency: 1, retryAfterSeconds: 7)
        roomState = try V2RoomCommandState(roomID: roomID, nextRoomSequence: 1, admission: .init(eligibleMemberCount: 3, commandWindow: .init(limit: 10), fanoutWindow: .init(limit: 10), outstandingFanoutUnits: 0, outstandingPlans: 0))
        shardState = try ShardAdmissionState(lease: .init(id: try ShardAdmissionLeaseID("00000000-0000-0000-0000-000000000004"), generation: 1, validUntil: now.addingTimeInterval(60), commandWindow: .init(limit: 10), fanoutWindow: .init(limit: 10), maxOutstandingFanoutUnits: 10, maxOutstandingPlans: 10), outstandingFanoutUnits: 0, outstandingPlans: 0)
    }

    func nextUUID() -> UUID { UUID() }
}
