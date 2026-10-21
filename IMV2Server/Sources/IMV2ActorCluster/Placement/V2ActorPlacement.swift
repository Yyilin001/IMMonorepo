import Crypto
import Foundation
import IMV2ActorContracts
import IMV2Core
import Synchronization

package enum V2ActorPlacementError: Error, Equatable {
    case invalidConfiguration, staleRevision, conflictingSnapshot, staleOwner, unavailable, retiring
    case invalidTransition, epochExhausted, archiveCapacity, requestExpired
}

package struct V2ActorPlacementOwner: Equatable, Sendable {
    package let host: V2ActorHostIdentity
    package let epoch: UInt64
    package init(host: V2ActorHostIdentity, epoch: UInt64) { self.host = host; self.epoch = epoch }
}

package struct V2ActorPlacementTransfer: Equatable, Sendable {
    package let id: UUID
    package let successor: V2ActorHostIdentity
    package init(id: UUID, successor: V2ActorHostIdentity) { self.id = id; self.successor = successor }
}

package struct V2ActorPlacementSlot: Equatable, Sendable {
    package let owner: V2ActorPlacementOwner
    package let transfer: V2ActorPlacementTransfer?
    package let retired: Bool
    package init(owner: V2ActorPlacementOwner, transfer: V2ActorPlacementTransfer?, retired: Bool = false) {
        self.owner = owner; self.transfer = transfer; self.retired = retired
    }
}

/// A committed control-plane value, not a membership-derived ownership claim.
/// No room, database address or wall-clock lease is stored in this snapshot.
package struct V2ActorPlacementHostRegistration: Equatable, Sendable {
    package let host: V2ActorHostIdentity
    package let retired: Bool
    package init(host: V2ActorHostIdentity, retired: Bool) { self.host = host; self.retired = retired }
    package static func reserved(_ hostID: V2ActorHostID) -> Self {
        .init(host: .init(hostID: hostID, incarnationID: UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))), retired: true)
    }
}

