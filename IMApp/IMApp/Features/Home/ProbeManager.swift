import Combine
import Foundation
import IMClientKit

@MainActor
protocol ProbeManagerDelegate: AnyObject {
    func probeManagerDidFetchUser(_ user: AuthUser)
    func probeManagerDidReceiveFailure(_ failure: ProbeFailureContext) async
}

@MainActor
final class ProbeManager: ObservableObject {
    @Published private(set) var isTrafficTestRunning = false
    @Published private(set) var trafficTestStatus = "未开始"
    @Published private(set) var trafficTestSuccessCount = 0
    @Published private(set) var trafficTestRateLimitedCount = 0
    @Published private(set) var trafficTestFailureCount = 0
    @Published private(set) var trafficTestLastRequestAt: Date?

    @Published private(set) var isConcurrentTestRunning = false
    @Published private(set) var concurrentTestStatus = "未开始"
    @Published private(set) var concurrentTestSuccessCount = 0
    @Published private(set) var concurrentTestRateLimitedCount = 0
    @Published private(set) var concurrentTestFailureCount = 0
    @Published private(set) var concurrentTestLastRunAt: Date?

    @Published private(set) var isLoadTestRunning = false
    @Published private(set) var loadTestStatus = "未开始"
    @Published private(set) var loadTestSuccessCount = 0
    @Published private(set) var loadTestRateLimitedCount = 0
    @Published private(set) var loadTestFailureCount = 0
    @Published private(set) var loadTestLastRequestAt: Date?

    weak var delegate: (any ProbeManagerDelegate)?

    private let runner: ProbeRunner
    private var concurrentTestTask: Task<Void, Never>?
    private var concurrentTestRunID: UInt64 = 0
    private var trafficTestTask: Task<Void, Never>?
    private var loadTestTask: Task<Void, Never>?

    init(sessionClient: SessionClient) {
        self.runner = ProbeRunner(sessionClient: sessionClient)
    }

    func toggleTrafficTest() {
        if isTrafficTestRunning {
            stopTrafficTest(status: "已停止随机请求测试。")
        } else {
            startTrafficTest()
        }
    }

    func runConcurrentTest(requestCount: Int = 8) {
        guard concurrentTestTask == nil else {
            return
        }

        isConcurrentTestRunning = true
        concurrentTestSuccessCount = 0
        concurrentTestRateLimitedCount = 0
        concurrentTestFailureCount = 0
        concurrentTestLastRunAt = nil
        concurrentTestStatus = "正在并发发起 \(requestCount) 个 /api/me 请求..."

        let runID = concurrentTestRunID
        concurrentTestRunID &+= 1
        concurrentTestTask = Task { [weak self] in
            guard let self else {
                return
            }

            let startedAt = Date()
            let outcomes = await self.runner.runConcurrentTest(requestCount: requestCount)
            guard self.shouldContinueConcurrentTest(runID) else {
                return
            }

            for outcome in outcomes {
                guard self.shouldContinueConcurrentTest(runID) else {
                    return
                }

                switch await self.handleProbeOutcome(outcome) {
                case .success:
                    self.concurrentTestSuccessCount += 1
                case .rateLimited:
                    self.concurrentTestRateLimitedCount += 1
                case .failure:
                    self.concurrentTestFailureCount += 1
                }
            }

            concurrentTestLastRunAt = Date()
            isConcurrentTestRunning = false
            concurrentTestTask = nil

            let duration = Date().timeIntervalSince(startedAt)
            if concurrentTestFailureCount == 0, concurrentTestRateLimitedCount == 0 {
                concurrentTestStatus = String(format: "并发测试完成，%d 个请求全部成功，耗时 %.2f 秒。", concurrentTestSuccessCount, duration)
            } else {
                concurrentTestStatus = String(
                    format: "并发测试完成，成功 %d 个，限流 %d 个，失败 %d 个，耗时 %.2f 秒。",
                    concurrentTestSuccessCount,
                    concurrentTestRateLimitedCount,
                    concurrentTestFailureCount,
                    duration
                )
            }
        }
    }

    func toggleLoadTest(workerCount: Int = 6) {
        if isLoadTestRunning {
            stopLoadTest(status: "已停止持续压测。")
        } else {
            startLoadTest(workerCount: workerCount)
        }
    }

    func stopAllForSignedOut() {
        stopTrafficTest(status: "登录状态已失效，已停止随机请求测试。")
        stopLoadTest(status: "登录状态已失效，已停止持续压测。")
        stopConcurrentTest(status: "登录状态已失效，已停止并发测试。")
    }

