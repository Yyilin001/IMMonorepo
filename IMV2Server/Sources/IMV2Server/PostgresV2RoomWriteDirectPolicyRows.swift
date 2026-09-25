import Foundation
import IMV2Core

// 将持久化私聊策略解码与缓存投影放在私聊接受路径旁，
// 不改变 Store 的事务或缓存更新时间。
struct DirectMessagePolicySnapshotRow: Decodable {
    let recipientUserID: UUID
    let senderProfileVisibleToRecipient: Bool
    let senderCanSend: Bool?
    let recipientIsActive: Bool
    let blocked: Bool
    let isFriend: Bool
    let senderHasReplied: Bool
    let recipientHasReplied: Bool
    let allowsStrangers: Bool
    let senderAccountKind: String?
    let senderAccountStatus: String?
    let senderAllowsServiceMessages: Bool?
    let recipientAccountKind: String?
    let recipientAccountStatus: String?
    let recipientAllowsCustomerMessages: Bool?

    enum CodingKeys: String, CodingKey {
        case recipientUserID = "recipient_user_id"
        case senderProfileVisibleToRecipient = "sender_profile_visible_to_recipient"
        case senderCanSend = "sender_can_send"
        case recipientIsActive = "recipient_is_active"
        case blocked
        case isFriend = "is_friend"
        case senderHasReplied = "sender_has_replied"
        case recipientHasReplied = "recipient_has_replied"
        case allowsStrangers = "allows_strangers"
        case senderAccountKind = "sender_account_kind"
        case senderAccountStatus = "sender_account_status"
        case senderAllowsServiceMessages = "sender_allows_service_messages"
        case recipientAccountKind = "recipient_account_kind"
        case recipientAccountStatus = "recipient_account_status"
        case recipientAllowsCustomerMessages = "recipient_allows_customer_messages"
    }
}

extension DirectMessagePolicySnapshotRow {
    func applyingControlPolicy(_ control: V2DirectSendControlPolicy) -> Self {
        .init(recipientUserID: recipientUserID,
            senderProfileVisibleToRecipient: senderProfileVisibleToRecipient, senderCanSend: senderCanSend,
            recipientIsActive: control.recipient.isActive, blocked: control.blocked, isFriend: control.isFriend,
            senderHasReplied: senderHasReplied, recipientHasReplied: recipientHasReplied,
            allowsStrangers: control.allowsStrangers,
            senderAccountKind: control.sender.specialKind, senderAccountStatus: control.sender.specialStatus,
            senderAllowsServiceMessages: control.sender.allowsServiceMessages,
            recipientAccountKind: control.recipient.specialKind, recipientAccountStatus: control.recipient.specialStatus,
            recipientAllowsCustomerMessages: control.recipient.allowsCustomerMessages)
    }
}

extension V2DirectSendPolicyCache.Entry {
    /// 集合预检已在持有锁的情况下比较过持久配对与策略修订。
    ///
    /// 只有在那道围栏匹配之后，这些缓存派生字段才可被复用于未变更的判定表。
    ///
    /// - Returns: 单聊策略快照行。
    func policySnapshot() -> DirectMessagePolicySnapshotRow {
        .init(
            recipientUserID: recipientID,
            senderProfileVisibleToRecipient: senderProfileVisibleToRecipient,
            senderCanSend: senderCanSend,
            recipientIsActive: recipientIsActive,
            blocked: blocked,
            isFriend: isFriend,
            senderHasReplied: senderHasReplied,
            recipientHasReplied: recipientHasReplied,
            allowsStrangers: allowsStrangers,
            senderAccountKind: senderAccountKind,
            senderAccountStatus: senderAccountStatus,
            senderAllowsServiceMessages: senderAllowsServiceMessages,
            recipientAccountKind: recipientAccountKind,
            recipientAccountStatus: recipientAccountStatus,
            recipientAllowsCustomerMessages: recipientAllowsCustomerMessages
        )
    }

    /// 这两个配对本地的标志会在与首条已接受消息相同的源事务中变为真。
    ///
    /// 因此只在提交之后发布精化值，就不会让一个未提交的资料/能力对后续授权尝试可见。
    /// 持久预检在依赖该提示之前，仍会校验配对与策略修订。
    ///
    /// - Parameters:
    ///   - senderCapabilityInserted: 是否插入了发送方能力投影。
    ///   - recipientProfileInserted: 是否插入了接收方资料投影。
    /// - Returns: 应用提交后投影后的缓存条目。
    func applyingPostAcceptanceProjection(
        senderCapabilityInserted: Bool,
        recipientProfileInserted: Bool
    ) -> Self {
        guard senderCapabilityInserted || recipientProfileInserted else { return self }
        return .init(
            recipientID: recipientID,
            directPairRevision: directPairRevision,
            senderPolicyRevision: senderPolicyRevision,
            recipientPolicyRevision: recipientPolicyRevision,
            senderProfileVisibleToRecipient: senderProfileVisibleToRecipient || recipientProfileInserted,
            senderCanSend: senderCapabilityInserted ? true : senderCanSend,
            senderIsActive: senderIsActive,
            recipientIsActive: recipientIsActive,
            blocked: blocked,
            isFriend: isFriend,
            senderHasReplied: senderHasReplied,
            recipientHasReplied: recipientHasReplied,
            allowsStrangers: allowsStrangers,
            senderAccountKind: senderAccountKind,
            senderAccountStatus: senderAccountStatus,
            senderAllowsServiceMessages: senderAllowsServiceMessages,
            recipientAccountKind: recipientAccountKind,
            recipientAccountStatus: recipientAccountStatus,
            recipientAllowsCustomerMessages: recipientAllowsCustomerMessages
        )
    }
}
