import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 room write service")
struct V2SendMessageServiceTests {
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
    }

    @Test("an unsupported batch shape falls back without exposing an optimisation failure")
    func admissionBatchingFallsBackToOrdinaryAcceptance() async throws {
        let profile = try V2CapacityProfile(id: "standard", limits: Fixture().profile)
        let store = AtomicBatchTestStore(shouldDeclineBatch: true)
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
}

private actor AtomicBatchTestStore: V2AtomicRoomWriteBatchStore {
    private let shouldFail: Bool
    private let shouldDeclineBatch: Bool
    private let failingNormalClientMessageIDs: Set<ClientMessageID>
    private var recordedBatches: [[ClientMessageID]] = []
    private var normalCalls = 0

    init(
        shouldFail: Bool = false,
        shouldDeclineBatch: Bool = false,
        failingNormalClientMessageIDs: Set<ClientMessageID> = []
    ) {
        self.shouldFail = shouldFail
        self.shouldDeclineBatch = shouldDeclineBatch
        self.failingNormalClientMessageIDs = failingNormalClientMessageIDs
    }

    func accept(
        command: V2SendMessageCommand,
        capacityProfile: V2CapacityProfile,
        identifiers: V2AcceptanceIdentifiers,
        now: Date
    ) throws -> V2SendMessageOutcome {
        normalCalls += 1
        if failingNormalClientMessageIDs.contains(command.clientMessageID) {
            throw V2RoomWriteStoreError.actorNotEligible
        }
        return .unavailable(.missingShardLease)
    }

    func acceptAtomically(requests: [V2RoomWriteRequest]) throws -> [V2SendMessageOutcome] {
        recordedBatches.append(requests.map(\.command.clientMessageID))
        if shouldDeclineBatch {
            throw V2AtomicRoomWriteBatchError.unsupportedRequestShape
        }
        if shouldFail {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        return requests.map {
            .rateLimited(retryAfterSeconds: $0.command.text == "one" ? 7 : 8)
        }
    }

    func normalAcceptCallCount() -> Int { normalCalls }
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
