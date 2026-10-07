import Foundation
import IMV2ServerApplication

package struct V2PolicyPublicationReport: Sendable {
    package let scanned: Int
    package let attempted: Int
    package let published: Int
    package let failed: Int
    package let exhausted: Bool
}

/// At-least-once revision notifications, independent of the authorization drain.
/// The sink must durably apply/deduplicate operation identity before returning.
package actor PostgresV2PolicyOutboxPublisher {
    package typealias Deliver = @Sendable (V2PolicyCommitNotification) async throws -> Void
    private let journal: PostgresV2PolicyAuthorizationJournal
    private let ownsScope: @Sendable (String) -> Bool
    private let deliver: Deliver
    private let limit: Int
    private let scanLimit: Int
    private var cursor: V2PolicyJournalCursor?
    private var scanUpper: V2PolicyJournalCursor?
    private var root: (id: UUID, task: Task<V2PolicyPublicationReport, any Error>)?
    private var closed = false
    package init(journal: PostgresV2PolicyAuthorizationJournal, limit: Int = 128, scanLimit: Int = 512,
        ownsScope: @escaping @Sendable (String) -> Bool, deliver: @escaping Deliver) {
        precondition((1...128).contains(limit) && (1...4096).contains(scanLimit))
        self.journal = journal; self.limit = limit; self.scanLimit = scanLimit
        self.ownsScope = ownsScope; self.deliver = deliver
    }
    package func runOnce() async throws -> V2PolicyPublicationReport {
        try Task.checkCancellation()
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        if let root { return try await root.task.value }
        let id = UUID()
        let task = Task.detached {
            let result: Result<V2PolicyPublicationReport, any Error>
            do { result = .success(try await self.publish()) } catch { result = .failure(error) }
            await self.finished(id)
            return try result.get()
        }
        root = (id, task)
        return try await task.value
    }
    private func publish() async throws -> V2PolicyPublicationReport {
        var upper = scanUpper
        if upper == nil { upper = try await journal.pendingPublicationHighWater() }
        guard let upper else { return .init(scanned: 0, attempted: 0, published: 0, failed: 0, exhausted: true) }
        var nextCursor = cursor, scanned = 0, exhausted = false
        var candidates: [V2PolicyCommitNotification] = []
        while scanned < scanLimit, candidates.count < limit {
            let page = try await journal.pendingPublicationPage(after: nextCursor, through: upper, limit: min(128, scanLimit - scanned))
            var consumed = 0
            for entry in page.entries {
                consumed += 1; scanned += 1; nextCursor = entry.cursor
                if ownsScope(entry.notification.scopeKey) { candidates.append(entry.notification) }
                if candidates.count == limit { break }
            }
            if consumed == page.entries.count, !page.hasMore { exhausted = true; nextCursor = nil; break }
        }
        cursor = nextCursor
        scanUpper = exhausted ? nil : upper
        let journal = journal, deliver = deliver
        let published = await withTaskGroup(of: Bool.self) { group in
            var next = 0, published = 0
            func enqueue(_ notification: V2PolicyCommitNotification) {
                group.addTask {
                    do {
                        try await deliver(notification)
                        try await journal.markPublished(notification)
                        return true
                    } catch { return false }
                }
            }
            while next < min(8, candidates.count) { enqueue(candidates[next]); next += 1 }
            while let succeeded = await group.next() {
                if succeeded { published += 1 }
                if next < candidates.count { enqueue(candidates[next]); next += 1 }
            }
            return published
        }
        return .init(scanned: scanned, attempted: candidates.count, published: published,
            failed: candidates.count - published, exhausted: exhausted)
    }
    private func finished(_ id: UUID) { if root?.id == id { root = nil } }
    package func pressure() -> (closed: Bool, active: Bool) { (closed, root != nil) }
    package func shutdown() async {
        closed = true
        if let root { _ = await root.task.result }
    }
}

package struct V2PolicyMaintenanceReport: Sendable {
    package let recovery: V2PolicyRecoveryReport?
    package let publication: V2PolicyPublicationReport?
    package var failed: Bool { recovery == nil || publication == nil || recovery!.failed > 0 || publication!.failed > 0 }
}

/// One owned periodic task, coalesced manual ticks, and retained actual roots.
/// Stop this before closing owners, transport clients or database resources.
package actor V2PolicyMaintenanceWorker {
    private let owners: PostgresV2PolicyOwnerDirectory
    private let publisher: PostgresV2PolicyOutboxPublisher
    private let interval: Duration
    private let limit: Int
    private let scanLimit: Int
    private var loop: Task<Void, Never>?
    private let report: @Sendable (V2PolicyMaintenanceReport) -> Void
    private var root: (id: UUID, task: Task<V2PolicyMaintenanceReport, Never>)?
    private var closed = false
    package init(owners: PostgresV2PolicyOwnerDirectory, publisher: PostgresV2PolicyOutboxPublisher,
        interval: Duration = .seconds(1), limit: Int = 128, scanLimit: Int = 512,
        report: @escaping @Sendable (V2PolicyMaintenanceReport) -> Void = { _ in }) {
        precondition(interval > .zero && interval <= .seconds(60))
        precondition((1...128).contains(limit) && (1...4096).contains(scanLimit))
        self.owners = owners; self.publisher = publisher; self.interval = interval
        self.limit = limit; self.scanLimit = scanLimit
        self.report = report
    }
    package func start() throws {
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        guard loop == nil else { return }
        let interval = interval, report = report
        loop = Task.detached {
            while !Task.isCancelled {
                if let value = try? await self.runOnce() { report(value) }
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }
    package func runOnce() async throws -> V2PolicyMaintenanceReport {
        try Task.checkCancellation()
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        if let root { return await root.task.value }
        let id = UUID(), owners = owners, publisher = publisher, limit = limit, scanLimit = scanLimit
        let task = Task.detached {
            // Committed notifications can progress while an unrelated pending
            // command is waiting for an actual room revocation boundary.
            async let recovery = try? owners.recoverPending(limit: limit, scanLimit: scanLimit)
            async let publication = try? publisher.runOnce()
            let report = await V2PolicyMaintenanceReport(recovery: recovery, publication: publication)
            await self.finished(id)
            return report
        }
        root = (id, task)
        return await task.value
    }
    private func finished(_ id: UUID) { if root?.id == id { root = nil } }
    package func pressure() -> (closed: Bool, active: Bool, started: Bool) { (closed, root != nil, loop != nil) }
    package func shutdown() async {
        closed = true
        loop?.cancel()
        if let root { _ = await root.task.value }
        if let loop { await loop.value }
        loop = nil
        await publisher.shutdown()
    }
}
