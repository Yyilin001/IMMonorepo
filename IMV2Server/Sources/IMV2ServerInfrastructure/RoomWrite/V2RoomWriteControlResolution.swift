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
    }

    private let state: State

    private init(_ state: State) { self.state = state }

    static var unresolved: Self { .init(.unresolved) }

    var needsPreparation: Bool {
        if case .unresolved = state { return true }
        return false
    }

    var roomKinds: [UUID: String]? {
        if case .prepared(let kinds, _, _) = state { return kinds }
        return nil
    }

    var policies: [V2DirectSendPolicyCache.Key: V2DirectSendControlPolicy]? {
        if case .prepared(_, let policies, _) = state { return policies }
        return nil
    }

    var authorization: V2RoomWriteAuthorizationBatch? {
        if case .prepared(_, _, let authorization) = state { return authorization }
        return nil
    }

    static func preparedWithoutGrants(roomKinds: [UUID: String]) -> Self {
        .init(.prepared(roomKinds: roomKinds, policies: [:], authorization: nil))
    }

    func authorizing(_ grants: [V2DirectAuthorizationGrant], now: Date) throws -> Self {
        let batch = try V2RoomWriteAuthorizationBatch(grants, now: now, roomKinds: roomKinds ?? [:])
        return .init(.prepared(roomKinds: batch.roomKinds, policies: batch.policies, authorization: batch))
    }
}
