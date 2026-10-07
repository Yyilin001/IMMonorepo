import Testing
@testable import IMV2ServerGateway

@Suite("Recovery demand scheduling indexes")
struct V2RecoveryOrderedStoreSchedulingTests {
    typealias Store = V2RecoveryOrderedStore<Int, Int>

    @Test("ordinary demand updates preserve ready FIFO while future queued positions remain exchangeable")
    func readyFIFOAndFutureVictimOwnership() {
        var store = Store()
        let now = ContinuousClock.now
        for key in 0..<4 {
            store[key] = key
            store.setScheduling(.init(classIndex: 3, placement: .queued,
                readyAt: key == 0 ? now + .seconds(5) : now), for: key, now: now)
        }
        #expect(store.schedulingCount(placement: .queued) == 4)
        #expect(store.schedulingCount(placement: .queued, classIndex: 3, eligibleOnly: true) == 3)
        #expect(store.peekScheduled(classIndex: 3, placement: .queued)?.key == 1)
        #expect(store.peekScheduled(classIndex: 3, placement: .queued, eligibleOnly: false)?.key == 0)
        // Merged watermarks update the sole primary value without moving its
        // scheduler position or manufacturing another future-deadline entry.
        for value in 10..<100 {
            store[1] = value
            store.setScheduling(.init(classIndex: 3, placement: .queued, readyAt: now), for: 1, now: now)
        }
        #expect(store.peekScheduled(classIndex: 3, placement: .queued)?.key == 1)
        #expect(store.peekScheduled(classIndex: 3, placement: .queued)?.value == 99)
        #expect(store.rotateScheduled(classIndex: 3, placement: .queued)?.key == 1)
        #expect(store.peekScheduled(classIndex: 3, placement: .queued)?.key == 2)
        store.setScheduling(.init(classIndex: 3, placement: .owned, readyAt: now), for: 0, now: now)
        #expect(store.peekScheduled(classIndex: 3, placement: .queued, eligibleOnly: false)?.key == 2)
        #expect(store.schedulingCount(placement: .owned) == 1)
        #expect(store.peekScheduled(classIndex: 3, placement: .owned, eligibleOnly: false) == nil)
        #expect(store.schedulingDeadlineCount == 0)
        store.setScheduling(.init(classIndex: 4, placement: .primary, readyAt: now), for: 2, now: now)
        #expect(store.peekScheduled(classIndex: 3, placement: .queued)?.key == 3)
        #expect(store.peekScheduled(classIndex: 4, placement: .primary)?.key == 2)
        #expect(Set(store.keys(at: .queued)) == [1, 3])
    }

    @Test("deadline changes replace one heap entry and expiry promotion preserves position ownership")
    func exactDeadlineUpdateAndPromotion() {
        var store = Store()
        let now = ContinuousClock.now
        for key in 0..<3 {
            store[key] = key
            store.setScheduling(.init(classIndex: 2, placement: .queued,
                readyAt: now + .seconds(10 + key)), for: key, now: now)
        }
        for offset in (1...100).reversed() {
            store.setScheduling(.init(classIndex: 2, placement: .queued,
                readyAt: now + .seconds(200), refreshAt: now + .milliseconds(offset)), for: 0, now: now)
        }
        #expect(store.schedulingDeadlineCount == 3)
        #expect(store.earliestSchedulingDeadline == now + .milliseconds(1))
        #expect(store.popDueScheduling(now: now + .milliseconds(1)) == [0])
        #expect(store.schedulingCount(placement: .queued) == 3)
        // The owner consumes the expired authority, then reschedules a fresh
        // classification; popping a deadline never releases its queue position.
        store.setScheduling(.init(classIndex: 3, placement: .queued,
            readyAt: now), for: 0, now: now + .milliseconds(1))
        #expect(store.peekScheduled(classIndex: 3, placement: .queued)?.key == 0)
        #expect(store.schedulingDeadlineCount == 2)
        _ = store.removeValue(forKey: 1)
        #expect(store.schedulingDeadlineCount == 1)
        #expect(store.earliestSchedulingDeadline == now + .seconds(12))
        #expect(store.popDueScheduling(now: now + .seconds(12)) == [2])
        store.setScheduling(.init(classIndex: 2, placement: .queued,
            readyAt: now + .seconds(12)), for: 2, now: now + .seconds(12))
        #expect(store.schedulingCount(placement: .queued, eligibleOnly: true) == 2)
        #expect(store.earliestSchedulingDeadline == nil)
        #expect(store.count == 2)
    }

    @Test("due cohorts remain bounded and deleting or taking ownership removes exact pending deadlines")
    func boundedDueWorkAndRemoval() {
        var store = Store()
        let now = ContinuousClock.now
        for key in 0..<700 {
            store[key] = key
            store.setScheduling(.init(classIndex: key % 7, placement: .primary,
                readyAt: now + .seconds(1)), for: key, now: now)
        }
        for key in 0..<100 { _ = store.removeValue(forKey: key) }
        for key in 100..<200 {
            store.setScheduling(.init(classIndex: key % 7, placement: .owned,
                readyAt: now + .seconds(1)), for: key, now: now)
        }
        #expect(store.schedulingDeadlineCount == 500)
        var returned: Set<Int> = []
        while store.earliestSchedulingDeadline != nil {
            let due = store.popDueScheduling(now: now + .seconds(1), limit: 1_000)
            #expect(!due.isEmpty && due.count <= 128)
            #expect(returned.isDisjoint(with: due))
            returned.formUnion(due)
            for key in due {
                store.setScheduling(.init(classIndex: key % 7, placement: .primary,
                    readyAt: now + .seconds(1)), for: key, now: now + .seconds(1))
            }
        }
        #expect(returned == Set(200..<700))
        #expect(store.schedulingCount(placement: .primary, eligibleOnly: true) == 500)
        #expect(store.schedulingCount(placement: .owned) == 100)
        store.removeAll()
        #expect(store.isEmpty && store.schedulingDeadlineCount == 0)
        #expect(store.peekScheduled(classIndex: 0, placement: .primary) == nil)
    }
}
