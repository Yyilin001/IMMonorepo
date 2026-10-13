import Foundation
import IMV2Core

// Fixed layout plus conservative string/data/collection allocation costs.
// Keep these explicit hot-model costs in step with their stored fields.
private typealias Cost = V2ActorPayloadBudget
extension V2RoomActivationToken: V2ActorBudgetedPayload {
    package var actorRetainedBytes: Int {
        Cost.sum(192, Cost.textBytes(roomID.rawValue), Cost.textBytes(owner.shardID), Cost.textBytes(host.hostID.rawValue))
    }
}
extension V2RoomSubscriptionFence: V2ActorBudgetedPayload {
    package var actorRetainedBytes: Int { Cost.sum(96, activation.actorRetainedBytes) }
}
extension V2GatewayRealtimeDescriptor: V2ActorBudgetedPayload {
    package var actorRetainedBytes: Int {
        Cost.sum(192, Cost.textBytes(identity.nodeID), Cost.textBytes(identity.serviceID),
            Cost.textBytes(address), Cost.dataBytes(endpointReference))
    }
}
extension V2ActorRoomLogPullWire: V2ActorBudgetedPayload {
    package var actorRetainedBytes: Int { Cost.sum(128, Cost.textBytes(roomID.rawValue), Cost.textBytes(actorUserID.rawValue)) }
}
extension V2RoomRequest: V2ActorBudgetedPayload {
    package var actorRetainedBytes: Int {
        switch self {
        case .messaging(.sendOperation(let command)): Cost.sum(64, command.estimatedRetainedBytes)
        case .roomLog(.pull(let command)): Cost.sum(64, command.actorRetainedBytes)
        default: Cost.reflectedBytes(of: self)
        }
    }
}
extension V2OperationIdentity: V2ActorBudgetedPayload {
    package var actorRetainedBytes: Int {
        var cost = Cost.sum(128, Cost.textBytes(accountID.rawValue), Cost.textBytes(operation.rawOperationID))
        switch scope {
        case .account(let user): cost = Cost.sum(cost, Cost.textBytes(user.rawValue))
        case .room(let room): cost = Cost.sum(cost, Cost.textBytes(room.rawValue))
        case .userPair(let a, let b): cost = Cost.sum(cost, Cost.textBytes(a.rawValue), Cost.textBytes(b.rawValue))
        case .message(let room, let message): cost = Cost.sum(cost, Cost.textBytes(room.rawValue), Cost.textBytes(message.rawValue))
        case .device(let user, let device): cost = Cost.sum(cost, Cost.textBytes(user.rawValue), Cost.textBytes(device.rawValue))
        }
        return cost
    }
}
extension V2MessageSendOperationReceipt: V2ActorBudgetedPayload {
    package var actorRetainedBytes: Int {
        let acceptance: Int
        switch outcome {
        case .accepted(let result): acceptance = Cost.sum(64, Cost.textBytes(result.messageID.rawValue))
        case .rejected: acceptance = 64
        }
        return Cost.sum(128, identity.actorRetainedBytes, Cost.dataBytes(fingerprint.digest), acceptance)
    }
}
extension V2MessageSendOperationRecoveryResult: V2ActorBudgetedPayload {
    package var actorRetainedBytes: Int {
        switch self {
        case .receipt(let receipt): Cost.sum(32, receipt.actorRetainedBytes)
        case .deferred(let hint): Cost.sum(128, hint.identity.actorRetainedBytes, Cost.dataBytes(hint.fingerprint.digest))
        case .unresolved, .fingerprintConflict: 128
        }
    }
}
extension V2RoomResponse: V2ActorBudgetedPayload {
    package var actorRetainedBytes: Int {
        switch self {
        case .messaging(.sendOperation(let result)): Cost.sum(64, result.actorRetainedBytes)
        case .roomLog(.page(let page)): Cost.sum(64, page.actorRetainedBytes)
        default: Cost.reflectedBytes(of: self)
        }
    }
}
extension V2RealtimeRoomEvent: V2ActorBudgetedPayload {
    package var actorRetainedBytes: Int {
        var cost = Cost.sum(256, Cost.textBytes(roomID.rawValue), Cost.textBytes(sourceEventID.rawValue),
            Cost.textBytes(projectionKind), Cost.dataBytes(payload))
        for user in recipientUserIDs { cost = Cost.sum(cost, 64, Cost.textBytes(user.rawValue)) }
        return cost
    }
}
private func memberCost(_ members: [V2RoomSubscriptionMember]) -> Int {
    members.reduce(64) { Cost.sum($0, 32, Cost.textBytes($1.userID.rawValue)) }
}
extension V2RoomSubscriptionDelivery: V2ActorBudgetedPayload {
    package var actorRetainedBytes: Int {
        let body: Int
        switch payload {
        case .baseline(let members), .baselinePage(_, _, let members): body = Cost.sum(64, memberCost(members))
        case .grant(let member, _): body = Cost.sum(64, Cost.textBytes(member.userID.rawValue))
        case .broadcast(let event): body = event.actorRetainedBytes
        case .event(let event, let members): body = Cost.sum(event.actorRetainedBytes, memberCost(members))
        case .head, .authorizationInvalidated: body = 64
        case .revoke(let user, _): body = Cost.sum(64, Cost.textBytes(user.rawValue))
        }
        return Cost.sum(128, fence.actorRetainedBytes, body)
    }
}
extension V2RoomSubscriptionDeliveryBatch: V2ActorBudgetedPayload {
    package var actorRetainedBytes: Int { deliveries.reduce(64) { Cost.sum($0, $1.actorRetainedBytes) } }
}
extension V2ActorRoomLogPageWire: V2ActorBudgetedPayload {
    package var actorRetainedBytes: Int {
        events.reduce(Cost.sum(192, Cost.textBytes(roomID.rawValue))) {
            Cost.sum($0, 128, Cost.textBytes($1.sourceEventID.rawValue), Cost.textBytes($1.projectionKind), Cost.dataBytes($1.payload))
        }
    }
}
