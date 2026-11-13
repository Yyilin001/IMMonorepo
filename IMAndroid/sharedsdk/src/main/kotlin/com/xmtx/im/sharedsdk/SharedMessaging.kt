package com.xmtx.im.sharedsdk

import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.toPersistentList
import org.json.JSONObject

data class SharedSearchHit(val id: String, val roomID: String, val text: String)
data class SharedSearch(val query: String, val roomID: String?, val status: String, val hits: PersistentList<SharedSearchHit>, val hasNext: Boolean)
data class SharedMessageWork(val id: String, val messageID: String, val kind: String, val text: String?, val status: String, val retryable: Boolean)
data class SharedReaders(val roomID: String, val messageID: String, val users: PersistentList<String>, val hasNext: Boolean, val expiresAtElapsed: Long)
data class SharedMessagingView(val roomID: String?, val isGroup: Boolean, val allowsReadReceipts: Boolean, val ownReadSequence: Long,
    val mutations: PersistentList<SharedMessageWork>, val readStatus: String?, val canRetryRead: Boolean, val search: SharedSearch?, val readers: SharedReaders?, val interactions: SharedInteractionView, val failure: String?)
internal fun decodeMessaging(value: JSONObject, startedAt: Long): SharedMessagingView {
    fun JSONObject.optional(key: String) = optString(key).takeIf { has(key) && !isNull(key) }
    val mutations = value.getJSONArray("mutations")
    return SharedMessagingView(value.optional("roomID"), value.getBoolean("isGroup"), value.getBoolean("allowsReadReceipts"), value.getLong("ownReadSequence"),
        (0 until mutations.length()).map { mutations.getJSONObject(it).let { row -> SharedMessageWork(row.getString("id"),row.getString("messageID"),row.getString("kind"),row.optional("text"),row.getString("status"),row.getBoolean("retryable")) } }.toPersistentList(),
        value.optional("readStatus"), value.getBoolean("canRetryRead"), value.optJSONObject("search")?.let { search ->
            val hits = search.getJSONArray("hits")
            SharedSearch(search.getString("query"),search.optional("roomID"),search.getString("status"),(0 until hits.length()).map { hits.getJSONObject(it).let { row -> SharedSearchHit(row.getString("id"),row.getString("roomID"),row.getString("text")) } }.toPersistentList(),search.getBoolean("hasNext"))
        }, value.optJSONObject("readers")?.let { readers ->
            val users = readers.getJSONArray("users")
            SharedReaders(readers.getString("roomID"),readers.getString("messageID"),(0 until users.length()).map(users::getString).toPersistentList(),readers.getBoolean("hasNext"),startedAt + readers.getLong("remainingMilliseconds"))
        },decodeInteractions(value.getJSONObject("interactions")),value.optional("failure"))
}
