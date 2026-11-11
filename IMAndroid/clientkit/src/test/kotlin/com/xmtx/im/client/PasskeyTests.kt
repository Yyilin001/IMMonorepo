package com.xmtx.im.client

import com.google.protobuf.ByteString
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.mockwebserver.*
import okhttp3.tls.*
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.test.*

class PasskeyTests {
    private val device=DeviceId("00000000-0000-0000-0000-000000000902")
    private fun bytes(vararg value:Int)=ByteString.copyFrom(value.map {it.toByte()}.toByteArray())
    private fun request()=PasskeyAssertionRequest("challenge-once",bytes(1,2,3),"im.example.com",persistentListOf(bytes(7)))
    private fun result()=PasskeyAssertionResult(bytes(7),bytes(1),bytes(2),bytes(3),null)
    private fun webAuthn(challenge:String="AQID",id:String="Bw",rawId:String=id,type:String="public-key",handle:JsonElement=JsonNull):String=buildJsonObject {
        put("type",type);put("id",id);put("rawId",rawId)
        put("response",buildJsonObject {
            put("clientDataJSON",passkeyBase64(ByteString.copyFromUtf8(buildJsonObject {put("type","webauthn.get");put("challenge",challenge);put("origin","android:apk-key-hash:test")}.toString())))
            put("authenticatorData","Ag");put("signature","Aw");put("userHandle",handle)
        })
    }.toString()
    @Test fun `binary values and credential lists are immutable and diagnostics are redacted`() {
        val raw=byteArrayOf(1,2,3);val challenge=ByteString.copyFrom(raw);raw[0]=9
        val r=request().copy(challenge=challenge);val replaced=r.copy(allowedCredentialIDs=r.allowedCredentialIDs.add(bytes(8)))
        assertEquals(1,r.challenge.byteAt(0).toInt());assertEquals(1,r.allowedCredentialIDs.size);assertEquals(2,replaced.allowedCredentialIDs.size)
        assertFalse(r.toString().contains("challenge-once"));assertFalse(AccountAssertion("PRIVATE-ASSERTION").toString().contains("PRIVATE-ASSERTION"))
        assertEquals("PasskeyAssertionResult(<redacted>)",result().toString())
        assertFailsWith<IllegalArgumentException> {AccountAssertion("x\ny")};assertFailsWith<IllegalArgumentException> {AccountAssertion("  ")}
        assertEquals(" value ",AccountAssertion(" value ").value)
    }
    @Test fun `WebAuthn envelope binds challenge credential type and allowed identity`() {
        assertEquals(bytes(7),PasskeyAssertionResult.fromWebAuthnJson(webAuthn(),request()).credentialID)
        assertNull(PasskeyAssertionResult.fromWebAuthnJson(webAuthn(),request()).userHandle)
        assertEquals(ByteString.EMPTY,PasskeyAssertionResult.fromWebAuthnJson(webAuthn(handle=JsonPrimitive("")),request()).userHandle)
        for(raw in listOf(webAuthn(challenge="BA"),webAuthn(id="CA"),webAuthn(rawId="CA"),webAuthn(type="password"),"{\"type\":5}","[".repeat(17))) {
            assertEquals(PasskeyFailureReason.InvalidResponse,assertFailsWith<PasskeyFailure> {PasskeyAssertionResult.fromWebAuthnJson(raw,request())}.reason)
        }
        val options=Json.parseToJsonElement(request().webAuthnRequestJson()).jsonObject
        assertEquals("AQID",options.string("challenge"));assertEquals("im.example.com",options.string("rpId"));assertNull(options["origin"])
        assertEquals("public-key",options.getValue("allowCredentials").jsonArray.single().jsonObject.string("type"))
    }
    @Test fun `provider obtains a fresh challenge for every attempt and stops after cancellation`() = runTest {
        var challenges=0;var submissions=0
        val source=PasskeyRequestProviding {account,id->assertEquals("alice_01",account);assertEquals(device,id);request().copy(challengeID="request-${++challenges}")}
        val submit=PasskeyAssertionSubmitting {_,request->submissions++;AccountAssertion(request.challengeID)}
        val provider=PasskeyAccountAssertionProvider(source,PasskeyAuthorizing {result()},submit,"alice_01")
        assertEquals("request-1",provider.accountAssertion(device).value);assertEquals("request-2",provider.accountAssertion(device).value)
        val cancelled=PasskeyAccountAssertionProvider(source,PasskeyAuthorizing {throw CancellationException()},submit,"alice_01")
        assertFailsWith<CancellationException> {cancelled.accountAssertion(device)};assertEquals(3,challenges);assertEquals(2,submissions)
    }
    private suspend fun <T> https(block:suspend (MockWebServer,OkHttpClient)->T):T {
        val cert=HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val serverKeys=HandshakeCertificates.Builder().heldCertificate(cert).build();val trust=HandshakeCertificates.Builder().addTrustedCertificate(cert.certificate).build()
        val http=OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(),trust.trustManager)
            .addInterceptor {chain->chain.proceed(chain.request().newBuilder().header("Authorization","SECRET-BUSINESS-TOKEN").header("X-Test-Interceptor","yes").build())}
            .cookieJar(object:CookieJar {
                override fun saveFromResponse(url:HttpUrl,cookies:List<Cookie>) {}
                override fun loadForRequest(url:HttpUrl)=listOf(Cookie.Builder().domain(url.host).name("private-cookie").value("secret").build())
            }).build()
        return MockWebServer().use {server->
            server.useHttps(serverKeys.sslSocketFactory(),false);server.start()
            try {block(server,http)} finally {http.connectionPool.evictAll();http.dispatcher.executorService.shutdown()}
        }
    }
    private fun options(allowed:String="[\"Bw\"]")="""{"challengeID":"challenge-once","challenge":"AQID","relyingPartyID":"im.example.com","allowedCredentialIDs":$allowed}"""
    private fun json(body:String)=MockResponse().setHeader("Content-Type","application/json").setBody(body)
    @Test fun `HTTP wire matches Swift optional fields base64url and device binding without ambient credentials`()=runBlocking<Unit> {
        https {server,http->
            server.enqueue(json(options()));server.enqueue(json("""{"accountAssertion":"ephemeral-factor"}"""))
            val client=PasskeyAssertionClient(server.url("/options").toString(),server.url("/complete").toString(),http)
            assertEquals(request(),client.assertionRequest(null,device));assertEquals("ephemeral-factor",client.submit(result(),request()).value)
            val first=server.takeRequest();assertEquals("POST",first.method)
            assertEquals(buildJsonObject {put("deviceID",device.value)},Json.parseToJsonElement(first.body.readUtf8()))
            assertEquals("no-store",first.getHeader("Cache-Control"));assertEquals("no-cache",first.getHeader("Pragma"))
            assertNull(first.getHeader("Authorization"));assertNull(first.getHeader("Cookie"));assertNull(first.getHeader("X-Test-Interceptor"))
            val second=server.takeRequest();assertEquals(Json.parseToJsonElement("""{"challengeID":"challenge-once","credentialID":"Bw","clientDataJSON":"AQ","authenticatorData":"Ag","signature":"Aw"}"""),Json.parseToJsonElement(second.body.readUtf8()))
            assertNull(second.getHeader("Authorization"))
        }
    }
    @Test fun `HTTP rejects malformed options oversized responses non JSON success and missing credential list`()=runBlocking<Unit> {
        https {server,http->
            val client=PasskeyAssertionClient(server.url("/options").toString(),server.url("/complete").toString(),http)
            for(response in listOf(json(options("null")),json(options("[5]")),json(options().replace("AQID","AB")),json(options().replace("\"challenge-once\"","5")),json(" ".repeat(262145)),MockResponse().setHeader("Content-Type","text/html").setBody(options()))) {
                server.enqueue(response);assertEquals(PasskeyFailureReason.InvalidResponse,assertFailsWith<PasskeyFailure> {client.assertionRequest(null,device)}.reason)
            }
        }
    }
    @Test fun `HTTP status redirect and lost completion are never retried`()=runBlocking<Unit> {
        https {server,http->
            val client=PasskeyAssertionClient(server.url("/options").toString(),server.url("/complete").toString(),http)
            for(status in listOf(401,403,429,503,302,201)) {
                server.enqueue(MockResponse().setResponseCode(status).setHeader("Location",server.url("/other")))
                val failure=assertFailsWith<PasskeyFailure> {client.submit(result(),request())}
                assertEquals(status,failure.status)
                assertEquals(if(status in listOf(401,403)) PasskeyFailureReason.AuthenticationRejected else PasskeyFailureReason.ServerStatus,failure.reason)
            }
            assertEquals(6,server.requestCount)
            server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AFTER_REQUEST))
            assertEquals(PasskeyFailureReason.Network,assertFailsWith<PasskeyFailure> {client.submit(result(),request())}.reason)
            assertEquals(7,server.requestCount)
        }
    }
    @Test fun `HTTP cancellation drains without delivering or submitting another assertion`()=runBlocking<Unit> {
        https {server,http->
            server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))
            val client=PasskeyAssertionClient(server.url("/options").toString(),server.url("/complete").toString(),http)
            val task=async(Dispatchers.Default) {client.assertionRequest(null,device)}
            assertNotNull(server.takeRequest(5,TimeUnit.SECONDS));withTimeout(5000) {task.cancelAndJoin()}
            assertEquals(1,server.requestCount);assertTrue(task.isCancelled)
        }
    }
    @Test fun `unsafe endpoint is rejected without exposing its contents`() {
        for(url in listOf("http://example.com/secret","https://user:secret@example.com/options","https://example.com/options#secret","not-a-secret-url")) {
            val error=assertFailsWith<IllegalArgumentException> {PasskeyAssertionClient(url,"https://example.com/complete")}
            assertFalse(error.toString().contains("secret"));assertNull(error.cause)
        }
    }
    @Test fun `device factor journal precedes authorizer and retries preserve registration without persisting assertions`()=runTest {
        val secrets=MemorySecrets();val api=FakeAccount().apply {failure=IOException()};val devices=mutableListOf<DeviceId>();var assertions=0
        val provider=DeviceBoundAccountAssertionProvider {id->
            devices+=id;assertNotNull(secrets.value);AccountAssertion("SECRET-FACTOR-${++assertions}")
        }
        assertFailsWith<IOException> {AuthSession(secrets,api){0}.registerDevice("rp:alice",provider)}
        val before=api.requests.single().second;assertFalse(secrets.value!!.contains("SECRET-FACTOR"))
        api.failure=null;val session=AuthSession(secrets,api){0};val issued=session.registerDevice("rp:alice",provider)
        assertEquals(devices.first(),devices.last());assertEquals(2,assertions)
        val after=api.requests.last().second;assertEquals(before["operationID"],after["operationID"]);assertEquals(before["cancellation"],after["cancellation"])
        assertNotEquals(before["accountAssertion"],after["accountAssertion"]);assertEquals(issued,session.current());assertFalse(secrets.value!!.contains("SECRET-FACTOR"))
    }
    @Test fun `unwritten expired or cancelled factors cannot issue credentials`()=runTest {
        val secrets=MemorySecrets().apply {failWrite=true};val api=FakeAccount();var factors=0
        val provider=DeviceBoundAccountAssertionProvider {factors++;AccountAssertion("factor")}
        assertFailsWith<IOException> {AuthSession(secrets,api){0}.registerDevice("rp:alice",provider)};assertEquals(0,factors)
        secrets.failWrite=false
        assertFailsWith<CancellationException> {AuthSession(secrets,api){0}.registerDevice("rp:alice") {throw CancellationException()}}
        assertTrue(api.requests.isEmpty());assertNotNull(secrets.value)
        var now=0L
        assertFailsWith<IllegalStateException> {AuthSession(secrets,api){now}.registerDevice("rp:alice") {now=600_001;AccountAssertion("factor")}}
        assertTrue(api.requests.isEmpty())
    }
    @Test fun `changing factor scope cancels old registration before asking for another assertion`()=runTest {
        val secrets=MemorySecrets();val api=FakeAccount()
        assertFailsWith<CancellationException> {AuthSession(secrets,api){0}.registerDevice("first") {throw CancellationException()}}
        val prior=Json.parseToJsonElement(secrets.value!!).jsonObject.getValue("registration").jsonObject
        AuthSession(secrets,api){0}.registerDevice("second") {id->
            assertEquals("/v2/device-credentials/cancel-registration",api.requests.single().first)
            assertNotEquals(prior.string("device"),id.value);AccountAssertion("new-factor")
        }
        assertEquals(2,api.requests.size)
    }
}
