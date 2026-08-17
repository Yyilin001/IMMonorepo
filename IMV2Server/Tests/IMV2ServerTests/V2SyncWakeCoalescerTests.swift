import Foundation
import IMV2Core
@testable import IMV2Server
import Synchronization
import Testing

@Suite("V2 Sync wake coalescer")
struct V2SyncWakeCoalescerTests {
    @Test("one user receives only the greatest pending watermark")
    func coalescesByUser() async throws {
        let downstream = SyncWakeProbe()
        let coalescer = V2SyncWakeCoalescer(
            downstream: downstream,
            interval: .seconds(1),
            maximumPendingUsers: 10,
            maximumConcurrentDeliveries: 2
        )
        let userID = try UserID("00000000-0000-0000-0000-000000000001")
        await coalescer.notifySyncAvailable(userID: userID, eventID: 5, highWatermark: 5)
        await coalescer.notifySyncAvailable(userID: userID, eventID: 7, highWatermark: 7)
        await coalescer.notifySyncAvailable(userID: userID, eventID: 6, highWatermark: 6)
        await coalescer.flush()

        #expect(await downstream.values() == [
            .init(userID: userID, eventID: 7, highWatermark: 7)
        ])
        #expect(await coalescer.snapshot().coalescedNotifications == 2)
    }

    @Test("pending memory is bounded and overflow remains best effort")
    func boundsPendingUsers() async throws {
        let downstream = SyncWakeProbe()
        let coalescer = V2SyncWakeCoalescer(
            downstream: downstream,
            interval: .seconds(1),
            maximumPendingUsers: 1,
            maximumConcurrentDeliveries: 1
        )
        let first = try UserID("00000000-0000-0000-0000-000000000001")
        let second = try UserID("00000000-0000-0000-0000-000000000002")
        await coalescer.notifySyncAvailable(userID: first, eventID: 1, highWatermark: 1)
        await coalescer.notifySyncAvailable(userID: second, eventID: 2, highWatermark: 2)
        #expect(await coalescer.snapshot() == .init(
            pendingUsers: 1, inFlightUsers: 0,
            coalescedNotifications: 0, deliveredNotifications: 0,
            droppedNotifications: 1
        ))
    }

    @Test("flush uses bounded parallel downstream delivery")
    func boundsParallelDelivery() async throws {
        let downstream = ConcurrentSyncWakeProbe()
        let coalescer = V2SyncWakeCoalescer(
            downstream: downstream,
            interval: .seconds(1),
            maximumPendingUsers: 10,
            maximumConcurrentDeliveries: 2
        )
        for value in 1 ... 6 {
            let userID = try UserID(String(format:
                "00000000-0000-0000-0000-%012d", value
            ))
            await coalescer.notifySyncAvailable(
                userID: userID,
                eventID: UInt64(value),
                highWatermark: UInt64(value)
            )
        }
        await coalescer.flush()
        let snapshot = downstream.snapshot()
        #expect(snapshot.delivered == 6)
        #expect(snapshot.maximumInFlight == 2)
        let coalescerSnapshot = await coalescer.snapshot()
        #expect(coalescerSnapshot.inFlightUsers == 0)
        #expect(coalescerSnapshot.deliveredNotifications == 6)
    }

    @Test("a higher watermark arriving in flight is delivered as one follow-up")
    func preservesInFlightFollowUpWithoutDoubleCountingCapacity() async throws {
        let downstream = GatedSyncWakeProbe()
        let coalescer = V2SyncWakeCoalescer(
            downstream: downstream,
            interval: .seconds(1),
            maximumPendingUsers: 2,
            maximumConcurrentDeliveries: 1
        )
        let first = try UserID("00000000-0000-0000-0000-000000000001")
        let second = try UserID("00000000-0000-0000-0000-000000000002")
        let overflow = try UserID("00000000-0000-0000-0000-000000000003")
        await coalescer.notifySyncAvailable(
            userID: first, eventID: 1, highWatermark: 1
        )
        let flush = Task { await coalescer.flush() }
        await downstream.waitUntilFirstDeliveryStarts()
        #expect(await coalescer.snapshot().inFlightUsers == 1)

        await coalescer.notifySyncAvailable(
            userID: first, eventID: 2, highWatermark: 2
        )
        await coalescer.notifySyncAvailable(
            userID: second, eventID: 3, highWatermark: 3
        )
        await coalescer.notifySyncAvailable(
            userID: overflow, eventID: 4, highWatermark: 4
        )
        await downstream.releaseFirstDelivery()
        await flush.value

        let betweenFlushes = await coalescer.snapshot()
        #expect(betweenFlushes.pendingUsers == 2)
        #expect(betweenFlushes.inFlightUsers == 0)
        #expect(betweenFlushes.coalescedNotifications == 1)
        #expect(betweenFlushes.droppedNotifications == 1)
        await coalescer.flush()
        let delivered = await downstream.values()
        #expect(delivered.count == 3)
        #expect(delivered.first == .init(
            userID: first, eventID: 1, highWatermark: 1
        ))
        #expect(Set(delivered.dropFirst().map(\.eventID)) == [2, 3])
        #expect(await coalescer.snapshot().deliveredNotifications == 3)
    }

    @Test("shutdown accounts for every hint that never entered delivery")
    func shutdownDropsPendingHintsObservably() async throws {
        let coalescer = V2SyncWakeCoalescer(
            downstream: SyncWakeProbe(),
            interval: .seconds(10),
            maximumPendingUsers: 2,
            maximumConcurrentDeliveries: 1
        )
        for value in 1 ... 2 {
            let userID = try UserID(String(format:
                "00000000-0000-0000-0000-%012d", value
            ))
            await coalescer.notifySyncAvailable(
                userID: userID,
                eventID: UInt64(value),
                highWatermark: UInt64(value)
            )
        }
        let lifecycle = Task { await coalescer.run() }
        await Task.yield()
        lifecycle.cancel()
        await lifecycle.value

        let snapshot = await coalescer.snapshot()
        #expect(snapshot.pendingUsers == 0)
        #expect(snapshot.inFlightUsers == 0)
        #expect(snapshot.deliveredNotifications == 0)
        #expect(snapshot.droppedNotifications == 2)
    }
}

