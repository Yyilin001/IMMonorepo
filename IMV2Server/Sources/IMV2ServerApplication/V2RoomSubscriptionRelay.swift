import Foundation
import IMV2Core
import IMV2ActorContracts
import Crypto
import IMV2ServerContracts

public enum V2RoomSubscriptionRelayError: Error, Equatable, Sendable {
    case stale, conflict, unauthorized, overloaded, roomSequenceGap, invalidInput
}

/// Inputs are emitted by the fenced room owner, after its membership transaction
/// commits. inputSequence covers membership, subscribe, unsubscribe and event
/// operations together. It must not be assigned by concurrent RPC arrival order.
public struct V2RoomSubscriptionInput: Equatable, Sendable {
    public let ownerEpoch: Int64
    public let inputSequence: UInt64
    public let operation: Operation
    public enum Operation: Equatable, Sendable {
        case membership(userID: UserID, revision: UInt64, authorized: Bool)
        case subscribe(gateway: V2GatewayRealtimeIdentity, userID: UserID, memberRevision: UInt64,
                       subscriptionID: UUID, generation: UInt64)
        case unsubscribe(gateway: V2GatewayRealtimeIdentity, userID: UserID, memberRevision: UInt64)
        /// Recovery starts a new independent generation and a fresh baseline.
        case reset(gateway: V2GatewayRealtimeIdentity, subscriptionID: UUID, generation: UInt64)
        case event(V2RealtimeRoomEvent)
    }
    public init(ownerEpoch: Int64, inputSequence: UInt64, operation: Operation) {
        self.ownerEpoch = ownerEpoch; self.inputSequence = inputSequence; self.operation = operation
    }
}