package struct V2ActorPlacementSnapshot: Equatable, Sendable {
    package let clusterID: UUID
    package let revision: UInt64
    package let slots: [V2ActorPlacementSlot]
    package let hosts: [V2ActorPlacementHostRegistration]
    package let serviceMembership: V2ActorServiceMembershipRecord?

    /// Fresh in-process fixtures may derive the initial roster from slots.
    /// Committed transitions and wire decoding always supply the full roster.
    package init(clusterID: UUID, revision: UInt64, slots: [V2ActorPlacementSlot],
                 hosts: [V2ActorPlacementHostRegistration]? = nil,
                 serviceMembership: V2ActorServiceMembershipRecord? = nil) throws {
        guard revision > 0, !slots.isEmpty, slots.count <= 4096,
              slots.allSatisfy({ $0.owner.epoch > 0 && $0.owner.epoch <= V2RoomActorPlacementGrant.maximumEpoch && $0.transfer?.successor != $0.owner.host }) else {
            throw V2ActorPlacementError.invalidConfiguration
        }
        let registrations: [V2ActorPlacementHostRegistration]
        if let hosts { registrations = hosts }
        else {
            let groups = Dictionary(grouping: slots, by: { $0.owner.host.hostID })
            registrations = try groups.values.map { owned in
                let identity = owned[0].owner.host
                guard owned.allSatisfy({ $0.owner.host == identity }) else {
                    throw V2ActorPlacementError.invalidConfiguration
                }
                return .init(host: identity, retired: owned.allSatisfy(\.retired))
            }
        }
        guard !registrations.isEmpty, registrations.count <= 64,
              Set(registrations.map { $0.host.hostID }).count == registrations.count else {
            throw V2ActorPlacementError.invalidConfiguration
        }
        let byHost = Dictionary(uniqueKeysWithValues: registrations.map { ($0.host.hostID, $0) })
        for slot in slots {
            guard let owner = byHost[slot.owner.host.hostID], owner.host == slot.owner.host,
                  !owner.retired || slot.retired else {
                throw V2ActorPlacementError.invalidConfiguration
            }
            if let transfer = slot.transfer {
                // A retired successor remains recorded until cancellation. Its
                // identity must still be exact; retirement never rewrites it.
                guard byHost[transfer.successor.hostID]?.host == transfer.successor else {
                    throw V2ActorPlacementError.invalidConfiguration
                }
            }
        }
        self.clusterID = clusterID; self.revision = revision; self.slots = slots
        self.serviceMembership = serviceMembership
        self.hosts = registrations.sorted { $0.host.hostID.rawValue < $1.host.hostID.rawValue }
    }

    package func registration(for hostID: V2ActorHostID) -> V2ActorPlacementHostRegistration? {
        hosts.first { $0.host.hostID == hostID }
    }

    package func partition(for room: RoomID) -> Int {
        Int(Self.partitionHash(for: room) % UInt64(slots.count))
    }

    fileprivate static func partitionHash(for room: RoomID) -> UInt64 {
        // Stable across processes; Swift's randomized Hasher is not a placement function.
        let hash = SHA256.hash(data: Array(room.rawValue.utf8))
        return hash.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}

/// These events must enter through an authenticated control-plane boundary and
/// be committed by its replication protocol. An RPC timeout is never evidence.
package enum V2ActorPlacementCommand: Equatable, Sendable {
    case beginTransfer(partition: Int, expected: V2ActorPlacementOwner, transfer: V2ActorPlacementTransfer)
    case completeTransfer(partition: Int, expected: V2ActorPlacementOwner, transferID: UUID)
    case cancelTransfer(partition: Int, expected: V2ActorPlacementOwner, transferID: UUID)
    /// Emitted by the application's final stop, after every physical job drains.
    case retireHost(V2ActorHostIdentity)
    /// Reserve a trusted new logical host without granting any partition.
    case admitHost(V2ActorHostID)
    case installServiceMembership(V2ActorServiceMembershipRecord)
    /// No expiry-based replacement: all of this predecessor's slots must be retired.
    case registerHost(previous: V2ActorHostIdentity, successor: V2ActorHostIdentity)

    package var logKind: Int {
        switch self {
        case .beginTransfer: 1
        case .completeTransfer: 2
        case .cancelTransfer: 3
        case .retireHost: 4
        case .registerHost: 5
        case .admitHost: 6
        case .installServiceMembership: 7
        }
    }
}

/// Deterministic application of already committed log entries. It intentionally
/// performs no election, quorum voting or local speculative publication.
package struct V2ActorPlacementStateMachine: Sendable {
    package private(set) var snapshot: V2ActorPlacementSnapshot
    package init(snapshot: V2ActorPlacementSnapshot) { self.snapshot = snapshot }

    package mutating func apply(_ command: V2ActorPlacementCommand, revision: UInt64) throws {
        guard snapshot.revision < UInt64.max, revision == snapshot.revision + 1 else {
            throw V2ActorPlacementError.staleRevision
        }
        var slots = snapshot.slots
        var hosts = snapshot.hosts
        switch command {
        case .installServiceMembership(let record):
            try record.validateSuccessor(of: snapshot.serviceMembership)
            snapshot = try .init(clusterID: snapshot.clusterID, revision: revision, slots: slots, hosts: hosts, serviceMembership: record)
            return
        case .admitHost(let hostID):
            guard hosts.count < 64, !hosts.contains(where: { $0.host.hostID == hostID }) else {
                throw V2ActorPlacementError.invalidTransition
            }
            hosts.append(.reserved(hostID))
            snapshot = try .init(clusterID: snapshot.clusterID, revision: revision, slots: slots, hosts: hosts, serviceMembership: snapshot.serviceMembership)
            return
        case .retireHost(let host):
            guard let registration = hosts.firstIndex(where: { $0.host == host }), !hosts[registration].retired else {
                throw V2ActorPlacementError.staleOwner
            }
            let matching = slots.indices.filter { slots[$0].owner.host == host }
            for index in matching {
                slots[index] = .init(owner: slots[index].owner, transfer: slots[index].transfer, retired: true)
            }
            hosts[registration] = .init(host: host, retired: true)
            snapshot = try .init(clusterID: snapshot.clusterID, revision: revision, slots: slots, hosts: hosts, serviceMembership: snapshot.serviceMembership)
            return
        case .registerHost(let previous, let successor):
            guard previous.hostID == successor.hostID, previous != successor else {
                throw V2ActorPlacementError.invalidTransition
            }
            let matching = slots.indices.filter { slots[$0].owner.host.hostID == previous.hostID }
            guard let registration = hosts.firstIndex(where: { $0.host == previous && $0.retired }),
                  !slots.contains(where: { $0.transfer?.successor == previous }),
                  matching.allSatisfy({ slots[$0].owner.host == previous && slots[$0].retired && slots[$0].transfer == nil }) else {
                throw V2ActorPlacementError.staleOwner
            }
            guard matching.allSatisfy({ slots[$0].owner.epoch < V2RoomActorPlacementGrant.maximumEpoch }) else {
                throw V2ActorPlacementError.epochExhausted
            }
            for index in matching {
                slots[index] = .init(owner: .init(host: successor, epoch: slots[index].owner.epoch + 1), transfer: nil)
            }
            hosts[registration] = .init(host: successor, retired: false)
            snapshot = try .init(clusterID: snapshot.clusterID, revision: revision, slots: slots, hosts: hosts, serviceMembership: snapshot.serviceMembership)
            return
        default: break
        }
        let partition: Int
        let expected: V2ActorPlacementOwner
        switch command {
        case .beginTransfer(let p, let e, _), .completeTransfer(let p, let e, _), .cancelTransfer(let p, let e, _):
            partition = p; expected = e
        case .retireHost, .registerHost, .admitHost, .installServiceMembership: preconditionFailure("handled above")
        }
        guard slots.indices.contains(partition) else { throw V2ActorPlacementError.invalidConfiguration }
        let current = slots[partition]
        guard current.owner == expected else { throw V2ActorPlacementError.staleOwner }
        switch command {
        case .beginTransfer(_, _, let transfer):
            guard current.transfer == nil, transfer.successor != current.owner.host else {
                throw V2ActorPlacementError.invalidTransition
            }
            guard let registered = snapshot.registration(for: transfer.successor.hostID),
                  registered.host == transfer.successor, !registered.retired else {
                throw V2ActorPlacementError.staleOwner
            }
            slots[partition] = .init(owner: current.owner, transfer: transfer, retired: current.retired)
        case .completeTransfer(_, _, let transferID):
            guard let transfer = current.transfer, transfer.id == transferID else {
                throw V2ActorPlacementError.invalidTransition
            }
            guard current.owner.epoch < V2RoomActorPlacementGrant.maximumEpoch else { throw V2ActorPlacementError.epochExhausted }
            guard let registered = snapshot.registration(for: transfer.successor.hostID),
                  registered.host == transfer.successor, !registered.retired else {
                throw V2ActorPlacementError.staleOwner
            }
            slots[partition] = .init(owner: .init(host: transfer.successor, epoch: current.owner.epoch + 1), transfer: nil)
        case .cancelTransfer(_, _, let transferID):
            guard current.transfer?.id == transferID else { throw V2ActorPlacementError.invalidTransition }
            slots[partition] = .init(owner: current.owner, transfer: nil, retired: current.retired)
        case .retireHost, .registerHost, .admitHost, .installServiceMembership: preconditionFailure("handled above")
        }
        snapshot = try .init(clusterID: snapshot.clusterID, revision: revision, slots: slots, hosts: hosts, serviceMembership: snapshot.serviceMembership)
    }
}

/// Warm calls only capture this immutable value under a short lock. SQL and
/// remote calls never execute inside the directory's critical section.
package final class V2ActorPlacementDirectory: Sendable {
    private let state: Mutex<V2ActorPlacementSnapshot>
    package init(snapshot: V2ActorPlacementSnapshot) { state = Mutex(snapshot) }
    package func snapshot() -> V2ActorPlacementSnapshot { state.withLock { $0 } }
    package func installCommitted(_ snapshot: V2ActorPlacementSnapshot) throws {
        try install(snapshot, ignoringOlder: false)
    }
    package func installCommittedUnlessOlder(_ snapshot: V2ActorPlacementSnapshot) throws {
        try install(snapshot, ignoringOlder: true)
    }
    private func install(_ snapshot: V2ActorPlacementSnapshot, ignoringOlder: Bool) throws {
        try state.withLock { current in
            guard snapshot.clusterID == current.clusterID, snapshot.slots.count == current.slots.count else {
                throw V2ActorPlacementError.conflictingSnapshot
            }
            if ignoringOlder && snapshot.revision < current.revision { return }
            guard snapshot.revision >= current.revision else { throw V2ActorPlacementError.staleRevision }
            for (old, new) in zip(current.slots, snapshot.slots) where snapshot.revision > current.revision {
                guard new.owner.epoch >= old.owner.epoch,
                      new.owner.epoch != old.owner.epoch || new.owner == old.owner else {
                    throw V2ActorPlacementError.staleOwner
                }
            }
            if snapshot.revision == current.revision {
                guard snapshot == current else { throw V2ActorPlacementError.conflictingSnapshot }
            }
            current = snapshot
        }
    }
    /// The caller binds the room to this partition once during activation.
    /// Warm admission does not copy/retain the snapshot's slot array.
    package func admits(partition: Int, owner: V2ActorPlacementOwner) -> Bool {
        state.withLock { current in
            guard current.slots.indices.contains(partition) else { return false }
            let slot = current.slots[partition]
            return !slot.retired && slot.transfer == nil && slot.owner == owner
        }
    }

}
