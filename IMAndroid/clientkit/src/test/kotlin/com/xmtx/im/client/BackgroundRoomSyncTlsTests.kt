package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.*
import javax.net.ssl.SSLSocket
import kotlin.test.*

class BackgroundRoomSyncTlsTests {
    private val room=RoomId("00000000-0000-0000-0000-000000000001")
    private fun SSLSocket.send(request:Envelope,response:Envelope) {
        outputStream.write(FrameCodec.encode(response.toBuilder().setProtocolVersion(FrameCodec.VERSION).setRequestId(request.requestId).build()));outputStream.flush()
    }
    private fun personal()=Envelope.newBuilder().setSyncBatch(SyncBatch.newBuilder().setGeneration(1).setCapabilityProfile("base").setNextSyncToken("background-token").setSyncReceipt("background-receipt")).build()
    @Test fun `dedicated TLS runner spends personal directory and room budget then closes without final catchup`()=runBlocking<Unit> {
        RealtimeReceiveTests.Peer().use {peer->
            val store=BackgroundRoomStore().apply {heads=persistentListOf(AccountRoomHead(room,10,1),AccountRoomHead(RoomId("00000000-0000-0000-0000-000000000002"),10,1))}
            val replies=BackgroundRoomWire(store);val requests=mutableListOf<Envelope>()
            val server=async(Dispatchers.IO) {peer.accept().use {socket->
                repeat(7) { // personal, listener, directory, state, summaries, content batch, progress
                    val request=FrameCodec.read(socket.inputStream);requests+=request
                    socket.send(request,if(request.hasSyncPull()) personal() else replies.respond(request))
                }
                assertEquals(-1,socket.inputStream.read())
            }}
            val connection=RealtimeBackgroundSyncConnection(peer.connection,{peer.credentials})
            val rooms=BackgroundRoomSync(peer.connection,store,store,store)
            val runner=BackgroundSyncRunner(connection,SyncEngine(connection,MemorySync()),this,rooms::run)
            try {
                assertEquals(IncrementalSyncResult(4,true,IncrementalSyncStopReason.PageLimit),withTimeout(5000) {runner.run()})
                server.await();assertEquals(1,requests.count {it.hasSyncPull()});assertEquals(1,store.bodyCommits)
                assertFalse(peer.connection.state.value.connected)
                assertEquals(0,peer.connection.syncEvents.replayCache.size)
            } finally {runner.stop();peer.connection.close();server.cancelAndJoin()}
        }
    }
    @Test fun `TLS account resync closes pending directory read before deadline and cannot commit it`()=runBlocking<Unit> {
        RealtimeReceiveTests.Peer().use {peer->
            val store=BackgroundRoomStore();val replies=BackgroundRoomWire(store)
            val server=async(Dispatchers.IO) {peer.accept().use {socket->
                val pull=FrameCodec.read(socket.inputStream);assertTrue(pull.hasSyncPull());socket.send(pull,personal())
                val start=FrameCodec.read(socket.inputStream);assertTrue(start.hasAccountRoomChangesStart());socket.send(start,replies.respond(start))
                assertTrue(FrameCodec.read(socket.inputStream).hasUserRoomDirectoryList())
                socket.send(Envelope.getDefaultInstance(),Envelope.newBuilder().setAccountRoomResyncRequired(AccountRoomResyncRequired.newBuilder().setConnectionEpoch(replies.epoch)).build())
                assertEquals(-1,socket.inputStream.read())
            }}
            val connection=RealtimeBackgroundSyncConnection(peer.connection,{peer.credentials})
            val rooms=BackgroundRoomSync(peer.connection,store,store,store)
            val runner=BackgroundSyncRunner(connection,SyncEngine(connection,MemorySync()),this,rooms::run)
            try {
                assertFailsWith<BackgroundRoomCoverageLost> {withTimeout(4000) {runner.run()}}
                assertEquals(0,store.directoryCommits);server.await();assertFalse(peer.connection.state.value.connected)
            } finally {runner.stop();peer.connection.close();server.cancelAndJoin()}
        }
    }
    @Test fun `shared deadline interrupts room body read after personal sync without body commit or progress report`()=runBlocking<Unit> {
        RealtimeReceiveTests.Peer(timeout=5000).use {peer->
            val store=BackgroundRoomStore().apply {heads=persistentListOf(AccountRoomHead(room,10,1))}
            val replies=BackgroundRoomWire(store);val bodyEntered=CompletableDeferred<Unit>()
            val server=async(Dispatchers.IO) {peer.accept().use {socket->
                while(true) {
                    val request=FrameCodec.read(socket.inputStream)
                    if(request.hasGroupEventPullBatch()) {bodyEntered.complete(Unit);break}
                    socket.send(request,if(request.hasSyncPull()) personal() else replies.respond(request))
                }
                assertEquals(-1,socket.inputStream.read())
            }}
            val connection=RealtimeBackgroundSyncConnection(peer.connection,{peer.credentials})
            val rooms=BackgroundRoomSync(peer.connection,store,store,store)
            val runner=BackgroundSyncRunner(connection,SyncEngine(connection,MemorySync()),this,rooms::run,BackgroundSyncBudget(workDurationMillis=1500))
            try {
                val work=async {runCatching {runner.run()}};withTimeout(3000) {bodyEntered.await()}
                assertIs<BackgroundSyncDeadlineReached>(withTimeout(4000) {work.await()}.exceptionOrNull())
                assertEquals(0,store.bodyCommits);assertEquals(1,store.summaryCommits);server.await()
                assertFalse(peer.connection.state.value.connected)
            } finally {runner.stop();peer.connection.close();server.cancelAndJoin()}
        }
    }
}
