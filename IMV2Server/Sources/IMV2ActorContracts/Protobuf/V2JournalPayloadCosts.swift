import IMV2Core

// Conservative retained-model costs. These are not protobuf byte lengths;
// the transport still enforces the actual encoded packet limit.
private typealias Cost = V2ActorPayloadBudget

extension V2RealtimeJournalRoomAuthorization: V2ActorBudgetedPayload {
    package var actorRetainedBytes: Int {
        Cost.sum(320, Cost.textBytes(roomID.rawValue),
            viewerMembershipRevisions.reduce(64) { Cost.sum($0, 192, Cost.textBytes($1.key.rawValue)) })
    }
}
extension V2RealtimeJournalProjectionChange: V2ActorBudgetedPayload {
    package var actorRetainedBytes: Int {
        switch self {
        case .authorization(let value): Cost.sum(64, value.actorRetainedBytes)
        case .head(let room, _, _, _): Cost.sum(288, Cost.textBytes(room.rawValue))
        case .invalidate(let room): Cost.sum(192, Cost.textBytes(room.rawValue))
        case .controlInvalidation(let room, _, _): Cost.sum(256, Cost.textBytes(room.rawValue))
        case .userControlInvalidation(let user, _, _, let room):
            Cost.sum(320, Cost.textBytes(user.rawValue), room.map { Cost.sum(96, Cost.textBytes($0.rawValue)) } ?? 0)
        }
    }
}
extension V2RealtimeJournalProjectionEntry: V2ActorBudgetedPayload {
    package var actorRetainedBytes: Int { Cost.sum(64, change.actorRetainedBytes) }
}
extension V2RealtimeJournalRoomHead: V2ActorBudgetedPayload {
    package var actorRetainedBytes: Int { Cost.sum(256, Cost.textBytes(roomID.rawValue)) }
}
