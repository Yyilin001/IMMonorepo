import Foundation
import IMV2ServerContracts

/// Message writes carry one runtime-minted policy execution for their activation.
struct V2RoomWriteControlResolution: Sendable {
    private let execution: V2RoomPolicyExecution?

    static var unresolved: Self { .init(execution: nil) }
    var needsPreparation: Bool { execution == nil }
    var roomKinds: [UUID: String]? {
        guard let execution else { return nil }
        return [execution.activation.roomID.uuidValue!: execution.snapshot.roomKind]
    }
    var policies: [V2DirectSendPolicyCache.Key: V2DirectSendControlPolicy]? {
        guard let execution else { return nil }
        guard let policy = execution.snapshot.policy else { return [:] }
        return [.init(roomID: execution.activation.roomID.uuidValue!, senderID: policy.sender.userID): policy]
    }
    var policyExecution: V2RoomPolicyExecution? { execution }
    static func executing(_ execution: V2RoomPolicyExecution) -> Self { .init(execution: execution) }
}
