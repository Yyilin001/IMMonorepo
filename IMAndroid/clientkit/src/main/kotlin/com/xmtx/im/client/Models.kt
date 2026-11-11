package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.PersistentSet
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.persistentSetOf
import kotlinx.serialization.Serializable
import java.util.UUID

internal fun canonicalId(value: String): String {
    require(value.matches(Regex("[A-Za-z0-9_.~-]{1,128}"))) { "无效的身份标识" }
    return if (value.matches(Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"))) UUID.fromString(value).toString().uppercase() else value
}
@Serializable @JvmInline value class UserId private constructor(val value: String) {
    init { require(canonicalId(value) == value) }
    companion object { operator fun invoke(value: String) = UserId(canonicalId(value)) }
}
@Serializable @JvmInline value class RoomId private constructor(val value: String) {
    init { require(canonicalId(value) == value) }
    companion object { operator fun invoke(value: String) = RoomId(canonicalId(value)) }
}
@Serializable @JvmInline value class MessageId private constructor(val value: String) {
    init { require(canonicalId(value) == value) }
    companion object { operator fun invoke(value: String) = MessageId(canonicalId(value)) }
}
@Serializable @JvmInline value class DeviceId private constructor(val value: String) {
    init { require(UUID.fromString(value).toString().uppercase() == value) }
    companion object { operator fun invoke(value: String) = DeviceId(canonicalId(value)) }
}

enum class RoomKind { Direct, Group }

/** Each nested element is an immutable value; no mutable collections/arrays escape to UI. */
data class Conversation(val id: RoomId, val title: String, val preview: String = "", val unread: Int = 0,
    val updatedAt: Long = 0, val pinned: Boolean = false, val archived: Boolean = false, val muted: Boolean = false, val historyIncomplete: Boolean = false, val kind: RoomKind = RoomKind.Direct,
    val peer: UserId? = null)
data class Contact(val id: UserId, val name: String, val handle: String)
enum class Delivery { Pending, Accepted, Failed }
data class ForwardAttribution(val message: MessageId, val sender: UserId)
/** Null media or rich content means a legacy projection without sufficient recovery evidence.
 * Accepted room-log position and timeline ordering are separate coordinates. Unknown accepted positions remain zero. */
data class Message(val id: MessageId, val roomId: RoomId, val sender: UserId, val text: String,
    val createdAt: Long, val delivery: Delivery = Delivery.Accepted, val withdrawn: Boolean = false, val revision: Long = 1, val roomSequence: Long = 0, val forwardedFrom: ForwardAttribution? = null, val redacted: Boolean = false, val timelineSequence: Long = roomSequence, val media: MessageMedia? = null, val rich: MessageRichContent? = null)
data class ClientSnapshot(val conversations: PersistentList<Conversation> = persistentListOf(),
    val contacts: PersistentList<Contact> = persistentListOf(), val messages: PersistentList<Message> = persistentListOf(),
    val ownProfile: ProfileView? = null,
    val ownProfileOperations: PersistentList<OwnProfileWork> = persistentListOf(),
    val profileIntents: PersistentList<ProfileIntentStatus> = persistentListOf(),
    val sendIntents: PersistentList<SendIntentStatus> = persistentListOf(),
    val nameOperations: PersistentList<NameWork> = persistentListOf(),
    val nameSnapshots: PersistentList<NameSnapshot> = persistentListOf(),
    val directOperations: PersistentList<DirectRoomWork> = persistentListOf(),
    val localDirectMessages: PersistentList<LocalDirectMessage> = persistentListOf(),
    val relationships: PersistentList<Relationship> = persistentListOf(), val blockedUsers: PersistentList<UserBlock> = persistentListOf(),
    val socialOperations: PersistentList<SocialWork> = persistentListOf(), val socialProposals: PersistentList<SocialProposal> = persistentListOf(),
    val groupCreations: PersistentList<GroupCreationWork> = persistentListOf(),
    val membershipOperations: PersistentList<MembershipWork> = persistentListOf(),
    val moderationOperations: PersistentList<ModerationWork> = persistentListOf(),
    val administrationOperations: PersistentList<AdministrationWork> = persistentListOf(),
    val moderationFacts: PersistentList<MemberMuteFact> = persistentListOf(),
    val readCheckpoints: PersistentList<RoomReadCheckpoint> = persistentListOf(),
    val readOperations: PersistentList<ReadWork> = persistentListOf(),
    val directReads: PersistentList<DirectReadProjection> = persistentListOf(),
    val groupPolicyStates: PersistentList<GroupPolicyState> = persistentListOf(),
    val rolePolicies: PersistentList<RolePolicyEffect> = persistentListOf(),
    val memberAccess: PersistentList<MemberAccessEffect> = persistentListOf(),
    val invitationOperations: PersistentList<InvitationWork> = persistentListOf(),
    val capabilityOperations: PersistentList<GroupCapabilityWork> = persistentListOf(),
    val preferences: PersistentList<PreferenceSnapshot> = persistentListOf(),
    val preferenceOperations: PersistentList<PreferenceWork> = persistentListOf(),
    val personalOperations: PersistentList<PersonalWork> = persistentListOf(),
    val forwardOperations: PersistentList<ForwardWork> = persistentListOf(),
    val reactions: PersistentList<MessageReactionSummary> = persistentListOf(),
    val reactionOperations: PersistentList<ReactionWork> = persistentListOf(),
    val mutationOperations: PersistentList<MessageMutationWork> = persistentListOf(),
    val personalStates: PersistentList<PersonalState> = persistentListOf(),
    val announcements: PersistentList<GroupAnnouncement> = persistentListOf(),
    val pins: PersistentList<GroupPin> = persistentListOf(),
    val revokedRooms: PersistentSet<RoomId> = persistentSetOf(),val presentationGeneration: String = "",val groupAvatarGeneration: String = "",val groupAvatarIntents: PersistentList<GroupAvatarIntent> = persistentListOf(),
    val resourceImports: PersistentList<ResourceImportWork> = persistentListOf())

sealed class ClientFailure(message: String) : Exception(message) {
    class Http(val status: Int, val code: String? = null, val retryAfter: String? = null) : ClientFailure("HTTP $status")
    class Protocol : ClientFailure("服务端协议响应无效")
    class SignedOut : ClientFailure("请先登录")
    class SessionInvalidated : ClientFailure("会话已变更")
    class ResetRequired : ClientFailure("需要完整快照恢复")
    class Storage : ClientFailure("本机受保护存储不可用")
}
