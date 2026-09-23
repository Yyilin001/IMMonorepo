import Foundation
import IMV2ActorContracts
import IMV2Core
import Synchronization
@testable import IMV2Server
import Testing

@Suite("Granted actor send batching")
struct V2ActorGrantedSendBatchTests {
    @Test("selected cross-room SQL batch uses its earliest call deadline")
    func earliestGrantedSQLDeadline() async throws {
        let store = GrantedBatchStore()
        let batcher = V2SendMessageAdmissionBatcher(
            store: store,
            configuration: .init(maximumBatchSize: 2, maximumDelay: .seconds(5)),
            actorGrantedStoreFactory: { _ in store }
        )
        let firstToken = try makeToken()
        let secondToken = V2RoomActivationToken(
            roomID: try RoomID("54000000-0000-0000-0000-000000000010"),
            owner: firstToken.owner, activationEpoch: firstToken.activationEpoch,
            host: firstToken.host)
        let earlier = ContinuousClock.now + .seconds(2)
        let later = earlier + .seconds(2)
        let firstSends = try makeSends(token: firstToken, texts: ["first"])
        let secondSends = try makeSends(token: secondToken, texts: ["second"])
        let first = Task {
            try await batcher.acceptGrantedTurn(firstSends,
                batchDeadline: later, callDeadline: earlier)
        }
        for _ in 0..<100 {
            if await batcher.snapshot().pendingRequests == 1 { break }
            await Task.yield()
        }
        #expect(await batcher.snapshot().pendingRequests == 1)
        let second = Task {
            try await V2RoomSQLDeadline.withSelectedDeadline(later + .seconds(5)) {
                try await batcher.acceptGrantedTurn(secondSends,
                    batchDeadline: later, callDeadline: later)
            }
        }
        #expect(try await first.value.count == 1)
        #expect(try await second.value.count == 1)
        #expect(await store.recordedSQLDeadlines() == [earlier])
    }

    @Test("one granted turn enters contiguously and retains its original deadline")
    func contiguousTurnAndDeadline() async throws {
        let store = GrantedBatchStore()
        let scoped = Mutex<[[V2RoomActivationToken]]>([])
        let batcher = V2SendMessageAdmissionBatcher(
            store: store,
            configuration: .init(maximumBatchSize: 8, maximumDelay: .seconds(5)),
            actorGrantedStoreFactory: { tokens in
                scoped.withLock { $0.append(tokens) }
                return store
            }
        )
        let token = try makeToken()
        let sends = try makeSends(token: token, texts: ["one", "two", "three"])
        let start = ContinuousClock().now
        let results = try await batcher.acceptGrantedTurn(sends, batchDeadline: start - .milliseconds(1))
        #expect(start.duration(to: ContinuousClock().now) < .seconds(1))
        #expect(results.count == 3)
        #expect(await store.recordedTexts() == [["one", "two", "three"]])
        #expect(scoped.withLock { $0 } == [[token]])
    }

    @Test("partitioned known results retain committed items and typed business rejection")
    func partitionedKnownResults() async throws {
        let store = GrantedBatchStore(rejectLast: true)
        let batcher = V2SendMessageAdmissionBatcher(
            store: store,
            configuration: .init(maximumBatchSize: 2, maximumDelay: .seconds(5)),
            actorGrantedStoreFactory: { _ in store }
        )
        let sends = try makeSends(token: makeToken(), texts: ["one", "two", "three"])
        let results = try await V2ActorGrantedSendBatchAdapter(batcher: batcher).execute(
            sends, batchDeadline: ContinuousClock().now
        )
        #expect(results.count == 3)
        #expect(results[0] == .send(.rateLimited(retryAfterSeconds: 1)))
        #expect(results[1] == .send(.rateLimited(retryAfterSeconds: 2)))
        #expect(results[2] == .failure(.sendStore(.actorNotEligible)))
        #expect(await store.recordedTexts() == [["one", "two"]])
    }

    @Test("mixed advisory partitions never move a later same-room send ahead")
    func mixedPartitionOrder() async throws {
        let store = GrantedBatchStore(partitionLast: true)
        let batcher = V2SendMessageAdmissionBatcher(
            store: store,
            configuration: .init(maximumBatchSize: 3, maximumDelay: .seconds(5)),
            actorGrantedStoreFactory: { _ in store }
        )
        let sends = try makeSends(token: makeToken(), texts: ["one", "two", "three"])
        _ = try await batcher.acceptGrantedTurn(sends, batchDeadline: ContinuousClock().now)
        #expect(await store.recordedTexts().isEmpty)
        #expect(await store.scalarCompletionOrder() == ["one", "two", "three"])
    }

