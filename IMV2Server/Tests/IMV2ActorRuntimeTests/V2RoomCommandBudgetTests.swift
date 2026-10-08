import Foundation
import IMV2ActorContracts
@testable import IMV2ActorRuntime
import IMV2Core
import Testing

@Suite("Bounded room and host command admission")
struct V2RoomCommandBudgetTests {
    @Test("a full hot room leaves capacity for a healthy room")
    func roomIsolation() async throws {
        let budget = V2RoomCommandBudget(configuration: try configuration())
        let hot = try RoomID("hot")
        let healthy = try RoomID("healthy")
        let first = try budget.acquire(roomID: hot, encodedRequest: bytes(10))
        let second = try budget.acquire(roomID: hot, encodedRequest: bytes(10))
        #expect(throws: V2RoomCallFailure.notAccepted(.overloaded)) {
            try budget.acquire(roomID: hot, encodedRequest: bytes(1))
        }
        let third = try budget.acquire(roomID: healthy, encodedRequest: bytes(10))
        #expect(budget.snapshot().commandCount == 3)
        #expect(budget.release(first))
        #expect(budget.release(second))
        #expect(budget.release(third))
        let drained = budget.snapshot()
        #expect(drained.roomCount == 0)
        #expect(drained.commandCount == 0)
        #expect(drained.byteCount == 0)
        #expect(drained.peakCommandCount == 3)
        #expect(drained.peakByteCount == 30)
        #expect(budget.snapshot() == drained)
    }

    @Test("simultaneous rooms cannot exceed the host's count or byte budget")
    func concurrentHostAdmission() async throws {
        let budget = V2RoomCommandBudget(configuration: try configuration())
        let permits = try await withThrowingTaskGroup(of: V2RoomCommandPermit?.self) { group in
            for index in 0..<100 {
                let room = try RoomID("room-\(index)")
                group.addTask {
                    do { return try budget.acquire(roomID: room, encodedRequest: bytes(10)) }
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
        #expect(budget.snapshot().byteCount == 40)
        for permit in permits { #expect(budget.release(permit)) }
        #expect(budget.snapshot().commandCount == 0)
        #expect(budget.snapshot().byteCount == 0)
    }

    @Test("capacity returns exactly once and only to the issuing budget")
    func duplicateAndForeignRelease() async throws {
        let first = V2RoomCommandBudget(configuration: try configuration())
        let other = V2RoomCommandBudget(configuration: try configuration())
        let permit = try first.acquire(roomID: RoomID("room"), encodedRequest: bytes(10))
        #expect(!(other.release(permit)))
        #expect(first.snapshot().byteCount == 10)
        let releaseCount = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 { group.addTask { first.release(permit) } }
            var count = 0
            for await released in group where released { count += 1 }
            return count
        }
        #expect(releaseCount == 1)
        #expect(first.snapshot().byteCount == 0)
    }

    @Test("byte limits reject before consuming a permit")
    func byteAdmission() async throws {
        let budget = V2RoomCommandBudget(configuration: try configuration())
        let room = try RoomID("room")
        #expect(throws: V2RoomCallFailure.notAccepted(.invalidRequest)) {
            try budget.acquire(roomID: room, encodedRequest: Data())
        }
        #expect(throws: V2RoomCallFailure.notAccepted(.invalidRequest)) {
            try budget.acquire(roomID: room, encodedRequest: bytes(31))
        }
        let first = try budget.acquire(roomID: room, encodedRequest: bytes(24))
        #expect(first.encodedRequest == bytes(24))
        #expect(first.byteCount == first.encodedRequest.count)
        #expect(throws: V2RoomCallFailure.notAccepted(.overloaded)) {
            try budget.acquire(roomID: room, encodedRequest: bytes(7))
        }
        let second = try budget.acquire(roomID: RoomID("other"), encodedRequest: bytes(16))
        #expect(throws: V2RoomCallFailure.notAccepted(.overloaded)) {
            try budget.acquire(roomID: RoomID("third"), encodedRequest: bytes(1))
        }
        #expect(budget.snapshot().commandCount == 2)
        #expect(budget.release(first))
        #expect(budget.release(second))
    }

    @Test("concurrent reservation accounting shares capacity and returns exactly once")
    func concurrentReservations() async throws {
        let budget = V2RoomCommandBudget(configuration: try configuration())
        let permits = await withTaskGroup(of: V2RoomCommandPermit?.self) { group in
            for index in 0..<100 {
                group.addTask {
                    do {
                        return try budget.acquireReservation(roomID: RoomID("reserved-\(index)"),
                                                             encodedRequest: bytes(10))
                    } catch { return nil }
                }
            }
            var accepted: [V2RoomCommandPermit] = []
            for await permit in group { if let permit { accepted.append(permit) } }
            return accepted
        }
        #expect(permits.count == 2)
        #expect(budget.snapshot().reservationCount == 2)
        let ordinary = try budget.acquire(roomID: RoomID("ordinary"), encodedRequest: bytes(20))
        #expect(budget.snapshot().byteCount == 40)
        #expect(throws: V2RoomCallFailure.notAccepted(.overloaded)) {
            try budget.acquire(roomID: RoomID("full"), encodedRequest: bytes(1))
        }
        let releases = await withTaskGroup(of: Bool.self) { group in
            for permit in permits + [ordinary] {
                for _ in 0..<20 { group.addTask { budget.release(permit) } }
            }
            var count = 0
            for await released in group where released { count += 1 }
            return count
        }
        #expect(releases == 3)
        let drained = budget.snapshot()
        #expect(drained.commandCount == 0)
        #expect(drained.byteCount == 0)
        #expect(drained.reservationCount == 0)
        #expect(drained.roomCount == 0)
        #expect(drained.peakCommandCount == 3)
        #expect(drained.peakByteCount == 40)
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

    private func bytes(_ count: Int) -> Data { Data(repeating: 65, count: count) }
}
