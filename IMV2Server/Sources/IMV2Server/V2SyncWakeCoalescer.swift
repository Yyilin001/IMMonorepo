import Foundation
import IMV2Core

public struct V2SyncWakeCoalescerSnapshot: Equatable, Sendable {
    public let pendingUsers: Int
    public let inFlightUsers: Int
    public let coalescedNotifications: UInt64
    public let deliveredNotifications: UInt64
    public let droppedNotifications: UInt64
}

/// Coalesces best-effort availability hints while preserving the greatest
/// known durable watermark for each user. One lifecycle task owns the periodic
/// flush; each flush uses bounded structured concurrency so one slow channel
/// cannot serialize the entire online audience.
public actor V2SyncWakeCoalescer: V2LiveSyncNotifier {
    private struct PendingWake: Sendable {
        var eventID: UInt64
        var highWatermark: UInt64
    }

    private struct Delivery: Sendable {
        let userID: UserID
        let wake: PendingWake
    }

    private struct InFlightWake: Sendable {
        let delivering: PendingWake
        var followUp: PendingWake?
    }

    private let downstream: any V2LiveSyncNotifier
    private let interval: Duration
    private let maximumTrackedUsers: Int
    private let maximumConcurrentDeliveries: Int
    private let clock = ContinuousClock()
    private var pending: [UserID: PendingWake] = [:]
    private var inFlight: [UserID: InFlightWake] = [:]
    private var coalescedNotifications: UInt64 = 0
    private var deliveredNotifications: UInt64 = 0
    private var droppedNotifications: UInt64 = 0
    private var isRunning = false
    private var isFlushing = false

    public init(
        downstream: any V2LiveSyncNotifier,
        interval: Duration,
        maximumPendingUsers: Int,
        maximumConcurrentDeliveries: Int
    ) {
        precondition(interval > .zero)
        precondition(maximumPendingUsers > 0)
        precondition(maximumConcurrentDeliveries > 0)
        self.downstream = downstream
        self.interval = interval
        maximumTrackedUsers = maximumPendingUsers
        self.maximumConcurrentDeliveries = maximumConcurrentDeliveries
    }

    public func notifySyncAvailable(
        userID: UserID,
        eventID: UInt64,
        highWatermark: UInt64
    ) {
        if var existing = pending[userID] {
            coalescedNotifications = saturatingIncrement(coalescedNotifications)
            if highWatermark >= existing.highWatermark {
                existing.eventID = eventID
                existing.highWatermark = highWatermark
                pending[userID] = existing
            }
            return
        }
        if var existing = inFlight[userID] {
            coalescedNotifications = saturatingIncrement(coalescedNotifications)
            let knownHighWatermark = max(
                existing.delivering.highWatermark,
                existing.followUp?.highWatermark ?? 0
            )
            if highWatermark > knownHighWatermark {
                existing.followUp = .init(
                    eventID: eventID,
                    highWatermark: highWatermark
                )
                inFlight[userID] = existing
            }
            return
        }
        guard pending.count + inFlight.count < maximumTrackedUsers else {
            // Hints are explicitly lossy; clients recover through cursor pull.
            // Count every bounded-capacity drop, including while an earlier
            // flush is still in flight, so operators can see the real pressure.
            droppedNotifications = saturatingIncrement(droppedNotifications)
            return
        }
        pending[userID] = .init(eventID: eventID, highWatermark: highWatermark)
    }

    public func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        while !Task.isCancelled {
            do {
                try await clock.sleep(for: interval)
            } catch {
                break
            }
            await flush()
        }
        dropPendingForShutdown()
    }

    public func flush() async {
        guard !isFlushing, !pending.isEmpty else { return }
        isFlushing = true
        let batch = pending.map { Delivery(userID: $0.key, wake: $0.value) }
        pending.removeAll(keepingCapacity: true)
        inFlight = Dictionary(uniqueKeysWithValues: batch.map { delivery in
            (delivery.userID, InFlightWake(delivering: delivery.wake, followUp: nil))
        })
        defer { isFlushing = false }

        let downstream = downstream
        func add(
            _ delivery: Delivery,
            to group: inout TaskGroup<(UserID, Bool)>
        ) {
            group.addTask {
                guard !Task.isCancelled else { return (delivery.userID, false) }
                await downstream.notifySyncAvailable(
                    userID: delivery.userID,
                    eventID: delivery.wake.eventID,
                    highWatermark: delivery.wake.highWatermark
                )
                return (delivery.userID, true)
            }
        }

        let concurrency = min(maximumConcurrentDeliveries, batch.count)
        var iterator = batch.makeIterator()
        await withTaskGroup(of: (UserID, Bool).self) { group in
            for _ in 0 ..< concurrency {
                guard let delivery = iterator.next() else { break }
                add(delivery, to: &group)
            }
            while let (userID, delivered) = await group.next() {
                let completed = inFlight.removeValue(forKey: userID)
                if let followUp = completed?.followUp {
                    pending[userID] = followUp
                }
                if delivered {
                    deliveredNotifications = saturatingIncrement(deliveredNotifications)
                }
                if !delivered {
                    droppedNotifications = saturatingIncrement(droppedNotifications)
                }
                guard let delivery = iterator.next() else { continue }
                add(delivery, to: &group)
            }
        }
        assert(inFlight.isEmpty)
    }

    public func snapshot() -> V2SyncWakeCoalescerSnapshot {
        .init(
            pendingUsers: pending.count,
            inFlightUsers: inFlight.count,
            coalescedNotifications: coalescedNotifications,
            deliveredNotifications: deliveredNotifications,
            droppedNotifications: droppedNotifications
        )
    }

    private func dropPendingForShutdown() {
        guard !pending.isEmpty else { return }
        droppedNotifications = saturatingAdd(
            droppedNotifications,
            UInt64(pending.count)
        )
        pending.removeAll(keepingCapacity: false)
    }

    private func saturatingIncrement(_ value: UInt64) -> UInt64 {
        value == .max ? .max : value + 1
    }

    private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }
}
