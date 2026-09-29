import IMV2ServerInfrastructure
import IMV2ServerApplication
import IMV2ServerContracts
import Foundation

/// 为每个已配置的来源分片启动独立调度循环的转发投递运行时。
///
/// 单个缓慢的归属不会拖住其他归属的持久化队列；每个工作器各自限制批量大小，
/// 进程整体的数据库预算由业务数据库连接池约束。
public struct V2ForwardDeliveryRuntime: Sendable {
    private let workers: [String: V2ForwardDeliveryWorker]
    private let minimumPollMilliseconds: Int
    private let onFailure: @Sendable (String) -> Void

    /// 组合各来源分片的投递工作器。
    ///
    /// - Parameters:
    ///   - workers: 逻辑分片标识到投递工作器的映射。
    ///   - minimumPollMilliseconds: 空闲轮询的最小间隔毫秒数，需大于零。
    ///   - onFailure: 单轮投递失败时的回调，参数为对应分片标识；默认忽略。
    /// - Throws: 轮询间隔非正时抛出 ``V2ForwardDeliveryError/invalidConfiguration``。
    public init(workers: [String: V2ForwardDeliveryWorker], minimumPollMilliseconds: Int = 100,
                onFailure: @escaping @Sendable (String) -> Void = { _ in }) throws {
        guard minimumPollMilliseconds > 0 else { throw V2ForwardDeliveryError.invalidConfiguration }
        self.workers = workers; self.minimumPollMilliseconds = minimumPollMilliseconds; self.onFailure = onFailure
    }

    /// 为每个分片启动投递循环，直到任务被取消。
    ///
    /// 循环按忙闲节奏自适应间隔：连续有工作量时立即继续，短暂空闲时让出执行权，
    /// 空闲时按有界退避休眠。取消信号会结束全部循环。
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
                            do { try await v2Sleep(for: duration) } catch { return }
                        }
                    }
                }
            }
            await group.waitForAll()
        }
    }
}
