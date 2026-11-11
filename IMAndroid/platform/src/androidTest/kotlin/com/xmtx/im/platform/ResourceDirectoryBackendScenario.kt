package com.xmtx.im.platform

import com.xmtx.im.client.*
import com.xmtx.imclientkit.generated.im.realtime.v2.Envelope
import com.xmtx.imclientkit.generated.im.realtime.v2.MessageSendOperationAcceptance
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import java.io.IOException
import java.util.UUID

internal suspend fun verifyResourceDirectoryBackend(actor: UserId,room: RoomId,store: SqliteClientStore,api: AuthenticatedTransport,
    peerApi: AuthenticatedTransport,transport: EnvelopeTransport,uploads: PersistentList<ResourceUploadRequest>) {
    var phase="frozen media send and lost accepted reply"
    fun id()=UUID.randomUUID().toString().uppercase()
    try {
        val media=uploads.map { it.media }.toPersistentList();val command=MessageCommand.withMedia(actor,room,"",media,System.currentTimeMillis()+86400000,id())
        store.enqueue(command);var lose=true;var accepted: MessageSendOperationAcceptance?=null;var submits=0
        val lossy=object: EnvelopeTransport {
            override suspend fun request(body: Envelope.Builder): Envelope {
                val sent=body.build()
                if(lose) {assertTrue(sent.hasMessageSendOperation());assertEquals(command,sent.messageSendOperation)} else {
                    assertTrue(sent.hasMessageSendOperationRecover());assertEquals(command.clientMessageId,sent.messageSendOperationRecover.identity.operationId)
                    assertEquals(command.fingerprint,sent.messageSendOperationRecover.fingerprint.digest)
                }
                submits++
                val response=transport.request(body);assertTrue(response.hasMessageSendOperationResult());val result=response.messageSendOperationResult
                assertTrue(result.hasReceipt());assertTrue(result.receipt.hasAccepted());accepted=result.receipt.accepted
                if(lose) { lose=false;throw IOException("simulated lost media message acceptance") };return response
            }
        }
        val outbox=MessageOutbox(lossy,store)
        assertTrue(runCatching { outbox.flush() }.exceptionOrNull() is IOException);assertEquals(command,store.pending().single())
        withTimeout(15000) {while(store.pending().isNotEmpty()) {delay(250);outbox.flush()}};assertEquals(2,submits)
        phase="authorized nonempty directory pagination"
        val client=RoomResourceDirectoryClient(api);val query=RoomResourceQuery(ResourceCategory.File,1)
        val scan=store.beginResourceDirectoryScan(room,query)
        val first=client.query(room,query);assertEquals(1,first.items.size);val cursor=requireNotNull(first.nextCursor)
        val second=client.query(room,query.copy(cursor=cursor));assertEquals(1,second.items.size);assertNull(second.nextCursor)
        assertEquals(first.snapshotUpper,second.snapshotUpper);assertTrue(first.items.single().position>second.items.single().position)
        val continuation=store.applyResourceDirectoryPage(scan,first)
        val finished=store.applyResourceDirectoryPage(continuation,second);assertTrue(finished.finished)
        assertEquals(finished,store.resourceDirectoryScan(room,query))
        assertEquals(media.toSet(),store.resourceDirectory(ResourceCatalogQuery(room=room)).entries.map { it.descriptor.key.media }.toSet())
        val source=store.resourceSources(first.items.single().descriptor.key).sources.single()
        assertTrue(store.containsResourceSource(first.items.single().descriptor.key,source))
        val items=first.items+second.items;assertEquals(media.toSet(),items.map { it.descriptor.key.media }.toSet())
        for(item in items) {
            val upload=uploads.first { it.media==item.descriptor.key.media }
            assertEquals(accepted!!.messageId,item.message.value);assertEquals(accepted!!.roomSequence,item.position.sequence);assertEquals(1L,item.messageRevision)
            assertEquals(ResourceHome.Room(room),item.descriptor.key.home);assertEquals(upload.checksum,item.descriptor.checksum);assertEquals(upload.byteCount,item.descriptor.byteCount)
            assertEquals(upload.displayName,item.descriptor.displayName);assertEquals(upload.contentType,item.descriptor.contentType);assertEquals(ResourceState.Ready,item.descriptor.state)
        }
        assertEquals(media.reversed(),items.map { it.descriptor.key.media });assertEquals(listOf(1,0),items.map { it.position.ordinal })
        phase="real room-log media descriptors persist with the accepted message"
        withTimeout(15000) {
            while(true) {
                RoomSyncEngine(transport,store).synchronize()
                val projection=store.snapshot().messages.firstOrNull { it.id.value==accepted!!.messageId }
                if(projection?.revision==1L) {
                    assertEquals(media,projection.media!!.ids)
                    assertEquals(uploads.map { it.media },projection.media!!.presentations!!.map { it.media })
                    projection.media!!.presentations!!.forEach { presentation ->
                        assertEquals(items.first { it.descriptor.key.media==presentation.media }.descriptor,presentation.descriptor)
                    }
                    break
                }
                delay(100)
            }
        }
        assertEquals(2,store.resourceDirectory(ResourceCatalogQuery(room=room)).entries.size)
        phase="cursor actor and filter binding plus exclusive time boundaries"
        val peer=RoomResourceDirectoryClient(peerApi);assertEquals(2,peer.query(room,RoomResourceQuery(ResourceCategory.File)).items.size)
        suspend fun fails(reason: ResourceDirectoryFailureReason,body: suspend ()->Unit) {
            val error=runCatching { body() }.exceptionOrNull();assertTrue(error is ResourceDirectoryFailure);assertEquals(reason,(error as ResourceDirectoryFailure).reason)
        }
        fails(ResourceDirectoryFailureReason.InvalidCursor) { peer.query(room,query.copy(cursor=cursor)) }
        fails(ResourceDirectoryFailureReason.InvalidCursor) { client.query(room,query.copy(category=ResourceCategory.Image,cursor=cursor)) }
        // An unknown room has no actor route in this isolated stack. A routing 503 is
        // transient unavailability, not a proof that a previously visible room was revoked.
        val unroutable=runCatching { client.query(RoomId(id()),query) }.exceptionOrNull() as ResourceDirectoryFailure
        assertEquals(ResourceDirectoryFailureReason.Unavailable,unroutable.reason);assertEquals(503,unroutable.status)
        assertTrue(client.query(room,RoomResourceQuery(ResourceCategory.Image)).items.isEmpty())
        val created=first.items.single().createdAt
        assertTrue(client.query(room,RoomResourceQuery(before=created)).items.isEmpty());assertTrue(client.query(room,RoomResourceQuery(after=created)).items.isEmpty())
        phase="withdrawn message disappears even through the original continuation"
        val withdrawal=MessageMutationCommand(actor,room,MessageId(accepted!!.messageId),id(),1,null,System.currentTimeMillis()+595_000)
        val result=MessageMutationClient(api).execute(withdrawal,false,false) as MutationResult.Receipt;assertEquals("withdrawal rejection: ${result.reason}",MutationStatus.Committed,result.status)
        val after=client.query(room,query.copy(cursor=cursor));assertTrue(after.items.isEmpty());assertNull(after.nextCursor);assertEquals(first.snapshotUpper,after.snapshotUpper)
        assertTrue(client.query(room,query).items.isEmpty());assertTrue(peer.query(room,query).items.isEmpty())
        withTimeout(15000) {
            while(true) {
                RoomSyncEngine(transport,store).synchronize()
                val projection=store.snapshot().messages.first { it.id.value==accepted!!.messageId }
                if(projection.withdrawn) {
                    assertEquals(MessageMedia.Empty,projection.media)
                    assertTrue(store.resourceDirectory(ResourceCatalogQuery(room=room)).entries.isEmpty())
                    assertFalse(store.containsResourceSource(first.items.single().descriptor.key,source));break
                }
                delay(100)
            }
        }
    } catch(error: Throwable) { throw AssertionError("Resource directory failed during $phase",error) }
}
