package com.xmtx.im.client

import com.google.protobuf.ByteString
import kotlinx.collections.immutable.*
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.*
import java.util.Base64

/** Ephemeral factor assertion. Never serialize it into the authentication journal or diagnostics. */
data class AccountAssertion(val value:String) {
    init {require(value.isNotBlank() && value.none {it.code<32 || it.code==127}) {"账号断言无效"}}
    override fun toString()="AccountAssertion(<redacted>)"
}
fun interface DeviceBoundAccountAssertionProvider {suspend fun accountAssertion(device:DeviceId):AccountAssertion}

data class PasskeyAssertionRequest(val challengeID:String,val challenge:ByteString,val relyingPartyID:String,
    val allowedCredentialIDs:PersistentList<ByteString>) {
    init {
        require(challengeID.isNotEmpty() && challengeID.length<=4096 && challengeID.none {it.code<32 || it.code==127}) {"通行密钥请求无效"}
        require(!challenge.isEmpty && challenge.size()<=65536 && relyingPartyID.isNotBlank() && relyingPartyID.length<=253 &&
            relyingPartyID.none {it.isWhitespace() || it.code<32 || it in "/\\:@?#"}) {"通行密钥请求无效"}
        require(allowedCredentialIDs.size<=128 && allowedCredentialIDs.all {!it.isEmpty && it.size()<=65536}) {"通行密钥请求无效"}
    }
    /** Standard WebAuthn options. Android supplies its own origin; callers must not forge one. */
    fun webAuthnRequestJson():String=buildJsonObject {
        put("challenge",passkeyBase64(challenge));put("rpId",relyingPartyID);put("userVerification","preferred")
        put("allowCredentials",JsonArray(allowedCredentialIDs.map {buildJsonObject {put("type","public-key");put("id",passkeyBase64(it))}}))
    }.toString()
    override fun toString()="PasskeyAssertionRequest(<redacted>)"
}
data class PasskeyAssertionResult(val credentialID:ByteString,val clientDataJSON:ByteString,val authenticatorData:ByteString,
    val signature:ByteString,val userHandle:ByteString?) {
    init {require(listOf(credentialID,clientDataJSON,authenticatorData,signature).all {!it.isEmpty && it.size()<=65536} && (userHandle==null || userHandle.size()<=65536)) {"通行密钥响应无效"}}
    override fun toString()="PasskeyAssertionResult(<redacted>)"
    companion object {
        /** Only checks response binding; signature, RP/origin and counter verification remain server-owned. */
        fun fromWebAuthnJson(raw:String,request:PasskeyAssertionRequest):PasskeyAssertionResult=passkeyDecode {
            val root=passkeyJson(raw);require(root.passkeyString("type")=="public-key")
            val credential=passkeyBytes(root.passkeyString("rawId"));require(credential==passkeyBytes(root.passkeyString("id")))
            require(request.allowedCredentialIDs.isEmpty() || credential in request.allowedCredentialIDs)
            val response=root.getValue("response").jsonObject
            val result=PasskeyAssertionResult(credential,passkeyBytes(response.passkeyString("clientDataJSON")),passkeyBytes(response.passkeyString("authenticatorData")),
                passkeyBytes(response.passkeyString("signature")),response["userHandle"]?.takeUnless {it is JsonNull}?.let {passkeyBytes(it.jsonPrimitive.content)})
            val client=passkeyJson(result.clientDataJSON.toByteArray().decodeToString(throwOnInvalidSequence=true))
            require(client.passkeyString("type")=="webauthn.get" && passkeyBytes(client.passkeyString("challenge"))==request.challenge)
            require(client["crossOrigin"]==null || client["crossOrigin"]==JsonPrimitive(false))
            result
        }
    }
}
fun interface PasskeyRequestProviding {suspend fun assertionRequest(accountHandle:String?,device:DeviceId):PasskeyAssertionRequest}
fun interface PasskeyAuthorizing {suspend fun authorize(request:PasskeyAssertionRequest):PasskeyAssertionResult}
fun interface PasskeyAssertionSubmitting {suspend fun submit(result:PasskeyAssertionResult,request:PasskeyAssertionRequest):AccountAssertion}

/** A fresh challenge and platform assertion for every attempt; no response or assertion cache. */
class PasskeyAccountAssertionProvider(private val requests:PasskeyRequestProviding,private val authorizer:PasskeyAuthorizing,
    private val submitter:PasskeyAssertionSubmitting,private val accountHandle:String?=null):DeviceBoundAccountAssertionProvider {
    override suspend fun accountAssertion(device:DeviceId):AccountAssertion {
        currentCoroutineContext().ensureActive()
        val request=requests.assertionRequest(accountHandle,device)
        currentCoroutineContext().ensureActive()
        val result=authorizer.authorize(request)
        currentCoroutineContext().ensureActive()
        return submitter.submit(result,request).also {currentCoroutineContext().ensureActive()}
    }
}
enum class PasskeyFailureReason {InvalidResponse,AuthenticationRejected,Unavailable,NoCredential,Network,ServerStatus}
class PasskeyFailure(val reason:PasskeyFailureReason,val status:Int?=null):Exception("通行密钥操作未完成：$reason")
internal inline fun <T> passkeyDecode(block:()->T):T=try {block()} catch(_:Exception) {throw PasskeyFailure(PasskeyFailureReason.InvalidResponse)}
internal fun passkeyBase64(value:ByteString):String=Base64.getUrlEncoder().withoutPadding().encodeToString(value.toByteArray())
internal fun JsonObject.passkeyString(name:String):String=getValue(name).jsonPrimitive.let {require(it.isString);it.content}
internal fun passkeyBytes(value:String):ByteString {
    require(value.length<=87384 && value.matches(Regex("[A-Za-z0-9_-]*={0,2}")))
    val bytes=Base64.getUrlDecoder().decode(value)
    require(Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)==value.trimEnd('='))
    return ByteString.copyFrom(bytes)
}
internal fun passkeyJson(value:String):JsonObject {
    require(value.toByteArray(Charsets.UTF_8).size<=262144)
    // Bound nesting before parsing a platform/server-controlled JSON document.
    var depth=0;var quoted=false;var escaped=false
    for(c in value) {
        if(quoted) {if(escaped) escaped=false else if(c=='\\') escaped=true else if(c=='"') quoted=false}
        else when(c) {'"'->quoted=true;'[','{'->{depth++;require(depth<=16)};']','}'->{depth--;require(depth>=0)}}
    }
    require(depth==0 && !quoted)
    return Json.parseToJsonElement(value).jsonObject
}
