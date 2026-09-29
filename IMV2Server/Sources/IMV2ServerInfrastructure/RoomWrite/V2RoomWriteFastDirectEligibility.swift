import IMV2ServerContracts

/// Pure shape and snapshot predicates shared by batch routing, cache updates,
/// scalar acceptance, and the borrowed-connection fast append path.
enum V2RoomWriteFastDirectEligibility {
    static func acceptsBatchShape(_ request: V2RoomWriteRequest) -> Bool {
        let command = request.command
        return command.media.isEmpty
            && command.mentions.isEmpty
            && command.replyTo == nil
            && command.forwardedFrom == nil
    }

    static func isCacheCandidate(_ policy: V2DirectSendPolicyCache.Entry) -> Bool {
        policy.senderIsActive
            && policy.senderProfileVisibleToRecipient
            && policy.senderCanSend == true
            && policy.recipientIsActive
            && !policy.blocked
            && policy.senderAccountKind == nil
            && policy.recipientAccountKind == nil
    }

    static func acceptsSnapshot(_ policy: V2DirectSendPolicyCache.Entry) -> Bool {
        isCacheCandidate(policy)
            && policy.senderHasReplied
            && (policy.isFriend || policy.recipientHasReplied || policy.allowsStrangers)
    }
}
