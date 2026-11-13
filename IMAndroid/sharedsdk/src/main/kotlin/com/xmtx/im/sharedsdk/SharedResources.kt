package com.xmtx.im.sharedsdk

import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.toPersistentList
import org.json.JSONObject

data class SharedAttachment(val id: String, val name: String, val contentType: String, val bytes: Long, val kind: String)
data class SharedTransfer(val id: String, val kind: String, val name: String, val phase: String, val bytes: Long?, val confirmed: Long?, val actions: PersistentList<String>)
data class SharedResourceView(val draft: SharedAttachment?, val importID: String?, val selected: SharedAttachment?, val roomID: String?, val messageID: String?,
    val image: String?, val expiresAtElapsed: Long, val readID: String?, val chunk: String?, val transfers: PersistentList<SharedTransfer>, val failure: SharedError?) {
    override fun toString() = "SharedResourceView(<private>)"
}
internal fun decodeAttachment(value: JSONObject) = SharedAttachment(value.getString("id"), value.getString("name"), value.getString("contentType"), value.getLong("bytes"), value.getString("kind"))
internal fun decodeResources(value: JSONObject, startedAt: Long): SharedResourceView {
    fun optional(key: String) = value.optString(key).takeIf { value.has(key) && !value.isNull(key) }
    val rows = value.getJSONArray("transfers")
    return SharedResourceView(value.optJSONObject("draft")?.let(::decodeAttachment), optional("importID"), value.optJSONObject("selected")?.let(::decodeAttachment), optional("roomID"), optional("messageID"), optional("image"),
        startedAt + value.getLong("remainingMilliseconds"), optional("readID"), optional("chunk"), (0 until rows.length()).map { index -> rows.getJSONObject(index).let {
            val actions = it.getJSONArray("actions")
            SharedTransfer(it.getString("id"), it.getString("kind"), it.getString("name"), it.getString("phase"), if (it.has("bytes")) it.getLong("bytes") else null,
                if (it.has("confirmed")) it.getLong("confirmed") else null, (0 until actions.length()).map(actions::getString).toPersistentList())
        } }.toPersistentList(), optional("failure")?.let { SharedError.OperationFailed })
}
enum class SharedTransferAction(val wire: String) { Pause("pause"), Resume("resume"), Retry("retry"), Cancel("cancel"), RetryCancellation("retryCancellation") }
