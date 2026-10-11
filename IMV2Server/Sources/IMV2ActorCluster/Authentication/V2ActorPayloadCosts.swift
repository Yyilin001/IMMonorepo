import IMV2ActorContracts

private typealias Cost = V2ActorPayloadBudget
extension V2ActorAuthenticatedCall: V2ActorBudgetedPayload {
    package var actorRetainedBytes: Int {
        let principalCost: Int
        switch principal { case .user(let user): principalCost = Cost.textBytes(user.rawValue); case .service: principalCost = 32 }
        return Cost.sum(384, Cost.textBytes(serviceID.rawValue), Cost.textBytes(recipient.hostID.rawValue),
            principalCost, request.actorRetainedBytes)
    }
}
extension V2ActorAuthenticatedReply: V2ActorBudgetedPayload {
    package var actorRetainedBytes: Int { Cost.sum(224, Cost.textBytes(host.hostID.rawValue), response.actorRetainedBytes) }
}
extension V2ActorRPCRequest: V2ActorBudgetedPayload {
    package var actorRetainedBytes: Int {
        switch self {
        case .invoke(let token, let request): Cost.sum(64, token.actorRetainedBytes, request.actorRetainedBytes)
        case .lookup(let token): Cost.sum(32, token.actorRetainedBytes)
        default: Cost.reflectedBytes(of: self)
        }
    }
}
extension V2ActorRPCResponse: V2ActorBudgetedPayload {
    package var actorRetainedBytes: Int {
        switch self {
        case .result(let response): Cost.sum(32, response.actorRetainedBytes)
        case .ready(let token, let reference): Cost.sum(64, token.actorRetainedBytes, Cost.dataBytes(reference))
        case .acknowledged, .completed: 64
        default: Cost.reflectedBytes(of: self)
        }
    }
}
