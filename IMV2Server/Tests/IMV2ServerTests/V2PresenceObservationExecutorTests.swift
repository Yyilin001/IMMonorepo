import Foundation
import IMV2Core
@testable import IMV2ServerContracts
@testable import IMV2ServerGateway
import Testing

@Suite("Presence query and handoff separation")
struct V2PresenceObservationExecutorTests {
    @Test("caller cancellation retains the actual query slot until database settlement")
    func actualQueryRemainsOwned() async throws {
        let reader = ObservationReader(blocked: true)
        let executor = V2PresenceObservationExecutor(maximumConcurrentAttempts: 1)
        let request = makeRequest()
        let query = Task { try await executor.execute(attemptID: UUID(), requests: [request], reader: reader) }
        await reader.waitUntilStarted()
        query.cancel()
        #expect(await executor.actualAttemptCount() == 1)
        await #expect(throws: V2PresenceObservationExecutor.Failure.capacity) {
            try await executor.execute(attemptID: UUID(), requests: [request], reader: reader)
        }
        let shutdown = Task { await executor.finish() }
        await reader.release()
        let result = try await query.value
        #expect(result.outcomes[request] == .denied(.actorNotMember))
        #expect(result.observed.duration(to: result.deadline) == .seconds(30))
        await shutdown.value
        #expect(await executor.actualAttemptCount() == 0)
    }

    @Test("malformed observation results cannot become authorized handoff proofs", arguments: [false, true])
    func malformedResultsFailClosed(wrongTarget: Bool) async throws {
        let reader = ObservationReader(wrongTarget: wrongTarget, omitResult: !wrongTarget)
        let executor = V2PresenceObservationExecutor()
        await #expect(throws: V2PresenceObservationExecutor.Failure.malformed) {
            try await executor.execute(attemptID: UUID(), requests: [makeRequest()], reader: reader)
        }
        #expect(await executor.actualAttemptCount() == 0)
        await executor.finish()
    }

    private func makeRequest() -> V2PresenceObservationRequest {
        .init(roomID: .init(uuid: UUID()), viewerUserID: .init(uuid: UUID()), targetUserID: .init(uuid: UUID()))
    }
}

private actor ObservationReader: V2LiveActivityStore {
    private var blocked: Bool
    private let wrongTarget: Bool
    private let omitResult: Bool
    private var began = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var gate: CheckedContinuation<Void, Never>?
    init(blocked: Bool = false, wrongTarget: Bool = false, omitResult: Bool = false) {
        self.blocked = blocked; self.wrongTarget = wrongTarget; self.omitResult = omitResult
    }
    func presenceBatch(_ requests: [V2PresenceObservationRequest], now: Date) async -> [V2PresenceObservationRequest: V2PresenceObservationOutcome] {
        began = true; startWaiter?.resume(); startWaiter = nil
        if blocked { await withCheckedContinuation { gate = $0 } }
        if omitResult { return [:] }
        return Dictionary(uniqueKeysWithValues: requests.map {
            let result: V2PresenceObservationOutcome = wrongTarget
                ? .observed(.init(roomID: $0.roomID, targetUserID: .init(uuid: UUID()), isOnline: true, expiresAt: now.addingTimeInterval(90)))
                : .denied(.actorNotMember)
            return ($0, result)
        })
    }
    func waitUntilStarted() async {
        if began { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func release() { blocked = false; gate?.resume(); gate = nil }
    func preferences(userID: UserID, now: Date) throws -> V2LiveActivityPreferences { throw CancellationError() }
    func presence(roomID: RoomID, viewerUserID: UserID, now: Date) throws -> V2PresenceState { throw CancellationError() }
    func authorizeTyping(roomID: RoomID, actorUserID: UserID, now: Date) throws { throw CancellationError() }
    func authorizeObservation(roomID: RoomID, viewerUserID: UserID, subjectUserID: UserID, now: Date) throws { throw CancellationError() }
    func allowsOnlinePresence(userID: UserID) -> Bool { false }
}
