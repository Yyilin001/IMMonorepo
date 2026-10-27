import Foundation
import Synchronization

public enum V2ResourceTransferWaitingReason: Equatable, Sendable {
    case network, networkPolicy, transferSlot, requestSlot, serviceCooldown
}

struct V2ResourceTransferWaitContext: Sendable {
    let transfer: V2ManagedResourceTransferID
    let hub: V2ResourceTransferProgressHub
    func begin(_ reason: V2ResourceTransferWaitingReason) -> V2ResourceTransferWaitReporter? { hub.beginWait(transfer: transfer, reason: reason) }
}
enum V2ResourceTransferWaitScope {
    @TaskLocal static var context: V2ResourceTransferWaitContext?
}
struct V2ResourceTransferWaitReporter: Sendable {
    let id: UUID
    let hub: V2ResourceTransferProgressHub
    func update(_ reason: V2ResourceTransferWaitingReason) { hub.updateWait(id, reason: reason) }
    func end() { hub.endWait(id) }
}

extension V2ResourceTransferSnapshot {
    func applyingTransferWaiting(_ waiting: [V2ManagedResourceTransferID: V2ResourceTransferWaitingReason]) -> Self {
        guard case .available(let page) = self else { return self }
        return .available(.init(entries: page.entries.map { item in
            var item = item
            let accepts = [.queued, .resolvingMetadata, .preparing, .transferring, .confirming].contains(item.phase)
                && !(item.purpose == .serverImport && item.phase == .transferring)
            // A different consumer waiting for authorization cannot hide actual
            // byte progress, a user pause, failure or a business terminal fact.
            let activeBytes = item.attemptProgress.map { $0.transferredBytes > 0 } ?? false
            item.waitingReason = accepts && !activeBytes ? waiting[item.id] : nil
            if item.waitingReason != nil { item.attemptProgress = nil }
            return item
        }, nextCursor: page.nextCursor))
    }
}

/// Bridges serial Foundation delegate events into the account observation hub.
/// It owns no request/permit and never changes durable transfer state. Cancellation
/// closes the observation immediately; the transport still drains its real task.
final class V2ResourceConnectivityObservation: Sendable {
    private enum State: Sendable {
        case pending, waiting(V2ResourceTransferWaitReporter?), finished
    }
    private let state = Mutex<State>(.pending)
    private let context: V2ResourceTransferWaitContext?
    init(context: V2ResourceTransferWaitContext? = V2ResourceTransferWaitScope.context) { self.context = context }
    func waiting() {
        state.withLock { value in
            guard case .pending = value else { return }
            value = .waiting(context?.begin(.network))
        }
    }
    /// Headers or positive body bytes prove the initial connectivity wait ended.
    /// Late waiting callbacks cannot resurrect a cancelled or already active task.
    func finish() {
        state.withLock { value in
            if case .waiting(let reporter) = value { reporter?.end() }
            value = .finished
        }
    }
}
