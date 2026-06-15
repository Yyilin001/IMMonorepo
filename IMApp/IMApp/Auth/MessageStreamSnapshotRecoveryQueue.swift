import Foundation
import IMClientKit

@MainActor
protocol MessageStreamSnapshotRecovering: AnyObject {
    func syncActiveMessageStreamSnapshots()
    func syncPendingMessageStreamSnapshotsIfNeeded()
    func cancel()
}

@MainActor
final class MessageStreamSnapshotRecoveryQueue: MessageStreamSnapshotRecovering {
    private let sessionClient: SessionClient
    private let imConversationStore: IMConversationStore
    private let currentUserProvider: () -> AuthUser?
    private let markServerOnline: () -> Void
    private let scheduleConversationCachePersist: () -> Void

    private var workerTask: Task<Void, Never>?
    private var pendingTargets: Set<IMActiveMessageStreamTarget> = []
    private var retryDelays: [IMActiveMessageStreamTarget: UInt64] = [:]
    private var retryTasks: [IMActiveMessageStreamTarget: Task<Void, Never>] = [:]

    init(
        sessionClient: SessionClient,
        imConversationStore: IMConversationStore,
        currentUserProvider: @escaping () -> AuthUser?,
        markServerOnline: @escaping () -> Void,
        scheduleConversationCachePersist: @escaping () -> Void
    ) {
        self.sessionClient = sessionClient
        self.imConversationStore = imConversationStore
        self.currentUserProvider = currentUserProvider
        self.markServerOnline = markServerOnline
        self.scheduleConversationCachePersist = scheduleConversationCachePersist
    }

    func syncActiveMessageStreamSnapshots() {
        Task { [weak self] in
            guard let self else {
                return
            }
            let targets = await imConversationStore.activeMessageStreamTargetsAsync()
            guard !targets.isEmpty else {
                return
            }
            enqueue(targets)
        }
    }

    func syncPendingMessageStreamSnapshotsIfNeeded() {
        Task { [weak self] in
            guard let self else {
                return
            }
            let targets = await imConversationStore.consumePendingStreamSnapshotTargetsAsync()
            guard !targets.isEmpty else {
                return
            }
            enqueue(targets)
        }
    }

    func cancel() {
        workerTask?.cancel()
        workerTask = nil
        for task in retryTasks.values {
            task.cancel()
        }
        pendingTargets.removeAll()
        retryDelays.removeAll()
        retryTasks.removeAll()
    }

    private func enqueue(_ targets: [IMActiveMessageStreamTarget]) {
        guard let currentUserID = currentUserProvider()?.id else {
            return
        }

        pendingTargets.formUnion(targets)
        startWorkerIfNeeded(currentUserID: currentUserID)
    }

    private func startWorkerIfNeeded(currentUserID: UUID) {
        guard workerTask == nil else {
            return
        }

        workerTask = Task { [weak self] in
            guard let self else {
                return
            }

            while !Task.isCancelled {
                guard self.currentUserProvider()?.id == currentUserID else {
                    return
                }
                guard let target = self.pendingTargets.first else {
                    self.workerTask = nil
                    if !self.pendingTargets.isEmpty {
                        self.startWorkerIfNeeded(currentUserID: currentUserID)
                    }
                    return
                }
                self.pendingTargets.remove(target)

                await self.fetchSnapshot(for: target, currentUserID: currentUserID)
            }
        }
    }

    private func fetchSnapshot(for target: IMActiveMessageStreamTarget, currentUserID: UUID) async {
        do {
            let retryDelay = retryDelays[target] ?? 0
            if retryDelay > 0 {
                try await Task.sleep(nanoseconds: retryDelay)
            }
            try Task.checkCancellation()
            let response = try await sessionClient.fetchMessageStreamSnapshot(
                conversationID: target.conversationID,
                messageID: target.messageID
            )
            guard currentUserProvider()?.id == currentUserID else {
                return
            }
            markServerOnline()
            await imConversationStore.applyMessageStreamSnapshotAsync(
                response,
                currentUserID: currentUserID
            )
            scheduleConversationCachePersist()
            retryDelays.removeValue(forKey: target)
        } catch is CancellationError {
            return
        } catch {
            let retryDelay = nextRetryDelay(after: retryDelays[target])
            retryDelays[target] = retryDelay
            scheduleRetry(
                target,
                currentUserID: currentUserID,
                delay: retryDelay
            )
        }
    }

    private func scheduleRetry(
        _ target: IMActiveMessageStreamTarget,
        currentUserID: UUID,
        delay: UInt64
    ) {
        guard retryTasks[target] == nil else {
            return
        }

        retryTasks[target] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
                try Task.checkCancellation()
            } catch {
                return
            }

            await MainActor.run {
                guard let self else {
                    return
                }
                self.retryTasks[target] = nil
                guard self.currentUserProvider()?.id == currentUserID else {
                    self.retryDelays.removeValue(forKey: target)
                    return
                }
                self.pendingTargets.insert(target)
                self.startWorkerIfNeeded(currentUserID: currentUserID)
            }
        }
    }

    private func nextRetryDelay(after current: UInt64?) -> UInt64 {
        switch current {
        case nil, 0:
            1_000_000_000
        case 1_000_000_000:
            2_000_000_000
        case 2_000_000_000:
            5_000_000_000
        case 5_000_000_000:
            10_000_000_000
        default:
            30_000_000_000
        }
    }
}
