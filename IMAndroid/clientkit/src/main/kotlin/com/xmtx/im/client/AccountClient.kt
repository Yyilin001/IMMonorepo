package com.xmtx.im.client

import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.HttpUrl.Companion.toHttpUrl
import java.io.IOException
import java.io.InterruptedIOException
import java.net.SocketTimeoutException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

interface AccountTransport {
    suspend fun post(path: String, payload: JsonObject, accessToken: String? = null, expectedStatus: Int = 200): JsonObject
    /** Implementations may report Expired only after validating an empty 410 response. */
    suspend fun cancelDeviceRegistration(cancellation: RegistrationCancellation): RegistrationCancellationResult {
        post("/v2/device-credentials/cancel-registration", cancellation.payload(), expectedStatus = 204)
        return RegistrationCancellationResult.Cancelled
    }
}
enum class RegistrationCancellationResult { Cancelled, Expired }

/** Raw authenticated edge response; operation clients interpret bound 429/503 hints themselves. */
data class EdgeResponse(val status: Int, val body: JsonObject, val retryAfter: String? = null, val arrayBody: JsonArray? = null)
interface EdgeTransport {
    suspend fun requestArray(path: String, credentials: Credentials, payload: JsonObject, maximumBytes: Long): EdgeResponse = throw UnsupportedOperationException("Array response unavailable")
    suspend fun put(path: String, credentials: Credentials, payload: JsonObject, maximumBytes: Long = 65_536): EdgeResponse = throw UnsupportedOperationException("PUT unavailable")
    suspend fun request(path: String, credentials: Credentials, payload: JsonObject? = null,
        query: Pair<String, String>? = null, maximumBytes: Long = 65_536): EdgeResponse
    suspend fun requestWithQuery(path: String, credentials: Credentials, query: Map<String, String>, maximumBytes: Long): EdgeResponse {
        require(query.size <= 1)
        return request(path, credentials, query = query.entries.singleOrNull()?.let { it.key to it.value }, maximumBytes = maximumBytes)
    }
}

/** Admission failed before this HTTP request was sent. Domain recovery still owns any earlier attempts. */
class AccountRequestAdmissionFailure(val reason:AccountWorkScheduler.Rejection):IOException("Account request admission: $reason")
/** A request budget expired; the request may already have reached the server. */
class AccountRequestDeadlineExceeded:IOException("Account request deadline exceeded")

