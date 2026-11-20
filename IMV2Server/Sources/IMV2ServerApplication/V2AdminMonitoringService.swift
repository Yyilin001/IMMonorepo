import Foundation
import IMV2ServerContracts

public enum V2AdminProbeTarget: String, CaseIterable, Sendable {
    case policy, account, gateway, actors
    var name: String {
        switch self {
        case .policy: "Policy Owner"
        case .account: "账户服务"
        case .gateway: "消息网关"
        case .actors: "远程 Actor 集群"
        }
    }
}

public struct V2AdminProbeReading: Sendable {
    public let healthy: Bool
    public let detail: String
    public var owners: Int?
    public var inFlight: Int?

    public init(healthy: Bool, detail: String, owners: Int? = nil, inFlight: Int? = nil) {
        self.healthy = healthy; self.detail = detail; self.owners = owners; self.inFlight = inFlight
    }
}

public typealias V2AdminProbe = @Sendable () async throws -> V2AdminProbeReading

/// 单次采集共享在途工作，成功或失败结果均缓存五秒，避免多个页面放大数据库压力。
public actor V2AdminMonitoringService: V2AdminMonitoring {
    private let database: @Sendable () async throws -> V2AdminDatabaseObservation
    private let probes: [V2AdminProbeTarget: V2AdminProbe]
    private let local: Bool
    private let startedAt: Date
    private let now: @Sendable () -> Date
    private var cached: V2AdminMonitoringSnapshot?
    private var cacheDeadline: ContinuousClock.Instant?
    private var inFlight: Task<V2AdminMonitoringSnapshot, Never>?
    private var lastSuccess: [String: Date] = [:]

    public init(local: Bool, now: @escaping @Sendable () -> Date = Date.init,
                database: @escaping @Sendable () async throws -> V2AdminDatabaseObservation,
                policy: (@Sendable () async throws -> V2AdminPolicyObservation)? = nil,
                remote: [V2AdminProbeTarget: V2AdminProbe] = [:]) {
        self.local = local; self.now = now; startedAt = now(); self.database = database
        var probes = remote
        if let policy {
            probes[.policy] = {
                let value = try await policy()
                return .init(healthy: !value.closed, detail: value.closed ? "本地策略目录已关闭" : "本地策略目录正在接受操作",
                    owners: value.owners, inFlight: value.inFlight)
            }
        }
        self.probes = probes
    }

    public func snapshot() async -> V2AdminMonitoringSnapshot {
        if let cached, let cacheDeadline, ContinuousClock.now < cacheDeadline { return cached }
        if let inFlight { return await inFlight.value }
        let task = Task { await self.collect() }
        inFlight = task
        let result = await task.value
        cached = result; cacheDeadline = .now + .seconds(5); inFlight = nil
        return result
    }

    private func collect() async -> V2AdminMonitoringSnapshot {
        var services = [V2AdminServiceStatus(id: "admin", name: "管理 API", status: .healthy,
            detail: "管理进程正在响应已认证请求", checkedAt: now(), lastSuccessAt: now())]
        async let probeStatuses = collectProbes()
        var observation: V2AdminDatabaseObservation?
        var pendingSampledAt: Date?
        let start = ContinuousClock.now
        do {
            observation = try await database()
            let checkedAt = now(); pendingSampledAt = checkedAt; lastSuccess["postgres"] = checkedAt
            services.append(.init(id: "postgres", name: "PostgreSQL", status: .healthy,
                detail: "已完成管理审计表的只读查询", checkedAt: checkedAt, lastSuccessAt: checkedAt,
                latencyMilliseconds: Self.milliseconds(start.duration(to: .now))))
        } catch {
            services.append(.init(id: "postgres", name: "PostgreSQL", status: .unavailable,
                detail: "数据库检查未完成；连接、查询失败或超时，待确认数量未知", checkedAt: now(), lastSuccessAt: lastSuccess["postgres"]))
        }
        services += await probeStatuses
        return .init(mode: local ? "local_demo" : "deployment", sampledAt: now(), startedAt: startedAt, services: services,
            pendingDisables: observation.map { String($0.pendingDisables) }, oldestPendingAt: observation?.oldestPendingAt, pendingSampledAt: pendingSampledAt)
    }
    private func collectProbes() async -> [V2AdminServiceStatus] {
        await withTaskGroup(of: V2AdminServiceStatus.self) { group in
            for target in V2AdminProbeTarget.allCases {
                let probe = probes[target], previous = lastSuccess[target.rawValue]
                group.addTask { [now, local] in
                    guard let probe else {
                        let absent = local && target != .policy
                        return .init(id: target.rawValue, name: target.name, status: absent ? .notDeployed : .unavailable,
                            detail: absent ? "本地演示未启动该服务" : "未配置探针")
                    }
                    let start = ContinuousClock.now
                    do {
                        let result = try await probe(), checked = now()
                        return .init(id: target.rawValue, name: target.name, status: result.healthy ? .healthy : .unhealthy,
                            detail: result.detail, checkedAt: checked, lastSuccessAt: result.healthy ? checked : previous,
                            latencyMilliseconds: Self.milliseconds(start.duration(to: .now)),
                            ownerCount: result.owners, inFlightOperations: result.inFlight)
                    } catch {
                        return .init(id: target.rawValue, name: target.name, status: .unavailable,
                            detail: "本次检查未取得有效响应", checkedAt: now(), lastSuccessAt: previous,
                            latencyMilliseconds: Self.milliseconds(start.duration(to: .now)))
                    }
                }
            }
            var values: [String: V2AdminServiceStatus] = [:]
            for await value in group {
                if value.status == .healthy { lastSuccess[value.id] = value.lastSuccessAt }
                values[value.id] = value
            }
            return V2AdminProbeTarget.allCases.compactMap { values[$0.rawValue] }
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
}
