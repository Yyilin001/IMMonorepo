package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import java.io.IOException
import kotlinx.serialization.json.*
import kotlin.test.*

internal suspend fun assertCommandAttempt(retry:Boolean) {
    val intent=assertNotNull(currentCoroutineContext()[NetworkWorkIntent])
    assertEquals(retry,intent.isRetry)
    assertEquals(if(retry) NetworkWorkPriority.Recovery else NetworkWorkPriority.Interactive,intent.priority)
}

class NetworkWorkIntentTests {
    @Test fun `cancelled command evidence survives serialization and manual rounds after unresolved recovery`()=runTest {
        val store=MemoryPreferences();var now=1000L
        val api=FakeEdge {_,_->EdgeResponse(200,preferenceBaseline(preferenceValues[0]))}
        fun service()=AccountPreferenceService(actorId,AccountPreferenceClient(api,actorId),store,{now},{now*1_000_000})
        val first=service();val draft=first.enqueue(PreferencePatch(PreferenceKind.StrangerMessages,first=true));first.flush()
        assertEquals(false,store.works.single().executionStarted)
        api.answer={_,_->assertCommandAttempt(false);throw CancellationException("fixture owner cancelled")}
        assertFailsWith<CancellationException> {first.flush()}
        assertEquals(0,store.works.single().attempts);assertEquals(true,store.works.single().executionStarted)
        store.works[0]=Json.decodeFromString<PreferenceWork>(Json.encodeToString(PreferenceWork.serializer(),store.works.single()))
        val resumed=service();resumed.retry(draft.operation)
        api.answer={path,_->assertTrue(path.endsWith("/recover"));assertCommandAttempt(true);EdgeResponse(200,buildJsonObject {put("unresolved",buildJsonObject {})})}
        resumed.flush();assertFalse(store.works.single().reconcile)
        now=store.works.single().nextAttemptMilliseconds;resumed.retry(draft.operation)
        assertEquals(0,store.works.single().attempts)
        val command=assertNotNull(store.works.single().command)
        api.answer={path,_->assertTrue(path.endsWith("/submit"));assertCommandAttempt(true);EdgeResponse(200,directResult("receipt",preferenceReceipt(command)))}
        resumed.flush();assertEquals(PreferenceStatus.Committed,store.works.single().status)
    }
    @Test fun `legacy command evidence is frozen before an explicit round resets counters`()=runTest {
        val store=MemoryPreferences();val operation="FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"
        val command=PreferenceCommand(actorId,operation,preferenceValues[0],7,116000)
        val old=PreferenceWork(actorId,operation,PreferencePatch(PreferenceKind.StrangerMessages,first=false),"old",116000,
            status=PreferenceStatus.NeedsAttention,command=command,attempts=0,reconcile=false)
        val json=Json.encodeToString(PreferenceWork.serializer(),old);assertFalse(json.contains("executionStarted"))
        store.works+=Json.decodeFromString<PreferenceWork>(json)
        val api=FakeEdge {_,_->assertCommandAttempt(true);EdgeResponse(200,directResult("receipt",preferenceReceipt(command)))}
        val service=AccountPreferenceService(actorId,AccountPreferenceClient(api,actorId),store,{1000},{0})
        service.retry(operation);assertEquals(true,store.works.single().executionStarted);assertEquals(0,store.works.single().attempts)
        service.flush();assertEquals(PreferenceStatus.Committed,store.works.single().status)
    }
    @Test fun `domain intent refines only the selected activation without acquiring a parent permit`()=runTest {
        val first=AccountWorkScheduler();val second=AccountWorkScheduler()
        try {
            withContext(NetworkWorkScope(first,NetworkWorkContext("unrelated",NetworkWorkPriority.Background,
                NetworkWorkKind.Upload,"old-account-order",true))) {
                assertNull(currentCoroutineContext().networkWorkFor(second))
                withContext(NetworkWorkIntent(NetworkWorkPriority.Recovery,false)) {
                    val value=assertNotNull(currentCoroutineContext().networkWorkFor(second))
                    assertEquals(NetworkWorkKind.Ordinary,value.kind);assertNull(value.orderingKey)
                    assertFalse(value.isRetry);assertEquals(NetworkWorkPriority.Recovery,value.priority)
                    assertEquals("old-account-order",currentCoroutineContext().networkWorkFor(first)?.orderingKey)
                    assertEquals(0,first.snapshot().active);assertEquals(0,second.snapshot().active)
                }
            }
        } finally {first.closeAndDrain();second.closeAndDrain()}
    }
    @Test fun `preparation retries use persisted attempts and direct interactive baselines keep their own intent`()=runTest {
        val store=MemoryPreferences();var now=1000L;val seen=mutableListOf<NetworkWorkIntent?>()
        var fail=true
        val api=FakeEdge {_,_->
            seen+=currentCoroutineContext()[NetworkWorkIntent]
            if(fail) {fail=false;throw IOException("fixture transport loss")}
            EdgeResponse(200,preferenceBaseline(preferenceValues[0]))
        }
        val service=AccountPreferenceService(actorId,AccountPreferenceClient(api,actorId),store,{now},{now*1_000_000})
        service.enqueue(PreferencePatch(PreferenceKind.StrangerMessages,first=true));service.flush()
        assertEquals(1,store.works.single().preparationAttempts)
        now=store.works.single().nextAttemptMilliseconds;service.flush()
        assertEquals(2,store.works.single().preparationAttempts);assertNotNull(store.works.single().command)
        assertEquals(listOf(false,true),seen.map {requireNotNull(it).isRetry})
        assertTrue(seen.all {it?.priority==NetworkWorkPriority.Recovery})
        service.baseline(PreferenceKind.StrangerMessages);assertNull(seen.last())
    }
}
