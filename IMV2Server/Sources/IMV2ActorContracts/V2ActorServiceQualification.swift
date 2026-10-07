import Foundation
import Synchronization

/// Local permission to serve, separate from authoritative database ownership.
/// Witnesses are authenticated round trips against one fixed voter roster.
public final class V2ActorServiceQualification: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public let generation: UUID
        public let validUntil: ContinuousClock.Instant
    }
    public enum ConfigurationError: Error { case invalidRoster }
    private struct State: Sendable { var current: Snapshot?; var revoked = false }
    private let state: Mutex<State>
    private let localNodeID: String
    private let roster: Set<String>
    private let singleNodeDeadline: ContinuousClock.Instant

    public init(localNodeID: String, roster: Set<String>) throws {
        guard !localNodeID.isEmpty, localNodeID.utf8.count <= 128, roster.contains(localNodeID), !roster.isEmpty,
              roster.count <= 64, roster.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else { throw ConfigurationError.invalidRoster }
        self.localNodeID = localNodeID; self.roster = roster
        singleNodeDeadline = .now + .seconds(3_153_600_000)
        state = Mutex(State(current: roster.count == 1 ? Snapshot(generation: UUID(), validUntil: singleNodeDeadline) : nil))
    }
    public static func standalone() -> V2ActorServiceQualification {
        // Constant valid configuration; one voter explicitly selects single-node operation.
        try! .init(localNodeID: "standalone", roster: ["standalone"])
    }
    public func matches(localNodeID: String, roster: Set<String>) -> Bool {
        self.localNodeID == localNodeID && self.roster == roster
    }
    public func snapshot() -> Snapshot? {
        state.withLock { value in
            guard !value.revoked, let current = value.current, current.validUntil > .now else {
                value.current = nil; return nil
            }
            return current
        }
    }
    // Only this package's authenticated discovery boundary can grant service
    // permission. Consumers may observe or revoke it, but cannot supply their
    // own unauthenticated witness deadlines through the public API.
    @discardableResult package func update(witnesses: [String: ContinuousClock.Instant]) -> Snapshot? {
        let now = ContinuousClock.now
        let required = roster.count / 2 // majority minus the local vote
        let deadlines = witnesses.filter { $0.key != localNodeID && roster.contains($0.key) && $0.value > now }
            .map(\.value).sorted(by: >)
        return state.withLock { value in
            guard deadlines.count >= required else { value.current = nil; value.revoked = false; return nil }
            let deadline = required == 0 ? singleNodeDeadline : deadlines[required - 1]
            let generation = (!value.revoked && value.current.map { $0.validUntil > now } == true)
                ? value.current!.generation : UUID()
            let snapshot = Snapshot(generation: generation, validUntil: deadline)
            value.current = snapshot; value.revoked = false; return snapshot
        }
    }
    public func revoke() { state.withLock { $0.current = nil; $0.revoked = true } }
}
