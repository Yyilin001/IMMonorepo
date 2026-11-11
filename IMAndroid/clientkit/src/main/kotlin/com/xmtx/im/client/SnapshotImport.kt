package com.xmtx.im.client

import com.google.protobuf.ByteString
import com.xmtx.imclientkit.generated.im.realtime.v2.SnapshotManifest
import com.xmtx.imclientkit.generated.im.realtime.v2.SnapshotPage
import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.toPersistentList
import kotlinx.serialization.json.*
import java.util.Base64

/** A durable prefix, advanced atomically with its decoded shadow rows. */
data class SnapshotImportProgress(val nextPage:Int,val itemCount:Long,val byteCount:Long,val digest:String,
    val lastKind:String?=null,val lastKey:String?=null) {
    init {require(nextPage>=0 && itemCount>=0 && byteCount>=0 && (lastKind==null)==(lastKey==null))}
    companion object {
        fun initial(manifest:SnapshotManifest)=SnapshotImportProgress(0,0,0,
            sha256("IM-SNAPSHOT-V3\u000031\u0000${manifest.baseUserSyncSequence}\u0000base".toByteArray()))
    }
}
data class SnapshotPageImport(val progress:SnapshotImportProgress,val items:PersistentList<SnapshotItem>)

/** Wire validation is shared by the engine and durable store; at most one page is decoded. */
object SnapshotImportValidation {
    fun validateManifest(m:SnapshotManifest) {
        if(m.snapshotId.isBlank() || m.generation<=0 || m.baseUserSyncSequence<0 || m.schemaVersion!=31 ||
            m.capabilityProfile!="base" || m.pageCount !in 0..4096 || m.totalItems !in 0..1_000_000 ||
            m.totalBytes !in 0..268_435_456 || m.nextSyncToken.isBlank() || m.syncReceipt.isBlank() ||
            !m.rootDigest.matches(Regex("[a-f0-9]{64}"))) throw ClientFailure.Protocol()
    }
    fun advance(manifest:SnapshotManifest,previous:SnapshotImportProgress,page:SnapshotPage):SnapshotPageImport {
        validateManifest(manifest)
        if(previous.nextPage>=manifest.pageCount || previous.itemCount>manifest.totalItems || previous.byteCount>manifest.totalBytes ||
            !previous.digest.matches(Regex("[a-f0-9]{64}")) || (previous.nextPage==0)!=(previous.lastKind==null)) throw ClientFailure.Protocol()
        var last=previous.lastKind?.let {it to requireNotNull(previous.lastKey)}
        if (page.snapshotId != manifest.snapshotId || page.generation != manifest.generation || page.rootDigest != manifest.rootDigest ||
            page.pageIndex != previous.nextPage || page.payload.size() !in 1..61_440 || sha256(page.payload.toByteArray()) != page.pageDigest)
            throw ClientFailure.Protocol()
        val wire = Json.parseToJsonElement(page.payload.toStringUtf8()).jsonObject
        if (wire.number("schema_version") != 31L) throw ClientFailure.Protocol()
        val decoded = wire["items"]?.jsonArray?.map { element ->
            val item = element.jsonObject
            val payload = ByteString.copyFrom(Base64.getDecoder().decode(item.string("payload")))
            val kind = item.string("projection_kind")
            val key = item.string("entity_key")
            val source = canonicalId(item.string("source_event_id"))
            val fields = Json.parseToJsonElement(payload.toStringUtf8()).jsonObject
            val expectedKey = when(kind) {
                "room", "room_head", "direct_room_profile", "conversation_state", "direct_sending_capability" -> fields.string("room_id")
                "own_read_watermark", "direct_read_receipt" -> fields.string("room_id").lowercase()
                "relationship", "user_block", "contact_alias" -> fields.string("target_user_id")
                "stranger_message_permission", "user_add_permission", "read_receipt_preferences", "live_activity_preferences" -> "singleton"
                "message_favorite" -> fields.string("message_id")
                "timeline_activity" -> source
                "profile_invalidation" -> fields.string("user_id")
                else -> throw ClientFailure.Protocol()
            }
            if(key != expectedKey) throw ClientFailure.Protocol()
            SnapshotItem(kind, key, source, item.number("sequence"), payload)
        } ?: throw ClientFailure.Protocol()
        if (decoded.size !in 1..500 || decoded.size != page.itemCount) throw ClientFailure.Protocol()
        for (item in decoded) {
            val key = item.kind to item.key
            if (item.kind in setOf("message", "message_reaction", "moderation", "group_capability") || item.kind.toByteArray().size > 64 || item.key.toByteArray().size > 512 || item.sequence !in 1..manifest.baseUserSyncSequence ||
                item.payload.size() !in 1..45_056 || (last != null && compareKeys(last!!, key) >= 0)) throw ClientFailure.Protocol()
            last = key
        }
        if (decoded.first().kind != page.firstProjectionKind || decoded.first().key != page.firstEntityKey ||
            decoded.last().kind != page.lastProjectionKind || decoded.last().key != page.lastEntityKey) throw ClientFailure.Protocol()
        val digest=sha256(listOf(previous.digest,page.pageIndex.toString(),page.pageDigest,page.firstProjectionKind,page.firstEntityKey,
            page.lastProjectionKind,page.lastEntityKey,page.itemCount.toString()).joinToString("\u0000").toByteArray())
        val count=previous.itemCount+decoded.size
        val bytes=previous.byteCount+page.payload.size()
        if(count>manifest.totalItems || bytes>manifest.totalBytes) throw ClientFailure.Protocol()
        val progress=SnapshotImportProgress(previous.nextPage+1,count,bytes,digest,last?.first,last?.second)
        // The final page is never persisted as complete with a mismatched root or totals.
        if(progress.nextPage==manifest.pageCount) validateComplete(manifest,progress)
        return SnapshotPageImport(progress,decoded.toPersistentList())
    }
    fun validateComplete(manifest:SnapshotManifest,progress:SnapshotImportProgress) {
        validateManifest(manifest)
        if(progress.nextPage!=manifest.pageCount || progress.itemCount!=manifest.totalItems || progress.byteCount!=manifest.totalBytes || progress.digest!=manifest.rootDigest)
            throw ClientFailure.Protocol()
    }
    private fun compareKeys(a:Pair<String,String>,b:Pair<String,String>)=a.first.compareTo(b.first).takeIf {it!=0} ?: a.second.compareTo(b.second)
}
