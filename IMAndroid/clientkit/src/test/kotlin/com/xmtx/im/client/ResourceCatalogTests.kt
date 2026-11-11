package com.xmtx.im.client

import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import kotlin.test.*

class ResourceCatalogTests {
    private val room=RoomId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
    private val id="BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
    private class Store: ResourceCatalogStore {
        override val resourceDirectoryChanges=MutableStateFlow(0L)
        var started=0;var applied=0;var denied=0
        override suspend fun beginResourceDirectoryScan(room: RoomId,query: RoomResourceQuery): ResourceDirectoryScan {
            started++;require(query.cursor==null)
            return ResourceDirectoryScan("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",room,query,generation="A".repeat(32))
        }
        override suspend fun applyResourceDirectoryPage(scan: ResourceDirectoryScan,page: RoomResourcePage): ResourceDirectoryScan {
            applied++;page.boundTo(scan.room,scan.query)
            return scan.copy(hasPage=true,snapshotUpper=page.snapshotUpper,query=scan.query.copy(cursor=page.nextCursor))
        }
        override suspend fun denyResourceDirectory(scan: ResourceDirectoryScan) { denied++ }
        override suspend fun resourceDirectory(query: ResourceCatalogQuery): ResourceCatalogPage=error("not used")
        override suspend fun resourceSources(key: ResourceKey,before: ResourceSourceCursor?,limit: Int): ResourceSourcePage=error("not used")
        override suspend fun containsResourceSource(key: ResourceKey,source: MessageResourceSource)=false
        override suspend fun resourceDirectoryScan(room: RoomId,query: RoomResourceQuery): ResourceDirectoryScan?=null
        override suspend fun indexResourceProjectionBatch(limit: Int)=false
    }
    @Test fun `metadata models bound page sizes identities and hide continuation admission tokens`() {
        assertFails { ResourceCatalogQuery(limit=101) };assertFails { ResourceCatalogQuery(search="界".repeat(86)) }
        assertFails { ResourceSourceCursor(MessageId(id),10) };assertFails { MessageResourceSource(room,MessageId(id),0,0) }
        assertFails { ResourceCatalogCursor(-1,ResourceKey(ResourceHome.Room(room),id)) }
        val scan=ResourceDirectoryScan(id,room,RoomResourceQuery(cursor="private-cursor"),true,10,generation="A".repeat(32))
        assertFalse(scan.toString().contains("private-cursor"));assertFalse(scan.toString().contains("A".repeat(32)))
        assertFails { scan.copy(hasPage=false) };assertFails { scan.copy(snapshotUpper=-1) }
    }
    @Test fun `synchronizer freezes one page and never replays terminal scans`()=runTest {
        val store=Store();var calls=0
        val worker=ResourceDirectorySynchronizer(store) { actual,query -> assertEquals(room,actual);assertEquals(ResourceCategory.Image,query.category);calls++;RoomResourcePage(persistentListOf(),0,null) }
        val finished=worker.refresh(room,RoomResourceQuery(ResourceCategory.Image));assertTrue(finished.finished)
        assertFails { worker.step(finished) };assertEquals(1,calls);assertEquals(1,store.started);assertEquals(1,store.applied)
    }
    @Test fun `only authoritative invisibility denies all cached directory facts`()=runTest {
        for(reason in ResourceDirectoryFailureReason.entries) {
            val store=Store();var calls=0
            val worker=ResourceDirectorySynchronizer(store) { _,_ -> calls++;throw ResourceDirectoryFailure(reason) }
            assertFailsWith<ResourceDirectoryFailure> { worker.refresh(room) }
            assertEquals(if(reason==ResourceDirectoryFailureReason.NotVisible) 1 else 0,store.denied);assertEquals(0,store.applied);assertEquals(1,calls)
        }
    }
    @Test fun `late response after cancellation cannot enter the account index`()=runTest {
        val store=Store()
        val worker=ResourceDirectorySynchronizer(store) { _,_ -> currentCoroutineContext().cancel();RoomResourcePage(persistentListOf(),0,null) }
        val job=launch { worker.refresh(room) };job.join()
        assertTrue(job.isCancelled);assertEquals(0,store.applied);assertEquals(0,store.denied)
    }
}
