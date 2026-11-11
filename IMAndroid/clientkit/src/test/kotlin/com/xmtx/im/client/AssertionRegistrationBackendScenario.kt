package com.xmtx.im.client

import kotlinx.serialization.json.*
import java.io.IOException
import kotlin.test.*

/** Real device issuance; the local deployment supplies password assertions, not a WebAuthn verifier. */
internal suspend fun verifyBackendAssertionRegistration(transport:AccountTransport,account:String,password:String,actor:UserId) {
    val secrets=MemorySecrets();var lose=true;var issued=0
    val requests=mutableListOf<JsonObject>();val devices=mutableListOf<DeviceId>();val factors=mutableListOf<String>()
    val uncertain=object:AccountTransport {
        override suspend fun post(path:String,payload:JsonObject,accessToken:String?,expectedStatus:Int):JsonObject {
            val response=transport.post(path,payload,accessToken,expectedStatus)
            if(path=="/v2/device-credentials") {
                issued++;requests+=payload
                if(lose) {lose=false;throw IOException("Controlled lost issuance reply")}
            }
            return response
        }
    }
    val provider=DeviceBoundAccountAssertionProvider {device->
        devices+=device
        AccountAssertion(transport.post("/v2/account-auth/password/assertion",buildJsonObject {
            put("accountHandle",account);put("password",password);put("deviceID",device.value)
        }).string("accountAssertion")).also {factors+=it.value}
    }
    try {
        assertFailsWith<IOException> {AuthSession(secrets,uncertain).registerDevice("factor:$account",provider)}
        assertFalse(secrets.value!!.contains(factors.single()))
        val restored=AuthSession(secrets,uncertain)
        val credentials=restored.registerDevice("factor:$account",provider)
        assertEquals(actor,credentials.userId);assertEquals(devices.first(),credentials.deviceId)
        assertEquals(2,issued);assertEquals(2,devices.size);assertEquals(1,devices.toSet().size)
        assertNotEquals(factors.first(),factors.last())
        assertEquals(requests.first()["operationID"],requests.last()["operationID"])
        assertEquals(requests.first()["cancellation"],requests.last()["cancellation"])
        assertTrue(factors.none {secrets.value!!.contains(it)})
        assertEquals(credentials,restored.current())
        println("E2E: fresh factor assertions recovered the same device registration after a lost issuance reply")
    } finally {AuthSession(secrets,transport).logout()}
}
