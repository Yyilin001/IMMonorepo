package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.*
import java.net.URI
import java.net.URLDecoder

/** Read-only authorized presentation; all lists and invitation bearer links remain ephemeral. */
data class InvitationLink(val invite: String, val room: RoomId, val title: String, val secret: InvitationSecret,
    val state: String, val expiresAt: Long, val maximumUses: Int, val approvedUses: Int, val createdAt: Long)
data class InvitationPreview(val invite: String, val room: RoomId, val title: String, val expiresAt: Long,
    val requestState: String?, val request: String?, val alreadyMember: Boolean)
data class GroupJoinRequest(val request: String, val invite: String, val room: RoomId, val applicant: UserId,
    val note: String?, val state: String, val resumableOperation: String?, val createdAt: Long, val decidedAt: Long?)
/** Request facts are not a profile grant; applicant presentation requires this complete review context. */
val GroupJoinRequest.presentationKey: ProfileKey get() = ProfileKey(applicant,ProfileContext.GroupJoinReview(room))

data class GroupJoinRequestPage(val requests: PersistentList<GroupJoinRequest>, val cursor: String?)
fun invitationURL(secret: InvitationSecret): String = "iim://group-invite?token=${secret.rawValue}"
fun invitationSecret(value: String): InvitationSecret {
    val trimmed = invitationTrim(value)
    if(trimmed.matches(Regex("[A-Za-z0-9_-]{43}"))) return InvitationSecret(trimmed)
    val url = URI(trimmed); require(url.scheme.equals("iim", true) && url.host == "group-invite")
    val token = url.rawQuery?.split('&')?.map { it.split('=', limit = 2) }?.firstOrNull { URLDecoder.decode(it.first(), "UTF-8") == "token" }?.getOrNull(1)
    return InvitationSecret(URLDecoder.decode(requireNotNull(token), "UTF-8"))
}
class InvitationDirectory(private val api: AuthenticatedTransport) {
    suspend fun links(room: RoomId): PersistentList<InvitationLink> = withTimeout(15000) {
        val value = checked(api.request("/v2/group-invites", query = "room_id" to room.value, maximumBytes = 1048576))
        value.getValue("items").jsonArray.map { item ->
            val v = item.jsonObject; val title = title(v); val id = uuidId(v.string("invite_id")); val target = RoomId(uuidId(v.string("room_id")))
            val state = v.string("state"); val max = v.number("maximum_approved_uses"); val used = v.number("approved_use_count")
            val created = v.number("created_at_ms"); val expires = v.number("expires_at_ms")
            require(target == room && state in setOf("active","revoked","expired","exhausted") && max in 1..Int.MAX_VALUE && used in 0..max && created > 0 && expires > created)
            InvitationLink(id, target, title, InvitationSecret(v.string("token")), state, expires, max.toInt(), used.toInt(), created)
        }.toPersistentList().also { require(it.map { link -> link.invite }.distinct().size == it.size) }
    }
    suspend fun preview(secret: InvitationSecret): InvitationPreview = withTimeout(15000) {
        val v = checked(api.request("/v2/group-invites/preview", buildJsonObject { put("token", secret.rawValue) }, maximumBytes = 1048576))
        val state = v.optionalText("request_state"); val request = v.optionalText("request_id")?.let(::uuidId)
        require((state == null) == (request == null) && (state == null || state in states))
        require(v.number("expires_at_ms") > 0)
        InvitationPreview(uuidId(v.string("invite_id")), RoomId(uuidId(v.string("room_id"))), title(v), v.number("expires_at_ms"), state, request, v.getValue("is_already_member").jsonPrimitive.boolean)
    }
    suspend fun requests(room: RoomId, cursor: String? = null, pageSize: Int = 50): GroupJoinRequestPage = withTimeout(15000) {
        require(pageSize in 1..100 && (cursor == null || cursor.isNotEmpty() && cursor.toByteArray().size <= 1024))
        val query = buildMap { put("room_id", room.value); put("page_size", pageSize.toString()); cursor?.let { put("cursor", it) } }
        val value = checked(api.requestWithQuery("/v2/group-join-requests", query, 1048576))
        val next = value.optionalText("next_cursor"); require(next == null || next.isNotEmpty() && next != cursor && next.toByteArray().size <= 1024)
        val items = value.getValue("items").jsonArray.map { item ->
            val v = item.jsonObject; val state = v.string("state"); val target = RoomId(uuidId(v.string("room_id"))); val resume = v.optionalText("resumable_decision_operation_id")?.let(::uuidId)
            val decided = v["decided_at_ms"]?.takeUnless { it is JsonNull }?.jsonPrimitive?.long
            require(target == room && state == "pending" && resume == null && decided == null && v.number("created_at_ms") > 0)
            GroupJoinRequest(uuidId(v.string("request_id")), uuidId(v.string("invite_id")), target, UserId(uuidId(v.string("applicant_user_id"))),
                invitationNote(v.optionalText("note")), state, resume, v.number("created_at_ms"), decided)
        }.toPersistentList()
        require(items.size <= pageSize && items.map { it.request }.distinct().size == items.size)
        GroupJoinRequestPage(items, next)
    }
    private fun checked(value: EdgeResponse): JsonObject { if(value.status != 200) throw value.failure(); return value.body }
    private fun title(value: JsonObject) = invitationTrim(value.string("room_title")).also { require(it.isNotEmpty() && it.toByteArray().size <= 120) }
    private fun JsonObject.optionalText(key: String) = get(key)?.takeUnless { it is JsonNull }?.jsonPrimitive?.content
    private val states = setOf("pending","approving","approved","cancelled","rejected")
}
