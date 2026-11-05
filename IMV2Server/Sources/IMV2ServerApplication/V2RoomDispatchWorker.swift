import Foundation
import IMV2ServerContracts
import IMV2Core

public struct V2RoomDispatchReport: Sendable {
    public var claimedPages = 0
    public var acknowledgedPages = 0
    public var failedPages = 0
}

/// Bounded fanout after the unique room Actor commits. Targets deduplicate each
/// event/user pair; an expired page cannot advance a successor worker's cursor.
public struct V2RoomDispatchWorker: Sendable {
    private let outbox: any V2RoomDispatchOutbox
    private let projector: any V2RoomDispatchProjecting
    private let now: @Sendable () -> Date
    private let concurrency: Int
    private let pageSize: Int

    public init(outbox: any V2RoomDispatchOutbox, projector: any V2RoomDispatchProjecting,
                concurrency: Int = 8, pageSize: Int = 32, now: @escaping @Sendable () -> Date = Date.init) {
        precondition((1...32).contains(concurrency) && (1...256).contains(pageSize))
        self.outbox = outbox; self.projector = projector; self.concurrency = concurrency
        self.pageSize = pageSize; self.now = now
    }

    public func runOnce(limit: Int, leaseDuration: TimeInterval = 30) async throws -> V2RoomDispatchReport {
        guard (1...1024).contains(limit), leaseDuration > 0 else { throw V2RoomDispatchError.invalidInput }
        // Two bounded cohorts overlap source I/O and target commits. A slow
        // cohort no longer owns the entire source queue; retries keep their fence.
        return try await withThrowingTaskGroup(of: [Bool].self) { tasks in
            var report = V2RoomDispatchReport(), active = 0
            var sourceEmpty = false
            while active > 0 || (!sourceEmpty && report.claimedPages < limit) {
                while active < 2 && !sourceEmpty && report.claimedPages < limit {
                    try Task.checkCancellation()
                    let leases = try await outbox.claim(now: now(), limit: min(32, limit-report.claimedPages), leaseDuration: leaseDuration)
                    if leases.isEmpty { sourceEmpty = true; break }
                    report.claimedPages += leases.count; active += 1
                    tasks.addTask { try await process(leases) }
                }
                guard let results = try await tasks.next() else { break }
                active -= 1
                if results.contains(true) { sourceEmpty = false } // An ACK may expose the next audience page.
                report.acknowledgedPages += results.filter { $0 }.count
                report.failedPages += results.filter { !$0 }.count
            }
            return report
        }
    }

    private func process(_ leases: [V2RoomDispatchLease]) async throws -> [Bool] {
        var audiences = Array<[UserID]?>(repeating: nil, count: leases.count)
        try await withThrowingTaskGroup(of: (Int, [UserID]?).self) { tasks in
            var next = 0
            func submit(_ index: Int) {
                tasks.addTask {
                    do { return (index, try await outbox.recipients(leases[index], limit: pageSize, now: now())) }
                    catch is CancellationError { throw CancellationError() }
                    catch { return (index, nil) }
                }
            }
            while next < min(concurrency, leases.count) { submit(next); next += 1 }
            for try await (index, recipients) in tasks {
                audiences[index] = recipients
                if next < leases.count { submit(next); next += 1 }
            }
        }
        var failed = Set(audiences.indices.filter { audiences[$0] == nil })
        var grouped: [UserID: [Int]] = [:]
        for (index, audience) in audiences.enumerated() {
            for user in audience ?? [] { grouped[user, default: []].append(index) }
        }
        // Room commits have already completed. Amortize only the independent
        // account projection transaction, with bounded per-account batches.
        let targets = grouped.map { RoomDispatchTarget(user: $0.key, indices: $0.value) }
        let requests = targets.map { target in
            V2RoomDispatchTarget(userID: target.user, leases: target.indices.map { leases[$0] }.sorted {
                ($0.roomID.rawValue, $0.roomSequence) < ($1.roomID.rawValue, $1.roomSequence)
            })
        }
        // Cap account facts as well as target count: pageSize may be 256,
        // but one storage transaction must never contain all 8192 facts.
        var batches: [[V2RoomDispatchTarget]] = [], batch: [V2RoomDispatchTarget] = [], factCount = 0
        for request in requests {
            if factCount + request.leases.count > 1024 {
                batches.append(batch); batch = []; factCount = 0
            }
            batch.append(request); factCount += request.leases.count
        }
        if !batch.isEmpty { batches.append(batch) }
        var accepted = Set<UserID>()
        for batch in batches {
            do {
                try Task.checkCancellation()
                guard leases.allSatisfy({ now() < $0.expiresAt }) else { throw V2RoomDispatchError.lostLease }
                accepted.formUnion(try await projector.projectTargets(batch))
            } catch is CancellationError { throw CancellationError() }
            catch { /* Previously committed targets remain safe to acknowledge. */ }
        }
        for target in targets where !accepted.contains(target.user) { failed.formUnion(target.indices) }
        let ready = leases.indices.filter { !failed.contains($0) && audiences[$0] != nil }
        let confirmed: Set<UUID>
        do {
            confirmed = try await outbox.acknowledgePages(ready.map {
                .init(lease: leases[$0], through: audiences[$0]?.last?.uuidValue)
            }, now: now())
        } catch is CancellationError { throw CancellationError() }
        catch { confirmed = [] }
        for lease in leases where !confirmed.contains(lease.eventID) { try await retry(lease) }
        return leases.map { confirmed.contains($0.eventID) }
    }

    private func retry(_ lease: V2RoomDispatchLease) async throws {
        try Task.checkCancellation()
        let delay = min(60.0, pow(2.0, Double(min(lease.attempt, 6))))
        try await outbox.retry(lease, now: now(), after: delay)
    }
}

private struct RoomDispatchTarget: Sendable {
    let user: UserID
    let indices: [Int]
}
