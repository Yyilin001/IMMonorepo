package com.xmtx.im.client

import kotlinx.collections.immutable.toPersistentList
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Swift-compatible deployment-provided endpoints, not invented routes on the password-only local server. */
class PasskeyAssertionClient(optionsEndpoint:String,completionEndpoint:String,http:OkHttpClient?=null):PasskeyRequestProviding,PasskeyAssertionSubmitting {
    private val options=endpoint(optionsEndpoint);private val completion=endpoint(completionEndpoint)
    private val client by lazy {(http?.newBuilder() ?: OkHttpClient.Builder()).apply {interceptors().clear();networkInterceptors().clear()}
        .cookieJar(CookieJar.NO_COOKIES).authenticator(Authenticator.NONE).proxyAuthenticator(Authenticator.NONE).eventListener(EventListener.NONE)
        .cache(null).followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).callTimeout(15,TimeUnit.SECONDS).build()}
    override suspend fun assertionRequest(accountHandle:String?,device:DeviceId):PasskeyAssertionRequest {
        require(uuidId(device.value)==device.value) {"设备标识无效"}
        require(accountHandle==null || accountHandle.length<=256 && accountHandle.none {it.code<32 || it.code==127}) {"账号标识无效"}
        val response=post(options,buildJsonObject {accountHandle?.let {put("accountHandle",it)};put("deviceID",device.value)})
        return passkeyDecode {
            val allowed=response.getValue("allowedCredentialIDs").jsonArray
            require(allowed.size<=128)
            PasskeyAssertionRequest(response.passkeyString("challengeID"),passkeyBytes(response.passkeyString("challenge")),response.passkeyString("relyingPartyID"),
                allowed.map {require(it.jsonPrimitive.isString);passkeyBytes(it.jsonPrimitive.content)}.toPersistentList())
        }
    }
    override suspend fun submit(result:PasskeyAssertionResult,request:PasskeyAssertionRequest):AccountAssertion {
        val response=post(completion,buildJsonObject {
            put("challengeID",request.challengeID);put("credentialID",passkeyBase64(result.credentialID));put("clientDataJSON",passkeyBase64(result.clientDataJSON))
            put("authenticatorData",passkeyBase64(result.authenticatorData));put("signature",passkeyBase64(result.signature));result.userHandle?.let {put("userHandle",passkeyBase64(it))}
        })
        return passkeyDecode {AccountAssertion(response.passkeyString("accountAssertion"))}
    }
    private suspend fun post(url:HttpUrl,body:JsonObject):JsonObject=withContext(Dispatchers.IO) {withTimeout(15_000) {
        val request=Request.Builder().url(url).header("Accept","application/json").header("Cache-Control","no-store").header("Pragma","no-cache")
            .post(body.toString().toRequestBody("application/json".toMediaType())).build()
        val call=client.newCall(request);val drained=CompletableDeferred<Unit>()
        try {
            suspendCancellableCoroutine {continuation->
                continuation.invokeOnCancellation {call.cancel()}
                try {call.enqueue(object:Callback {
                    override fun onFailure(call:Call,e:IOException) {
                        try {if(continuation.isActive) continuation.resumeWithException(PasskeyFailure(PasskeyFailureReason.Network))}
                        finally {drained.complete(Unit)}
                    }
                    override fun onResponse(call:Call,response:Response) {
                        try {
                            val value=response.use {r->
                                if(r.code in setOf(401,403)) throw PasskeyFailure(PasskeyFailureReason.AuthenticationRejected,r.code)
                                if(r.code!=200) throw PasskeyFailure(PasskeyFailureReason.ServerStatus,r.code)
                                passkeyDecode {
                                    val content=requireNotNull(r.body);require(content.contentType()?.subtype=="json")
                                    val source=content.source();source.request(262145);require(source.buffer.size<=262144)
                                    passkeyJson(source.readByteArray().decodeToString(throwOnInvalidSequence=true))
                                }
                            }
                            if(continuation.isActive) continuation.resume(value)
                        } catch(error:Exception) {
                            if(continuation.isActive) continuation.resumeWithException(if(error is PasskeyFailure) error else PasskeyFailure(PasskeyFailureReason.InvalidResponse))
                        } finally {drained.complete(Unit)}
                    }
                })} catch(_:Exception) {drained.complete(Unit);if(continuation.isActive) continuation.resumeWithException(PasskeyFailure(PasskeyFailureReason.Network))}
            }
        } finally {call.cancel();withContext(NonCancellable) {drained.await()}}
    }}
    private fun endpoint(value:String)=try {value.toHttpUrl().also {require(it.isHttps && it.username.isEmpty() && it.password.isEmpty() && it.fragment==null)}}
        catch(_:Exception) {throw IllegalArgumentException("通行密钥端点必须是有效 HTTPS 地址")}
}