/** HTTPS only; redirects, HTTP retries and credential logging deliberately disabled. */
class AccountClient(baseUrl: String, http: OkHttpClient? = null, private val scheduler:AccountWorkScheduler?=null) : AccountTransport, EdgeTransport {
    // Android trust-store initialization is blocking. Defer it until a request runs on IO,
    // rather than doing certificate/provider work while the login screen is being composed.
    private val http by lazy {
        val base=http ?: OkHttpClient()
        base.newBuilder()
        .eventListenerFactory {call->
            val delegate=base.eventListenerFactory.create(call)
            call.request().tag(HTTPMeasurement::class.java)?.let {HTTPMetricsListener(delegate,it)} ?: delegate
        }
        .followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false)
        .callTimeout(20, TimeUnit.SECONDS).build() }
    private val base = baseUrl.toHttpUrl().also {
        require(it.isHttps && it.username.isEmpty() && it.password.isEmpty() && it.query == null && it.fragment == null && it.encodedPath == "/")
    }

    override suspend fun post(path: String, payload: JsonObject, accessToken: String?, expectedStatus: Int): JsonObject {
        validatePath(path)
        val request = Request.Builder().url(base.resolve(path) ?: error("Invalid endpoint"))
            .header("Cache-Control", "no-store").header("Pragma", "no-cache")
            .header("Accept", "application/json")
            .post(payload.toString().toRequestBody("application/json".toMediaType()))
            .apply { if (accessToken != null) header("Authorization", "Bearer $accessToken") }.build()
        val response = execute(request, 1_048_576, authentication=true)
        if (response.status !in 200..299) throw response.failure()
        if (response.status != expectedStatus) throw ClientFailure.Protocol()
        return response.body
    }

    override suspend fun cancelDeviceRegistration(cancellation: RegistrationCancellation): RegistrationCancellationResult {
        val request = Request.Builder().url(base.resolve("/v2/device-credentials/cancel-registration")!!)
            .header("Cache-Control", "no-store").header("Pragma", "no-cache").header("Accept", "application/json")
            .post(cancellation.payload().toString().toRequestBody("application/json".toMediaType())).build()
        val response = try { execute(request, 1_048_576, authentication = true, emptyTerminalStatuses = setOf(204, 410), decodeJsonBody = false) }
            catch (_: java.net.ProtocolException) { throw ClientFailure.Protocol() }
        return when (response.status) {
            204 -> RegistrationCancellationResult.Cancelled
            410 -> RegistrationCancellationResult.Expired
            in 200..299 -> throw ClientFailure.Protocol()
            else -> throw response.failure()
        }
    }

    override suspend fun request(path: String, credentials: Credentials, payload: JsonObject?,
        query: Pair<String, String>?, maximumBytes: Long): EdgeResponse {
        return edgeRequest(path, credentials, payload, query?.let { mapOf(it) } ?: emptyMap(), maximumBytes)
    }
    override suspend fun requestWithQuery(path: String, credentials: Credentials, query: Map<String, String>, maximumBytes: Long) =
        edgeRequest(path, credentials, null, query, maximumBytes)
    override suspend fun put(path: String, credentials: Credentials, payload: JsonObject, maximumBytes: Long) =
        edgeRequest(path, credentials, payload, emptyMap(), maximumBytes, "PUT")
    override suspend fun requestArray(path: String, credentials: Credentials, payload: JsonObject, maximumBytes: Long) =
        edgeRequest(path, credentials, payload, emptyMap(), maximumBytes, allowArray = true)
    private suspend fun edgeRequest(path: String, credentials: Credentials, payload: JsonObject?, query: Map<String, String>, maximumBytes: Long, method: String? = null, allowArray: Boolean = false): EdgeResponse {
        validatePath(path)
        // Profile presentation batches have a 2 MiB wire budget; all callers retain their narrower caps.
        require(maximumBytes in 1..2_097_152)
        val url = base.resolve(path)!!.newBuilder().apply { query.forEach { (key, value) -> addQueryParameter(key, value) } }.build()
        val request = Request.Builder().url(url).header("Cache-Control", "no-store").header("Pragma", "no-cache")
            .header("Accept", "application/json").header("Authorization", "Bearer ${credentials.accessToken}")
            .header("X-IM-Device-ID", credentials.deviceId.value)
            .apply { if (payload != null) method(method ?: "POST", payload.toString().toRequestBody("application/json".toMediaType())) else get() }.build()
        return execute(request, maximumBytes, allowArray)
    }

    private fun validatePath(path: String) {
        require(path.matches(Regex("/v2/[A-Za-z0-9/_-]+")) && !path.contains("//"))
    }

    private suspend fun execute(request:Request,maximumBytes:Long,allowArray:Boolean=false,authentication:Boolean=false,
        emptyTerminalStatuses: Set<Int> = setOf(204), decodeJsonBody: Boolean = true):EdgeResponse {
        val scoped=currentCoroutineContext()[NetworkWorkScope]
        val owner=scheduler ?: scoped?.scheduler
        val work=if(authentication) NetworkWorkContext("authentication",NetworkWorkPriority.Critical,NetworkWorkKind.Authentication)
            else (owner?.let {currentCoroutineContext().networkWorkFor(it)} ?: currentCoroutineContext()[NetworkWorkIntent]?.let {
                NetworkWorkContext("account",it.priority,isRetry=it.isRetry)
            } ?: NetworkWorkContext("account")).copy(service="account",kind=NetworkWorkKind.Ordinary)
        val diagnostics=owner?.networkDiagnostics ?: currentCoroutineContext()[NetworkDiagnosticsScope]?.diagnostics
        val measurement=HTTPMeasurement(diagnostics,work)
        suspend fun measured(body:suspend ()->EdgeResponse):EdgeResponse {
            measurement.admitted()
            var failure:Throwable?=null
            try {return body()} catch(error:Throwable) {failure=error;throw error}
            finally {measurement.finish(failure)}
        }
        if(owner==null) return measured {executeUnscheduled(request,maximumBytes,allowArray,emptyTerminalStatuses,decodeJsonBody,measurement)}
        val started=AtomicBoolean(false);val receivedBody=AtomicBoolean(false);val status=AtomicInteger(0)
        // Queue time and transmission share the existing 20-second request budget.
        try {
            val result=withTimeoutOrNull(20_000) {owner.withPermit(work) {measured {
                executeUnscheduled(request,maximumBytes,allowArray,emptyTerminalStatuses,decodeJsonBody,measurement,onStarted={started.set(true)},onBody={receivedBody.set(true)}) {response->
                    status.set(response.code)
                    if(response.code==429 || response.code==503) response.header("Retry-After")?.let {header->
                        val delay=runCatching {retryAfterMilliseconds(header,System.currentTimeMillis())}.getOrNull()
                        // Header cooldown is registered before a possibly stalled or malformed body.
                        if(delay!=null) runBlocking {owner.coolDown(work.service,delay)}
                    }
                }
            }}} ?: throw AccountRequestDeadlineExceeded()
            owner.recordQuality(if(status.get() in listOf(429,503)) NetworkQualityObserver.Sample.ServiceCooldown else NetworkQualityObserver.Sample.Success,work.service)
            return result
        }
        catch(error:AccountWorkScheduler.AdmissionException) {measurement.finish(error);throw AccountRequestAdmissionFailure(error.reason)}
        catch(error:CancellationException) {measurement.finish(error);throw error}
        catch(error:Exception) {
            measurement.finish(error)
            if(started.get()) {
                val sample=when {
                    status.get() in listOf(429,503)->NetworkQualityObserver.Sample.ServiceCooldown
                    // The raw HTTP body arrived even if local JSON decoding subsequently rejected it.
                    receivedBody.get()->NetworkQualityObserver.Sample.Success
                    error is AccountRequestDeadlineExceeded || error is SocketTimeoutException ||
                        error is InterruptedIOException && error.message=="timeout"->NetworkQualityObserver.Sample.Timeout
                    error is IOException->NetworkQualityObserver.Sample.TransportFailure
                    else->NetworkQualityObserver.Sample.LocalProcessing
                }
                owner.recordQuality(sample,work.service)
            }
            throw error
        }
    }
    private suspend fun executeUnscheduled(request: Request, maximumBytes: Long, allowArray: Boolean,
        emptyTerminalStatuses: Set<Int>, decodeJsonBody: Boolean,measurement:HTTPMeasurement,
        onStarted:()->Unit={},onBody:()->Unit={},onHeaders:(Response)->Unit={}): EdgeResponse = withContext(Dispatchers.IO) {
        val call = http.newCall(request.newBuilder().tag(HTTPMeasurement::class.java,measurement).build())
        val drained=CompletableDeferred<Unit>();var callbackExpected=false
        try {suspendCancellableCoroutine { continuation ->
        continuation.invokeOnCancellation { call.cancel() }
        try {continuation.context.ensureActive();callbackExpected=true;onStarted();measurement.started();call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) { try {if (continuation.isActive) continuation.resumeWithException(e)} finally {drained.complete(Unit)} }
            override fun onResponse(call: Call, response: Response) {
                try {
                    val result = response.use {
                        measurement.headers(it.code)
                        onHeaders(it)
                        val body = it.body ?: throw ClientFailure.Protocol()
                        // Stream cap also applies when Content-Length is omitted or dishonest.
                        val source = body.source()
                        try {source.request(maximumBytes + 1)} finally {measurement.body(source.buffer.size,false)}
                        if (source.buffer.size > maximumBytes) throw ClientFailure.Protocol()
                        measurement.body(source.buffer.size,true)
                        val text = source.readUtf8()
                        onBody()
                        val json = if (it.code in emptyTerminalStatuses) {
                            if (text.isNotEmpty()) throw ClientFailure.Protocol()
                            JsonObject(emptyMap())
                        } else if (!decodeJsonBody) JsonObject(emptyMap()) else {
                            if (body.contentType()?.subtype != "json") {
                                if (it.isSuccessful) throw ClientFailure.Protocol()
                                JsonObject(emptyMap())
                            } else Json.parseToJsonElement(text)
                        }
                        when(json) {
                            is JsonObject -> EdgeResponse(it.code, json, it.header("Retry-After"))
                            is JsonArray -> { if(!allowArray) throw ClientFailure.Protocol();EdgeResponse(it.code,JsonObject(emptyMap()),it.header("Retry-After"),json) }
                            else -> throw ClientFailure.Protocol()
                        }
                    }
                    if (continuation.isActive) continuation.resume(result)
                } catch (e: Exception) { if (continuation.isActive) continuation.resumeWithException(e) } finally {drained.complete(Unit)}
            }
        })} catch(error:Exception) {drained.complete(Unit);if(continuation.isActive) continuation.resumeWithException(error)}
        }} finally {call.cancel();if(callbackExpected) withContext(NonCancellable) {drained.await()}}
    }
}

