import Foundation
import Synchronization

/// Local permission to serve, separate from authoritative database ownership.
/// Witnesses are authenticated round trips bound to an installed membership revision.
public final class V2ActorServiceQualification: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public let generation: UUID
        public let validUntil: ContinuousClock.Instant
    }
    public enum ConfigurationError: Error { case invalidRoster }
    package struct Membership: Sendable, Equatable {
        package let revision: UInt64
        package let current: Set<String>
        package let next: Set<String>?
        package var nodes: Set<String> { current.union(next ?? []) }
        package init(revision: UInt64, current: Set<String>, next: Set<String>? = nil) throws {
            let nodes = current.union(next ?? [])
            guard revision > 0, !current.isEmpty, next?.isEmpty != true,
                  nodes.count <= 64, nodes.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
                  next != current else { throw ConfigurationError.invalidRoster }
            self.revision = revision; self.current = current; self.next = next
        }
    }
    private struct State: Sendable {
        var current: Snapshot?
        var revoked = false
        var membershipSuspended = false
        var membership: Membership
    }
    private let state: Mutex<State>
    private let localNodeID: String
    private let singleNodeDeadline: ContinuousClock.Instant

    public convenience init(localNodeID: String, roster: Set<String>) throws {
        try self.init(localNodeID: localNodeID, membership: Membership(revision: 1, current: roster))
    }
    package init(localNodeID: String, membership: Membership, allowNonMember: Bool = false) throws {
        guard !localNodeID.isEmpty, membership.nodes.contains(localNodeID) || allowNonMember else { throw ConfigurationError.invalidRoster }
        self.localNodeID = localNodeID
        singleNodeDeadline = .now + .seconds(3_153_600_000)
        state = Mutex(State(current: membership.nodes.contains(localNodeID) && membership.next == nil && membership.current.count == 1
            ? Snapshot(generation: UUID(), validUntil: singleNodeDeadline) : nil, membership: membership))
    }
    public static func standalone() -> V2ActorServiceQualification {
        // Constant valid configuration; one voter explicitly selects single-node operation.
        try! .init(localNodeID: "standalone", roster: ["standalone"])
    }
    public func matches(localNodeID: String, roster: Set<String>) -> Bool {
        self.localNodeID == localNodeID && state.withLock { $0.membership.nodes == roster }
    }
    public func snapshot() -> Snapshot? {
        state.withLock { value in
            guard !value.revoked, let current = value.current, current.validUntil > .now else {
                value.current = nil; return nil
            }
            return current
        }
    }
    package func membershipObservation() -> (revision: UInt64, qualified: Bool) {
        state.withLock { value in
            (value.membership.revision, !value.revoked && !value.membershipSuspended &&
                value.current.map { $0.validUntil > .now } == true)
        }
    }

    package var membership: Membership { state.withLock { $0.membership } }

    /// Only a fresh certified control read may use this catch-up path. The
    /// replicated state machine has already validated every skipped transition.
    package func installCommittedMembership(_ proposed: Membership) throws {
        try state.withLock { value in
            if proposed == value.membership { return }
            guard proposed.revision > value.membership.revision else { throw ConfigurationError.invalidRoster }
            value.membership = proposed
            value.current = nil; value.revoked = true
        }
    }
    package func suspendMembershipConfirmation() {
        state.withLock { $0.membershipSuspended = true; $0.current = nil; $0.revoked = true }
    }
    package func confirmMembership() { state.withLock { $0.membershipSuspended = false } }

    /// Install only membership already authorized by the control plane. Health
    /// observations cannot call this to elect their own roster. A transition is
    /// stable -> joint -> stable; retries are exact and rollback is rejected.
    package func installMembership(_ proposed: Membership) throws {
        try state.withLock { value in
            let previous = value.membership
            if proposed == previous { return }
            guard previous.revision < UInt64.max, proposed.revision == previous.revision + 1 else {
                throw ConfigurationError.invalidRoster
            }
            if let next = previous.next {
                guard proposed.current == next, proposed.next == nil else { throw ConfigurationError.invalidRoster }
            } else {
                guard proposed.current == previous.current, proposed.next != nil else { throw ConfigurationError.invalidRoster }
            }
            value.membership = proposed
            // Even an overlapping majority must provide fresh round trips for
            // the new revision. In-flight work retains an obsolete generation.
            value.current = nil; value.revoked = true
        }
    }

    // Only the authenticated discovery boundary may provide witness deadlines.
    // Late replies from another membership version neither grant nor revoke
    // the installed version's qualification.
    @discardableResult package func update(witnesses: [String: ContinuousClock.Instant],
                                            membershipRevision: UInt64) -> Snapshot? {
        let now = ContinuousClock.now
        return state.withLock { value in
            guard !value.membershipSuspended, membershipRevision == value.membership.revision else { return nil }
            guard value.membership.nodes.contains(localNodeID) else {
                value.current = nil; return nil
            }
            func deadline(for roster: Set<String>) -> ContinuousClock.Instant? {
                let required = roster.count / 2 + 1 - (roster.contains(localNodeID) ? 1 : 0)
                if required == 0 { return singleNodeDeadline }
                let deadlines = witnesses.filter { $0.key != localNodeID && roster.contains($0.key) && $0.value > now }
                    .map(\.value).sorted(by: >)
                return deadlines.count >= required ? deadlines[required - 1] : nil
            }
            guard var validUntil = deadline(for: value.membership.current) else {
                value.current = nil; value.revoked = false; return nil
            }
            if let next = value.membership.next {
                guard let nextDeadline = deadline(for: next) else {
                    value.current = nil; value.revoked = false; return nil
                }
                validUntil = min(validUntil, nextDeadline)
            }
            let generation = (!value.revoked && value.current.map { $0.validUntil > now } == true)
                ? value.current!.generation : UUID()
            let snapshot = Snapshot(generation: generation, validUntil: validUntil)
            value.current = snapshot; value.revoked = false; return snapshot
        }
    }
    public func revoke() { state.withLock { $0.current = nil; $0.revoked = true } }
}
