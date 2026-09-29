import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core

/// Immutable control-side facts used to map a locked direct-room policy row.
struct V2RoomWriteDirectPolicyContext: Sendable {
    let controlPolicyScope: [V2DirectSendPolicyCache.Key: V2DirectSendControlPolicy]?
    let controlScopeRoomKinds: [UUID: String]?

    func controlPolicy(roomID: UUID, senderID: UUID, recipientID: UUID? = nil) throws -> V2DirectSendControlPolicy? {
        guard let scope = controlPolicyScope else { return nil }
        if controlScopeRoomKinds?[roomID] == "group" { return nil }
        guard let policy = scope[.init(roomID: roomID, senderID: senderID)],
              policy.sender.userID == senderID,
              recipientID == nil || recipientID == policy.recipient.userID
        else { throw V2RoomWriteStoreError.corruptPersistenceState }
        return policy
    }

    func senderIsActive(_ local: Bool?, roomID: UUID, senderID: UUID) throws -> Bool {
        try controlPolicy(roomID: roomID, senderID: senderID)?.sender.isActive ?? (local == true)
    }

    /// `ScalarMessagePreflight.load` 负责一致的数据库快照与锁；
    /// 这次纯映射刻意保持既有的单聊策略判定表不变。
    ///
    /// - Parameter policy: 单聊策略快照行。
    /// - Returns: 单聊消息接受上下文。
    /// - Throws: 快照字段非法时抛出。
    func directMessageContext(
        from localPolicy: DirectMessagePolicySnapshotRow, roomID: UUID, senderID: UUID
    ) throws -> DirectMessageAcceptanceContext {
        let authority = try controlPolicy(roomID: roomID, senderID: senderID, recipientID: localPolicy.recipientUserID)
        let policy = authority.map { localPolicy.applyingControlPolicy($0) } ?? localPolicy
        let recipientID = policy.recipientUserID
        let restriction: V2DirectMessageDenied.Reason?
        if policy.senderAccountKind != nil {
            restriction = policy.senderAccountStatus == "active" && policy.senderAllowsServiceMessages == true ? nil : .generic
            // 特殊主体没有公共网关凭据；到达此分支的调用来自可信服务边界。
        } else if let recipientAccountKind = policy.recipientAccountKind {
            if policy.recipientAccountStatus != "active" {
                restriction = .generic
            } else if recipientAccountKind == "system" {
                restriction = .systemAccountReadOnly
            } else {
                restriction = policy.recipientAllowsCustomerMessages == true ? nil : .generic
            }
        } else if !policy.recipientIsActive || policy.blocked {
            restriction = .generic
        } else if policy.isFriend || policy.recipientHasReplied {
            restriction = nil
        } else {
            restriction = policy.allowsStrangers ? nil : .generic
        }
        return .init(
            recipientID: recipientID,
            restriction: restriction,
            requiresStrangerQuota: policy.senderAccountKind == nil && policy.recipientAccountKind == nil && !policy.isFriend && !policy.recipientHasReplied,
            senderProfileVisibleToRecipient: policy.senderProfileVisibleToRecipient,
            senderCanSend: policy.senderCanSend,
            senderHasReplied: policy.senderHasReplied,
            supportAccountID: policy.recipientAccountKind == "customer_support" && policy.recipientAccountStatus == "active"
                ? recipientID
                : nil
        )
    }

}
