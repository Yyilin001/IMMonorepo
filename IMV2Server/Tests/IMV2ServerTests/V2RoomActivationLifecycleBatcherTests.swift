@testable import IMV2ServerInfrastructure
import Foundation
import IMV2ActorContracts
import IMV2Core
import Testing

@Suite("Activation lifecycle actual task ownership", .serialized, .timeLimit(.minutes(1)))
struct V2RoomActivationLifecycleBatcherTests {
    @Test("full slots still expire queued originals; cancellation and shutdown retain actual ownership")
    func deadlinesCancellationAndDrain() async throws {
        let controller = LifecycleExecutorController()
        let batcher = V2RoomActivationLifecycleBatcher { inputs, deadline in
            try await controller.execute(inputs, deadline: deadline)
        }
        let firstInput = try input(), secondInput = try input()
        let first = Task { try await batcher.execute(firstInput) }
        try await controller.waitForCalls(1)
        let second = Task { try await batcher.execute(secondInput) }
        try await controller.waitForCalls(2)
        first.cancel()
        let expiresAt = ContinuousClock.now + .milliseconds(40)
        let expiring = Task {
            try await V2RoomSQLDeadline.withDeadline(expiresAt) { try await batcher.execute(firstInput) }
        }
        await #expect(throws: V2RoomCallFailure.notAccepted(.deadlineExceeded)) { _ = try await expiring.value }
        #expect(await controller.callCount == 2)
        let cancelledInput = try input()
        let cancelled = Task { try await batcher.execute(cancelledInput) }
        cancelled.cancel()
        _ = await cancelled.result
        #expect(await controller.callCount == 2)
        let closed = LifecycleCompletionMarker()
        let queued = Task { try await batcher.execute(firstInput) }
        let shutdown = Task { await batcher.shutdown(); await closed.finish() }
        await #expect(throws: V2RoomCallFailure.notAccepted(.retired)) { _ = try await queued.value }
        await #expect(throws: V2RoomCallFailure.notAccepted(.retired)) { _ = try await batcher.execute(firstInput) }
        #expect(await closed.finished == false)
        await controller.release(0)
        _ = await first.result
        #expect(await closed.finished == false)
        await controller.release(1)
        _ = await second.result
        await shutdown.value
        #expect(await closed.finished)
        #expect(await controller.callCount == 2)
        await batcher.shutdown()
    }

    @Test("canonical room FIFO persists through actual settlement while other rooms proceed")
    func canonicalRoomSerializes() async throws {
        let controller = LifecycleExecutorController()
        let batcher = V2RoomActivationLifecycleBatcher { inputs, deadline in
            try await controller.execute(inputs, deadline: deadline)
        }
        let original = try input()
        let alias = V2RoomActivationLifecycleInput(roomID: try RoomID(original.roomID.rawValue.lowercased()), operation: original.operation)
        let first = Task { try await batcher.execute(original) }
        try await controller.waitForCalls(1)
        let nextDeadline = ContinuousClock.now + .seconds(3)
        let successor = Task {
            try await V2RoomSQLDeadline.withDeadline(nextDeadline) { try await batcher.execute(alias) }
        }
        let unrelatedInput = try input()
        let unrelated = Task { try await batcher.execute(unrelatedInput) }
        try await controller.waitForCalls(2)
        #expect(await controller.rooms(at: 1) == [unrelatedInput.roomID.uuidValue!])
        await controller.release(0)
        _ = try await first.value
        try await controller.waitForCalls(3)
        #expect(await controller.rooms(at: 2) == [original.roomID.uuidValue!])
        #expect(await controller.deadline(at: 2) == nextDeadline)
        await controller.release(1)
        await controller.release(2)
        _ = try await unrelated.value
        _ = try await successor.value
        await batcher.shutdown()
    }

    private func input() throws -> V2RoomActivationLifecycleInput {
        .init(roomID: try .init(UUID().uuidString), operation: .locate(owner: try .init(shardID: "owner-a", epoch: 0)))
    }
}

private actor LifecycleExecutorController {
    private struct Call {
        let rooms: [UUID]
        let deadline: ContinuousClock.Instant
    }
    private var calls: [Call] = []
    private var held: [Int: CheckedContinuation<Void, Never>] = [:]
    var callCount: Int { calls.count }
    func rooms(at index: Int) -> [UUID] { calls[index].rooms }
    func deadline(at index: Int) -> ContinuousClock.Instant { calls[index].deadline }
    func execute(_ inputs: [V2RoomActivationLifecycleInput], deadline: ContinuousClock.Instant) async throws -> [Result<V2RoomActivationLifecycleValue, any Error>] {
        #expect(V2RoomSQLDeadline.current == deadline)
        let index = calls.count
        calls.append(.init(rooms: inputs.map { $0.roomID.uuidValue! }, deadline: deadline))
        await withCheckedContinuation { held[index] = $0 }
        return inputs.map { _ in .success(.located(nil)) }
    }
    func release(_ index: Int) { held.removeValue(forKey: index)?.resume() }
    func waitForCalls(_ count: Int) async throws {
        let limit = ContinuousClock.now + .seconds(5)
        while calls.count < count {
            guard ContinuousClock.now < limit else { throw LifecycleExecutorFailure.timeout }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}
private enum LifecycleExecutorFailure: Error { case timeout }
private actor LifecycleCompletionMarker {
    var finished = false
    func finish() { finished = true }
}
