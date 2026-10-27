import Foundation
import Synchronization

/// Transport observations for one attempt, not provider receipts or business
/// completion. Multipart attempts measure only the current part; Range
/// downloads measure only the current accepted HTTP response body.
public struct V2ResourceTransferAttemptProgress: Equatable, Sendable {
    public let attemptID: UUID
    public let transferredBytes: Int64
    public let expectedBytes: Int64
}

enum V2ResourceTransferProgressScope {
    @TaskLocal static var reporter: V2ResourceTransferProgressReporter?
}

struct V2ResourceTransferProgressReporter: Sendable {
    let transfer: V2ManagedResourceTransferID
    let attempt: UUID
    let hub: V2ResourceTransferProgressHub
    func report(transferredBytes: Int64) { hub.report(transfer: transfer, attempt: attempt, transferredBytes: transferredBytes) }
    func end() { hub.end(transfer: transfer, attempt: attempt) }
}

/// Delegate callbacks never start tasks, retain byte buffers or write SQL.
/// One bounded, coalescing pulse stream feeds the account snapshot owner.
final class V2ResourceTransferProgressHub: Sendable {
    private struct Wait: Sendable { let transfer: V2ManagedResourceTransferID; var reason: V2ResourceTransferWaitingReason }
    private struct State: Sendable {
        var closed = false
        var attempts: [V2ManagedResourceTransferID: V2ResourceTransferAttemptProgress] = [:]
        var waits: [UUID: Wait] = [:]
        var networkWaits: [V2ManagedResourceTransferID: V2ResourceTransferWaitingReason] = [:]
    }
    private let state = Mutex(State())
    let updates: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    init() {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        updates = pair.stream; continuation = pair.continuation
    }
    func begin(transfer: V2ManagedResourceTransferID, expectedBytes: Int64) throws -> V2ResourceTransferProgressReporter {
        let attempt = UUID()
        try state.withLock { value in
            guard !value.closed else { throw V2ResourceStorageError.closed }
            guard expectedBytes > 0 else { throw V2ResourceStorageError.invalidRecord }
            if case .serverImport = transfer { throw V2ResourceStorageError.invalidRecord }
            guard value.attempts[transfer] == nil else { throw V2ResourceStorageError.conflict }
            guard value.attempts.count < 4 else { throw V2ResourceStorageError.capacityExceeded }
            value.attempts[transfer] = .init(attemptID: attempt, transferredBytes: 0, expectedBytes: expectedBytes)
        }
        continuation.yield(())
        return .init(transfer: transfer, attempt: attempt, hub: self)
    }
    func snapshot() -> [V2ManagedResourceTransferID: V2ResourceTransferAttemptProgress] { state.withLock { $0.attempts } }
    func beginWait(transfer: V2ManagedResourceTransferID, reason: V2ResourceTransferWaitingReason) -> V2ResourceTransferWaitReporter? {
        let id = UUID()
        let admitted = state.withLock { value in
            guard !value.closed, value.waits.count < 64 else { return false }
            value.waits[id] = .init(transfer: transfer, reason: reason); return true
        }
        guard admitted else { return nil }
        continuation.yield(())
        return .init(id: id, hub: self)
    }
    func updateWait(_ id: UUID, reason: V2ResourceTransferWaitingReason) {
        let changed = state.withLock { value in
            guard let old = value.waits[id], old.reason != reason else { return false }
            value.waits[id]?.reason = reason; return true
        }
        if changed { continuation.yield(()) }
    }
    func endWait(_ id: UUID) {
        if state.withLock({ $0.waits.removeValue(forKey: id) != nil }) { continuation.yield(()) }
    }
    func setNetworkWaits(_ waits: [V2ManagedResourceTransferID: V2ResourceTransferWaitingReason]) {
        guard waits.count <= 16 else { return }
        let changed = state.withLock { value in
            guard !value.closed, value.networkWaits != waits else { return false }
            value.networkWaits = waits; return true
        }
        if changed { continuation.yield(()) }
    }
    func waitingSnapshot() -> [V2ManagedResourceTransferID: V2ResourceTransferWaitingReason] {
        state.withLock { value in
            var result = value.networkWaits
            // Stable precedence for multiple consumers; never depend on hash
            // iteration order when authorization and byte admission overlap.
            for wait in value.waits.values {
                let rank: (V2ResourceTransferWaitingReason) -> Int = { switch $0 {
                    case .serviceCooldown: 5; case .network: 4; case .networkPolicy: 3; case .transferSlot: 2; case .requestSlot: 1
                } }
                if result[wait.transfer].map({ rank($0) >= rank(wait.reason) }) != true { result[wait.transfer] = wait.reason }
            }
            return result
        }
    }
    func requestRefresh() { if !state.withLock({ $0.closed }) { continuation.yield(()) } }
    fileprivate func report(transfer: V2ManagedResourceTransferID, attempt: UUID, transferredBytes: Int64) {
        let changed = state.withLock { value in
            guard !value.closed, let old = value.attempts[transfer], old.attemptID == attempt,
                  transferredBytes > old.transferredBytes, transferredBytes <= old.expectedBytes else { return false }
            value.attempts[transfer] = .init(attemptID: attempt, transferredBytes: transferredBytes, expectedBytes: old.expectedBytes)
            return true
        }
        if changed { continuation.yield(()) }
    }
    fileprivate func end(transfer: V2ManagedResourceTransferID, attempt: UUID) {
        let changed = state.withLock { value in
            guard value.attempts[transfer]?.attemptID == attempt else { return false }
            value.attempts[transfer] = nil; return true
        }
        if changed { continuation.yield(()) }
    }
    func close() {
        state.withLock { $0.closed = true; $0.attempts.removeAll(); $0.waits.removeAll(); $0.networkWaits.removeAll() }
        continuation.finish()
    }
}

