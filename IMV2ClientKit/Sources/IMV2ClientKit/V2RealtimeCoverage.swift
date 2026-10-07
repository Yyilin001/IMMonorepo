import Foundation

/// Acceleration coverage is distinct from authentication and message authority.
/// The revision is scoped to one physical connection generation.
public struct V2RealtimeCoverageState: Equatable, Sendable {
    public enum Scope: Int, Hashable, Sendable { case account = 1, room = 2, directory = 3, presence = 4, typing = 5 }
    public enum Status: Int, Sendable { case recovering = 1, ready = 2, ended = 3 }
    public enum Reason: Int, Sendable { case confirmed = 0, installing = 1, coverageLost = 2, dependencyUnavailable = 3, cancelled = 4 }
    public let connectionGeneration: UUID
    public let scope: Scope
    public let scopeID: String
    public let scopeGeneration: UInt64
    public let highWatermark: UInt64
    public let connectionEpoch: String
    public let revision: UInt64
    public let status: Status
    public let reason: Reason

    /// The wire's legacy Ready value proves installation only. Its head is a
    /// fixed baseline for this scope generation, never the consumer's cursor.
    public var subscriptionInstalled: Bool { status == .ready }
    public var baselineHead: UInt64? { subscriptionInstalled ? highWatermark : nil }

    /// Only a cursor returned after the local apply transaction can prove catch-up.
    public func isCaughtUp(appliedThrough: UInt64) -> Bool {
        subscriptionInstalled && appliedThrough >= highWatermark
    }

    init(wire: IMV2RealtimeCoverage, generation: UUID) throws {
        guard let scope = Scope(rawValue: wire.scope.rawValue),
              let status = Status(rawValue: wire.state.rawValue),
              let reason = Reason(rawValue: wire.reason.rawValue),
              UUID(uuidString: wire.scopeID) != nil, wire.revision > 0, wire.scopeGeneration > 0,
              (status != .ended || reason == .cancelled),
              (status != .recovering || reason == .installing || reason == .coverageLost || reason == .dependencyUnavailable),
              (scope != .directory || status != .ready || UUID(uuidString: wire.connectionEpoch) != nil),
              (status == .ready) == (reason == .confirmed) else {
            throw V2TLSFrameConnectionError.unexpectedResponse
        }
        connectionGeneration = generation; self.scope = scope; scopeID = wire.scopeID
        scopeGeneration = wire.scopeGeneration; highWatermark = wire.highWatermark; connectionEpoch = wire.connectionEpoch
        revision = wire.revision; self.status = status; self.reason = reason
    }

    var key: String { String(scope.rawValue) + ":" + scopeID.lowercased() }
}

public protocol V2RealtimeCoverageSource: Sendable {
    /// One consumer, bounded latest-state buffer. A fresh consumer first receives
    /// the current scope snapshots, so authentication is never inferred as Ready.
    func realtimeCoverageChanges() async -> AsyncStream<V2RealtimeCoverageState>
}

/// Heartbeat progress is scoped to a physical connection and its installed room
/// interest. Reading it does not consume the coverage notification stream.
public protocol V2RoomProgressConnection: Sendable {
    func roomProgressScope() async -> V2RealtimeCoverageState?
    func acceptRoomProgressHead(roomID: String, scopeGeneration: UInt64, highWatermark: UInt64,
                                connectionID: UUID) async throws
}
