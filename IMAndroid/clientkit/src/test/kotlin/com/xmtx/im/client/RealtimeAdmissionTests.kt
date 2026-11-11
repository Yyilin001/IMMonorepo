package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import com.xmtx.im.client.RealtimeReceiveTests.Peer
import kotlinx.coroutines.*
import javax.net.ssl.SSLSocket
import kotlin.test.*

class RealtimeAdmissionTests {
    private fun read()=Envelope.newBuilder().setSyncPull(SyncPull.getDefaultInstance())
    private fun heartbeat()=Envelope.newBuilder().setHeartbeat(Heartbeat.getDefaultInstance())
    private fun SSLSocket.reply(request:Envelope) {
        val reply=Envelope.newBuilder().setRequestId(request.requestId).setProtocolVersion(FrameCodec.VERSION)
        if(request.hasHeartbeat()) reply.setHeartbeatAck(HeartbeatAck.newBuilder().setServerTimeMs(1_000_000).build()) else reply.setSyncBatch(SyncBatch.getDefaultInstance())
        outputStream.write(FrameCodec.encode(reply.build()));outputStream.flush()
    }
    private suspend fun waiting(s:AccountWorkScheduler,count:Int) {withTimeout(3000) {while(s.snapshot().waiting!=count) delay(5)}}
    private suspend fun active(s:AccountWorkScheduler,count:Int) {withTimeout(3000) {while(s.snapshot().active!=count) delay(5)}}
    @Test fun `captured durable session cannot migrate requests or cooldown to new activation`()=runBlocking<Unit> {
        Peer().use {p->
            val oldScheduler=AccountWorkScheduler();val newScheduler=AccountWorkScheduler()
            val server=async(Dispatchers.IO) {
                p.accept().use {assertEquals(-1,it.inputStream.read())}
                p.accept().use {socket->val request=FrameCodec.read(socket.inputStream);assertTrue(request.hasSyncPull());socket.reply(request)}
            }
            try {
                p.connection.connect(p.credentials,oldScheduler)
                val captured=p.connection.captureRequestSession();assertSame(oldScheduler,captured.scheduler)
                val permit=oldScheduler.acquire(NetworkWorkContext("realtime"));oldScheduler.release(permit)
                p.connection.connect(p.credentials,newScheduler)
                captured.scheduler!!.coolDown("realtime",60_000)
                assertFailsWith<RealtimeUnavailableBeforeAdmission> {captured.transport.request(read())}
                assertTrue(p.connection.request(read()).hasSyncBatch());server.await()
                assertEquals(0,oldScheduler.snapshot().active);assertEquals(0,oldScheduler.snapshot().waiting)
            } finally {p.connection.close();server.cancelAndJoin();oldScheduler.closeAndDrain();newScheduler.closeAndDrain()}
        }
    }
    @Test fun `domain retry metadata reaches real frames while heartbeat remains outside retry quota`()=runBlocking<Unit> {
        Peer().use {p->
            val clock=java.util.concurrent.atomic.AtomicLong(0);val s=AccountWorkScheduler(nowMillis=clock::get)
            val count=java.util.concurrent.atomic.AtomicInteger()
            val server=async(Dispatchers.IO) {p.accept().use {socket->repeat(8) {
                val request=FrameCodec.read(socket.inputStream);count.incrementAndGet();socket.reply(request)
            }}}
            try {
                p.connection.connect(p.credentials,s)
                repeat(5) {withContext(NetworkWorkIntent(NetworkWorkPriority.Recovery,true)) {p.connection.request(read())}}
                val next=async(NetworkWorkIntent(NetworkWorkPriority.Recovery,true)) {p.connection.request(read())}
                waiting(s,1);assertEquals(5,count.get())
                withContext(NetworkWorkIntent(NetworkWorkPriority.Background,true,"same-command")) {assertTrue(p.connection.request(heartbeat()).hasHeartbeatAck())}
                withContext(NetworkWorkIntent(NetworkWorkPriority.Interactive,false)) {assertTrue(p.connection.request(read()).hasSyncBatch())}
                assertEquals(7,count.get());assertFalse(next.isCompleted)
                clock.set(2000);s.setDegraded(false);assertTrue(next.await().hasSyncBatch());server.await()
            } finally {p.connection.close();server.cancelAndJoin();s.closeAndDrain()}
        }
    }
    @Test fun `reserved heartbeat bypasses both full ordinary pool and local pending capacity`()=runBlocking<Unit> {
        Peer(maximumPending=1).use {p->
            val s=AccountWorkScheduler(AccountWorkScheduler.Configuration(ordinaryLimit=2));val seen=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
            var held:AccountWorkScheduler.Permit?=null
            val server=async(Dispatchers.IO) {p.accept().use {socket->
                val first=FrameCodec.read(socket.inputStream);assertTrue(first.hasSyncPull());seen.complete(Unit)
                val control=FrameCodec.read(socket.inputStream);assertTrue(control.hasHeartbeat());socket.reply(control)
                release.await();socket.reply(first)
            }}
            try {
                p.connection.connect(p.credentials,s)
                val http=s.acquire(NetworkWorkContext("account")).also {held=it};val ordinary=async {p.connection.request(read())};seen.await()
                assertTrue(p.connection.request(heartbeat()).hasHeartbeatAck());assertEquals(2,s.snapshot().active)
                release.complete(Unit);assertTrue(ordinary.await().hasSyncBatch());s.release(http);server.await()
            } finally {release.complete(Unit);p.connection.close();server.cancelAndJoin();withContext(NonCancellable) {held?.let {s.release(it)}};s.closeAndDrain()}
        }
    }
    @Test fun `caller cancellation retains on wire permit until response and does not block control`()=runBlocking<Unit> {
        Peer().use {p->
            val s=AccountWorkScheduler(AccountWorkScheduler.Configuration(ordinaryLimit=1));val seen=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
            var held:AccountWorkScheduler.Permit?=null
            val server=async(Dispatchers.IO) {p.accept().use {socket->
                val first=FrameCodec.read(socket.inputStream);seen.complete(Unit)
                val control=FrameCodec.read(socket.inputStream);assertTrue(control.hasHeartbeat());socket.reply(control)
                release.await();socket.reply(first)
                val next=FrameCodec.read(socket.inputStream);assertTrue(next.hasSyncPull());socket.reply(next)
            }}
            try {
                p.connection.connect(p.credentials,s)
                val first=launch {p.connection.request(read())};seen.await();first.cancel()
                val next=async {p.connection.request(read())};waiting(s,1)
                assertFalse(first.isCompleted);assertEquals(1,s.snapshot().active)
                assertTrue(p.connection.request(heartbeat()).hasHeartbeatAck())
                release.complete(Unit);first.join();assertTrue(next.await().hasSyncBatch());server.await();assertEquals(0,s.snapshot().active)
            } finally {release.complete(Unit);p.connection.close();server.cancelAndJoin();withContext(NonCancellable) {held?.let {s.release(it)}};s.closeAndDrain()}
        }
    }
    @Test fun `account queued old epoch cannot send on reconnected socket`()=runBlocking<Unit> {
        Peer().use {p->
            val s=AccountWorkScheduler(AccountWorkScheduler.Configuration(ordinaryLimit=1))
            var held:AccountWorkScheduler.Permit?=null
            val server=async(Dispatchers.IO) {
                p.accept().use {assertEquals(-1,it.inputStream.read())}
                p.accept().use {socket->val request=FrameCodec.read(socket.inputStream);assertTrue(request.hasHeartbeat());socket.reply(request)}
            }
            try {
                p.connection.connect(p.credentials,s);val old=p.connection.authenticatedEpoch!!
                val permit=s.acquire(NetworkWorkContext("account")).also {held=it}
                val queued=async {runCatching {p.connection.request(read())}};waiting(s,1)
                p.connection.connect(p.credentials,s);s.release(permit)
                assertIs<RealtimeUnavailableBeforeAdmission>(queued.await().exceptionOrNull())
                p.connection.close(old);assertTrue(p.connection.state.value.connected)
                assertTrue(p.connection.request(heartbeat()).hasHeartbeatAck());server.await()
            } finally {p.connection.close();server.cancelAndJoin();withContext(NonCancellable) {held?.let {s.release(it)}};s.closeAndDrain()}
        }
    }
    @Test fun `request builder is frozen before account queue suspension`()=runBlocking<Unit> {
        Peer().use {p->
            val s=AccountWorkScheduler(AccountWorkScheduler.Configuration(ordinaryLimit=1))
            var held:AccountWorkScheduler.Permit?=null
            val server=async(Dispatchers.IO) {p.accept().use {socket->val request=FrameCodec.read(socket.inputStream);assertTrue(request.hasSyncPull());socket.reply(request)}}
            try {
                p.connection.connect(p.credentials,s);val permit=s.acquire(NetworkWorkContext("account")).also {held=it};val mutable=read()
                val queued=async {p.connection.request(mutable)};waiting(s,1);mutable.clearBody().setHeartbeat(Heartbeat.getDefaultInstance())
                s.release(permit);assertTrue(queued.await().hasSyncBatch());server.await()
            } finally {p.connection.close();server.cancelAndJoin();withContext(NonCancellable) {held?.let {s.release(it)}};s.closeAndDrain()}
        }
    }
    @Test fun `queue timeout is before admission and preserves connection without replay`()=runBlocking<Unit> {
        Peer(timeout=150).use {p->
            val s=AccountWorkScheduler(AccountWorkScheduler.Configuration(ordinaryLimit=1))
            var held:AccountWorkScheduler.Permit?=null
            val server=async(Dispatchers.IO) {p.accept().use {socket->val request=FrameCodec.read(socket.inputStream);assertTrue(request.hasHeartbeat());socket.reply(request)}}
            try {
                p.connection.connect(p.credentials,s);val permit=s.acquire(NetworkWorkContext("account")).also {held=it}
                val failure=assertFailsWith<RealtimeUnavailableBeforeAdmission> {p.connection.request(read())}
                assertEquals(AccountWorkScheduler.Rejection.DeadlineExceeded,failure.reason);assertTrue(p.connection.state.value.connected)
                assertEquals(0,s.snapshot().waiting);assertTrue(p.connection.request(heartbeat()).hasHeartbeatAck());s.release(permit);server.await()
            } finally {p.connection.close();server.cancelAndJoin();withContext(NonCancellable) {held?.let {s.release(it)}};s.closeAndDrain()}
        }
    }
    @Test fun `on wire cancellation deadline closes socket and releases permit only after drain`()=runBlocking<Unit> {
        Peer(timeout=200).use {p->
            val s=AccountWorkScheduler();val seen=CompletableDeferred<Unit>()
            val server=async(Dispatchers.IO) {p.accept().use {socket->FrameCodec.read(socket.inputStream);seen.complete(Unit);assertEquals(-1,socket.inputStream.read())}}
            try {
                p.connection.connect(p.credentials,s);val first=launch {p.connection.request(read())};seen.await();first.cancel()
                assertFalse(first.isCompleted);assertEquals(1,s.snapshot().active)
                withTimeout(3000) {first.join()};server.await();assertFalse(p.connection.state.value.connected);assertEquals(0,s.snapshot().active)
            } finally {p.connection.close();server.cancelAndJoin();s.closeAndDrain()}
        }
    }
    @Test fun `invalid client direction never enters scheduler or wire`()=runBlocking<Unit> {
        Peer().use {p->
            val s=AccountWorkScheduler()
            val server=async(Dispatchers.IO) {p.accept().use {socket->val request=FrameCodec.read(socket.inputStream);assertTrue(request.hasHeartbeat());socket.reply(request)}}
            try {
                p.connection.connect(p.credentials,s)
                for(frame in listOf(Envelope.newBuilder(),Envelope.newBuilder().setClientHello(ClientHello.getDefaultInstance()),Envelope.newBuilder().setSyncBatch(SyncBatch.getDefaultInstance()))) {
                    assertFailsWith<ClientFailure.Protocol> {p.connection.request(frame)}
                }
                assertEquals(0,s.snapshot().active);assertTrue(p.connection.request(heartbeat()).hasHeartbeatAck());server.await()
            } finally {p.connection.close();server.cancelAndJoin();s.closeAndDrain()}
        }
    }
    @Test fun `local queue cancellation returns account capacity and cannot leak local slot`()=runBlocking<Unit> {
        Peer(maximumPending=1).use {p->
            val s=AccountWorkScheduler(AccountWorkScheduler.Configuration(ordinaryLimit=2));val seen=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
            var held:AccountWorkScheduler.Permit?=null
            val server=async(Dispatchers.IO) {p.accept().use {socket->
                val first=FrameCodec.read(socket.inputStream);seen.complete(Unit);release.await();socket.reply(first)
                val next=FrameCodec.read(socket.inputStream);assertTrue(next.hasSyncPull());socket.reply(next)
            }}
            try {
                p.connection.connect(p.credentials,s);val first=async {p.connection.request(read())};seen.await()
                val cancelled=launch {p.connection.request(read())};active(s,2);cancelled.cancelAndJoin();assertEquals(1,s.snapshot().active)
                val next=async {p.connection.request(read())};active(s,2);release.complete(Unit)
                assertTrue(first.await().hasSyncBatch());assertTrue(next.await().hasSyncBatch());server.await()
            } finally {release.complete(Unit);p.connection.close();server.cancelAndJoin();withContext(NonCancellable) {held?.let {s.release(it)}};s.closeAndDrain()}
        }
    }
}