struct V2ResourceDownloadProgressContext: Sendable {
    let job: UUID
    let hub: V2ResourceTransferProgressHub
}
enum V2ResourceDownloadProgressScope {
    @TaskLocal static var context: V2ResourceDownloadProgressContext?
}

/// One accepted response, not a whole resumed file. Header validation must
/// precede begin; failed writes never advance the visible byte count.
final class V2ResourceDownloadProgressRequest: Sendable {
    private struct State: Sendable {
        var closed = false
        var received: Int64 = 0
        var expected: Int64 = 0
        var reporter: V2ResourceTransferProgressReporter?
    }
    private let state = Mutex(State())
    private let context: V2ResourceDownloadProgressContext?
    init(context: V2ResourceDownloadProgressContext?) { self.context = context }
    func begin(expectedBytes: Int64) throws {
        guard let context else { return }
        try state.withLock { value in
            guard !value.closed, value.reporter == nil, expectedBytes >= 0 else { throw V2ResourceStorageError.conflict }
            value.expected = expectedBytes
            if expectedBytes > 0 { value.reporter = try context.hub.begin(transfer: .download(context.job), expectedBytes: expectedBytes) }
        }
    }
    func consume(byteCount: Int) throws {
        guard context != nil else { return }
        try state.withLock { value in
            guard !value.closed else { return }
            guard let reporter = value.reporter else { return }
            guard byteCount >= 0, Int64(byteCount) <= value.expected - value.received else { throw V2ClientMediaTransferError.byteCountMismatch }
            value.received += Int64(byteCount)
            reporter.report(transferredBytes: value.received)
        }
    }
    func end() {
        let reporter = state.withLock { value in
            value.closed = true
            let reporter = value.reporter; value.reporter = nil; return reporter
        }
        reporter?.end()
    }
}

extension V2ResourceTransferSnapshot {
    func applyingTransferProgress(_ progress: [V2ManagedResourceTransferID: V2ResourceTransferAttemptProgress]) -> Self {
        guard case .available(let page) = self else { return self }
        return .available(.init(entries: page.entries.map { entry in
            var entry = entry
            let acceptsProgress: Bool = switch entry.id {
            case .upload: [.transferring, .confirming].contains(entry.phase)
            case .download: entry.phase == .transferring
            case .serverImport: false
            }
            if acceptsProgress, let attempt = progress[entry.id] {
                // The journal writes `status` before I/O so a crash confirms
                // the original operation. A live attempt is presentation
                // evidence of transfer, never a change to that recovery action.
                entry.phase = .transferring
                entry.attemptProgress = attempt
            } else { entry.attemptProgress = nil }
            return entry
        }, nextCursor: page.nextCursor))
    }
}
