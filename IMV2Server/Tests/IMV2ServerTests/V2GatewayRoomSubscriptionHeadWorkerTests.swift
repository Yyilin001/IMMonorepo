import Foundation
import Synchronization
import Testing
import IMV2Core
@testable import IMV2ServerGateway

@Suite("Room head worker pending capacity", .timeLimit(.minutes(1)))
struct V2GatewayRoomSubscriptionHeadWorkerTests {
    @Test("a paused room does not block other rooms or overlap its own publications")
    func independentRoomsProgressWhileOneIsHeld() async throws {
        let first = RoomID(uuid: UUID()), second = RoomID(uuid: UUID())
        let release = AsyncStream<Void>.makeStream()
        let observed = Mutex<[(RoomID, UInt64)]>([])
        let worker = V2GatewayRoomSubscriptionHeadWorker(maximumRooms: 2) { room, head in
            observed.withLock { $0.append((room, head)) }
            if room == first, head == 1 { for await _ in release.stream { break } }
        }
        worker.start()
        #expect(worker.offer(roomID: first, highWatermark: 1))
        let started = ContinuousClock.now + .seconds(2)
        while !observed.withLock({ $0.contains { $0.0 == first } }), ContinuousClock.now < started {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(observed.withLock { $0.contains { $0.0 == first } })
        #expect(worker.offer(roomID: first, highWatermark: 3))
        #expect(worker.offer(roomID: first, highWatermark: 2))
        #expect(worker.offer(roomID: second, highWatermark: 7))
        let deadline = ContinuousClock.now + .milliseconds(250)
        while !observed.withLock({ $0.contains { $0.0 == second } }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(observed.withLock { $0.contains { $0.0 == second && $0.1 == 7 } })
        #expect(observed.withLock { $0.filter { $0.0 == first }.count } == 1)
        release.continuation.finish()
        let completed = ContinuousClock.now + .seconds(2)
        while !observed.withLock({ $0.contains { $0.0 == first && $0.1 == 3 } }), ContinuousClock.now < completed {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(observed.withLock { $0.filter { $0.0 == first }.map(\.1) } == [1, 3])
        await worker.shutdown()
    }

    @Test("published rooms release capacity for later account memberships")
    func retiredRoomsDoNotExhaustCapacity() async throws {
        let output = AsyncStream<RoomID>.makeStream()
        let worker = V2GatewayRoomSubscriptionHeadWorker(maximumRooms: 2) { room, _ in
            output.continuation.yield(room)
        }
        worker.start()
        do {
            var delivered = output.stream.makeAsyncIterator()
            for _ in 0..<100 {
                let room = RoomID(uuid: UUID())
                try #require(worker.offer(roomID: room, highWatermark: 1))
                #expect(await delivered.next() == room)
            }
        } catch {
            await worker.shutdown()
            output.continuation.finish()
            throw error
        }
        await worker.shutdown()
        output.continuation.finish()
        #expect(!worker.offer(roomID: RoomID(uuid: UUID()), highWatermark: 1))
    }
    @Test("an in-flight publication retains and coalesces the next head within pending capacity")
    func inFlightHeadIsNotLost() async throws {
        let output = AsyncStream<UInt64>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let worker = V2GatewayRoomSubscriptionHeadWorker(maximumRooms: 1) { _, head in
            output.continuation.yield(head)
            for await _ in release.stream { break }
        }
        worker.start()
        let room = RoomID(uuid: UUID())
        var delivered = output.stream.makeAsyncIterator()
        #expect(worker.offer(roomID: room, highWatermark: 1))
        #expect(await delivered.next() == 1)
        #expect(worker.offer(roomID: room, highWatermark: 10))
        #expect(worker.offer(roomID: room, highWatermark: 9))
        #expect(!worker.offer(roomID: RoomID(uuid: UUID()), highWatermark: 1))
        release.continuation.yield(())
        #expect(await delivered.next() == 10)
        release.continuation.finish()
        await worker.shutdown()
        output.continuation.finish()
    }

}
