package com.xmtx.im.sharedsdk

import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.toPersistentList
import org.json.JSONArray
import org.json.JSONObject

enum class SharedContactScope(val wire: String) { Accepted("accepted"), Incoming("incoming"), Outgoing("outgoing"), Blocked("blocked") }
enum class SharedSocialAction(val wire: String) { Request("request"), Accept("accept"), Reject("reject"), Remove("remove"), Block("block"), Unblock("unblock") }
enum class SharedGroupAction(val wire: String) { Add("add"), Remove("remove"), Leave("leave"), Announcement("announcement"), Role("role"), Transfer("transfer"), Dissolve("dissolve"), Permissions("permissions") }
enum class SharedRole(val wire: String) { Owner("owner"), Admin("admin"), Member("member") }
enum class SharedPermission(val wire: String, val label: String) {
    SendMessages("send_messages", "发送消息"), InviteMembers("invite_members", "添加成员"), RemoveMembers("remove_members", "移除成员"),
    ChangeMemberRoles("change_member_roles", "设置角色"), PinMessages("pin_messages", "置顶消息"), ManageAnnouncements("manage_announcements", "管理公告"),
    ModerateMessages("moderate_messages", "管理消息"), MuteMembers("mute_members", "管理禁言")
}
data class SharedContact(val userID: String, val state: String)
data class SharedIdentity(val userID: String, val handle: String, val name: String)
data class SharedWork(val id: String, val kind: String, val target: String, val status: String, val retryable: Boolean, val roomID: String?)
data class SharedMember(val userID: String, val role: SharedRole)
data class SharedRolePolicy(val role: SharedRole, val permissions: PersistentList<SharedPermission>, val revision: Long)
data class SharedGroup(val roomID: String, val actorRole: SharedRole, val revision: Long, val members: PersistentList<SharedMember>, val hasMore: Boolean,
    val announcement: String, val announcementRevision: Long, val policies: PersistentList<SharedRolePolicy>, val permissions: PersistentList<SharedPermission>, val policiesReady: Boolean)
data class SharedDirectory(val contacts: PersistentList<SharedContact>, val scope: SharedContactScope, val hasMoreContacts: Boolean, val firstContacts: Boolean,
    val groups: PersistentList<SharedConversation>, val hasMoreGroups: Boolean, val firstGroups: Boolean, val identity: SharedIdentity?, val group: SharedGroup?, val works: PersistentList<SharedWork>, val failure: SharedError?, val profiles: PersistentList<SharedProfile>, val selectedProfile: String?, val community: SharedCommunity?, val avatarEditor: SharedAvatarEditor?)

private fun <T> JSONArray.rows(transform: (JSONObject) -> T): PersistentList<T> = (0 until length()).map { transform(getJSONObject(it)) }.toPersistentList()
private fun role(value: String) = SharedRole.entries.first { it.wire == value }
private fun permissions(value: JSONArray) = (0 until value.length()).map { index -> SharedPermission.entries.first { it.wire == value.getString(index) } }.toPersistentList()
internal fun decodeDirectory(value: JSONObject, startedAt: Long): SharedDirectory = SharedDirectory(
    value.getJSONArray("contacts").rows { SharedContact(it.getString("userID"), it.getString("state")) },
    SharedContactScope.entries.first { it.wire == value.getString("scope") }, value.getBoolean("hasMoreContacts"), value.getBoolean("firstContacts"),
    value.getJSONArray("groups").rows { SharedConversation(it.getString("id"), it.getString("title"), it.getString("preview")) },
    value.getBoolean("hasMoreGroups"), value.getBoolean("firstGroups"),
    value.optJSONObject("identity")?.let { SharedIdentity(it.getString("userID"), it.getString("handle"), it.getString("name")) },
    value.optJSONObject("group")?.let { group -> SharedGroup(group.getString("roomID"), role(group.getString("actorRole")), group.getLong("revision"),
        group.getJSONArray("members").rows { SharedMember(it.getString("userID"), role(it.getString("role"))) }, group.getBoolean("hasMore"),
        group.getString("announcement"), group.getLong("announcementRevision"), group.getJSONArray("policies").rows {
            SharedRolePolicy(role(it.getString("role")), permissions(it.getJSONArray("permissions")), it.getLong("revision"))
        }, permissions(group.getJSONArray("permissions")), group.getBoolean("policiesReady")) },
    value.getJSONArray("works").rows { SharedWork(it.getString("id"), it.getString("kind"), it.getString("target"), it.getString("status"), it.getBoolean("retryable"), it.optString("roomID").takeIf(String::isNotEmpty)) },
    value.optString("failure").takeIf(String::isNotEmpty)?.let(::decodeSharedError),
    decodeProfiles(value.getJSONArray("profiles"), startedAt), value.optString("selectedProfile").takeIf(String::isNotEmpty), value.optJSONObject("community")?.let(::decodeCommunity), value.optJSONObject("avatarEditor")?.let { decodeAvatarEditor(it, startedAt) })
