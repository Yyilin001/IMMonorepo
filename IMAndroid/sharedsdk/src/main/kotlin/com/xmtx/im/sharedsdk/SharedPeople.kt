package com.xmtx.im.sharedsdk

import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.toPersistentList
import org.json.JSONArray
import org.json.JSONObject

data class SharedProfile(val userID: String, val name: String, val handle: String, val alias: String?, val aliasRevision: Long?, val expiresAtElapsed: Long, val avatar: String?) {
    override fun toString() = "SharedProfile(<private>)"
}
data class SharedInvite(val id: String, val url: String, val expires: Long, val used: Int, val maximum: Int) {
    override fun toString() = "SharedInvite(<redacted>)"
}
data class SharedJoinRequest(val id: String, val userID: String, val note: String, val state: String)
data class SharedInvitePreview(val roomID: String, val title: String, val requestID: String?, val state: String?, val member: Boolean, val canSubmit: Boolean, val canCancel: Boolean)
data class SharedCommunity(val roomID: String?, val invites: PersistentList<SharedInvite>, val requests: PersistentList<SharedJoinRequest>, val hasMore: Boolean, val preview: SharedInvitePreview?, val failure: SharedError?)
enum class SharedInviteAction(val wire: String) { Create("create"), Revoke("revoke"), Submit("submit"), Cancel("cancel"), Approve("approve"), Reject("reject") }
private fun JSONObject.optional(key: String) = optString(key).takeIf(String::isNotEmpty)
private fun <T> JSONArray.rows(transform: (JSONObject) -> T) = (0 until length()).map { transform(getJSONObject(it)) }.toPersistentList()
internal fun decodeProfiles(value: JSONArray, startedAt: Long) = value.rows {
    SharedProfile(it.getString("userID"), it.getString("name"), it.getString("handle"), it.optional("alias"), if (it.has("aliasRevision")) it.getLong("aliasRevision") else null,
        startedAt + it.getLong("remainingMilliseconds"), it.optional("avatar"))
}
internal fun decodeCommunity(value: JSONObject) = SharedCommunity(value.optional("roomID"), value.getJSONArray("invites").rows {
    SharedInvite(it.getString("id"), it.getString("url"), it.getLong("expires"), it.getInt("used"), it.getInt("maximum"))
}, value.getJSONArray("requests").rows { SharedJoinRequest(it.getString("id"), it.getString("userID"), it.getString("note"), it.getString("state")) }, value.getBoolean("hasMore"),
    value.optJSONObject("preview")?.let { SharedInvitePreview(it.getString("roomID"), it.getString("title"), it.optional("requestID"), it.optional("state"), it.getBoolean("member"), it.getBoolean("canSubmit"), it.getBoolean("canCancel")) },
    value.optional("failure")?.let { raw -> SharedError.entries.firstOrNull { it.name.equals(raw, true) } ?: SharedError.OperationFailed })

data class SharedAvatarEditor(val roomID: String?, val revision: Long, val canManage: Boolean, val expiresAtElapsed: Long,
    val image: String?, val hasAvatar: Boolean, val works: PersistentList<SharedWork>, val failure: SharedError?) {
    override fun toString() = "SharedAvatarEditor(<private>)"
}
internal fun decodeAvatarEditor(value: JSONObject, startedAt: Long) = SharedAvatarEditor(value.optional("roomID"), value.getLong("revision"),
    value.getBoolean("canManage"), startedAt + value.getLong("remainingMilliseconds"), value.optional("image"), value.getBoolean("hasAvatar"),
    value.getJSONArray("works").rows { SharedWork(it.getString("id"), it.getString("kind"), it.getString("target"), it.getString("status"), it.getBoolean("retryable"), it.optional("roomID")) },
    value.optional("failure")?.let { SharedError.OperationFailed })

enum class SharedAvatarAction(val wire: String) { Retry("retry"), Reapply("reapply"), Query("query"), Cancel("cancel"), CloseIfAbsent("close"), Discard("discard") }
