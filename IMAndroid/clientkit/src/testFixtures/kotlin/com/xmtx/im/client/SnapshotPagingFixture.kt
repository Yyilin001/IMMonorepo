package com.xmtx.im.client

import com.google.protobuf.ByteString
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.serialization.json.*
import java.security.MessageDigest
import java.util.Base64

/** Identical deterministic wire bytes in JVM and real SQLite tests. */
data class SnapshotPagingFixture(val manifest:SnapshotManifest,val pages:List<SnapshotPage>,val items:List<SnapshotItem>)
fun snapshotFixture(pages:List<List<SnapshotItem>>):SnapshotPagingFixture {
    fun sha(bytes:ByteArray)=MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") {"%02x".format(it)}
    val id="00000000-0000-0000-0000-000000009999"
    val base=pages.flatten().maxOfOrNull {it.sequence} ?: 0
    var digest=sha("IM-SNAPSHOT-V3\u000031\u0000$base\u0000base".toByteArray())
    val encoded=pages.mapIndexed {index,items->
        val json=buildJsonObject {put("schema_version",31);putJsonArray("items") {items.forEach {item->add(buildJsonObject {
            put("projection_kind",item.kind);put("entity_key",item.key);put("source_event_id",item.sourceEvent);put("sequence",item.sequence)
            put("payload",Base64.getEncoder().encodeToString(item.payload.toByteArray()))
        })}}}.toString().toByteArray()
        val page=SnapshotPage.newBuilder().setSnapshotId(id).setGeneration(2).setPageIndex(index).setPayload(ByteString.copyFrom(json)).setPageDigest(sha(json))
            .setItemCount(items.size).setFirstProjectionKind(items.first().kind).setFirstEntityKey(items.first().key)
            .setLastProjectionKind(items.last().kind).setLastEntityKey(items.last().key).build()
        digest=sha(listOf(digest,index.toString(),page.pageDigest,page.firstProjectionKind,page.firstEntityKey,page.lastProjectionKind,page.lastEntityKey,page.itemCount.toString()).joinToString("\u0000").toByteArray())
        page
    }
    val manifest=SnapshotManifest.newBuilder().setSnapshotId(id).setGeneration(2).setBaseUserSyncSequence(base).setSchemaVersion(31).setCapabilityProfile("base")
        .setPageCount(pages.size).setTotalItems(pages.sumOf {it.size}.toLong()).setTotalBytes(encoded.sumOf {it.payload.size()}.toLong())
        .setRootDigest(digest).setNextSyncToken("snapshot-token").setSyncReceipt("snapshot-receipt").build()
    return SnapshotPagingFixture(manifest,encoded.map {it.toBuilder().setRootDigest(digest).build()},pages.flatten())
}
fun blockSnapshotFixture(pageCount:Int=9,itemsPerPage:Int=2,invalidAt:Int?=null):SnapshotPagingFixture {
    val items=(1..pageCount*itemsPerPage).map {index->
        val id="00000000-0000-0000-0000-"+index.toString().padStart(12,'0')
        val payload=buildJsonObject {put("target_user_id",id);if(index!=invalidAt) put("is_blocked",true);put("updated_at_ms",index)}
        SnapshotItem("user_block",id,id,index.toLong(),ByteString.copyFromUtf8(payload.toString()))
    }
    return snapshotFixture(items.chunked(itemsPerPage))
}
