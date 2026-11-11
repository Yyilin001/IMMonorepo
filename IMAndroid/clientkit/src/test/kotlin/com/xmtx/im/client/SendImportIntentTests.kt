package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import java.util.UUID
import kotlin.test.*

class SendImportIntentTests {
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val actor=UserId(id());private val room=RoomId(id())
    private fun imported()=SendImportedAttachment(id(),ResourceImportRequest(id(),ResourceImportSource.Message(RoomId(id()),MessageId(id()),id()),ResourceUsage.Attachment(room),id()))
    private fun upload()=SendAttachment(id(),id(),"file.txt","text/plain",10)
    private fun intent(local: PersistentList<SendAttachment>,remote: PersistentList<SendImportedAttachment>)=
        SendIntent(id(),actor,room,id(),"",local,100,86400100,serverImports=remote)
    @Test fun mixedOrderResolvesTargetMediaAndRoundTripsWithoutMutableCollections() {
        val local=upload();val remote=imported();val original=intent(persistentListOf(local),persistentListOf(remote))
        val ordered=original.copy(attachmentOrder=persistentListOf(remote.id,local.id))
        assertEquals(persistentListOf(remote.request.targetMedia,local.id),ordered.mediaIds)
        assertEquals(persistentListOf(local.id,remote.id),original.attachmentOrder)
        assertEquals(ordered,Json.decodeFromString<SendIntent>(Json.encodeToString(ordered)))
        assertEquals(1,ordered.serverImports.size);assertEquals(2,ordered.attachmentOrder.size)
        ordered.serverImports.clear();ordered.attachmentOrder.clear()
        assertEquals(1,ordered.serverImports.size);assertEquals(2,ordered.attachmentOrder.size)
    }
    @Test fun existingUploadOnlyPayloadDerivesItsOriginalOrder() {
        val source=upload();val original=intent(persistentListOf(source),persistentListOf())
        val old=JsonObject(Json.encodeToJsonElement(original).jsonObject.filterKeys {it !in setOf("serverImports","attachmentOrder")})
        val decoded=Json.decodeFromJsonElement<SendIntent>(old)
        assertEquals(original,decoded);assertEquals(persistentListOf(source.id),decoded.mediaIds)
    }
    @Test fun roomIdentityMediaAndOrderingConflictsAreRejectedBeforePersistence() {
        val local=upload();val remote=imported();val valid=intent(persistentListOf(local),persistentListOf(remote))
        assertFailsWith<IllegalArgumentException> {valid.copy(room=RoomId(id()))}
        assertFailsWith<IllegalArgumentException> {valid.copy(attachmentOrder=persistentListOf(remote.id,remote.id))}
        assertFailsWith<IllegalArgumentException> {valid.copy(attachmentOrder=persistentListOf(local.id))}
        assertFailsWith<IllegalArgumentException> {intent(persistentListOf(local),persistentListOf(remote.copy(id=local.id)))}
        assertFailsWith<IllegalArgumentException> {intent(persistentListOf(local),persistentListOf(remote.copy(request=remote.request.copy(targetMedia=local.id))))}
        assertFailsWith<IllegalArgumentException> {SendImportedAttachment(id(),remote.request.copy(targetUsage=ResourceUsage.UserAvatar))}
        assertFailsWith<IllegalArgumentException> {intent(persistentListOf(),persistentListOf(remote,remote.copy(id=id(),request=remote.request.copy(targetMedia=id()))))}
    }
    @Test fun combinedAttachmentLimitIncludesImportsAndImportOnlyMessagesAreValid() {
        assertEquals(1,intent(persistentListOf(),persistentListOf(imported())).mediaIds.size)
        assertEquals(10,intent((1..5).map {upload()}.toPersistentList(),(1..5).map {imported()}.toPersistentList()).mediaIds.size)
        assertFailsWith<IllegalArgumentException> {intent((1..6).map {upload()}.toPersistentList(),(1..5).map {imported()}.toPersistentList())}
    }
}
