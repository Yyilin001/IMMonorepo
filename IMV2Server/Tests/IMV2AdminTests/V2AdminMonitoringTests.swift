import Foundation
import IMV2ServerApplication
import IMV2ServerContracts
import Testing

@Suite("管理服务监控")
struct V2AdminMonitoringTests {
    @Test("并发采集共享工作并缓存快照，缺席服务不伪装正常")
    func coalescing() async throws {
        let calls = ProbeCalls()
        let oldest = Date(timeIntervalSince1970: 1_700_000_000)
        let monitor = V2AdminMonitoringService(local: true, database: {
            await calls.record()
            try await Task.sleep(for: .milliseconds(20))
            return .init(pendingDisables: 2, oldestPendingAt: oldest)
        }, policy: { .init(closed: false, owners: 3, inFlight: 1) })
        let snapshots = await withTaskGroup(of: V2AdminMonitoringSnapshot.self) { group in
            for _ in 0..<10 { group.addTask { await monitor.snapshot() } }
            var values: [V2AdminMonitoringSnapshot] = []
            for await value in group { values.append(value) }
            return values
        }
        #expect(await calls.count == 1)
        #expect(snapshots.count == 10)
        for snapshot in snapshots {
            #expect(snapshot.mode == "local_demo")
            #expect(snapshot.pendingDisables == "2" && snapshot.oldestPendingAt == oldest)
            #expect(snapshot.pendingSampledAt != nil)
            #expect(snapshot.services.filter { $0.status == .healthy }.count == 3)
            #expect(snapshot.services.filter { $0.status == .notDeployed }.count == 3)
            #expect(snapshot.services.first { $0.id == "policy" }?.ownerCount == 3)
        }
        _ = await monitor.snapshot()
        #expect(await calls.count == 1)
    }

    @Test("数据库采集失败保留未知数量，关闭的策略目录显示异常")
    func unavailable() async {
        let monitor = V2AdminMonitoringService(local: true, database: { throw V2AdminError.unavailable },
            policy: { .init(closed: true, owners: 0, inFlight: 0) })
        let snapshot = await monitor.snapshot()
        #expect(snapshot.pendingDisables == nil && snapshot.pendingSampledAt == nil)
        #expect(snapshot.services.first { $0.id == "postgres" }?.status == .unavailable)
        #expect(snapshot.services.first { $0.id == "postgres" }?.lastSuccessAt == nil)
        #expect(snapshot.services.first { $0.id == "policy" }?.status == .unhealthy)
    }

    @Test("单个远程探针失败不影响其他结果，已响应但不就绪与采集失败分别显示")
    func isolatedRemoteFailure() async throws {
        let monitor = V2AdminMonitoringService(local: false, database: { .init(pendingDisables: 0, oldestPendingAt: nil) },
            remote: [
                .policy: { .init(healthy: true, detail: "响应", owners: 0, inFlight: 0) },
                .gateway: { throw V2AdminError.unavailable },
                .account: { .init(healthy: false, detail: "鉴权响应异常") },
                .actors: { .init(healthy: true, detail: "多数派确认") },
            ])
        let snapshot = await monitor.snapshot()
        let status = Dictionary(uniqueKeysWithValues: snapshot.services.map { ($0.id, $0) })
        #expect(status["gateway"]?.status == .unavailable && status["gateway"]?.lastSuccessAt == nil)
        #expect(status["account"]?.status == .unhealthy)
        #expect(status["policy"]?.ownerCount == 0 && status["policy"]?.lastSuccessAt != nil)
        #expect(status["actors"]?.status == .healthy)
    }

    @Test("正式部署的未配置探针不得被误报为未部署")
    func unknownDeployment() async {
        let monitor = V2AdminMonitoringService(local: false, database: { .init(pendingDisables: 0, oldestPendingAt: nil) })
        let snapshot = await monitor.snapshot()
        #expect(snapshot.services.allSatisfy { $0.status != .notDeployed })
        #expect(snapshot.services.first { $0.id == "policy" }?.status == .unavailable)
    }
}
private actor ProbeCalls {
    var count = 0
    func record() { count += 1 }
}
