package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlinx.serialization.json.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class AccountNetworkActivityTests {
    @Test fun `all authenticated edges carry activation scope without parent permit`()=runTest {
        val owner=AccountNetworkActivity();val seen=mutableListOf<NetworkWorkScope>();val authScopes=mutableListOf<NetworkWorkScope?>()
        val credentialServer=FakeAccount()
        val auth=AuthSession(MemorySecrets(),object:AccountTransport {
            override suspend fun post(path:String,payload:JsonObject,accessToken:String?,expectedStatus:Int):JsonObject {
                authScopes+=currentCoroutineContext()[NetworkWorkScope]
                return credentialServer.post(path,payload,accessToken,expectedStatus)
            }
        }) {0}
        val c=auth.login("account","password123456");authScopes.clear()
        val edge=object:EdgeTransport {
            suspend fun observed():EdgeResponse {
                seen+=requireNotNull(currentCoroutineContext()[NetworkWorkScope])
                assertEquals(0,owner.scheduler.snapshot().active)
                return EdgeResponse(200,buildJsonObject {})
            }
            override suspend fun request(path:String,credentials:Credentials,payload:JsonObject?,query:Pair<String,String>?,maximumBytes:Long)=observed()
            override suspend fun put(path:String,credentials:Credentials,payload:JsonObject,maximumBytes:Long)=observed()
            override suspend fun requestArray(path:String,credentials:Credentials,payload:JsonObject,maximumBytes:Long)=observed()
            override suspend fun requestWithQuery(path:String,credentials:Credentials,query:Map<String,String>,maximumBytes:Long)=observed()
        }
        val api=owner.authenticated(auth,edge,c.userId,c.deviceId);val body=buildJsonObject {}
        withContext(owner.recoveryScope()) {
            api.request("/v2/read");api.requestWithQuery("/v2/read",emptyMap(),1024)
            api.requestWithResourcePlans("/v2/read");api.requestWithoutReplay("/v2/write",body)
            api.putWithoutReplay("/v2/write",body);api.requestArray("/v2/batch",body)
            api.mediaTarget("/v2/media",emptyMap(),1024)
        }
        assertEquals(7,seen.size);assertTrue(seen.all {it.scheduler===owner.scheduler && it.work.priority==NetworkWorkPriority.Recovery})
        owner.access(auth,c)
        assertEquals(1,authScopes.size);assertSame(owner.scheduler,authScopes.single()!!.scheduler)
        assertEquals(NetworkWorkKind.Authentication,authScopes.single()!!.work.kind)
        assertEquals(NetworkWorkPriority.Critical,authScopes.single()!!.work.priority)
        owner.closeAndDrain()
        // Post-retirement credential revocation is outside the closed activation's request pool.
        auth.logout();assertNull(authScopes.last())
    }
    @Test fun `foreign coroutine metadata does not migrate a bound authenticated account`()=runTest {
        val owner=AccountNetworkActivity();val foreign=AccountNetworkActivity();val fake=FakeAccount()
        val auth=AuthSession(MemorySecrets(),fake) {0};val c=auth.login("account","password123456")
        val edge=object:EdgeTransport {
            override suspend fun request(path:String,credentials:Credentials,payload:JsonObject?,query:Pair<String,String>?,maximumBytes:Long):EdgeResponse {
                val scope=requireNotNull(currentCoroutineContext()[NetworkWorkScope])
                assertSame(owner.scheduler,scope.scheduler);assertEquals(NetworkWorkPriority.Interactive,scope.work.priority)
                assertFalse(scope.work.isRetry);assertNull(scope.work.orderingKey)
                return EdgeResponse(200,buildJsonObject {})
            }
        }
        withContext(NetworkWorkScope(foreign.scheduler,NetworkWorkContext("other",NetworkWorkPriority.Background,orderingKey="foreign",isRetry=true))) {
            owner.authenticated(auth,edge,c.userId,c.deviceId).request("/v2/read")
        }
        owner.closeAndDrain();assertFalse(foreign.scheduler.snapshot().closed);foreign.closeAndDrain()
    }
    @Test fun `request queue budget is recoverable I O failure not caller cancellation`()=runTest {
        val scheduler=AccountWorkScheduler(AccountWorkScheduler.Configuration(ordinaryLimit=1),nowMillis={testScheduler.currentTime},dispatcher=StandardTestDispatcher(testScheduler))
        val held=scheduler.acquire(NetworkWorkContext("account"));val client=AccountClient("https://localhost",scheduler=scheduler)
        val auth=AuthSession(MemorySecrets(),FakeAccount()) {0};val c=auth.login("account","password123456")
        val request=async {runCatching {client.request("/v2/waiting",c)}}
        runCurrent();assertEquals(1,scheduler.snapshot().waiting)
        advanceTimeBy(20_000);runCurrent()
        assertIs<AccountRequestDeadlineExceeded>(request.await().exceptionOrNull());assertTrue(currentCoroutineContext().isActive)
        assertEquals(0,scheduler.snapshot().waiting);assertEquals(1,scheduler.snapshot().active)
        scheduler.release(held);scheduler.closeAndDrain()
    }
    @Test fun `real caller cancellation remains cancellation`()=runTest {
        val scheduler=AccountWorkScheduler(AccountWorkScheduler.Configuration(ordinaryLimit=1),nowMillis={testScheduler.currentTime},dispatcher=StandardTestDispatcher(testScheduler))
        val held=scheduler.acquire(NetworkWorkContext("account"));val client=AccountClient("https://localhost",scheduler=scheduler)
        val auth=AuthSession(MemorySecrets(),FakeAccount()) {0};val c=auth.login("account","password123456")
        val request=async {client.request("/v2/waiting",c)};runCurrent();request.cancelAndJoin()
        assertFailsWith<CancellationException> {request.await()};assertEquals(0,scheduler.snapshot().waiting)
        scheduler.release(held);scheduler.closeAndDrain()
    }
}
