package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.*

/** One bounded control request per call. Stable locators route requests; they never authorize byte access. */
class ResourceUploadClient(private val api: AuthenticatedTransport,private val actor: UserId,private val now:()->Long=System::currentTimeMillis,private val nanoTime:()->Long=System::nanoTime): ResourceUploadControl,ResourceBackgroundUploadControl {
    suspend fun capabilities(): ResourceCapabilities = withTimeout(5_000) {
        val response = api.request("/v2/resource-capabilities",maximumBytes = 524288);response.requireResourceSuccess();ResourceCapabilities.decode(response.body)
    }
    override suspend fun create(request: ResourceUploadRequest): ResourceUploadSession = withTimeout(30_000) {
        require(request.modes.all { it in supportedModes })
        val response = api.requestWithoutReplay("/v2/resource-uploads",request.payload(),524288);response.requireResourceSuccess()
        ResourceUploadSession.decode(response.body).also { require(it.media == request.media && it.locator.home == request.usage.home(actor));validateParts(it,request.byteCount) }
    }
    override suspend fun status(previous: ResourceUploadSession): ResourceUploadSession = withTimeout(30_000) {
        val response = api.request("/v2/resource-uploads/status",previous.locator.payload(),maximumBytes = 524288);response.requireResourceSuccess()
        bound(ResourceUploadSession.decode(response.body),previous)
    }
    /** Returns an ephemeral full PUT or a managed-slice part PUT. Background grants are never requested. */
    override suspend fun target(session: ResourceUploadSession,request: ResourceUploadRequest): ResourceTransferPlan? = withTimeout(30_000) {
        require(session.media == request.media && session.locator.home == request.usage.home(actor))
        require(session.state in setOf(ResourceSessionState.Created,ResourceSessionState.Uploading))
        val payload = buildJsonObject { put("locator",session.locator.payload());put("generation",session.generation);put("partNumbers",JsonArray(emptyList()));put("background",false) }
        val response = api.requestArray("/v2/resource-uploads/targets",payload,524288);response.requireResourceSuccess()
        val plans = requireNotNull(response.arrayBody);require(plans.size <= 1)
        plans.singleOrNull()?.let { ResourceTransferPlan.decode(it.jsonObject).also { plan ->
            require(plan.backgroundUpload==null && plan.mode in supportedModes && plan.mode in request.modes)
            if(plan.mode == ResourceTransferMode.Put) require(plan.expectedBytes == request.byteCount && (plan.checksum == null || plan.checksum == request.checksum))
            else require(plan.range != null && plan.range.upper < request.byteCount && plan.expectedBytes > 0)
        } }
    }
    /** Explicit opt-in for a provider-delegated OS handoff; ordinary engine targets remain ephemeral. */
    override suspend fun backgroundTargets(session:ResourceUploadSession,request:ResourceUploadRequest,
        parts:PersistentList<Int>):PersistentList<ResourceBackgroundUploadTarget> = withTimeout(30_000) {
        require(request.usage is ResourceUsage.Attachment && request.byteCount<=256L*1024*1024 && request.modes.all {it in supportedModes})
        require(session.media==request.media && session.locator.home==request.usage.home(actor))
        require(session.state in setOf(ResourceSessionState.Created,ResourceSessionState.Uploading))
        require(parts.size<=16 && parts.distinct().size==parts.size && parts.all {it in 1..32})
        require(parts.isEmpty() || ResourceTransferMode.PartPut in request.modes)
        val wall=now();val monotonic=nanoTime()
        require(wall>0 && session.expiresAt>wall)
        val payload=buildJsonObject {
            put("locator",session.locator.payload());put("generation",session.generation)
            put("partNumbers",JsonArray(parts.sorted().map(::JsonPrimitive)));put("background",true)
        }
        val response=api.requestArray("/v2/resource-uploads/targets",payload,524288);response.requireResourceSuccess()
        val plans=requireNotNull(response.arrayBody).also {require(it.size<=if(parts.isEmpty()) 1 else parts.size)}
            .map {ResourceTransferPlan.decode(it.jsonObject)}
        require(plans.map {requireNotNull(it.backgroundUpload).id}.distinct().size==plans.size)
        require(plans.map {it.part}.distinct().size==plans.size)
        plans.map {plan->
            val grant=requireNotNull(plan.backgroundUpload)
            require(plan.mode in supportedModes && plan.mode in request.modes && grant.expiresAt<=session.expiresAt)
            require(parts.isEmpty() || plan.part in parts)
            val remaining=Math.subtractExact(grant.expiresAt,wall)
            require(remaining>0)
            ResourceBackgroundUploadTarget(plan,session,request,monotonic+remaining.coerceAtMost(900_000)*1_000_000,now,nanoTime).also {it.requireValid(session,request)}
        }.toPersistentList()
    }
    override suspend fun finalize(session: ResourceUploadSession): ResourceUploadSession = withTimeout(30_000) {
        val body = buildJsonObject { put("locator",session.locator.payload());put("generation",session.generation);put("parts",JsonArray(session.parts.sortedBy { it.number }.map { it.payload() })) }
        val response = api.requestWithoutReplay("/v2/resource-uploads/finalize",body,524288);response.requireResourceSuccess();bound(ResourceUploadSession.decode(response.body),session)
    }
    override suspend fun cancel(session: ResourceUploadSession): ResourceUploadSession = withTimeout(30_000) {
        val body = buildJsonObject { put("locator",session.locator.payload());put("generation",session.generation) }
        val response = api.request("/v2/resource-uploads/cancel",body,maximumBytes = 524288);response.requireResourceSuccess();bound(ResourceUploadSession.decode(response.body),session)
    }
    private fun bound(value: ResourceUploadSession,previous: ResourceUploadSession): ResourceUploadSession {
        require(value.locator == previous.locator && value.media == previous.media && value.generation >= previous.generation)
        return value
    }
    private fun validateParts(session: ResourceUploadSession,bytes: Long) {
        var total = 0L;for(part in session.parts) { require(part.byteCount <= bytes-total);total += part.byteCount }
    }
    companion object { val supportedModes = persistentListOf(ResourceTransferMode.Put,ResourceTransferMode.PartPut) }
}
private fun EdgeResponse.requireResourceSuccess() { if(status !in 200..299) throw failure() }
