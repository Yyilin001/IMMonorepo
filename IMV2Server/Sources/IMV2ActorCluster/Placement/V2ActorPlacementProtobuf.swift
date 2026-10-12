import Foundation
import IMV2ActorContracts
import SwiftProtobuf

/// Serialization occurs only at the durable/remote control-plane boundary.
/// Local room dispatch continues to pass immutable domain values directly.
package enum V2ActorPlacementProtobuf {
    package static func encode(_ snapshot: V2ActorPlacementSnapshot) throws -> Data {
        var wire = Im_Actor_V1_PlacementSnapshot()
        wire.clusterID = V2HotPB.bytes(snapshot.clusterID)
        wire.revision = snapshot.revision
        wire.hosts = snapshot.hosts.map { registration in
            var value = Im_Actor_V1_PlacementHostRegistration()
            value.host = .init(registration.host); value.retired = registration.retired
            return value
        }
        wire.slots = snapshot.slots.map { slot in
            var value = Im_Actor_V1_PlacementSlot()
            value.owner = owner(slot.owner)
            value.retired = slot.retired
            if let transfer = slot.transfer { value.transfer = self.transfer(transfer) }
            return value
        }
        return try wire.serializedData()
    }

    package static func decode(_ bytes: Data) throws -> V2ActorPlacementSnapshot {
        guard bytes.count <= 1_048_576 else { throw V2ActorPlacementError.invalidConfiguration }
        let wire = try Im_Actor_V1_PlacementSnapshot(serializedBytes: bytes)
        try V2HotPB.check(wire, !wire.slots.isEmpty && wire.slots.count <= 4096 && !wire.hosts.isEmpty && wire.hosts.count <= 64)
        return try .init(clusterID: V2HotPB.uuid(wire.clusterID), revision: wire.revision,
            slots: wire.slots.map { slot in
                try V2HotPB.check(slot, slot.hasOwner)
                let value = try model(slot.owner)
                let pending: V2ActorPlacementTransfer?
                if slot.hasTransfer {
                    try V2HotPB.check(slot.transfer, slot.transfer.hasSuccessor)
                    pending = try .init(id: V2HotPB.uuid(slot.transfer.id), successor: slot.transfer.successor.model())
                } else { pending = nil }
                return .init(owner: value, transfer: pending, retired: slot.retired)
            }, hosts: wire.hosts.map { registration in
                try V2HotPB.check(registration, registration.hasHost)
                return try .init(host: registration.host.model(), retired: registration.retired)
            })
    }

    package static func encode(_ command: V2ActorPlacementCommand) throws -> Data {
        var wire = Im_Actor_V1_PlacementCommand()
        let partition: Int
        switch command {
        case .beginTransfer(let p, let expected, let transfer):
            partition = p; wire.kind = .beginTransfer; wire.expected = owner(expected)
            wire.transfer = self.transfer(transfer)
        case .completeTransfer(let p, let expected, let id):
            partition = p; wire.kind = .completeTransfer; wire.expected = owner(expected)
            wire.transferID = V2HotPB.bytes(id)
        case .cancelTransfer(let p, let expected, let id):
            partition = p; wire.kind = .cancelTransfer; wire.expected = owner(expected)
            wire.transferID = V2HotPB.bytes(id)
        case .retireHost(let host):
            partition = 0; wire.kind = .retireHost; wire.previousHost = .init(host)
        case .registerHost(let previous, let successor):
            partition = 0; wire.kind = .registerHost; wire.previousHost = .init(previous); wire.successorHost = .init(successor)
        }
        guard (0..<4096).contains(partition) else { throw V2ActorPlacementError.invalidConfiguration }
        wire.partition = UInt32(partition)
        return try wire.serializedData()
    }

    package static func decodeCommand(_ bytes: Data) throws -> V2ActorPlacementCommand {
        guard bytes.count <= 4096 else { throw V2ActorPlacementError.invalidConfiguration }
        let wire = try Im_Actor_V1_PlacementCommand(serializedBytes: bytes)
        try V2HotPB.check(wire, wire.partition < 4096)
        if wire.kind == .retireHost || wire.kind == .registerHost {
            try V2HotPB.check(wire, wire.partition == 0 && !wire.hasExpected && !wire.hasTransfer &&
                wire.transferID.isEmpty && wire.hasPreviousHost)
            let previous = try wire.previousHost.model()
            if wire.kind == .retireHost {
                guard !wire.hasSuccessorHost else { throw V2ActorPlacementError.invalidConfiguration }
                return .retireHost(previous)
            }
            guard wire.hasSuccessorHost else { throw V2ActorPlacementError.invalidConfiguration }
            return try .registerHost(previous: previous, successor: wire.successorHost.model())
        }
        guard wire.hasExpected, !wire.hasPreviousHost, !wire.hasSuccessorHost else {
            throw V2ActorPlacementError.invalidConfiguration
        }
        let expected = try model(wire.expected), partition = Int(wire.partition)
        switch wire.kind {
        case .beginTransfer:
            try V2HotPB.check(wire.transfer, wire.hasTransfer && wire.transfer.hasSuccessor && wire.transferID.isEmpty)
            return try .beginTransfer(partition: partition, expected: expected,
                transfer: .init(id: V2HotPB.uuid(wire.transfer.id), successor: wire.transfer.successor.model()))
        case .completeTransfer, .cancelTransfer:
            guard !wire.hasTransfer else { throw V2ActorPlacementError.invalidConfiguration }
            let id = try V2HotPB.uuid(wire.transferID)
            if wire.kind == .completeTransfer { return .completeTransfer(partition: partition, expected: expected, transferID: id) }
            return .cancelTransfer(partition: partition, expected: expected, transferID: id)
        default: throw V2ActorPlacementError.invalidConfiguration
        }
    }

    private static func owner(_ value: V2ActorPlacementOwner) -> Im_Actor_V1_PlacementOwner {
        var wire = Im_Actor_V1_PlacementOwner(); wire.host = .init(value.host); wire.epoch = value.epoch; return wire
    }
    private static func model(_ value: Im_Actor_V1_PlacementOwner) throws -> V2ActorPlacementOwner {
        try V2HotPB.check(value, value.hasHost && value.epoch > 0)
        return try .init(host: value.host.model(), epoch: value.epoch)
    }
    private static func transfer(_ value: V2ActorPlacementTransfer) -> Im_Actor_V1_PlacementTransfer {
        var wire = Im_Actor_V1_PlacementTransfer(); wire.id = V2HotPB.bytes(value.id)
        wire.successor = .init(value.successor); return wire
    }
}
