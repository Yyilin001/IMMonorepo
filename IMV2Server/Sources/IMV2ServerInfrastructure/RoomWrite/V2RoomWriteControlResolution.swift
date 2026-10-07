import Foundation
import IMV2ServerContracts

/// A control reservation is either pending or fully prepared, including the
/// valid prepared result with no direct-room grants.
struct V2RoomWriteControlResolution: Sendable {
    private enum State: Sendable {
        case unresolved
        case prepared(roomKinds: [UUID: String],
                      policies: [V2DirectSendPolicyCache.Key: V2DirectSendControlPolicy],
                      authorization: V2RoomWriteAuthorizationBatch?)
        case leased(V2RoomPolicyExecution)
    }

    private let state: State

    private init(_ state: State) { self.state = state }

    static var unresolved: Self { .init(.unresolved) }

    var needsPreparation: Bool {
        if case .unresolved = state { return true }
        return false
    }

    var roomKinds: [UUID: String]? {
        if case .leased(let execution) = state { return [execution.activation.roomID.uuidValue!: execution.snapshot.roomKind] }
        if case .prepared(let kinds, _, _) = state { return kinds }
        return nil
    }

    var policies: [V2DirectSendPolicyCache.Key: V2DirectSendControlPolicy]? {
        if case .leased(let execution) = state {
            guard let policy = execution.snapshot.policy else { return [:] }
            return [.init(roomID: execution.activation.roomID.uuidValue!, senderID: policy.sender.userID): policy]
        }
        if case .prepared(_, let policies, _) = state { return policies }
        return nil
    }

    var authorization: V2RoomWriteAuthorizationBatch? {
        if case .prepared(_, _, let authorization) = state { return authorization }
        return nil
    }

    var policyExecution: V2RoomPolicyExecution? {
        if case .leased(let execution) = state { return execution }
        return nil
    }

    static func leased(_ execution: V2RoomPolicyExecution) -> Self { .init(.leased(execution)) }

    static func preparedWithoutGrants(roomKinds: [UUID: String]) -> Self {
        .init(.prepared(roomKinds: roomKinds, policies: [:], authorization: nil))
    }

    func authorizing(_ grants: [V2DirectAuthorizationGrant], now: Date) throws -> Self {
        let batch = try V2RoomWriteAuthorizationBatch(grants, now: now, roomKinds: roomKinds ?? [:])
        return .init(.prepared(roomKinds: batch.roomKinds, policies: batch.policies, authorization: batch))
    }
}
