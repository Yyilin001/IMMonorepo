import IMV2ActorContracts
import IMV2Core

public extension V2ActorSpecialAccountMessageWire {
    init(_ value: V2TrustedSpecialAccountMessage) {
        self.init(stableAccountKey: value.stableAccountKey,
                  servicePrincipal: value.servicePrincipal, operatorID: value.operatorID,
                  operationID: value.operationID, requestFingerprint: value.requestFingerprint,
                  customerUserID: value.customerUserID, text: value.text, media: value.media,
                  mentions: value.mentions.map(V2ActorMentionTargetWire.init),
                  entities: value.entities, replyTo: value.replyTo)
    }

    func toDomain() throws -> V2TrustedSpecialAccountMessage {
        let value = try V2TrustedSpecialAccountMessage(
            stableAccountKey: stableAccountKey, servicePrincipal: servicePrincipal,
            operatorID: operatorID, operationID: operationID,
            requestFingerprint: requestFingerprint, customerUserID: customerUserID,
            text: text, media: media, mentions: mentions.map { $0.toDomain() },
            entities: entities, replyTo: replyTo)
        guard value.stableAccountKey == stableAccountKey,
              value.servicePrincipal == servicePrincipal,
              value.requestFingerprint == requestFingerprint
        else { throw V2SpecialAccountMessagingError.invalidRequest }
        // The trusted request constructor checks principal metadata; this checks rich content too.
        try V2RichMessageContent.validate(text: text, entities: entities)
        return value
    }
}

public extension V2ActorResolvedSpecialAccountWire {
    init(_ value: V2ResolvedSpecialAccount) {
        self.init(userID: value.userID, stableKey: value.stableKey, kind: value.kind)
    }

    func toDomain() -> V2ResolvedSpecialAccount {
        .init(userID: userID, stableKey: stableKey, kind: kind)
    }
}

public extension V2ActorSpecialAccountAuditWire {
    init(request: V2TrustedSpecialAccountMessage, account: V2ResolvedSpecialAccount,
         roomID: RoomID, outcome: V2SendMessageOutcome) {
        self.init(request: .init(request), account: .init(account), roomID: roomID,
                  outcome: .init(outcome))
    }

    func toDomain() throws -> (request: V2TrustedSpecialAccountMessage,
                               account: V2ResolvedSpecialAccount, roomID: RoomID,
                               outcome: V2SendMessageOutcome) {
        let sendOutcome = try outcome.toDomain()
        let trustedRequest = try request.toDomain()
        guard let receipt = sendOutcome.acceptanceReceipt,
              receipt.roomID == roomID,
              receipt.senderUserID == account.userID,
              receipt.clientMessageID == trustedRequest.operationID,
              account.stableKey == trustedRequest.stableAccountKey else {
            throw V2SpecialAccountMessagingError.invalidRequest
        }
        return (trustedRequest, account.toDomain(), roomID, sendOutcome)
    }
}
