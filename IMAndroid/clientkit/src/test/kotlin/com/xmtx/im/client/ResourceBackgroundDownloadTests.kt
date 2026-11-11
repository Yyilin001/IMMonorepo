package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class ResourceBackgroundDownloadTests {
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val room=RoomId(id());private val key=ResourceKey(ResourceHome.Room(room),id())
    private val descriptor=ResourceDescriptor(key,1,"original.txt","text/plain",8,ResourceChecksum("a".repeat(64)),ResourceState.Ready)
    private val grant=ResourceBackgroundDownloadAuthorization(id(),8,descriptor.checksum!!,1000,61000)
    private fun plan()=ResourceTransferPlan(ResourceTransferMode.Get,"https://provider.example/original?secret=delegation",persistentListOf(),persistentMapOf(),null,61000,8,null,null,descriptor.checksum,grant)
    @Test fun delegationRequiresExplicitOriginalGrantAndBothDeadlines() {
        var nanos=0L
        val target=MediaDownloadTarget(plan(),null,10_000_000_000L,{nanos});val background=ResourceBackgroundDownloadTarget(target)
        assertEquals(10000L,background.remainingLifetimeMillis(descriptor,1000))
        assertEquals(500L,background.remainingLifetimeMillis(descriptor,60500))
        assertTrue(runCatching {background.remainingLifetimeMillis(descriptor,999)}.isFailure)
        assertTrue(runCatching {background.remainingLifetimeMillis(descriptor,61000)}.isFailure)
        assertTrue(runCatching {background.remainingLifetimeMillis(descriptor.copy(byteCount=9),1000)}.isFailure)
        nanos=10_000_000_000L
        assertTrue(runCatching {background.remainingLifetimeMillis(descriptor,1000)}.isFailure)
        assertTrue(runCatching {ResourceBackgroundDownloadTarget(MediaDownloadTarget(plan().copy(backgroundDownload=null),null,Long.MAX_VALUE,{0}))}.isFailure)
        assertFalse(background.toString().contains("delegation"))
    }
    @Test fun durableMappingRoundTripsOnlyIdentityBytesAndNetworkPolicy() {
        val mapping=ResourceBackgroundDownloadMapping(id(),id(),id(),id(),key,MediaMessageLocation(room,MessageId(id())),grant,
            resourceBackgroundOriginDigest(plan().url),ResourceDownloadNetworkConstraints(false,false,false),1000)
        assertEquals(mapping,ResourceBackgroundDownloadMapping.decode(Json.parseToJsonElement(mapping.payload().toString()).jsonObject))
        assertEquals(grant,ResourceBackgroundDownloadAuthorization.decode(grant.payload()))
        assertFalse(mapping.payload().toString().contains("provider.example"));assertFalse(mapping.payload().toString().contains("secret"))
        assertTrue(runCatching {mapping.copy(originDigest="invalid")}.isFailure)
        assertTrue(runCatching {mapping.copy(message=MediaMessageLocation(RoomId(id()),mapping.message.message))}.isFailure)
    }
    @Test fun delegatedDownloadCannotBeTerminalOrOwnedAndCannotResumeBeforeDrain() {
        val work=ResourceDownloadWork(id(),descriptor,MediaMessageLocation(room,MessageId(id())),1000,backgroundPending=true)
        assertTrue(runCatching {work.copy(phase=ResourceDownloadPhase.Running,owner=id(),claim=id())}.isFailure)
        assertTrue(runCatching {work.copy(phase=ResourceDownloadPhase.Completed,requested=false,finishedAt=1000)}.isFailure)
        val pausing=work.copy(control=ResourceDownloadControl.Pause,requested=false)
        val ui=ResourceTransferProjection.download(ResourceDownloadSnapshot(pausing,true),1000)
        assertEquals(ResourceTransferPhase.Pausing,ui.phase);assertEquals(persistentSetOf(ResourceTransferAction.Cancel),ui.actions)
        assertEquals(ResourceTransferPhase.Paused,ResourceTransferProjection.download(ResourceDownloadSnapshot(pausing.copy(backgroundPending=false),true),1000).phase)
    }
    @Test fun resultBoundariesRejectUnboundedBytesAndMalformedTaskIdentity() {
        val result=ResourceBackgroundDownloadResult(id(),id(),200,null,8,"a".repeat(64))
        assertTrue(runCatching {result.copy(receivedBytes=512L*1024*1024+1)}.isFailure)
        assertTrue(runCatching {result.copy(task="other")}.isFailure)
        assertTrue(runCatching {result.copy(retryNotBefore=-1)}.isFailure)
    }
}