    private func startTrafficTest() {
        guard trafficTestTask == nil else {
            return
        }

        trafficTestSuccessCount = 0
        trafficTestRateLimitedCount = 0
        trafficTestFailureCount = 0
        trafficTestLastRequestAt = nil
        isTrafficTestRunning = true
        trafficTestStatus = "随机请求测试已启动。"

        trafficTestTask = Task { [weak self] in
            guard let self else {
                return
            }
            let stream = await self.runner.makeTrafficStream()

            defer {
                if self.trafficTestTask != nil {
                    self.trafficTestTask = nil
                    self.isTrafficTestRunning = false
                }
            }

            for await event in stream {
                switch event {
                case .waiting(let delay):
                    self.trafficTestStatus = String(format: "等待 %.1f 秒后访问 /api/me", delay)
                case .result(let outcome):
                    let outcomeKind = await self.handleProbeOutcome(outcome)
                    self.trafficTestLastRequestAt = Date()
                    switch outcomeKind {
                    case .success:
                        self.trafficTestSuccessCount += 1
                    case .rateLimited:
                        self.trafficTestRateLimitedCount += 1
                    case .failure:
                        self.trafficTestFailureCount += 1
                    }
                    self.trafficTestStatus = self.trafficStatusMessage(
                        outcomeKind: outcomeKind,
                        failureMessage: outcome.failureMessage,
                        totalCount: self.trafficTestSuccessCount + self.trafficTestRateLimitedCount + self.trafficTestFailureCount
                    )
                }
            }
        }
    }

    private func stopTrafficTest(status: String) {
        trafficTestTask?.cancel()
        trafficTestTask = nil
        isTrafficTestRunning = false
        trafficTestStatus = status
    }

    private func startLoadTest(workerCount: Int) {
        guard loadTestTask == nil else {
            return
        }

        loadTestSuccessCount = 0
        loadTestRateLimitedCount = 0
        loadTestFailureCount = 0
        loadTestLastRequestAt = nil
        isLoadTestRunning = true
        loadTestStatus = "持续压测已启动，当前并发 \(workerCount) 路。"

        loadTestTask = Task { [weak self] in
            guard let self else {
                return
            }
            let stream = await self.runner.makeLoadStream(workerCount: workerCount)

            defer {
                if self.loadTestTask != nil {
                    self.loadTestTask = nil
                    self.isLoadTestRunning = false
                }
            }

            for await event in stream {
                let outcomeKind = await self.handleProbeOutcome(event.outcome)
                let failureMessage = event.outcome.failureMessage ?? "未知错误"
                self.recordLoadTestResult(
                    outcomeKind: outcomeKind,
                    message: self.loadStatusMessage(
                        outcomeKind: outcomeKind,
                        workerIndex: event.workerIndex,
                        failureMessage: failureMessage
                    )
                )
            }
        }
    }

    private func stopLoadTest(status: String) {
        loadTestTask?.cancel()
        loadTestTask = nil
        isLoadTestRunning = false
        loadTestStatus = status
    }

    private func stopConcurrentTest(status: String) {
        concurrentTestTask?.cancel()
        concurrentTestTask = nil
        isConcurrentTestRunning = false
        concurrentTestStatus = status
    }

    private func shouldContinueConcurrentTest(_ runID: UInt64) -> Bool {
        !Task.isCancelled && concurrentTestTask != nil && runID == concurrentTestRunID - 1
    }

    private func handleProbeOutcome(_ outcome: ProbeOutcome) async -> ProbeOutcomeKind {
        switch outcome {
        case .success(let user):
            delegate?.probeManagerDidFetchUser(user)
            return .success
        case .rateLimited(let failure):
            await delegate?.probeManagerDidReceiveFailure(failure)
            return .rateLimited
        case .failure(let failure):
            await delegate?.probeManagerDidReceiveFailure(failure)
            return .failure
        }
    }

    private func trafficStatusMessage(outcomeKind: ProbeOutcomeKind, failureMessage: String?, totalCount: Int) -> String {
        switch outcomeKind {
        case .success:
            return "第 \(totalCount) 次请求成功。"
        case .rateLimited:
            return "第 \(totalCount) 次请求触发限流：\(failureMessage ?? "请求过于频繁。")"
        case .failure:
            return "第 \(totalCount) 次请求失败：\(failureMessage ?? "未知错误")"
        }
    }

    private func loadStatusMessage(outcomeKind: ProbeOutcomeKind, workerIndex: Int, failureMessage: String) -> String {
        switch outcomeKind {
        case .success:
            return "压测进行中，最近成功来自 worker \(workerIndex)。"
        case .rateLimited:
            return "压测进行中，worker \(workerIndex) 触发限流：\(failureMessage)"
        case .failure:
            return "压测进行中，worker \(workerIndex) 失败：\(failureMessage)"
        }
    }

    private func recordLoadTestResult(outcomeKind: ProbeOutcomeKind, message: String) {
        loadTestLastRequestAt = Date()
        switch outcomeKind {
        case .success:
            loadTestSuccessCount += 1
        case .rateLimited:
            loadTestRateLimitedCount += 1
        case .failure:
            loadTestFailureCount += 1
        }
        loadTestStatus = message
    }
}

private extension ProbeOutcome {
    var failureMessage: String? {
        switch self {
        case .rateLimited(let failure), .failure(let failure):
            return failure.message
        case .success:
            return nil
        }
    }
}

private enum ProbeOutcomeKind {
    case success
    case rateLimited
    case failure
}
