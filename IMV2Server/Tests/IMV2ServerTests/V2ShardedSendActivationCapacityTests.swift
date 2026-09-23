import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("Shared owner activation identity budget")
struct V2ShardedSendActivationCapacityTests {
    @Test("one lane also holds an idle activation until credit cleanup and retirement")
    func singleLaneLifetime() async throws {
        let store = GrantedBatchStore()
        let batcher = V2SendMessageAdmissionBatcher(store: store,
            configuration: .init(maximumBatchSize: 2, maximumDelay: .milliseconds(20),
                maximumTrackedActivations: 1),
            actorGrantedStoreFactory: { _ in store })
        let first = try makeToken(80)
        let other = try makeToken(81)
        #expect(try await batcher.acceptGrantedTurn(makeSends(first, ["first"]),
            batchDeadline: .now, callDeadline: .now + .seconds(2)).count == 1)
        await #expect(throws: V2SendMessageAdmissionBatcherError.serverBusy) {
            try await batcher.acceptGrantedTurn(makeSends(other, ["blocked"]),
                batchDeadline: .now, callDeadline: .now + .seconds(2))
        }
        await batcher.retireActivation(first)
        #expect(try await batcher.acceptGrantedTurn(makeSends(other, ["accepted"]),
            batchDeadline: .now, callDeadline: .now + .seconds(2)).count == 1)
    }

    @Test("two lanes share one token limit and rejection restores every pending slot")
    func crossLaneLimitAndRollback() async throws {
        let store = GrantedBatchStore()
        let batcher = makeBatcher(store: store, maximumPendingRequests: 3)
        let first = try makeToken(1)
        let other = try oppositeLaneToken(to: first)
        let deadline = ContinuousClock.now + .seconds(10)
        let firstTask = Task {
            try await batcher.acceptGrantedTurn(makeSends(first, ["first"]),
                batchDeadline: deadline, callDeadline: deadline)
        }
        try await waitForPending(batcher, 1)
        await #expect(throws: V2SendMessageAdmissionBatcherError.serverBusy) {
            try await batcher.acceptGrantedTurn(makeSends(other, ["second", "third"]),
                batchDeadline: deadline, callDeadline: deadline)
        }
        // The rejected turn reserved two shared pending slots first. Neither
        // those slots nor its activation identity may survive the rejection.
        #expect(await batcher.snapshot().pendingRequests == 1)
        #expect(try await firstTask.value.count == 1)
        #expect(try await batcher.acceptGrantedTurn(makeSends(first, ["same-token"]),
            batchDeadline: .now, callDeadline: deadline).count == 1)
        await #expect(throws: V2SendMessageAdmissionBatcherError.serverBusy) {
            try await batcher.acceptGrantedTurn(makeSends(other, ["still-held"]),
                batchDeadline: .now, callDeadline: deadline)
        }
        // A normal completion can leave unused credits for this activation.
        // Its identity remains charged until the host closes those credits.
        await batcher.retireActivation(first)
        #expect(try await batcher.acceptGrantedTurn(makeSends(other, ["second", "third"]),
            batchDeadline: .now, callDeadline: deadline).count == 2)
    }

    @Test("unknown completion retains the slot until exact retirement")
    func quarantineRetainsSlot() async throws {
        let unknownStore = GrantedBatchStore(unknown: true)
        let healthyStore = GrantedBatchStore()
        let first = try makeToken(20)
        let other = try oppositeLaneToken(to: first)
        let batcher = makeBatcher(store: healthyStore) { tokens in
            tokens.contains(first) ? unknownStore : healthyStore
        }
        let adapter = V2ActorGrantedSendBatchAdapter(batcher: batcher)
        await #expect(throws: V2RoomCallFailure.outcomeUnknown) {
            try await adapter.execute(makeSends(first, ["unknown-a", "unknown-b"]),
                batchDeadline: .now)
        }
        #expect(await batcher.snapshot().pendingRequests == 0)
        await #expect(throws: V2SendMessageAdmissionBatcherError.serverBusy) {
            try await batcher.acceptGrantedTurn(makeSends(other, ["blocked"]),
                batchDeadline: .now, callDeadline: .now + .seconds(2))
        }
        await batcher.retireActivation(other) // Never releases another token's slot.
        await #expect(throws: V2SendMessageAdmissionBatcherError.serverBusy) {
            try await batcher.acceptGrantedTurn(makeSends(other, ["still-blocked"]),
                batchDeadline: .now, callDeadline: .now + .seconds(2))
        }
        await batcher.retireActivation(first)
        #expect(try await batcher.acceptGrantedTurn(makeSends(other, ["accepted"]),
            batchDeadline: .now, callDeadline: .now + .seconds(2)).count == 1)
    }

    @Test("retiring an old epoch cannot release a successor's reserved slot")
    func oldEpochRetirementIsExact() async throws {
        let unknownStore = GrantedBatchStore(unknown: true)
        let healthyStore = GrantedBatchStore()
        let old = try makeToken(40)
        let successor = V2RoomActivationToken(roomID: old.roomID, owner: old.owner,
            activationEpoch: try .init(2), host: old.host)
        let other = try oppositeLaneToken(to: old)
        let batcher = makeBatcher(store: healthyStore) { tokens in
            tokens.contains(old) ? unknownStore : healthyStore
        }
        await #expect(throws: V2RoomCallFailure.outcomeUnknown) {
            try await V2ActorGrantedSendBatchAdapter(batcher: batcher).execute(
                makeSends(old, ["old-a", "old-b"]), batchDeadline: .now)
        }
        await batcher.retireActivation(old)
        let deadline = ContinuousClock.now + .seconds(10)
        let successorTask = Task {
            try await batcher.acceptGrantedTurn(makeSends(successor, ["successor"]),
                batchDeadline: deadline, callDeadline: deadline)
        }
        try await waitForPending(batcher, 1)
        await batcher.retireActivation(old)
        await #expect(throws: V2SendMessageAdmissionBatcherError.serverBusy) {
            try await batcher.acceptGrantedTurn(makeSends(other, ["other"]),
                batchDeadline: deadline, callDeadline: deadline)
        }
        #expect(try await successorTask.value.count == 1)
        await batcher.retireActivation(successor)
        #expect(try await batcher.acceptGrantedTurn(makeSends(other, ["other"]),
            batchDeadline: .now, callDeadline: deadline).count == 1)
    }

    private func makeBatcher(
        store: GrantedBatchStore,
        maximumPendingRequests: Int = 4,
        factory: (@Sendable ([V2RoomActivationToken]) throws -> any V2AtomicRoomWriteBatchStore)? = nil
    ) -> V2ShardedSendMessageAdmissionBatcher {
        V2ShardedSendMessageAdmissionBatcher(
            store: store,
            configuration: .init(maximumBatchSize: 4, maximumDelay: .milliseconds(200),
                maximumInFlightBatches: 2, maximumPendingRequests: maximumPendingRequests,
                maximumTrackedActivations: 1),
            laneCount: 2,
            actorGrantedStoreFactory: factory ?? { _ in store })
    }

    private func waitForPending(_ batcher: V2ShardedSendMessageAdmissionBatcher,
                                _ expected: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while await batcher.snapshot().pendingRequests != expected {
            guard ContinuousClock.now < deadline else {
                throw V2RoomCallFailure.notAccepted(.deadlineExceeded)
            }
            await Task.yield()
        }
    }

    private func oppositeLaneToken(to first: V2RoomActivationToken) throws -> V2RoomActivationToken {
        let lane = V2ShardedSendMessageAdmissionBatcher.laneIndex(for: first.roomID, laneCount: 2)
        for suffix in 1...100 {
            let candidate = try makeToken(suffix)
            if candidate.roomID != first.roomID,
               V2ShardedSendMessageAdmissionBatcher.laneIndex(for: candidate.roomID,
                laneCount: 2) != lane { return candidate }
        }
        throw V2RoomCallFailure.notAccepted(.invalidRequest)
    }

    private func makeToken(_ suffix: Int) throws -> V2RoomActivationToken {
        .init(roomID: try RoomID(String(format: "57000000-0000-0000-0000-%012d", suffix)),
              owner: try .init(shardID: "shard-a", epoch: 1),
              activationEpoch: try .init(1),
              host: .init(hostID: try V2ActorHostID("host-a"), incarnationID: UUID()))
    }

    private func makeSends(_ token: V2RoomActivationToken,
                           _ texts: [String]) throws -> [V2PreparedActorSend] {
        let profile = try V2CapacityProfile(id: "standard", limits: .init(
            maxEligibleMembers: 10, maxCommandsPerWindow: 10, retryAfterSeconds: 7))
        let limits = try V2MessageCommandLimits(maxUTF8Bytes: 64)
        let sender = try UserID("57000000-0000-0000-0000-000000000099")
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        return try texts.enumerated().map { index, text in
            let command = try V2SendMessageCommand(roomID: token.roomID,
                senderUserID: sender,
                clientMessageID: try ClientMessageID(String(format:
                    "57000000-0000-0000-0000-%012d", index + 1)),
                text: text, limits: limits)
            return V2PreparedActorSend(token: token, request: .init(
                command: command, capacityProfile: profile,
                identifiers: try V2AcceptanceIDFactory().make(at: now), now: now))
        }
    }
}
