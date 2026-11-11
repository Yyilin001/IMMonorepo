package com.xmtx.im.platform

import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class ResourceNativeProgressTests {
    private fun id()=UUID.randomUUID().toString().uppercase()
    private fun binding(kind:ResourceTransferKind=ResourceTransferKind.Download,job:String=id())=NativeTransferProgressBinding(
        SystemTransferProgressKey("account-a",kind,id(),id()),ResourceTransferId(kind,job),10,2000)
    @Test fun exactMappingTaskScopeDirectionLengthAndLifetimeAreRequired() {
        val b=binding();val sample=ResourceTransferAttemptProgress(b.key.mapping,7,10)
        fun snapshot(key:SystemTransferProgressKey=b.key,value:ResourceTransferAttemptProgress=sample,now:Long=1000)=
            AccountNativeTransferProgress.snapshot(listOf(b),persistentMapOf(key to value),now)
        assertEquals(sample,snapshot()[b.transfer])
        for(key in listOf(b.key.copy(scope="account-b"),b.key.copy(task=id()),b.key.copy(mapping=id()),b.key.copy(kind=ResourceTransferKind.Upload))) assertTrue(snapshot(key).isEmpty())
        assertTrue(snapshot(value=sample.copy(expectedBytes=20)).isEmpty());assertTrue(snapshot(value=sample.copy(attemptId=id())).isEmpty())
        assertTrue(snapshot(now=2000).isEmpty());assertTrue(AccountNativeTransferProgress.snapshot(listOf(b),persistentMapOf(),1000).isEmpty())
        val second=b.copy(key=b.key.copy(mapping=id(),task=id()))
        assertTrue(AccountNativeTransferProgress.snapshot(listOf(b,second),persistentMapOf(b.key to sample),1000).isEmpty())
        val upload=binding(ResourceTransferKind.Upload,b.transfer.value)
        val values=AccountNativeTransferProgress.snapshot(listOf(b,upload),persistentMapOf(b.key to sample,upload.key to ResourceTransferAttemptProgress(upload.key.mapping,10,10)),1000)
        assertEquals(2,values.size);assertEquals(7L,values[b.transfer]!!.transferredBytes);assertEquals(10L,values[upload.transfer]!!.transferredBytes)
    }
    @Test fun registryCoalescesBytesAndLateCallbacksCannotClearReplacement() {
        var nanos=0L;val registry=SystemTransferProgressRegistry {nanos};val b=binding()
        val first=registry.begin(b.key,10)!!;assertNull(registry.begin(b.key,10))
        first.report(1);val previous=registry.samples.value;first.report(4);assertEquals(1L,registry.samples.value[b.key]!!.transferredBytes)
        nanos=100_000_000;first.report(5);first.report(3);first.report(11);assertEquals(5L,registry.samples.value[b.key]!!.transferredBytes)
        first.report(10);assertEquals(10L,registry.samples.value[b.key]!!.transferredBytes);first.end();assertTrue(registry.samples.value.isEmpty())
        val second=registry.begin(b.key,10)!!;second.report(2);first.report(9);first.end()
        assertEquals(2L,registry.samples.value[b.key]!!.transferredBytes);assertEquals(1L,previous[b.key]!!.transferredBytes);second.end()
    }
    @Test fun coldTaskNeedsAdoptionAndClosedAccountNeverReceivesItsLateBytes()=runBlocking<Unit> {
        var now=1000L;val registry=SystemTransferProgressRegistry();val b=binding();val task=registry.begin(b.key,10)!!;task.report(4)
        val hub=ResourceTransferWaiting();val owner=AccountNativeTransferProgress("account-a",hub,registry) {now};val observing=launch {owner.observe()}
        try {
            yield();assertTrue(hub.snapshots.value.attempts.isEmpty())
            owner.bind(b.copy(key=b.key.copy(scope="other")));assertTrue(hub.snapshots.value.attempts.isEmpty())
            owner.bind(b);assertEquals(4L,hub.snapshots.value.attempts[b.transfer]!!.transferredBytes)
            now=2000;withTimeout(2000) {hub.snapshots.first {it.attempts.isEmpty()}}
            now=1000;owner.bind(b);assertEquals(4L,hub.snapshots.value.attempts[b.transfer]!!.transferredBytes)
            owner.retire(b.key.mapping);assertTrue(hub.snapshots.value.attempts.isEmpty())
            owner.close();task.report(10);owner.bind(b);yield();assertTrue(hub.snapshots.value.attempts.isEmpty())
            val nextHub=ResourceTransferWaiting();val next=AccountNativeTransferProgress("account-a",nextHub,registry) {now}
            next.bind(b);assertEquals(10L,nextHub.snapshots.value.attempts[b.transfer]!!.transferredBytes);next.close()
        } finally {observing.cancelAndJoin();owner.close();hub.close();task.end()}
    }
    @Test fun oversizedObservationSetsAreOmittedAndRegistryIsBounded() {
        val registry=SystemTransferProgressRegistry();val bindings=(1..65).map {binding()}
        val handles=bindings.take(64).map {registry.begin(it.key,10)!!}
        try {
            assertNull(registry.begin(bindings.last().key,10));assertEquals(64,registry.samples.value.size)
            assertTrue(AccountNativeTransferProgress.snapshot(bindings,registry.samples.value,1000).isEmpty())
        } finally {handles.forEach {it.end()}}
        assertTrue(registry.samples.value.isEmpty())
    }
}
