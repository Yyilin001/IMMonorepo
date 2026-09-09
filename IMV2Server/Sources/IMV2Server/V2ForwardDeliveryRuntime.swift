import Foundation

/// One independently scheduled loop per configured source shard. A slow owner
/// cannot stop another owner's durable queue. Each worker bounds its own batch;
/// workload database pools enforce the process's configured database budget.
public struct V2ForwardDeliveryRuntime: Sendable {
    private let workers: [String: V2ForwardDeliveryWorker]
    private let minimumPollMilliseconds: Int
    private let onFailure: @Sendable (String) -> Void

    public init(workers: [String: V2ForwardDeliveryWorker], minimumPollMilliseconds: Int = 100,
                onFailure: @escaping @Sendable (String) -> Void = { _ in }) throws {
        guard minimumPollMilliseconds > 0 else { throw V2ForwardDeliveryError.invalidConfiguration }
        self.workers = workers; self.minimumPollMilliseconds = minimumPollMilliseconds; self.onFailure = onFailure
    }

    public func run() async {
        await withTaskGroup(of: Void.self) { group in
            for (shardID, worker) in workers {
                group.addTask {
                    var cadence = V2BoundedBusyDrainCadence(minimumIdleIntervalMilliseconds: minimumPollMilliseconds,
                        maximumIdleIntervalMilliseconds: max(2_000, minimumPollMilliseconds),
                        maximumConsecutiveBusyPasses: 8, maximumConsecutiveBusyDurationMilliseconds: 100)
                    while !Task.isCancelled {
                        let started = ContinuousClock.now
                        var didWork = false
                        do {
                            didWork = try await worker.runOnce(sourceShardID: shardID, limit: 4).claimed > 0
                        } catch is CancellationError { return
                        } catch { onFailure(shardID) }
                        switch cadence.decisionAfterPass(didWork: didWork, passDuration: started.duration(to: .now)) {
                        case .continueImmediately: break
                        case .yield: await Task.yield()
                        case .sleep(let duration):
                            do { try await Task.sleep(for: duration) } catch { return }
                        }
                    }
                }
            }
            await group.waitForAll()
        }
    }
}
