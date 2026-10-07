import Foundation

/// A room-local execution boundary, not a TTL cache. A coordinator installs a
/// lease only after durable registration and ownership fencing. Revocation ACK
/// means all actual users settled; cancellation and lease expiry are not ACKs.
/// No production send may bypass its existing SQL fences merely by constructing
/// this gate. Durable policy-owner registration/transport supplies that boundary.
package actor V2RoomPolicyAuthorizationGate {
    package enum Versions: Sendable, Equatable {
        case direct(sender: Int64, recipient: Int64, pair: Int64, stranger: Int64?)
        case account(sender: Int64)

        package init(sender: Int64, recipient: Int64, pair: Int64) {
            self = .direct(sender: sender, recipient: recipient, pair: pair, stranger: recipient)
        }
        package init(sender: Int64, recipient: Int64, pair: Int64, stranger: Int64?) {
            self = .direct(sender: sender, recipient: recipient, pair: pair, stranger: stranger)
        }
        package init(accountSender: Int64) { self = .account(sender: accountSender) }
        fileprivate var sender: Int64 {
            switch self { case .direct(let value, _, _, _), .account(let value): value }
        }
        fileprivate var recipient: Int64? {
            if case .direct(_, let value, _, _) = self { return value }; return nil
        }
        fileprivate var pair: Int64? {
            if case .direct(_, _, let value, _) = self { return value }; return nil
        }
        fileprivate var stranger: Int64? {
            if case .direct(_, _, _, let value) = self { return value }; return nil
        }
        fileprivate var isAccount: Bool { if case .account = self { return true }; return false }
        fileprivate func dominates(_ other: Self) -> Bool {
            switch (self, other) {
            case (.direct(let a, let b, let c, let d), .direct(let x, let y, let z, let w)):
                guard a >= x, b >= y, c >= z else { return false }
                switch (d, w) {
                case (.none, .none): return true
                case (.some(let current), .some(let previous)): return current >= previous
                default: return c > z // Only a newer relationship can change the branch.
                }
            case (.account(let a), .account(let b)): return a >= b
            default: return false
            }
        }
        fileprivate var valid: Bool {
            switch self {
            case .direct(let a, let b, let c, let d): a > 0 && b > 0 && c > 0 && (d.map { $0 > 0 } ?? true)
            case .account(let value): value > 0
            }
        }
    }

    package struct Policy: Sendable, Equatable {
        package let versions: Versions
        package let senderActive: Bool
        package let recipientActive: Bool
        package let blocked: Bool
        package let friend: Bool
        package let allowsStrangers: Bool
        /// Complete account facts (including special-account capabilities) are
        /// versioned independently. The room writer owns their policy mapping.
        package let senderFacts: Data?
        package let recipientFacts: Data?

        package init(versions: Versions, senderActive: Bool, recipientActive: Bool,
                     blocked: Bool, friend: Bool, allowsStrangers: Bool,
                     senderFacts: Data? = nil, recipientFacts: Data? = nil) {
            self.versions = versions; self.senderActive = senderActive
            self.recipientActive = recipientActive; self.blocked = blocked
            self.friend = friend; self.allowsStrangers = allowsStrangers
            self.senderFacts = senderFacts; self.recipientFacts = recipientFacts
        }
        /// Account-only authorization carries no recipient or pair version.
        /// Membership and room permissions remain the writer's responsibility.
        package init(accountVersion: Int64, senderActive: Bool, senderFacts: Data) {
            self.init(versions: .init(accountSender: accountVersion), senderActive: senderActive,
                recipientActive: true, blocked: false, friend: true, allowsStrangers: false,
                senderFacts: senderFacts, recipientFacts: nil)
        }
        fileprivate var validShape: Bool {
            if !versions.isAccount { return versions.stranger != nil || (friend && !allowsStrangers) }
            return recipientActive && !blocked && friend && !allowsStrangers && recipientFacts == nil
                && senderFacts.map { !$0.isEmpty && $0.count <= 16_384 } == true
        }
    }

    /// Epoch and activation are scoped to the registered room holder, not the
    /// policy version. A fresh activation must use a fresh gate and registration.
    package struct Lease: Sendable, Equatable {
        package let id: UUID
        package let activation: UUID
        package let ownerEpoch: Int64
        package let generation: Int64
        package let validUntil: ContinuousClock.Instant

        package init(id: UUID, activation: UUID, ownerEpoch: Int64, generation: Int64,
                     validUntil: ContinuousClock.Instant) {
            self.id = id; self.activation = activation
            self.ownerEpoch = ownerEpoch; self.validUntil = validUntil
            self.generation = generation
        }
    }

    /// Opaque actual-execution ownership. Only this gate can mint a permit;
    /// release must follow physical SQL settlement, including COMMIT unknown.
    package struct Permit: Sendable {
        fileprivate let gate: UUID
        fileprivate let id: UUID
        package let leaseID: UUID
        package let versions: Versions
        package let deadline: ContinuousClock.Instant
    }

    package enum Failure: Error, Equatable {
        case unavailable, expired, staleVersion, wrongActivation, overloaded
        case senderInactive, recipientInactive, blocked, strangerForbidden
        case invalidPermit
    }

    private let identity = UUID()
    private let activation: UUID
    private let ownerEpoch: Int64
    private let maximumInFlight: Int
    private let now: @Sendable () -> ContinuousClock.Instant
    private var installed: (policy: Policy, lease: Lease)?
    private var lastVersions: Versions?
    private var lastStrangerVersion: Int64?
    private var revokedGeneration: Int64 = 0
    private var executing: Set<UUID> = []
    private var accepting = false
    private var closed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    package init(activation: UUID, ownerEpoch: Int64, maximumInFlight: Int,
                 now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        precondition(ownerEpoch >= 0 && maximumInFlight > 0)
        self.activation = activation; self.ownerEpoch = ownerEpoch
        self.maximumInFlight = maximumInFlight; self.now = now
    }

    package func install(_ policy: Policy, lease: Lease) throws {
        guard !closed, executing.isEmpty else { throw Failure.unavailable }
        guard lease.activation == activation, lease.ownerEpoch == ownerEpoch else {
            throw Failure.wrongActivation
        }
        guard lease.validUntil > now() else { throw Failure.expired }
        guard lease.generation > revokedGeneration, policy.versions.valid, policy.validShape,
              lastVersions.map({ policy.versions.dominates($0) }) ?? true,
              policy.versions.stranger.map({ current in lastStrangerVersion.map { current >= $0 } ?? true }) ?? true else {
            throw Failure.staleVersion
        }
        if let installed {
            guard lease.generation >= installed.lease.generation else { throw Failure.staleVersion }
            let previous = installed.policy
            guard policy.versions.sender != previous.versions.sender
                    || (policy.senderActive == previous.senderActive && policy.senderFacts == previous.senderFacts),
                  policy.versions.recipient != previous.versions.recipient
                    || (policy.recipientActive == previous.recipientActive
                        && policy.recipientFacts == previous.recipientFacts),
                  policy.versions.stranger != previous.versions.stranger
                    || policy.allowsStrangers == previous.allowsStrangers,
                  policy.versions.pair != previous.versions.pair
                    || (policy.blocked == previous.blocked && policy.friend == previous.friend) else {
                throw Failure.staleVersion
            }
            if lease.generation == installed.lease.generation {
                guard lease.id == installed.lease.id,
                      lease.validUntil >= installed.lease.validUntil,
                      policy == installed.policy else { throw Failure.staleVersion }
            }
        }
        // An equal version cannot change facts. That would give the same
        // version two incompatible meanings after a delayed refresh response.
        if let installed, installed.policy.versions == policy.versions,
           installed.policy != policy { throw Failure.staleVersion }
        installed = (policy, lease)
        lastVersions = policy.versions
        if let version = policy.versions.stranger { lastStrangerVersion = version }
        accepting = true
    }

    package func acquire(callerDeadline: ContinuousClock.Instant) throws -> Permit {
        let permit = try reserveExecution(callerDeadline: callerDeadline)
        do {
            let policy = installed!.policy
            guard policy.senderActive else { throw Failure.senderInactive }
            if policy.versions.isAccount { return permit }
            guard policy.recipientActive else { throw Failure.recipientInactive }
            guard !policy.blocked else { throw Failure.blocked }
            guard policy.friend || policy.allowsStrangers else { throw Failure.strangerForbidden }
            return permit
        } catch {
            try settled(permit)
            throw error
        }
    }

    /// Reserve actual execution ownership before borrowing SQL. Full policy
    /// evaluation also needs locked room-local reply/quota facts and remains
    /// in the room writer; this method alone grants no message permission.
    package func reserveExecution(callerDeadline: ContinuousClock.Instant) throws -> Permit {
        guard !closed, accepting, let installed else { throw Failure.unavailable }
        let deadline = min(callerDeadline, installed.lease.validUntil)
        guard deadline > now() else { throw Failure.expired }
        guard executing.count < maximumInFlight else { throw Failure.overloaded }
        let id = UUID()
        executing.insert(id)
        return Permit(gate: identity, id: id, leaseID: installed.lease.id,
                      versions: installed.policy.versions, deadline: deadline)
    }

    package func requireExecuting(_ permit: Permit) throws {
        guard permit.gate == identity, executing.contains(permit.id) else { throw Failure.invalidPermit }
    }

    package func settled(_ permit: Permit) throws {
        guard permit.gate == identity, executing.remove(permit.id) != nil else {
            throw Failure.invalidPermit
        }
        if executing.isEmpty {
            let completed = waiters; waiters.removeAll()
            for waiter in completed { waiter.resume() }
        }
    }

    /// A delayed revoke can retire an old registration, never a new one.
    /// Cancellation of the waiting caller cannot reopen the gate or erase SQL
    /// ownership. Repeated revocations join the same actual executions.
    package func revoke(leaseID: UUID) async -> Bool {
        guard installed?.lease.id == leaseID else { return false }
        accepting = false
        revokedGeneration = max(revokedGeneration, installed!.lease.generation)
        await drain()
        return true
    }

    /// Remember a revoke even if its cold-load response has not arrived yet.
    /// The high-water mark is bounded and cannot retire a newer registration.
    package func revoke(lease: Lease) async throws {
        guard lease.activation == activation, lease.ownerEpoch == ownerEpoch, lease.generation > 0 else {
            throw Failure.wrongActivation
        }
        if let installed, lease.generation == installed.lease.generation,
           lease.id != installed.lease.id { throw Failure.staleVersion }
        revokedGeneration = max(revokedGeneration, lease.generation)
        if let installed, installed.lease.generation <= lease.generation {
            accepting = false
            await drain()
        }
    }

    package func shutdown() async {
        closed = true; accepting = false
        await drain()
    }

    private func drain() async {
        guard !executing.isEmpty else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    package func snapshot() -> (accepting: Bool, inFlight: Int, waitingForSettlement: Int) {
        (accepting && !closed && (installed.map { $0.lease.validUntil > now() } ?? false),
         executing.count, waiters.count)
    }
}
