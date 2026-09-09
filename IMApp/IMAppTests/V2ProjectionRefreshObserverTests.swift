import Foundation
import Testing
@testable import IMApp

@MainActor
@Suite("Projection refresh ownership", .timeLimit(.minutes(1)))
struct V2ProjectionRefreshObserverTests {
    @Test("ordinary updates merge into one follow-up without cancelling the active read")
    func ordinaryUpdatesAreBounded() async throws {
        let probe = ProjectionRefreshProbe()
        let notifier = V2ProjectionChangeNotifier()
        let owner = V2ProjectionRefreshObserver { await probe.refresh() }
        let updates = await notifier.updates()
        let observation = Task { await owner.run(updates) }
        await probe.waitForStarts(1)
        for generation in 1...40 { owner.submit(.init(generation: UInt64(generation), requiresImmediateRefresh: false)) }
        await probe.release(1)
        await probe.waitForStarts(2)
        #expect(await probe.committed == [1])
        #expect(await probe.cancelled.isEmpty)
        await probe.release(2)
        await probe.waitForFinishes(2)
        await notifier.finish()
        await observation.value
        #expect(await probe.started == 2)
        #expect(await probe.maximumActive == 1)
        #expect(await probe.committed == [1, 2])
    }

    @Test("urgent work cancels and drains the old read; page exit drains its replacement")
    func urgentReadAndExit() async throws {
        let probe = ProjectionRefreshProbe()
        let notifier = V2ProjectionChangeNotifier()
        let owner = V2ProjectionRefreshObserver { await probe.refresh() }
        let observation = Task { await owner.run(await notifier.updates()) }
        await probe.waitForStarts(1)
        owner.submit(.init(generation: 1, requiresImmediateRefresh: true))
        await probe.waitForStarts(2)
        #expect(await probe.finished == [1])
        #expect(await probe.cancelled == [1])
        #expect(await probe.committed.isEmpty)
        #expect(await probe.maximumActive == 1)
        observation.cancel()
        await observation.value
        #expect(await probe.finished == [1, 2])
        #expect(await probe.cancelled == [1, 2])
        #expect(await probe.activeCount == 0)
        await notifier.finish()
    }
}

private actor ProjectionRefreshProbe {
    private(set) var started = 0
    private(set) var finished: [Int] = []
    private(set) var cancelled: [Int] = []
    private(set) var committed: [Int] = []
    private(set) var maximumActive = 0
    private var active = Set<Int>()
    private var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    private var arrivals: [(Bool, Int, CheckedContinuation<Void, Never>)] = []
    var activeCount: Int { active.count }

    func refresh() async {
        started += 1
        let id = started
        active.insert(id)
        maximumActive = max(maximumActive, active.count)
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                gates[id] = continuation
                notifyArrivals()
                if Task.isCancelled { cancel(id) }
            }
        }, onCancel: { Task { await self.cancel(id) } })
        if !Task.isCancelled { committed.append(id) }
        active.remove(id)
        finished.append(id)
        notifyArrivals()
    }
    func release(_ id: Int) { gates.removeValue(forKey: id)?.resume() }
    private func cancel(_ id: Int) {
        guard let continuation = gates.removeValue(forKey: id) else { return }
        cancelled.append(id)
        continuation.resume()
    }
    func waitForStarts(_ count: Int) async {
        guard started < count || (gates[count] == nil && !finished.contains(count)) else { return }
        await withCheckedContinuation { arrivals.append((true, count, $0)) }
    }
    func waitForFinishes(_ count: Int) async {
        guard finished.count < count else { return }
        await withCheckedContinuation { arrivals.append((false, count, $0)) }
    }
    private func notifyArrivals() {
        let ready = arrivals.filter { ($0.0 ? started : finished.count) >= $0.1 }
        arrivals.removeAll { ($0.0 ? started : finished.count) >= $0.1 }
        for (_, _, continuation) in ready { continuation.resume() }
    }
}
