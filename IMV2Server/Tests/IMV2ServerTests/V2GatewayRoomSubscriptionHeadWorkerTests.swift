import Foundation
import Testing
import IMV2Core
@testable import IMV2ServerGateway

@Suite("Room head worker pending capacity", .timeLimit(.minutes(1)))
struct V2GatewayRoomSubscriptionHeadWorkerTests {
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