/// A bounded online relay. No suspension occurs while advancing its authoritative
/// state, so a baseline and its following events are one ordered transition.
/// The transport inspects `status`, replaces a fence when needsBaseline is set,
/// and acknowledges `pending` only after exact-fence Gateway admission. Bodies
/// may become heads; durable room pull remains the recovery path.
public actor V2RoomSubscriptionRelay {
    public struct AuthorizationProgress: Sendable {
        public let fence: V2RoomSubscriptionFence
        public let issued: UInt64
        public let applied: UInt64
        public let invalidated: Bool
        public let isUnreferenced: Bool
        public init(fence: V2RoomSubscriptionFence, issued: UInt64, applied: UInt64,
                    invalidated: Bool, isUnreferenced: Bool = false) {
            self.fence = fence; self.issued = issued; self.applied = applied
            self.invalidated = invalidated; self.isUnreferenced = isUnreferenced
        }
    }
    public typealias ObserveAuthorization = @Sendable (AuthorizationProgress, V2GatewayRealtimeIdentity) -> Void
    public struct Status: Equatable, Sendable {
        public let fence: V2RoomSubscriptionFence
        public let latestHighWatermark: UInt64
        public let needsBaseline: Bool
    }
    private struct Membership: Sendable { let revision: UInt64; let authorized: Bool }
    private struct BufferedInput: Sendable {
        let input: V2RoomSubscriptionInput
        let fingerprint: Data
        let retainedBytes: Int
    }
    private struct Subscription: Sendable {
        let gateway: V2GatewayRealtimeIdentity
        let fence: V2RoomSubscriptionFence
        var members: [UserID: UInt64]
        var nextAuthorizationSequence: UInt64 = 1
        var nextSequence: UInt64 = 1
        // Message ACK progress is independent of the authorization frontier.
        var latestAuthoritySequence: UInt64 { nextAuthorizationSequence - 1 }
        var authorizationOutbox: [V2RoomSubscriptionDelivery] = []
        var messageOutbox: [V2RoomSubscriptionDelivery] = []
        var deferredHighWatermark: UInt64?
        var pending: [V2RoomSubscriptionDelivery] {
            (authorizationOutbox + messageOutbox).sorted { $0.deliverySequence < $1.deliverySequence }
        }
        var pendingBodyBytes: Int = 0
        var latestHighWatermark: UInt64 = 0
        var needsBaseline = false
        var controlInvalidated = false
    }
    private let roomID: RoomID
    private let ownerEpoch: Int64
    private let sourceOwner: V2RoomDataOwner
    private let activation: V2RoomActivationToken
    private let observeAuthorization: ObserveAuthorization
    private let maximumBufferedInputs: Int
    private let maximumBufferedInputBytes: Int
    private let maximumPendingDeliveries: Int
    private let maximumPendingBodyBytes: Int
    private let maximumGateways: Int
    private let maximumMembers: Int
    private var sourceMembershipRevision: UInt64
    private var roomSequence: UInt64
    private var nextInput: UInt64
    private var membership: [UserID: Membership] = [:]
    private var subscriptions: [V2GatewayRealtimeIdentity: Subscription] = [:]
    private var buffered: [UInt64: BufferedInput] = [:]
    private var bufferedInputBytes = 0
    private var applied: [UInt64: Data] = [:]

    public init(activation: V2RoomActivationToken, baselineSequence: UInt64,
                nextInputSequence: UInt64 = 1, members: [V2RoomSubscriptionMember] = [],
                initialAuthorizations: [V2RoomSubscriptionSourceMember] = [],
                sourceMembershipRevision: UInt64 = 0,
                maximumBufferedInputs: Int = 128, maximumPendingDeliveries: Int = 256,
                maximumBufferedInputBytes: Int = 1_048_576,
                maximumPendingBodyBytes: Int = 1_048_576,
                maximumGateways: Int = 64, maximumMembers: Int = V2GroupCapacityPolicy.largeMaximumMembers,
                observeAuthorization: @escaping ObserveAuthorization = { _, _ in }) throws {
        guard sourceMembershipRevision <= UInt64(Int64.max), activation.owner.epoch >= 0, baselineSequence <= UInt64(Int64.max), nextInputSequence > 0,
              maximumBufferedInputs > 0, maximumPendingDeliveries > 0, maximumPendingBodyBytes > 0, maximumGateways > 0,
              maximumBufferedInputBytes > 0,
              maximumMembers > 0, members.count <= maximumMembers,
              initialAuthorizations.count <= maximumMembers,
              Set(initialAuthorizations.map(\.userID)).count == initialAuthorizations.count,
              Set(initialAuthorizations.map(\.userID)).isDisjoint(with: members.map(\.userID)),
              initialAuthorizations.count + members.count <= maximumMembers,
              Set(members.map(\.userID)).count == members.count,
              members.allSatisfy({ $0.memberRevision <= UInt64(Int64.max) }),
              initialAuthorizations.allSatisfy({ $0.memberRevision <= UInt64(Int64.max) }) else {
            throw V2RoomSubscriptionRelayError.invalidInput
        }
        self.roomID = activation.roomID; self.ownerEpoch = activation.owner.epoch; self.roomSequence = baselineSequence
        self.activation = activation
        self.observeAuthorization = observeAuthorization
        self.sourceOwner = activation.owner; self.sourceMembershipRevision = sourceMembershipRevision
        self.nextInput = nextInputSequence; self.maximumBufferedInputs = maximumBufferedInputs
        self.maximumBufferedInputBytes = maximumBufferedInputBytes
        self.maximumPendingDeliveries = maximumPendingDeliveries; self.maximumGateways = maximumGateways
        self.maximumPendingBodyBytes = maximumPendingBodyBytes
        self.maximumMembers = maximumMembers
        for member in members { membership[member.userID] = .init(revision: member.memberRevision, authorized: true) }
        for member in initialAuthorizations {
            membership[member.userID] = .init(revision: member.memberRevision, authorized: member.authorized)
        }
    }

    public static func restored(from snapshot: V2RoomSubscriptionSourceSnapshot, activation: V2RoomActivationToken,
                                maximumMembers: Int = V2GroupCapacityPolicy.largeMaximumMembers, maximumGateways: Int = 64,
                                observeAuthorization: @escaping ObserveAuthorization = { _, _ in }) throws -> V2RoomSubscriptionRelay {
        guard snapshot.roomID == activation.roomID, snapshot.owner == activation.owner else {
            throw V2RoomSubscriptionRelayError.stale
        }
        return try .init(activation: activation,
                  baselineSequence: snapshot.highWatermark, initialAuthorizations: snapshot.members,
                  sourceMembershipRevision: snapshot.membershipRevision,
                  maximumGateways: maximumGateways, maximumMembers: maximumMembers, observeAuthorization: observeAuthorization)
    }

    public func committedSequence() -> UInt64 { roomSequence }

    /// Owner source fencing failure stops every old stream. Composition must
    /// restore from a fresh fenced snapshot; transport cannot ACK past this.
    public func invalidate() {
        for gateway in Array(subscriptions.keys) {
            if let subscription = subscriptions[gateway] { reportAuthorization(subscription, invalidated: true) }
            subscriptions[gateway]?.needsBaseline = true
            subscriptions[gateway]?.authorizationOutbox.removeAll(keepingCapacity: false)
            subscriptions[gateway]?.messageOutbox.removeAll(keepingCapacity: false)
            subscriptions[gateway]?.deferredHighWatermark = nil
            subscriptions[gateway]?.pendingBodyBytes = 0
        }
    }

    /// A retirement may not discard an unacknowledged final revoke. A healthy
    /// pump releases it; a slow receiver retains bounded recovery responsibility.
    public func retireEmptyGateways(_ candidates: Set<V2GatewayRealtimeIdentity>) -> Set<V2GatewayRealtimeIdentity> {
        var retired: Set<V2GatewayRealtimeIdentity> = []
        for gateway in candidates {
            guard let subscription = subscriptions[gateway], subscription.members.isEmpty,
                  !subscription.needsBaseline,
                  subscription.pending.isEmpty else { continue }
            subscriptions.removeValue(forKey: gateway); retired.insert(gateway)
        }
        return retired
    }

    public func forgetAuthorizations(_ candidates: Set<UserID>) -> Set<UserID> {
        let referenced = Set(subscriptions.values.flatMap { $0.members.keys })
        let forgotten = candidates.subtracting(referenced)
        for user in forgotten { membership.removeValue(forKey: user) }
        return forgotten
    }

    /// Attach new tracked users only after existing subscriptions have consumed
    /// through this snapshot cut. Existing grants/fences are left intact.
    public func seedAuthorizations(from snapshot: V2RoomSubscriptionSourceSnapshot) throws {
        guard snapshot.roomID == roomID, snapshot.owner == sourceOwner,
              snapshot.highWatermark == roomSequence, snapshot.membershipRevision == sourceMembershipRevision else { throw V2RoomSubscriptionRelayError.stale }
        guard Set(snapshot.members.map(\.userID)).count == snapshot.members.count else {
            throw V2RoomSubscriptionRelayError.invalidInput
        }
        let added = snapshot.members.filter { membership[$0.userID] == nil }
        guard added.count <= maximumMembers - membership.count,
              snapshot.members.allSatisfy({ $0.memberRevision <= UInt64(Int64.max) }) else {
            throw V2RoomSubscriptionRelayError.overloaded
        }
        for member in snapshot.members {
            if let old = membership[member.userID] {
                guard old.revision == member.memberRevision, old.authorized == member.authorized else {
                    throw V2RoomSubscriptionRelayError.stale
                }
            }
        }
        for member in added {
            membership[member.userID] = .init(revision: member.memberRevision, authorized: member.authorized)
        }
    }

    /// A page is validated before any mutation, then applied without suspension:
    /// each committed member transition precedes that sequence's body/head.
    /// Room sequence provides ordering independently of concurrent RPC arrival.
    public func ingest(_ page: V2RoomSubscriptionSourcePage) throws {
        guard page.roomID == roomID, page.owner.epoch == ownerEpoch,
              page.owner == sourceOwner,
              page.afterRoomSequence == roomSequence else { throw V2RoomSubscriptionRelayError.stale }
        var projected = membership
        var revision = sourceMembershipRevision
        var expected = roomSequence + 1
        for record in page.records {
            try validateEvent(record.event, expected: expected)
            guard record.event.highWatermark == page.highWatermark else { throw V2RoomSubscriptionRelayError.invalidInput }
            if let control = record.membershipControl {
                guard control.revisionBefore == revision, control.revisionAfter == revision + 1,
                      control.revisionAfter <= UInt64(Int64.max),
                      record.event.groupMembershipRevision == control.revisionBefore || record.event.groupMembershipRevision == control.revisionAfter,
                      control.members.count <= maximumMembers,
                      Set(control.members.map(\.userID)) == Set(membership.keys),
                      Set(control.members.map(\.userID)).count == control.members.count else {
                    throw V2RoomSubscriptionSourceError.snapshotRequired
                }
                for member in control.members {
                    guard member.memberRevision <= control.revisionAfter else { throw V2RoomSubscriptionRelayError.invalidInput }
                    if let old = projected[member.userID],
                       old.revision != member.memberRevision || old.authorized != member.authorized {
                        guard member.memberRevision > old.revision else { throw V2RoomSubscriptionRelayError.stale }
                    }
                    projected[member.userID] = .init(revision: member.memberRevision, authorized: member.authorized)
                }
                revision = control.revisionAfter
            } else {
                // A message at a new membership revision without its preceding
                // room-sequence control is incomplete; fail closed, never infer
                // permissions from current SQL membership state.
                guard record.event.groupMembershipRevision == revision else {
                    throw V2RoomSubscriptionSourceError.snapshotRequired
                }
            }
            if case .explicit(let eligible) = record.recipientPolicy {
                guard eligible.count <= maximumMembers,
                      eligible.allSatisfy({ projected[$0]?.authorized == true }) else {
                    throw V2RoomSubscriptionRelayError.invalidInput
                }
            }
            expected += 1
        }
        for record in page.records {
            if let control = record.membershipControl {
                for member in control.members {
                    if let old = membership[member.userID], old.revision == member.memberRevision,
                       old.authorized == member.authorized { continue }
                    try apply(.membership(userID: member.userID, revision: member.memberRevision, authorized: member.authorized))
                }
                sourceMembershipRevision = control.revisionAfter
            }
            let eligible: Set<UserID>?
            switch record.recipientPolicy {
            case .currentAuthorized: eligible = nil
            case .explicit(let users): eligible = users
            }
            emitEvent(record.event, eligible: eligible, hasBody: record.hasOnlineBody)
            roomSequence = record.event.roomSequence
        }
    }

    /// Returns the last contiguous applied input. Out-of-order arrivals wait in
    /// a bounded buffer; duplicates never repeat a control or event.
    @discardableResult public func offer(_ input: V2RoomSubscriptionInput) throws -> UInt64 {
        guard input.ownerEpoch == ownerEpoch else { throw V2RoomSubscriptionRelayError.stale }
        guard input.inputSequence > 0, input.inputSequence < UInt64.max else {
            throw V2RoomSubscriptionRelayError.invalidInput
        }
        if case .event(let event) = input.operation {
            guard event.payload.count <= 262_144, event.recipientUserIDs.count <= maximumMembers,
                  event.projectionKind.utf8.count <= 128 else { throw V2RoomSubscriptionRelayError.invalidInput }
        }
        let inputGateway: V2GatewayRealtimeIdentity?
        switch input.operation {
        case .subscribe(let gateway, _, _, _, _), .unsubscribe(let gateway, _, _), .reset(let gateway, _, _):
            inputGateway = gateway
        default: inputGateway = nil
        }
        if let gateway = inputGateway {
            guard gateway.nodeID.utf8.count <= 128, gateway.serviceID.utf8.count <= 128 else {
                throw V2RoomSubscriptionRelayError.invalidInput
            }
        }
        if input.inputSequence < nextInput {
            guard let previous = applied[input.inputSequence] else { throw V2RoomSubscriptionRelayError.stale }
            guard previous == fingerprint(input) else { throw V2RoomSubscriptionRelayError.conflict }
            return nextInput - 1
        }
        if input.inputSequence == nextInput, buffered[input.inputSequence] == nil {
            // An arriving gap-filler must make progress even when the reorder
            // budget is full. It need not be retained: failure leaves retry
            // responsibility with the caller, success retains just its digest.
            try apply(input.operation)
            applied[nextInput] = fingerprint(input)
            nextInput += 1
            pruneAppliedHistory()
        } else if let previous = buffered[input.inputSequence] {
            guard previous.input == input else { throw V2RoomSubscriptionRelayError.conflict }
        } else {
            let bytes = retainedBytes(input)
            guard buffered.count < maximumBufferedInputs,
                  bytes <= maximumBufferedInputBytes - bufferedInputBytes,
                  input.inputSequence - nextInput < UInt64(maximumBufferedInputs) else {
                throw V2RoomSubscriptionRelayError.overloaded
            }
            buffered[input.inputSequence] = .init(input: input, fingerprint: fingerprint(input), retainedBytes: bytes)
            bufferedInputBytes += bytes
        }
        while let current = buffered[nextInput] {
            // Validate before mutation. A slow recipient degrades locally and
            // cannot roll back committed room progress or another recipient.
            try apply(current.input.operation)
            buffered.removeValue(forKey: nextInput)
            bufferedInputBytes -= current.retainedBytes
            applied[nextInput] = current.fingerprint
            nextInput += 1
            pruneAppliedHistory()
        }
        return nextInput - 1
    }

    private func pruneAppliedHistory() {
        if nextInput > UInt64(maximumBufferedInputs) {
            applied.removeValue(forKey: nextInput - UInt64(maximumBufferedInputs) - 1)
        }
    }

    /// Includes conservative metadata/collection storage, not just body bytes.
    private func retainedBytes(_ input: V2RoomSubscriptionInput) -> Int {
        switch input.operation {
        case .event(let event): return 1024 + event.payload.count + event.recipientUserIDs.count * 256
        default: return 1024
        }
    }

    /// Length-prefixed canonical fields avoid ambiguous concatenation. Set
    /// recipients are sorted; body bytes enter SHA256 directly without retaining
    /// a second body or encoding it into the deduplication history.
    private func fingerprint(_ input: V2RoomSubscriptionInput) -> Data {
        var hash = SHA256()
        func field(_ value: String) {
            hash.update(data: Data("\(value.utf8.count):".utf8))
            hash.update(data: Data(value.utf8))
        }
        func gateway(_ value: V2GatewayRealtimeIdentity) {
            field(value.nodeID); field(value.serviceID); field(value.incarnationID.uuidString)
        }
        field(String(input.ownerEpoch)); field(String(input.inputSequence))
        switch input.operation {
        case .membership(let user, let revision, let authorized):
            field("membership"); field(user.rawValue); field(String(revision)); field(String(authorized))
        case .subscribe(let target, let user, let revision, let id, let generation):
            field("subscribe"); gateway(target); field(user.rawValue); field(String(revision))
            field(id.uuidString); field(String(generation))
        case .unsubscribe(let target, let user, let revision):
            field("unsubscribe"); gateway(target); field(user.rawValue); field(String(revision))
        case .reset(let target, let id, let generation):
            field("reset"); gateway(target); field(id.uuidString); field(String(generation))
        case .event(let event):
            field("event"); field(event.roomID.rawValue); field(String(event.highWatermark))
            field(event.sourceEventID.rawValue); field(String(event.roomSequence)); field(event.projectionKind)
            field(event.groupMembershipRevision.map { String($0) } ?? "nil")
            field(event.acceptedMembershipRevision.map { String($0) } ?? "nil")
            field(event.excludedConnectionID?.uuidString ?? "nil")
            field(String(event.recipientUserIDs.count))
            for user in event.recipientUserIDs.sorted() { field(user.rawValue) }
            field(String(event.payload.count)); hash.update(data: event.payload)
        }
        return Data(hash.finalize())
    }

    public func pending(for gateway: V2GatewayRealtimeIdentity) -> [V2RoomSubscriptionDelivery] {
        subscriptions[gateway]?.pending ?? []
    }

    package func pending(for gateway: V2GatewayRealtimeIdentity, lane: V2RoomSubscriptionLane) -> [V2RoomSubscriptionDelivery] {
        guard let subscription = subscriptions[gateway] else { return [] }
        return lane == .authorization ? subscription.authorizationOutbox : subscription.messageOutbox
    }

    /// Select status and its lane prefix in one actor turn. The immutable array
    /// remains a snapshot while the pump reserves and sends the actual call.
    package func pendingSnapshot(for gateway: V2GatewayRealtimeIdentity, lane: V2RoomSubscriptionLane)
        -> (status: Status, pending: [V2RoomSubscriptionDelivery])? {
        guard let subscription = subscriptions[gateway] else { return nil }
        let status = Status(fence: subscription.fence, latestHighWatermark: subscription.latestHighWatermark,
            needsBaseline: subscription.needsBaseline || (subscription.controlInvalidated
                && subscription.authorizationOutbox.isEmpty && subscription.messageOutbox.isEmpty))
        return (status, lane == .authorization ? subscription.authorizationOutbox : subscription.messageOutbox)
    }

    /// Trusted Owner reconciliation after a complete shared-stream reset.
    package func subscriptionMembers(for gateway: V2GatewayRealtimeIdentity) -> [V2RoomSubscriptionMember] {
        (subscriptions[gateway]?.members ?? [:]).map { .init(userID: $0.key, memberRevision: $0.value) }
    }

    /// A trusted complete cut proves the ordered authorization state, or fails
    /// closed with one terminal control per old fence. No old body can follow it.
    package func reconcileControlCut(_ snapshot: V2RoomSubscriptionSourceSnapshot, requireTerminal: Bool = false) throws -> Bool {
        guard snapshot.roomID == roomID, snapshot.owner == sourceOwner, snapshot.highWatermark >= roomSequence,
              Set(snapshot.members.map(\.userID)) == Set(membership.keys) else { throw V2RoomSubscriptionRelayError.stale }
        // Send-only policies can advance the log without changing receivers.
        // Keep consuming that log in order instead of resetting live grants.
        let matches = snapshot.membershipRevision == sourceMembershipRevision
            && snapshot.members.allSatisfy { member in
                membership[member.userID].map { $0.revision == member.memberRevision && $0.authorized == member.authorized } ?? false
            }
        if matches && !requireTerminal { return false }
        membership = Dictionary(uniqueKeysWithValues: snapshot.members.map { ($0.userID, Membership(revision: $0.memberRevision, authorized: $0.authorized)) })
        sourceMembershipRevision = snapshot.membershipRevision; roomSequence = snapshot.highWatermark
        try invalidateAuthorizations()
        return true
    }

    /// Permission controls do not await or acknowledge message consumption.
    package func invalidateAuthorizations() throws {
        for gateway in Array(subscriptions.keys) {
            guard var subscription = subscriptions[gateway], !subscription.controlInvalidated else { continue }
            guard subscription.nextSequence < .max else { throw V2RoomSubscriptionRelayError.overloaded }
            // One reserved terminal slot beyond the bounded ordinary queue.
            // Preserve previously published immutable prefixes for lost ACK retry.
            subscription.authorizationOutbox.append(.init(fence: subscription.fence, deliverySequence: subscription.nextSequence, authorizationSequence: subscription.nextAuthorizationSequence, payload: .authorizationInvalidated))
            subscription.nextAuthorizationSequence += 1
            subscription.nextSequence += 1; subscription.controlInvalidated = true
            reportAuthorization(subscription)
            subscriptions[gateway] = subscription
        }
    }
    package func controlInvalidationPending(gateway: V2GatewayRealtimeIdentity? = nil) -> Bool {
        let selected = gateway.map { subscriptions[$0].map { [$0] } ?? [] } ?? Array(subscriptions.values)
        return selected.contains { subscription in
            subscription.controlInvalidated && subscription.pending.contains { $0.payload == .authorizationInvalidated }
        }
    }

    /// Advisory anti-entropy for already-consumed committed facts. It never
    /// grants members or changes a fence. An outstanding equal/newer head/body
    /// owns delivery responsibility, so periodic ticks cannot grow that queue.
    package func refreshHeads(highWatermark: UInt64, gateways: Set<V2GatewayRealtimeIdentity>) throws -> Bool {
        guard highWatermark <= roomSequence else { throw V2RoomSubscriptionRelayError.roomSequenceGap }
        var changed = false
        for gateway in gateways {
            guard var subscription = subscriptions[gateway], !subscription.members.isEmpty, !subscription.controlInvalidated else { continue }
            subscription.latestHighWatermark = max(subscription.latestHighWatermark, highWatermark)
            if subscription.needsBaseline { subscriptions[gateway] = subscription; continue }
            let outstanding = subscription.pending.contains { delivery in
                switch delivery.payload {
                case .head(let head): return head >= highWatermark
                case .broadcast(let event), .event(let event, _): return event.highWatermark >= highWatermark
                case .baseline, .baselinePage: return delivery.fence.baselineSequence >= highWatermark
                default: return false
                }
            }
            if !outstanding {
                append(.head(highWatermark: highWatermark), to: &subscription)
                subscriptions[gateway] = subscription; changed = true
            }
        }
        return changed
    }

    public func status(for gateway: V2GatewayRealtimeIdentity) -> Status? {
        guard let subscription = subscriptions[gateway] else { return nil }
        return .init(fence: subscription.fence, latestHighWatermark: subscription.latestHighWatermark,
                     needsBaseline: subscription.needsBaseline || (subscription.controlInvalidated
                        && subscription.authorizationOutbox.isEmpty && subscription.messageOutbox.isEmpty))
    }

    package func acknowledge(gateway: V2GatewayRealtimeIdentity, fence: V2RoomSubscriptionFence,
                             through sequence: UInt64, lane: V2RoomSubscriptionLane) throws {
        guard var subscription = subscriptions[gateway], subscription.fence == fence else { throw V2RoomSubscriptionRelayError.stale }
        guard sequence < subscription.nextSequence else { throw V2RoomSubscriptionRelayError.invalidInput }
        if lane == .authorization {
            subscription.authorizationOutbox.removeAll { $0.deliverySequence <= sequence }
            reportAuthorization(subscription)
        } else {
            subscription.messageOutbox.removeAll { $0.deliverySequence <= sequence }
            subscription.pendingBodyBytes = subscription.messageOutbox.reduce(0) { $0 + bodyBytes($1.payload) }
            if let head = subscription.deferredHighWatermark,
               subscription.messageOutbox.count < maximumPendingDeliveries, !subscription.controlInvalidated {
                subscription.deferredHighWatermark = nil
                append(.head(highWatermark: head), to: &subscription)
            }
        }
        subscriptions[gateway] = subscription
        if lane == .message, subscription.members.isEmpty { reportAuthorization(subscription) }
    }

    /// A receiver with a newer permission cut rejects old bodies. Retire only
    /// their transport responsibility and retain the durable recovery target.
    package func recoverRejectedMessages(gateway: V2GatewayRealtimeIdentity, fence: V2RoomSubscriptionFence,
                                         through sequence: UInt64) throws {
        try acknowledge(gateway: gateway, fence: fence, through: sequence, lane: .message)
        guard var subscription = subscriptions[gateway], subscription.fence == fence,
              !subscription.controlInvalidated, !subscription.members.isEmpty else { return }
        append(.head(highWatermark: subscription.latestHighWatermark), to: &subscription)
        subscriptions[gateway] = subscription
    }

    private func bodyBytes(_ payload: V2RoomSubscriptionPayload) -> Int {
        switch payload {
        case .broadcast(let event), .event(let event, _): return event.payload.count
        default: return 0
        }
    }

    private func append(_ payload: V2RoomSubscriptionPayload, to subscription: inout Subscription) {
        defer { if payload.isAuthorizationControl { reportAuthorization(subscription) } }
        guard !subscription.needsBaseline else { return }
        guard subscription.nextSequence < UInt64.max else {
            subscription.needsBaseline = true
            return
        }
        if payload.isAuthorizationControl {
            guard !subscription.controlInvalidated else { return }
            guard subscription.nextAuthorizationSequence < UInt64.max else { subscription.needsBaseline = true; return }
            if subscription.authorizationOutbox.count >= maximumPendingDeliveries {
                // Preserve the immutable prefix and one reserved terminal slot.
                // The Gateway must apply denial before this fence can retire.
                subscription.authorizationOutbox.append(.init(fence: subscription.fence,
                    deliverySequence: subscription.nextSequence, authorizationSequence: subscription.nextAuthorizationSequence,
                    payload: .authorizationInvalidated))
                subscription.nextSequence += 1; subscription.nextAuthorizationSequence += 1
                subscription.controlInvalidated = true
                return
            }
        } else if subscription.messageOutbox.count >= maximumPendingDeliveries {
            // Body pressure retains one coalesced durable recovery target. It
            // neither consumes control capacity nor invalidates authorization.
            let head: UInt64
            switch payload {
            case .event(let event, _), .broadcast(let event): head = event.highWatermark
            case .head(let watermark): head = watermark
            default: return
            }
            subscription.deferredHighWatermark = max(subscription.deferredHighWatermark ?? 0, head)
            return
        }
        var admitted = payload
        if bodyBytes(payload) > maximumPendingBodyBytes - subscription.pendingBodyBytes {
            // Pending deliveries may already have been admitted with a lost
            // ACK. Their content is immutable for exact-duplicate retry. Only
            // this new event becomes a head until ACK releases body capacity.
            switch payload {
            case .event(let event, _), .broadcast(let event): admitted = .head(highWatermark: event.highWatermark)
            default: break
            }
        }
        let authoritySequence = admitted.isAuthorizationControl
            ? subscription.nextAuthorizationSequence : subscription.latestAuthoritySequence
        let delivery = V2RoomSubscriptionDelivery(fence: subscription.fence,
            deliverySequence: subscription.nextSequence, authorizationSequence: authoritySequence, payload: admitted)
        switch admitted {
        case .baseline, .baselinePage, .grant, .revoke, .authorizationInvalidated:

            subscription.nextAuthorizationSequence += 1
        default: break
        }
        subscription.pendingBodyBytes += bodyBytes(admitted)
        if admitted.isAuthorizationControl { subscription.authorizationOutbox.append(delivery) }
        else { subscription.messageOutbox.append(delivery) }
        subscription.nextSequence += 1
    }

    /// Enqueue and application ACK are the only normal update points. This
    /// bounded synchronous observer runs before a control can wait in the pump;
    /// ordinary messages perform no session bookkeeping or extra Actor hop.
    private func reportAuthorization(_ subscription: Subscription, invalidated: Bool = false) {
        observeAuthorization(.init(fence: subscription.fence,
            issued: subscription.latestAuthoritySequence,
            applied: subscription.authorizationOutbox.first.map { $0.authorizationSequence - 1 } ?? subscription.latestAuthoritySequence,
            invalidated: invalidated, isUnreferenced: subscription.members.isEmpty
                && subscription.authorizationOutbox.isEmpty && subscription.messageOutbox.isEmpty
                && subscription.deferredHighWatermark == nil), subscription.gateway)
    }

    private func apply(_ operation: V2RoomSubscriptionInput.Operation) throws {
        switch operation {
        case .membership(let user, let revision, let authorized):
            guard revision <= UInt64(Int64.max) else { throw V2RoomSubscriptionRelayError.invalidInput }
            if let previous = membership[user] {
                guard revision > previous.revision else { throw V2RoomSubscriptionRelayError.stale }
            } else if membership.count >= maximumMembers { throw V2RoomSubscriptionRelayError.overloaded }
            membership[user] = .init(revision: revision, authorized: authorized)
            // Changing a membership incarnation invalidates just this user's
            // grant, including a remove/re-add with the same UserID.
            for gateway in Array(subscriptions.keys) {
                guard var subscription = subscriptions[gateway], !subscription.controlInvalidated, subscription.members.removeValue(forKey: user) != nil else { continue }
                append(.revoke(userID: user, memberRevision: revision), to: &subscription)
                subscriptions[gateway] = subscription
            }
        case .subscribe(let gateway, let user, let revision, let id, let generation):
            guard let permission = membership[user], permission.authorized, permission.revision == revision else {
                throw V2RoomSubscriptionRelayError.unauthorized
            }
            guard generation > 0, !gateway.nodeID.isEmpty, !gateway.serviceID.isEmpty else {
                throw V2RoomSubscriptionRelayError.invalidInput
            }
            let member = V2RoomSubscriptionMember(userID: user, memberRevision: revision)
            if var subscription = subscriptions[gateway] {
                guard subscription.fence.subscriptionID == id, subscription.fence.generation == generation else {
                    throw V2RoomSubscriptionRelayError.stale
                }
                if subscription.members[user] == revision { return }
                guard subscription.members.count < maximumMembers else { throw V2RoomSubscriptionRelayError.overloaded }
                subscription.members[user] = revision
                append(.grant(member: member, baselineSequence: roomSequence), to: &subscription)
                subscriptions[gateway] = subscription
            } else {
                guard subscriptions.count < maximumGateways else { throw V2RoomSubscriptionRelayError.overloaded }
                var subscription = Subscription(gateway: gateway, fence: .init(activation: activation, subscriptionID: id,
                    generation: generation, baselineSequence: roomSequence), members: [user: revision], latestHighWatermark: roomSequence)
                append(.baseline(members: [member]), to: &subscription)
                subscriptions[gateway] = subscription
            }
        case .unsubscribe(let gateway, let user, let revision):
            guard var subscription = subscriptions[gateway] else { return }
            guard subscription.members[user] == revision else { throw V2RoomSubscriptionRelayError.stale }
            subscription.members.removeValue(forKey: user)
            if subscription.members.isEmpty { subscription.deferredHighWatermark = nil }
            append(.revoke(userID: user, memberRevision: revision), to: &subscription)
            subscriptions[gateway] = subscription
        case .reset(let gateway, let id, let generation):
            guard let previous = subscriptions[gateway], generation > previous.fence.generation else {
                throw V2RoomSubscriptionRelayError.stale
            }
            let members = previous.members.compactMap { user, revision -> V2RoomSubscriptionMember? in
                guard let permission = membership[user], permission.authorized, permission.revision == revision else { return nil }
                return .init(userID: user, memberRevision: revision)
            }.sorted { $0.userID.rawValue < $1.userID.rawValue }
            var subscription = Subscription(gateway: gateway, fence: .init(activation: activation, subscriptionID: id,
                generation: generation, baselineSequence: roomSequence),
                members: Dictionary(uniqueKeysWithValues: members.map { ($0.userID, $0.memberRevision) }),
                latestHighWatermark: max(previous.latestHighWatermark, roomSequence))
            let pageSize = V2RoomSubscriptionPayload.maximumBaselinePageMembers
            if members.count <= pageSize {
                append(.baseline(members: members), to: &subscription)
            } else {
                for offset in stride(from: 0, to: members.count, by: pageSize) {
                    append(.baselinePage(index: offset / pageSize, totalMembers: members.count,
                        members: Array(members[offset..<min(offset + pageSize, members.count)])), to: &subscription)
                }
            }
            subscriptions[gateway] = subscription
        case .event(let event):
            try validateEvent(event, expected: roomSequence + 1)
            emitEvent(event, eligible: nil, hasBody: true)
            roomSequence = event.roomSequence
        }
    }

    private func validateEvent(_ event: V2RealtimeRoomEvent, expected: UInt64) throws {
        guard event.roomID == roomID, event.roomSequence == expected else {
            throw V2RoomSubscriptionRelayError.roomSequenceGap
        }
        guard event.highWatermark >= event.roomSequence, event.highWatermark <= UInt64(Int64.max),
              !event.recipientUserIDs.isEmpty || event.groupMembershipRevision != nil,
              event.payload.count <= 262_144, event.recipientUserIDs.count <= maximumMembers,
              !event.projectionKind.isEmpty, event.projectionKind.utf8.count <= 128 else {
            throw V2RoomSubscriptionRelayError.invalidInput
        }
    }

    private func emitEvent(_ event: V2RealtimeRoomEvent, eligible: Set<UserID>?, hasBody: Bool) {
        for gateway in Array(subscriptions.keys) {
            guard var subscription = subscriptions[gateway], !subscription.controlInvalidated else { continue }
            if eligible == nil && event.recipientUserIDs.isEmpty {
                // The only mutations of subscription.members are validated
                // grants and preceding membership controls. No ordinary body
                // enumerates or rebuilds the room's online authorization set.
                guard !subscription.members.isEmpty else { continue }
                subscription.latestHighWatermark = max(subscription.latestHighWatermark, event.highWatermark)
                append(hasBody ? .broadcast(event) : .head(highWatermark: event.highWatermark), to: &subscription)
                subscriptions[gateway] = subscription
                continue
            }
            let members = subscription.members.compactMap { user, revision -> V2RoomSubscriptionMember? in
                guard let permission = membership[user], permission.authorized, permission.revision == revision,
                      eligible?.contains(user) ?? true,
                      event.recipientUserIDs.isEmpty || event.recipientUserIDs.contains(user) else { return nil }
                return .init(userID: user, memberRevision: revision)
            }.sorted { $0.userID.rawValue < $1.userID.rawValue }
            if !members.isEmpty {
                subscription.latestHighWatermark = max(subscription.latestHighWatermark, event.highWatermark)
                append(hasBody ? .event(event, members: members) : .head(highWatermark: event.highWatermark), to: &subscription)
                subscriptions[gateway] = subscription
            }
        }
    }
}
