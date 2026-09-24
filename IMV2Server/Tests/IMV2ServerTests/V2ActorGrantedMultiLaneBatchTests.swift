import Foundation
import IMV2ActorContracts
import IMV2Core
import Synchronization
@testable import IMV2Server
import Testing

@Suite("Granted actor multi-lane send batching")
struct V2ActorGrantedMultiLaneBatchTests {
    @Test("disabled batching sends each item through its activation scope")
    func disabledBatching() async throws {
        let store = GrantedBatchStore()
        let scopes = Mutex<[[V2RoomActivationToken]]>([])
        let batcher = V2SendMessageAdmissionBatcher(
            store: store,
            configuration: .init(maximumBatchSize: 1, maximumDelay: .milliseconds(20)),
            actorGrantedStoreFactory: { tokens in
                scopes.withLock { $0.append(tokens) }
                return store
            })
        let token = try makeToken(1)
        let result = try await V2ActorGrantedSendBatchAdapter(batcher: batcher).execute(
            makeSends(token, ["first", "second"]),
            batchDeadline: .now + .seconds(1), callDeadline: .now + .seconds(2))
        #expect(result.count == 2)
        #expect(await store.recordedTexts().isEmpty)
        #expect(await store.scalarCompletionOrder() == ["first", "second"])
        #expect(scopes.withLock { $0 } == [[token], [token]])
        #expect(await batcher.snapshot().singletonDispatches == 2)
    }