internal fun EdgeResponse.failure() = ClientFailure.Http(status, body["code"]?.jsonPrimitive?.contentOrNull, retryAfter)

/** A response may only escape into the account/device generation that issued it. */
interface AuthenticatedTransport {
    /** Fresh message-media authority: one GET, no 401 replay, provider credentials checked before exposure. */
    suspend fun mediaTarget(path: String,query: Map<String,String>,maximumBytes: Long): EdgeResponse = throw UnsupportedOperationException("Media authorization unavailable")
    /** Validate provider capabilities against the business credential before they leave the auth boundary. */
    suspend fun requestWithResourcePlans(path: String, payload: JsonObject? = null, maximumBytes: Long = 65_536): EdgeResponse = request(path,payload,maximumBytes=maximumBytes)
    suspend fun requestArray(path: String, payload: JsonObject, maximumBytes: Long = 524_288): EdgeResponse = throw UnsupportedOperationException("Array response unavailable")
    suspend fun putWithoutReplay(path: String, payload: JsonObject, maximumBytes: Long = 65_536): EdgeResponse = throw UnsupportedOperationException("PUT unavailable")
    /** Commands with one-shot submission authority must not be replayed after an HTTP 401. */
    suspend fun requestWithoutReplay(path: String, payload: JsonObject, maximumBytes: Long = 65_536): EdgeResponse = request(path, payload, maximumBytes = maximumBytes)
    suspend fun request(path: String, payload: JsonObject? = null, query: Pair<String, String>? = null,
        maximumBytes: Long = 65_536): EdgeResponse
    suspend fun requestWithQuery(path: String, query: Map<String, String>, maximumBytes: Long): EdgeResponse {
        require(query.size <= 1)
        return request(path, query = query.entries.singleOrNull()?.let { it.key to it.value }, maximumBytes = maximumBytes)
    }
}
class AuthenticatedApi(private val auth: AuthSession, private val transport: EdgeTransport,
    private val account: UserId, private val device: DeviceId,private val scheduler:AccountWorkScheduler?=null,
    private val epoch:AuthSessionEpoch=auth.currentEpoch()) : AuthenticatedTransport {
    private suspend fun <T> scheduled(body:suspend ()->T):T {
        val owner=scheduler ?: return body()
        val inherited=currentCoroutineContext().networkWorkFor(owner)
        return withContext(NetworkWorkScope(owner,inherited ?: NetworkWorkContext("account"))) {body()}
    }
    override suspend fun mediaTarget(path: String,query: Map<String,String>,maximumBytes: Long): EdgeResponse = scheduled {
        val credential=auth.access(expectedEpoch = epoch)
        if(credential.userId!=account || credential.deviceId!=device) throw ClientFailure.SignedOut()
        val response=transport.requestWithQuery(path,credential,query,maximumBytes)
        val current=auth.current(expectedEpoch = epoch)
        if(current?.userId!=account || current.deviceId!=device) throw ClientFailure.SignedOut()
        rejectBearer(response.body,credential.accessToken)
        response
    }
    override suspend fun requestWithResourcePlans(path: String,payload: JsonObject?,maximumBytes: Long): EdgeResponse = authenticated { credential ->
        transport.request(path,credential,payload,maximumBytes=maximumBytes).also { rejectBearer(it.body,credential.accessToken) }
    }
    override suspend fun request(path: String, payload: JsonObject?, query: Pair<String, String>?,
        maximumBytes: Long): EdgeResponse {
        return authenticated { credential -> transport.request(path, credential, payload, query, maximumBytes) }
    }
    override suspend fun requestWithQuery(path: String, query: Map<String, String>, maximumBytes: Long) =
        authenticated { credential -> transport.requestWithQuery(path, credential, query, maximumBytes) }
    override suspend fun requestWithoutReplay(path: String, payload: JsonObject, maximumBytes: Long): EdgeResponse = scheduled {
        val credential = auth.access(expectedEpoch = epoch)
        if(credential.userId != account || credential.deviceId != device) throw ClientFailure.SignedOut()
        val result = transport.request(path, credential, payload, maximumBytes = maximumBytes)
        val current = auth.current(expectedEpoch = epoch)
        if(current?.userId != account || current.deviceId != device) throw ClientFailure.SignedOut()
        result
    }
    override suspend fun requestArray(path: String, payload: JsonObject, maximumBytes: Long): EdgeResponse = authenticated { credential ->
        val response = transport.requestArray(path,credential,payload,maximumBytes)
        response.arrayBody?.let { body ->
            rejectBearer(body,credential.accessToken)
        }
        response
    }
    override suspend fun putWithoutReplay(path: String, payload: JsonObject, maximumBytes: Long): EdgeResponse = scheduled {
        val credential = auth.access(expectedEpoch = epoch)
        if(credential.userId != account || credential.deviceId != device) throw ClientFailure.SignedOut()
        val result = transport.put(path, credential, payload, maximumBytes)
        val current = auth.current(expectedEpoch = epoch)
        if(current?.userId != account || current.deviceId != device) throw ClientFailure.SignedOut()
        result
    }
    private suspend fun authenticated(send: suspend (Credentials) -> EdgeResponse): EdgeResponse = scheduled {
        var credential = auth.access(expectedEpoch = epoch)
        fun checkIdentity(value: Credentials?) { if (value?.userId != account || value.deviceId != device) throw ClientFailure.SignedOut() }
        checkIdentity(credential)
        var result = send(credential)
        if (result.status == 401) {
            credential = auth.access(rejectedAccess = credential, expectedEpoch = epoch)
            checkIdentity(credential)
            result = send(credential)
        }
        checkIdentity(auth.current(expectedEpoch = epoch))
        result
    }
    private fun rejectBearer(body: JsonElement,bearer: String) {
        // Inspect keys and values, including encoded URLs, before any provider GET is possible.
        fun contains(value: JsonElement): Boolean = when(value) {
            is JsonObject -> value.any { contains(JsonPrimitive(it.key)) || contains(it.value) }
            is JsonArray -> value.any(::contains)
            is JsonPrimitive -> {
                val raw=value.content
                val decoded=java.net.URLDecoder.decode(raw.replace(Regex("%(?![0-9a-fA-F]{2})"),"%25"),"UTF-8")
                raw.contains(bearer) || decoded.contains(bearer)
            }
        }
        if(contains(body)) throw ClientFailure.Protocol()
    }
}

internal fun JsonObject.string(key: String): String = get(key)?.jsonPrimitive?.content?.takeIf { it.isNotBlank() } ?: throw ClientFailure.Protocol()
internal fun JsonObject.number(key: String): Long = get(key)?.jsonPrimitive?.longOrNull ?: throw ClientFailure.Protocol()
