package com.xmtx.im.sharedsdk

import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.toPersistentList
import org.json.JSONObject

data class SharedReaction(val value: String, val count: Int, val includesMe: Boolean)
data class SharedReactionWork(val id: String, val messageID: String, val reaction: String, val present: Boolean, val status: String, val retryable: Boolean)
data class SharedForwardWork(val id: String, val status: String, val succeeded: Int, val rejected: Int, val cancelled: Int, val unresolved: Int, val retryable: Boolean, val cancellable: Boolean)
data class SharedInteractionView(val reactions: PersistentList<SharedReactionWork>, val forwards: PersistentList<SharedForwardWork>, val failure: String?)
internal fun decodeReactions(value: JSONObject): PersistentList<SharedReaction> = value.getJSONArray("reactions").let { rows ->
    (0 until rows.length()).map { rows.getJSONObject(it).let { row -> SharedReaction(row.getString("value"), row.getInt("count"), row.getBoolean("includesMe")) } }.toPersistentList()
}
internal fun decodeInteractions(value: JSONObject): SharedInteractionView {
    val reactions = value.getJSONArray("reactions"); val forwards = value.getJSONArray("forwards")
    return SharedInteractionView((0 until reactions.length()).map { reactions.getJSONObject(it).let { row ->
        SharedReactionWork(row.getString("id"),row.getString("messageID"),row.getString("reaction"),row.getBoolean("present"),row.getString("status"),row.getBoolean("retryable"))
    } }.toPersistentList(), (0 until forwards.length()).map { forwards.getJSONObject(it).let { row ->
        SharedForwardWork(row.getString("id"),row.getString("status"),row.getInt("succeeded"),row.getInt("rejected"),row.getInt("cancelled"),row.getInt("unresolved"),row.getBoolean("retryable"),row.getBoolean("cancellable"))
    } }.toPersistentList(), value.optString("failure").takeIf { it.isNotEmpty() })
}
