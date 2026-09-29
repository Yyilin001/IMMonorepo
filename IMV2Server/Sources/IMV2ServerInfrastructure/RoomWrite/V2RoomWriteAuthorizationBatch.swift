import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core

/// Validated grants and their recording time are one indivisible transaction input.
struct V2RoomWriteAuthorizationBatch: Sendable {
    let grants: [String: V2DirectAuthorizationGrant]
    let recordedAt: Date
    let policies: [V2DirectSendPolicyCache.Key: V2DirectSendControlPolicy]
    let roomKinds: [UUID: String]

    init(_ grants: [V2DirectAuthorizationGrant], now: Date, roomKinds: [UUID: String]) throws {
        guard !grants.isEmpty, grants.count <= 128, v2PostgresTimestampCanEncode(now) else {
            throw V2DirectAuthorizationIntentError.invalidRequest
        }
        var attempts: [String: V2DirectAuthorizationGrant] = [:]
        var policies: [V2DirectSendPolicyCache.Key: V2DirectSendControlPolicy] = [:]
        var kinds = roomKinds
        for grant in grants {
            let attempt = grant.attempt
            try attempt.validate()
            guard grant.policy.sender.userID == attempt.senderID,
                  grant.policy.recipient.userID == attempt.recipientID else {
                throw V2DirectAuthorizationIntentError.identityConflict
            }
            let key = Self.operationKey(roomID: attempt.roomID, senderID: attempt.senderID, clientMessageID: attempt.clientMessageID)
            guard attempts.updateValue(grant, forKey: key) == nil else { throw V2DirectAuthorizationIntentError.invalidRequest }
            let cacheKey = V2DirectSendPolicyCache.Key(roomID: attempt.roomID, senderID: attempt.senderID)
            if let existing = policies[cacheKey], existing != grant.policy { throw V2DirectAuthorizationIntentError.identityConflict }
            policies[cacheKey] = grant.policy
            kinds[attempt.roomID] = "direct"
        }
        self.grants = attempts
        self.recordedAt = now
        self.policies = policies
        self.roomKinds = kinds
    }

    static func operationKey(roomID: UUID, senderID: UUID, clientMessageID: UUID) -> String {
        [roomID, senderID, clientMessageID].map { $0.uuidString.lowercased() }.joined(separator: ":")
    }

    func finishReceipts(in transaction: any Database) async throws {
        for key in grants.keys.sorted() {
            guard let grant = grants[key] else { throw V2DirectAuthorizationIntentError.corruptPersistence }
            _ = try await PostgresV2DirectAuthorizationReceiptStore().finishIfPresent(
                grant.attempt, now: recordedAt, transaction: transaction)
        }
    }
}
