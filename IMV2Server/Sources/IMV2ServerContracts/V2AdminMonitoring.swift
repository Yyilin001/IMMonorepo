import Foundation

public enum V2AdminHealth: String, Codable, Sendable { case healthy, unhealthy, unavailable, notDeployed = "not_deployed" }
public struct V2AdminServiceStatus: Codable, Sendable {
    public let id: String
    public let name: String
    public let status: V2AdminHealth
    public let detail: String
    public let checkedAt: Date?
    public let lastSuccessAt: Date?
    public let latencyMilliseconds: Double?
    public let ownerCount: Int?
    public let inFlightOperations: Int?
    public init(id: String, name: String, status: V2AdminHealth, detail: String, checkedAt: Date? = nil,
                lastSuccessAt: Date? = nil, latencyMilliseconds: Double? = nil, ownerCount: Int? = nil, inFlightOperations: Int? = nil) {
        self.id = id; self.name = name; self.status = status; self.detail = detail; self.checkedAt = checkedAt
        self.lastSuccessAt = lastSuccessAt; self.latencyMilliseconds = latencyMilliseconds
        self.ownerCount = ownerCount; self.inFlightOperations = inFlightOperations
    }
}
public struct V2AdminDatabaseObservation: Sendable {
    public let pendingDisables: Int64
    public let oldestPendingAt: Date?
    public init(pendingDisables: Int64, oldestPendingAt: Date?) {
        self.pendingDisables = pendingDisables; self.oldestPendingAt = oldestPendingAt
    }
}
public struct V2AdminPolicyObservation: Sendable {
    public let closed: Bool
    public let owners: Int
    public let inFlight: Int
    public init(closed: Bool, owners: Int, inFlight: Int) {
        self.closed = closed; self.owners = owners; self.inFlight = inFlight
    }
}
public struct V2AdminMonitoringSnapshot: Codable, Sendable {
    public let mode: String
    public let sampledAt: Date
    public let startedAt: Date
    public let services: [V2AdminServiceStatus]
    public let pendingDisables: String?
    public let oldestPendingAt: Date?
    public let pendingSampledAt: Date?
    public init(mode: String, sampledAt: Date, startedAt: Date, services: [V2AdminServiceStatus],
                pendingDisables: String?, oldestPendingAt: Date?, pendingSampledAt: Date?) {
        self.mode = mode; self.sampledAt = sampledAt; self.startedAt = startedAt; self.services = services
        self.pendingDisables = pendingDisables; self.oldestPendingAt = oldestPendingAt; self.pendingSampledAt = pendingSampledAt
    }
}
public protocol V2AdminMonitoring: Sendable {
    func snapshot() async -> V2AdminMonitoringSnapshot
}
