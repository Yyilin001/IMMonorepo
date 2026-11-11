package com.xmtx.im.client

import com.xmtx.im.client.NetworkQualityObserver.Quality.*
import com.xmtx.im.client.NetworkQualityObserver.Sample.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import kotlin.test.*

class NetworkQualityObserverTests {
    @Test fun `stale and sparse samples cannot create consecutive bad windows`() {
        for(sparse in listOf(false,true)) {
            val observer=NetworkQualityObserver()
            repeat(if(sparse) 5 else 20) {observer.record(Timeout,"api",it*100L)}
            for(time in if(sparse) listOf(10L,20,30,40) else listOf(100L,110,120,130)) observer.record(if(sparse) Timeout else Success,"api",time*1000)
            assertEquals(Normal,observer.quality("api"))
        }
    }
    @Test fun `only three fresh healthy windows recover the affected service`() {
        val observer=NetworkQualityObserver()
        repeat(2) {window->repeat(20) {observer.record(Timeout,"api",window*10_000L+it*100)}}
        observer.record(Timeout,"api",20_000);assertEquals(Degraded,observer.quality("api"));assertEquals(Normal,observer.quality("media"))
        for(time in 21..60) for(sample in listOf(TransportFailure,ServiceCooldown,LocalProcessing)) observer.record(sample,"api",time*1000L)
        assertEquals(Degraded,observer.quality("api"))
        repeat(3) {window->
            repeat(20) {observer.record(Success,"api",100_000+window*10_000L+it*100)}
            assertEquals(Degraded,observer.quality("api"))
        }
        assertEquals(Normal,observer.record(Success,"api",130_000))
    }
    @Test fun `negative and backward clocks do not poison observations`() {
        val observer=NetworkQualityObserver();observer.record(Timeout,"api",-1)
        repeat(2) {window->repeat(5) {
            observer.record(Timeout,"api",100_000+window*10_000L+it*1000)
            observer.record(Success,"api",1)
        }}
        assertEquals(Degraded,observer.record(Timeout,"api",120_000))
    }
    @Test fun `service budget ignores non samples and preserves existing services`() {
        val observer=NetworkQualityObserver(1)
        repeat(100) {observer.record(ServiceCooldown,"ignored-$it",0)}
        repeat(2) {window->repeat(5) {observer.record(Timeout,"first",window*10_000L+it*1000);observer.record(Timeout,"overflow",window*10_000L+it*1000)}}
        assertEquals(Degraded,observer.record(Timeout,"first",20_000));assertEquals(Normal,observer.record(Timeout,"overflow",20_000))
    }
    @Test fun `thirty percent degrades but intermediate ratio breaks consecutive windows`() {
        for(middle in listOf(false,true)) {
            val observer=NetworkQualityObserver()
            repeat(3) {window->repeat(20) {index->
                val failures=if(middle && window==1) 2 else 6
                observer.record(if(index>=20-failures) Timeout else Success,"api",window*10_000L+index*100)
            }}
            assertEquals(if(middle) Normal else Degraded,observer.record(Success,"api",30_000))
        }
    }
    @Test fun `observed degradation changes admission and fresh recovery releases the queue`()=runTest {
        var clock=0L;val scheduler=AccountWorkScheduler(nowMillis={clock})
        val held=mutableListOf<AccountWorkScheduler.Permit>()
        try {
            repeat(2) {window->repeat(5) {clock=window*10_000L+it*1000;scheduler.recordQuality(Timeout,"account")}}
            clock=20_000;scheduler.recordQuality(Success,"account");assertEquals(Degraded,scheduler.serviceQuality("account"))
            repeat(3) {held+=scheduler.acquire(NetworkWorkContext("account"))}
            val queued=async {scheduler.acquire(NetworkWorkContext("account"))};yield();assertEquals(1,scheduler.snapshot().waiting)
            held+=scheduler.acquire(NetworkWorkContext("other"));held+=scheduler.acquire(NetworkWorkContext("authentication",kind=NetworkWorkKind.Authentication))
            repeat(3) {window->repeat(20) {clock=100_000+window*10_000L+it*100;scheduler.recordQuality(Success,"account")}}
            assertFalse(queued.isCompleted);clock=130_000;scheduler.recordQuality(Success,"account")
            held+=queued.await();assertEquals(Normal,scheduler.serviceQuality("account"))
        } finally {held.forEach {scheduler.release(it)};scheduler.closeAndDrain()}
        val replacement=AccountWorkScheduler();assertEquals(Normal,replacement.serviceQuality("account"));replacement.closeAndDrain()
        scheduler.recordQuality(Timeout,"account");assertTrue(scheduler.snapshot().closed)
    }
}