    @Test("same-lane granted turns coalesce under exact activation scopes")
    func sameLaneCoalesces() async throws {
        let store = GrantedBatchStore()
        let scopes = Mutex<[[V2RoomActivationToken]]>([])
        let batcher = V2ShardedSendMessageAdmissionBatcher(
            store: store,
            configuration: .init(maximumBatchSize: 2, maximumDelay: .milliseconds(150),
                                 maximumInFlightBatches: 2, maximumPendingRequests: 4),
            laneCount: 2, actorGrantedStoreFactory: { tokens in
                scopes.withLock { $0.append(tokens) }
                return store
            })
        let first = try makeToken(10)
        let lane = V2ShardedSendMessageAdmissionBatcher.laneIndex(for: first.roomID, laneCount: 2)
        let second = try #require((11...50).map(makeToken).first {
            V2ShardedSendMessageAdmissionBatcher.laneIndex(for: $0.roomID, laneCount: 2) == lane
        })
        let deadline = ContinuousClock.now + .seconds(2)
        let firstTask = Task {
            try await batcher.acceptGrantedTurn(makeSends(first, ["first"]),
                batchDeadline: deadline, callDeadline: deadline)
        }
        try await waitForPending(batcher, 1)
        let secondTask = Task {
            try await batcher.acceptGrantedTurn(makeSends(second, ["second"]),
                batchDeadline: deadline, callDeadline: deadline)
        }
        #expect(try await firstTask.value.count == 1)
        #expect(try await secondTask.value.count == 1)
        #expect(await store.recordedTexts() == [["first", "second"]])
        #expect(scopes.withLock { $0 }.count == 1)
        #expect(Set(scopes.withLock { $0 }.flatMap { $0 }) == Set([first, second]))
        #expect(await batcher.snapshot().atomicBatchCommitted == 1)
        await batcher.retireActivation(first)
        await batcher.retireActivation(second)
    }

    @Test("a successor epoch for the same room stays on its lane and cannot overtake")
    func successorEpochOrder() async throws {
        let store = GrantedBatchStore()
        let scopes = Mutex<[[V2RoomActivationToken]]>([])
        let batcher = V2ShardedSendMessageAdmissionBatcher(
            store: store,
            configuration: .init(maximumBatchSize: 2, maximumDelay: .milliseconds(150),
                                 maximumInFlightBatches: 2, maximumPendingRequests: 4),
            laneCount: 2, actorGrantedStoreFactory: { tokens in
                scopes.withLock { $0.append(tokens) }
                return store
            })
        let old = try makeToken(15)
        let successor = V2RoomActivationToken(roomID: old.roomID, owner: old.owner,
            activationEpoch: try .init(2), host: old.host)
        let deadline = ContinuousClock.now + .seconds(2)
        let firstTask = Task {
            try await batcher.acceptGrantedTurn(makeSends(old, ["old"]),
                batchDeadline: deadline, callDeadline: deadline)
        }
        try await waitForPending(batcher, 1)
        let secondTask = Task {
            try await batcher.acceptGrantedTurn(makeSends(successor, ["new"]),
                batchDeadline: deadline, callDeadline: deadline)
        }
        #expect(try await firstTask.value.count == 1)
        #expect(try await secondTask.value.count == 1)
        #expect(scopes.withLock { $0 } == [[old], [successor]])
        #expect(await store.scalarCompletionOrder() == ["old", "new"])
    }

    @Test("all lanes share one pending limit without partial turn admission")
    func sharedPendingLimit() async throws {
        let store = GrantedBatchStore()
        let batcher = V2ShardedSendMessageAdmissionBatcher(
            store: store,
            configuration: .init(maximumBatchSize: 4, maximumDelay: .milliseconds(150),
                                 maximumInFlightBatches: 2, maximumPendingRequests: 3),
            laneCount: 2, actorGrantedStoreFactory: { _ in store })
        let first = try makeToken(20)
        let lane = V2ShardedSendMessageAdmissionBatcher.laneIndex(for: first.roomID, laneCount: 2)
        let second = try #require((21...60).map(makeToken).first {
            V2ShardedSendMessageAdmissionBatcher.laneIndex(for: $0.roomID, laneCount: 2) != lane
        })
        let deadline = ContinuousClock.now + .seconds(2)
        let firstTask = Task {
            try await batcher.acceptGrantedTurn(makeSends(first, ["a", "b"]),
                batchDeadline: deadline, callDeadline: deadline)
        }
        try await waitForPending(batcher, 2)
        await #expect(throws: V2SendMessageAdmissionBatcherError.serverBusy) {
            try await batcher.acceptGrantedTurn(makeSends(second, ["c", "d"]),
                batchDeadline: deadline, callDeadline: deadline)
        }
        #expect(await batcher.snapshot().pendingRequests == 2)
        #expect(try await firstTask.value.count == 2)
        #expect(await store.recordedTexts() == [["a", "b"]])
    }

    @Test("host batch window flushes before a later call deadline")
    func adaptiveHostWindowDeadline() async throws {
        let store = GrantedBatchStore()
        let batcher = makeAdaptiveBatcher(store: store)
        let token = try makeToken(30)
        _ = try await batcher.acceptGrantedTurn(makeSends(token, ["warmup"]),
            batchDeadline: .now + .seconds(1), callDeadline: .now + .seconds(1))
        let started = ContinuousClock.now
        let result = try await V2ActorGrantedSendBatchAdapter(batcher: batcher).execute(
            makeSends(token, ["bounded"]), batchDeadline: started + .milliseconds(70),
            callDeadline: started + .milliseconds(500))
        #expect(result.count == 1)
        #expect(started.duration(to: .now) < .milliseconds(175))
        #expect(await store.scalarCompletionOrder() == ["warmup", "bounded"])
    }

    @Test("expired caller budget rejects before SQL even when host window remains")
    func adaptiveCallerDeadline() async throws {
        let store = GrantedBatchStore()
        let batcher = makeAdaptiveBatcher(store: store)
        let token = try makeToken(32)
        _ = try await batcher.acceptGrantedTurn(makeSends(token, ["warmup"]),
            batchDeadline: .now + .seconds(1), callDeadline: .now + .seconds(1))
        let started = ContinuousClock.now
        await #expect(throws: V2RoomCallFailure.notAccepted(.deadlineExceeded)) {
            try await V2ActorGrantedSendBatchAdapter(batcher: batcher).execute(
                makeSends(token, ["bounded"]), batchDeadline: started + .milliseconds(90),
                callDeadline: started + .milliseconds(70))
        }
        #expect(started.duration(to: .now) < .milliseconds(175))
        #expect(await store.scalarCompletionOrder() == ["warmup"])
    }

    @Test("granted turns still select high-activity delay when the host budget allows it")
    func adaptiveHighActivity() async throws {
        let store = GrantedBatchStore()
        let batcher = V2SendMessageAdmissionBatcher(
            store: store,
            configuration: .init(maximumBatchSize: 8, maximumDelay: .milliseconds(20),
                adaptiveDelayPolicy: .init(highActivityMaximumDelay: .milliseconds(100),
                    minimumRequestsInWindow: 2, observationWindow: .seconds(5))),
            actorGrantedStoreFactory: { _ in store })
        let token = try makeToken(31)
        _ = try await batcher.acceptGrantedTurn(makeSends(token, ["warmup"]),
            batchDeadline: .now + .seconds(1), callDeadline: .now + .seconds(1))
        let second = Task {
            try await batcher.acceptGrantedTurn(makeSends(token, ["high"]),
                batchDeadline: .now + .seconds(1), callDeadline: .now + .seconds(1))
        }
        let limit = ContinuousClock.now + .milliseconds(80)
        while !(await batcher.snapshot().highActivityDelayScheduled) && ContinuousClock.now < limit {
            await Task.yield()
        }
        #expect(await batcher.snapshot().highActivityDelayScheduled)
        #expect(try await second.value.count == 1)
        #expect(await batcher.snapshot().highActivityDelayFlushes == 1)
    }

    private func waitForPending(_ batcher: V2ShardedSendMessageAdmissionBatcher,
                                _ count: Int) async throws {
        let limit = ContinuousClock.now + .seconds(1)
        while await batcher.snapshot().pendingRequests != count {
            guard ContinuousClock.now < limit else {
                throw V2RoomCallFailure.notAccepted(.deadlineExceeded)
            }
            await Task.yield()
        }
    }

    private func makeAdaptiveBatcher(store: GrantedBatchStore) -> V2SendMessageAdmissionBatcher {
        V2SendMessageAdmissionBatcher(
            store: store,
            configuration: .init(maximumBatchSize: 8, maximumDelay: .milliseconds(25),
                adaptiveDelayPolicy: .init(highActivityMaximumDelay: .milliseconds(200),
                    minimumRequestsInWindow: 2, observationWindow: .seconds(5))),
            actorGrantedStoreFactory: { _ in store })
    }

    private func makeToken(_ suffix: Int) throws -> V2RoomActivationToken {
        .init(roomID: try RoomID(String(format: "55000000-0000-0000-0000-%012d", suffix)),
              owner: try .init(shardID: "shard-a", epoch: 1),
              activationEpoch: try .init(1),
              host: .init(hostID: try V2ActorHostID("host-a"), incarnationID: UUID()))
    }

    private func makeSends(_ token: V2RoomActivationToken, _ texts: [String]) throws -> [V2PreparedActorSend] {
        let profile = try V2CapacityProfile(id: "standard", limits: .init(
            maxEligibleMembers: 10, maxCommandsPerWindow: 10, retryAfterSeconds: 7))
        let limits = try V2MessageCommandLimits(maxUTF8Bytes: 64)
        let sender = try UserID("55000000-0000-0000-0000-000000000099")
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        return try texts.enumerated().map { index, text in
            let command = try V2SendMessageCommand(roomID: token.roomID,
                senderUserID: sender,
                clientMessageID: try ClientMessageID(String(format:
                    "56000000-0000-0000-0000-%012d", index + 1)),
                text: text, limits: limits)
            return V2PreparedActorSend(token: token, request: .init(
                command: command, capacityProfile: profile,
                identifiers: try V2AcceptanceIDFactory().make(at: now), now: now))
        }
    }
}