    @Test("isolated middle retry does not advance a later same-room send first")
    func isolatedMiddleOrder() async throws {
        let store = GrantedBatchStore(isolateMiddle: true)
        let batcher = V2SendMessageAdmissionBatcher(
            store: store,
            configuration: .init(maximumBatchSize: 3, maximumDelay: .seconds(5)),
            actorGrantedStoreFactory: { _ in store }
        )
        let sends = try makeSends(token: makeToken(), texts: ["one", "two", "three"])
        _ = try await batcher.acceptGrantedTurn(sends, batchDeadline: ContinuousClock().now)
        #expect(await store.scalarCompletionOrder() == ["one", "two", "three"])
    }

    @Test("an unknown SQL batch propagates to every item of the turn")
    func unknownPropagates() async throws {
        let store = GrantedBatchStore(unknown: true)
        let batcher = V2SendMessageAdmissionBatcher(
            store: store,
            configuration: .init(maximumBatchSize: 2, maximumDelay: .seconds(5)),
            actorGrantedStoreFactory: { _ in store }
        )
        let sends = try makeSends(token: makeToken(), texts: ["one", "two"])
        await #expect(throws: V2RoomCallFailure.outcomeUnknown) {
            try await V2ActorGrantedSendBatchAdapter(batcher: batcher).execute(
                sends, batchDeadline: ContinuousClock().now
            )
        }
    }

    @Test("proved SQL rollback does not quarantine a granted activation")
    func rolledBackBatchDoesNotQuarantine() async throws {
        let store = GrantedBatchStore(rolledBack: true)
        let batcher = V2SendMessageAdmissionBatcher(
            store: store,
            configuration: .init(maximumBatchSize: 2, maximumDelay: .seconds(5)),
            actorGrantedStoreFactory: { _ in store })
        let adapter = V2ActorGrantedSendBatchAdapter(batcher: batcher)
        let token = try makeToken()
        for _ in 0..<2 {
            let sends = try makeSends(token: token, texts: ["one", "two"])
            await #expect(throws: V2RoomCallFailure.rolledBack(.unavailable)) {
                _ = try await adapter.execute(sends, batchDeadline: ContinuousClock.now)
            }
        }
    }

    @Test("a mixed committed and rolled-back turn quarantines its activation")
    func mixedRollbackQuarantines() async throws {
        let store = GrantedBatchStore(partitionLast: true, rollbackLastScalar: true)
        let batcher = V2SendMessageAdmissionBatcher(
            store: store,
            configuration: .init(maximumBatchSize: 3, maximumDelay: .seconds(5)),
            actorGrantedStoreFactory: { _ in store })
        let adapter = V2ActorGrantedSendBatchAdapter(batcher: batcher)
        let token = try makeToken()
        await #expect(throws: V2RoomCallFailure.outcomeUnknown) {
            _ = try await adapter.execute(try makeSends(token: token,
                texts: ["one", "two", "three"]), batchDeadline: ContinuousClock.now)
        }
        await #expect(throws: V2RoomCallFailure.outcomeUnknown) {
            _ = try await adapter.execute(try makeSends(token: token,
                texts: ["late"]), batchDeadline: ContinuousClock.now)
        }
    }

    @Test("one shared SQL unknown reaches both room turns on the same shard")
    func sharedUnknownPropagates() async throws {
        let store = GrantedBatchStore(unknown: true)
        let scopes = Mutex<[[V2RoomActivationToken]]>([])
        let batcher = V2SendMessageAdmissionBatcher(
            store: store,
            configuration: .init(maximumBatchSize: 2, maximumDelay: .seconds(5)),
            actorGrantedStoreFactory: { tokens in
                scopes.withLock { $0.append(tokens) }
                return store
            }
        )
        let firstToken = try makeToken()
        let secondToken = V2RoomActivationToken(
            roomID: try RoomID("54000000-0000-0000-0000-000000000010"),
            owner: firstToken.owner,
            activationEpoch: try .init(1),
            host: firstToken.host
        )
        let adapter = V2ActorGrantedSendBatchAdapter(batcher: batcher)
        let deadline = ContinuousClock().now + .seconds(2)
        let firstSends = try makeSends(token: firstToken, texts: ["one"])
        let secondSends = try makeSends(token: secondToken, texts: ["two"])
        let first = Task { try await adapter.execute(
            firstSends, batchDeadline: deadline
        ) }
        let second = Task { try await adapter.execute(
            secondSends, batchDeadline: deadline
        ) }
        await #expect(throws: V2RoomCallFailure.outcomeUnknown) { try await first.value }
        await #expect(throws: V2RoomCallFailure.outcomeUnknown) { try await second.value }
        #expect(scopes.withLock { $0 }.count == 1)
        #expect(Set(scopes.withLock { $0 }[0]) == Set([firstToken, secondToken]))
        for token in [firstToken, secondToken] {
            let late = try makeSends(token: token, texts: ["late"])
            await #expect(throws: V2RoomCallFailure.outcomeUnknown) {
                try await adapter.execute(late, batchDeadline: ContinuousClock().now)
            }
        }
        #expect(await batcher.snapshot().completedBatches == 1)
        await adapter.retire(firstToken)
        await adapter.retire(secondToken)
    }

    @Test("over-capacity turn does not leave partially enqueued requests")
    func allOrNothingCapacity() async throws {
        let store = GrantedBatchStore()
        let batcher = V2SendMessageAdmissionBatcher(
            store: store,
            configuration: .init(maximumBatchSize: 8, maximumDelay: .seconds(5), maximumPendingRequests: 2),
            actorGrantedStoreFactory: { _ in store }
        )
        let sends = try makeSends(token: makeToken(), texts: ["one", "two", "three"])
        await #expect(throws: V2SendMessageAdmissionBatcherError.serverBusy) {
            try await batcher.acceptGrantedTurn(sends, batchDeadline: ContinuousClock().now)
        }
        #expect(await batcher.snapshot().pendingRequests == 0)
        #expect(await store.recordedTexts().isEmpty)
    }

    @Test("a contending turn cannot reserve only part of the remaining queue")
    func contendedCapacity() async throws {
        let store = GrantedBatchStore()
        let batcher = V2SendMessageAdmissionBatcher(
            store: store,
            configuration: .init(maximumBatchSize: 8, maximumDelay: .seconds(5), maximumPendingRequests: 3),
            actorGrantedStoreFactory: { _ in store }
        )
        let firstSends = try makeSends(token: makeToken(), texts: ["one", "two"])
        let secondSends = try makeSends(token: makeToken(), texts: ["three", "four"])
        let first = Task { try await batcher.acceptGrantedTurn(
            firstSends, batchDeadline: ContinuousClock().now + .milliseconds(200)
        ) }
        for _ in 0..<100 {
            if await batcher.snapshot().pendingRequests == 2 { break }
            await Task.yield()
        }
        #expect(await batcher.snapshot().pendingRequests == 2)
        await #expect(throws: V2SendMessageAdmissionBatcherError.serverBusy) {
            try await batcher.acceptGrantedTurn(
                secondSends, batchDeadline: ContinuousClock().now
            )
        }
        #expect(await batcher.snapshot().pendingRequests == 2)
        #expect((try await first.value).count == 2)
        #expect(await store.recordedTexts() == [["one", "two"]])
    }

    @Test("scalar fallback keeps same-room granted sends in original order")
    func scalarFallbackOrder() async throws {
        let store = GrantedBatchStore(fallback: true)
        let batcher = V2SendMessageAdmissionBatcher(
            store: store,
            configuration: .init(maximumBatchSize: 3, maximumDelay: .seconds(5)),
            actorGrantedStoreFactory: { _ in store }
        )
        let sends = try makeSends(token: makeToken(), texts: ["one", "two", "three"])
        let results = try await batcher.acceptGrantedTurn(sends, batchDeadline: ContinuousClock().now)
        #expect(results.count == 3)
        #expect(await store.scalarCompletionOrder() == ["one", "two", "three"])
        #expect(await batcher.snapshot().atomicBatchFallbacks == 1)
    }

    @Test("unknown first partition purges queued successor and holds a bounded token slot")
    func unknownQuarantine() async throws {
        let store = GrantedBatchStore(unknown: true)
        let batcher = V2SendMessageAdmissionBatcher(
            store: store,
            configuration: .init(maximumBatchSize: 2, maximumDelay: .seconds(5),
                maximumTrackedActivations: 1),
            actorGrantedStoreFactory: { _ in store }
        )
        let adapter = V2ActorGrantedSendBatchAdapter(batcher: batcher)
        let token = try makeToken()
        let sends = try makeSends(token: token, texts: ["one", "two", "three"])
        await #expect(throws: V2RoomCallFailure.outcomeUnknown) {
            try await adapter.execute(sends, batchDeadline: ContinuousClock().now)
        }
        #expect(await store.recordedTexts() == [["one", "two"]])
        #expect(await batcher.snapshot().completedBatches == 1)
        #expect(await batcher.snapshot().pendingRequests == 0)
        let late = try makeSends(token: token, texts: ["late"])
        await #expect(throws: V2RoomCallFailure.outcomeUnknown) {
            try await adapter.execute(late, batchDeadline: ContinuousClock().now)
        }
        let other = V2RoomActivationToken(
            roomID: try RoomID("54000000-0000-0000-0000-000000000010"),
            owner: token.owner, activationEpoch: token.activationEpoch, host: token.host
        )
        let otherSends = try makeSends(token: other, texts: ["other", "another"])
        await #expect(throws: V2RoomCallFailure.notAccepted(.overloaded)) {
            try await adapter.execute(otherSends, batchDeadline: ContinuousClock().now)
        }
        await adapter.retire(token)
        await #expect(throws: V2RoomCallFailure.outcomeUnknown) {
            try await adapter.execute(otherSends, batchDeadline: ContinuousClock().now)
        }
        #expect(await batcher.snapshot().completedBatches == 2)
        await adapter.retire(other)
    }

    private func makeToken() throws -> V2RoomActivationToken {
        .init(
            roomID: try RoomID("54000000-0000-0000-0000-000000000001"),
            owner: try .init(shardID: "shard-a", epoch: 1),
            activationEpoch: try .init(1),
            host: .init(hostID: try V2ActorHostID("host-a"), incarnationID: UUID())
        )
    }

    private func makeSends(token: V2RoomActivationToken, texts: [String]) throws -> [V2PreparedActorSend] {
        let profile = try V2CapacityProfile(
            id: "standard",
            limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10, retryAfterSeconds: 7)
        )
        let limits = try V2MessageCommandLimits(maxUTF8Bytes: 64)
        let senderID = try UserID("54000000-0000-0000-0000-000000000002")
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        return try texts.enumerated().map { index, text in
            let clientID = try ClientMessageID(String(format: "54000000-0000-0000-0000-%012d", index + 3))
            let command = try V2SendMessageCommand(
                roomID: token.roomID,
                senderUserID: senderID,
                clientMessageID: clientID,
                text: text,
                limits: limits
            )
            return V2PreparedActorSend(token: token, request: .init(
                command: command,
                capacityProfile: profile,
                identifiers: try V2AcceptanceIDFactory().make(at: now),
                now: now
            ))
        }
    }
}

