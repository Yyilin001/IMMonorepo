import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core
import Testing

@Suite("Bounded room and host command admission")
struct V2RoomCommandBudgetTests {
    @Test("a full hot room leaves capacity for a healthy room")
    func roomIsolation() async throws {
        let budget = V2RoomCommandBudget(configuration: try configuration())
        let hot = try RoomID("hot")
        let healthy = try RoomID("healthy")
        let first = try await budget.acquire(roomID: hot, byteCount: 10)
        let second = try await budget.acquire(roomID: hot, byteCount: 10)
        await #expect(throws: V2RoomCallFailure.notAccepted(.overloaded)) {
            try await budget.acquire(roomID: hot, byteCount: 1)
        }
        let third = try await budget.acquire(roomID: healthy, byteCount: 10)
        #expect(await budget.snapshot().commandCount == 3)
        #expect(await budget.release(first))
        #expect(await budget.release(second))
        #expect(await budget.release(third))
        #expect(await budget.snapshot().roomCount == 0)
    }

    @Test("simultaneous rooms cannot exceed the host's count or byte budget")
    func concurrentHostAdmission() async throws {
        let budget = V2RoomCommandBudget(configuration: try configuration())
        let permits = try await withThrowingTaskGroup(of: V2RoomCommandPermit?.self) { group in
            for index in 0..<100 {
                let room = try RoomID("room-\(index)")
                group.addTask {
                    do { return try await budget.acquire(roomID: room, byteCount: 10) }
                    catch V2RoomCallFailure.notAccepted(.overloaded) { return nil }
                }
            }
            var accepted: [V2RoomCommandPermit] = []
            for try await permit in group {
                if let permit { accepted.append(permit) }
            }
            return accepted
        }
        #expect(permits.count == 4)
        #expect(await budget.snapshot().byteCount == 40)
        for permit in permits { #expect(await budget.release(permit)) }
        #expect(await budget.snapshot().commandCount == 0)
        #expect(await budget.snapshot().byteCount == 0)
    }

    @Test("capacity returns exactly once and only to the issuing budget")
    func duplicateAndForeignRelease() async throws {
        let first = V2RoomCommandBudget(configuration: try configuration())
        let other = V2RoomCommandBudget(configuration: try configuration())
        let permit = try await first.acquire(roomID: RoomID("room"), byteCount: 10)
        #expect(!(await other.release(permit)))
        #expect(await first.snapshot().byteCount == 10)
        let releaseCount = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 { group.addTask { await first.release(permit) } }
            var count = 0
            for await released in group where released { count += 1 }
            return count
        }
        #expect(releaseCount == 1)
        #expect(await first.snapshot().byteCount == 0)
    }

    @Test("byte limits reject before consuming a permit")
    func byteAdmission() async throws {
        let budget = V2RoomCommandBudget(configuration: try configuration())
        let room = try RoomID("room")
        await #expect(throws: V2RoomCallFailure.notAccepted(.invalidRequest)) {
            try await budget.acquire(roomID: room, byteCount: 0)
        }
        await #expect(throws: V2RoomCallFailure.notAccepted(.invalidRequest)) {
            try await budget.acquire(roomID: room, byteCount: Int.max)
        }
        let first = try await budget.acquire(roomID: room, byteCount: 24)
        await #expect(throws: V2RoomCallFailure.notAccepted(.overloaded)) {
            try await budget.acquire(roomID: room, byteCount: 7)
        }
        let second = try await budget.acquire(roomID: RoomID("other"), byteCount: 16)
        await #expect(throws: V2RoomCallFailure.notAccepted(.overloaded)) {
            try await budget.acquire(roomID: RoomID("third"), byteCount: 1)
        }
        #expect(await budget.snapshot().commandCount == 2)
        #expect(await budget.release(first))
        #expect(await budget.release(second))
    }

    private func configuration() throws -> V2RoomRuntimeConfiguration {
        try V2RoomRuntimeConfiguration(
            maximumActiveRooms: 4, maximumConcurrentRestores: 2,
            maximumQueuedCommandsPerRoom: 2, maximumQueuedBytesPerRoom: 30,
            maximumQueuedCommandsPerHost: 4, maximumQueuedBytesPerHost: 40,
            maximumRequestBytes: 30, maximumCommandsPerTurn: 2,
            maximumBytesPerTurn: 30, maximumConcurrentReservations: 2
        )
    }
}
