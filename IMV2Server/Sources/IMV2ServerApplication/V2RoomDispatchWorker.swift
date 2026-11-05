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
        var report = V2RoomDispatchReport()
        while report.claimedPages < limit {
            try Task.checkCancellation()
            let leases = try await outbox.claim(now: now(), limit: min(concurrency, limit - report.claimedPages), leaseDuration: leaseDuration)
            guard !leases.isEmpty else { break }
            report.claimedPages += leases.count
            let results = try await process(leases)
            report.acknowledgedPages += results.filter { $0 }.count
            report.failedPages += results.filter { !$0 }.count
            // Avoid immediately reclaiming expired pages against a slow target.
            if results.contains(false) { break }
        }
        return report
    }

    private func process(_ leases: [V2RoomDispatchLease]) async throws -> [Bool] {
        var audiences = Array<[UserID]?>(repeating: nil, count: leases.count)
        try await withThrowingTaskGroup(of: (Int, [UserID]?).self) { tasks in
            for (index, lease) in leases.enumerated() {
                tasks.addTask {
                    do { return (index, try await outbox.recipients(lease, limit: pageSize, now: now())) }
                    catch is CancellationError { throw CancellationError() }
                    catch { return (index, nil) }
                }
            }
            for try await (index, recipients) in tasks { audiences[index] = recipients }
        }
        var failed = Set(audiences.indices.filter { audiences[$0] == nil })
        var grouped: [UserID: [Int]] = [:]
        for (index, audience) in audiences.enumerated() {
            for user in audience ?? [] { grouped[user, default: []].append(index) }
        }
        // Room commits have already completed. Amortize only the independent
        // account projection transaction, with bounded per-account batches.
        let targets = grouped.map { RoomDispatchTarget(user: $0.key, indices: $0.value) }
        try await withThrowingTaskGroup(of: (RoomDispatchTarget, Bool).self) { tasks in
            var next = targets.makeIterator()
            func submit(_ target: RoomDispatchTarget) {
                tasks.addTask {
                    let batch = target.indices.map { leases[$0] }.sorted {
                        ($0.roomID.rawValue, $0.roomSequence) < ($1.roomID.rawValue, $1.roomSequence)
                    }
                    do {
                        try Task.checkCancellation()
                        guard batch.allSatisfy({ now() < $0.expiresAt }) else { return (target, false) }
                        try await projector.project(batch, to: target.user)
                        return (target, true)
                    } catch is CancellationError { throw CancellationError() }
                    catch { return (target, false) }
                }
            }
            for _ in 0..<min(concurrency, targets.count) {
                guard let target = next.next() else { break }; submit(target)
            }
            for try await (target, accepted) in tasks {
                if !accepted { failed.formUnion(target.indices) }
                if let target = next.next() { submit(target) }
            }
        }
        let failedPages = failed
        let completedAudiences = audiences
        return try await withThrowingTaskGroup(of: Bool.self, returning: [Bool].self) { tasks in
            for (index, lease) in leases.enumerated() {
                tasks.addTask {
                    try Task.checkCancellation()
                    guard !failedPages.contains(index), let audience = completedAudiences[index] else {
                        try await retry(lease); return false
                    }
                    do {
                        return try await outbox.acknowledgePage(lease, through: audience.last?.uuidValue, now: now())
                    } catch is CancellationError { throw CancellationError() }
                    catch { try await retry(lease); return false }
                }
            }
            var results: [Bool] = []
            for try await result in tasks { results.append(result) }
            return results
        }
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