private struct RecordedSyncWake: Equatable, Sendable {
    let userID: UserID
    let eventID: UInt64
    let highWatermark: UInt64
}

private actor SyncWakeProbe: V2LiveSyncNotifier {
    private var recorded: [RecordedSyncWake] = []

    func notifySyncAvailable(userID: UserID, eventID: UInt64, highWatermark: UInt64) {
        recorded.append(.init(
            userID: userID, eventID: eventID, highWatermark: highWatermark
        ))
    }

    func values() -> [RecordedSyncWake] { recorded }
}

private actor GatedSyncWakeProbe: V2LiveSyncNotifier {
    private var recorded: [RecordedSyncWake] = []
    private var firstDeliveryStarted = false
    private var shouldGateFirstDelivery = true
    private var gate: CheckedContinuation<Void, Never>?

    func notifySyncAvailable(
        userID: UserID,
        eventID: UInt64,
        highWatermark: UInt64
    ) async {
        if shouldGateFirstDelivery {
            shouldGateFirstDelivery = false
            firstDeliveryStarted = true
            await withCheckedContinuation { continuation in
                gate = continuation
            }
        }
        recorded.append(.init(
            userID: userID,
            eventID: eventID,
            highWatermark: highWatermark
        ))
    }

    func waitUntilFirstDeliveryStarts() async {
        while !firstDeliveryStarted { await Task.yield() }
    }

    func releaseFirstDelivery() {
        gate?.resume()
        gate = nil
    }

    func values() -> [RecordedSyncWake] { recorded }
}

private final class ConcurrentSyncWakeProbe: V2LiveSyncNotifier, Sendable {
    struct Snapshot: Sendable {
        let delivered: Int
        let maximumInFlight: Int
    }

    private struct State: Sendable {
        var inFlight = 0
        var delivered = 0
        var maximumInFlight = 0
    }

    private let state = Mutex(State())

    func notifySyncAvailable(
        userID _: UserID,
        eventID _: UInt64,
        highWatermark _: UInt64
    ) async {
        state.withLock { state in
            state.inFlight += 1
            state.maximumInFlight = max(state.maximumInFlight, state.inFlight)
        }
        try? await Task.sleep(for: .milliseconds(10))
        state.withLock { state in
            state.inFlight -= 1
            state.delivered += 1
        }
    }

    func snapshot() -> Snapshot {
        state.withLock {
            .init(delivered: $0.delivered, maximumInFlight: $0.maximumInFlight)
        }
    }
}
