package com.xmtx.im.sharedsdk

import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.toPersistentList
import org.json.JSONObject

data class SharedForwardWork(val id: String, val status: String, val succeeded: Int, val rejected: Int, val cancelled: Int, val unresolved: Int, val retryable: Boolean, val cancellable: Boolean)
data class SharedInteractionView(val forwards: PersistentList<SharedForwardWork>, val failure: String?)
internal fun decodeInteractions(value: JSONObject): SharedInteractionView {
    val forwards = value.getJSONArray("forwards")
    return SharedInteractionView((0 until forwards.length()).map { forwards.getJSONObject(it).let { row ->
        SharedForwardWork(row.getString("id"),row.getString("status"),row.getInt("succeeded"),row.getInt("rejected"),row.getInt("cancelled"),row.getInt("unresolved"),row.getBoolean("retryable"),row.getBoolean("cancellable"))
    } }.toPersistentList(), value.optString("failure").takeIf { it.isNotEmpty() })
}