private actor GrantedBatchStore: V2AtomicRoomWriteBatchStore {
    let partitionLast: Bool
    let rejectLast: Bool
    let unknown: Bool
    let rolledBack: Bool
    let rollbackLastScalar: Bool
    let fallback: Bool
    let isolateMiddle: Bool
    var texts: [[String]] = []
    var scalarOrder: [String] = []
    var sqlDeadlines: [ContinuousClock.Instant?] = []

    init(partitionLast: Bool = false, rejectLast: Bool = false,
         unknown: Bool = false, rolledBack: Bool = false,
         rollbackLastScalar: Bool = false,
         fallback: Bool = false, isolateMiddle: Bool = false) {
        self.partitionLast = partitionLast
        self.rejectLast = rejectLast
        self.unknown = unknown
        self.rolledBack = rolledBack
        self.rollbackLastScalar = rollbackLastScalar
        self.fallback = fallback
        self.isolateMiddle = isolateMiddle
    }

    func atomicBatchPartitions(requests: [V2RoomWriteRequest]) -> [V2AtomicRoomWriteBatchPartition?] {
        requests.map { partitionLast && $0.command.text == "three" ? nil : .large }
    }

    func atomicBatchSupportsRepeatedRooms(in partition: V2AtomicRoomWriteBatchPartition) -> Bool {
        partition == .large
    }

    func accept(
        command: V2SendMessageCommand,
        capacityProfile: V2CapacityProfile,
        identifiers: V2AcceptanceIdentifiers,
        now: Date
    ) async throws -> V2SendMessageOutcome {
        sqlDeadlines.append(V2RoomSQLDeadline.current)
        if fallback && command.text == "one" { try await Task.sleep(for: .milliseconds(30)) }
        scalarOrder.append(command.text)
        if rollbackLastScalar && command.text == "three" {
            throw V2RoomCallFailure.rolledBack(.unavailable)
        }
        if rejectLast && command.text == "three" { throw V2RoomWriteStoreError.actorNotEligible }
        return .rateLimited(retryAfterSeconds: 3)
    }

    func acceptAtomically(requests: [V2RoomWriteRequest]) throws -> [V2SendMessageOutcome] {
        sqlDeadlines.append(V2RoomSQLDeadline.current)
        texts.append(requests.map(\.command.text))
        if isolateMiddle { throw V2AtomicRoomWriteBatchError(
            reason: .requestShape, isolatedRequestIndices: [1]) }
        if fallback { throw V2AtomicRoomWriteBatchError(reason: .requestShape) }
        if unknown { throw V2RoomTransactionOutcomeUnknown() }
        if rolledBack { throw V2RoomCallFailure.rolledBack(.unavailable) }
        return requests.enumerated().map { .rateLimited(retryAfterSeconds: $0.offset + 1) }
    }

    func recordedTexts() -> [[String]] { texts }
    func scalarCompletionOrder() -> [String] { scalarOrder }
    func recordedSQLDeadlines() -> [ContinuousClock.Instant?] { sqlDeadlines }
}
