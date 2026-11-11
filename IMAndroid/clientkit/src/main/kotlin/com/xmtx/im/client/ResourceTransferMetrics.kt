package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.flow.*
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext

/** Body stream counters exclude headers/TLS framing and never prove provider acceptance. */
data class ResourceTransferMetric(val mode:Mode,val statusCode:Int?,val bodyBytesSent:Long,val bodyBytesReceived:Long,
    val elapsedNanos:Long,val retryAttempt:Boolean,val cancelled:Boolean,val failed:Boolean,
    val verifiedRangeRebuildPrefixBytes:Long?=null) {
    enum class Mode { Upload,MultipartUpload,Download,RangeDownload }
    enum class Response { Absent,SuccessStatus,PartialResponse,FullResponseForRange,RangeUnsatisfied,Other }
    init {require(statusCode==null || statusCode in 100..599);require(bodyBytesSent>=0 && bodyBytesReceived>=0 && elapsedNanos>=0)
        require(verifiedRangeRebuildPrefixBytes==null || mode==Mode.RangeDownload && statusCode==200 && verifiedRangeRebuildPrefixBytes in 0..bodyBytesReceived)}
    val response:Response get()=when {
        statusCode==null->Response.Absent
        statusCode==206 && mode==Mode.RangeDownload->Response.PartialResponse
        statusCode==200 && mode==Mode.RangeDownload->Response.FullResponseForRange
        statusCode==416->Response.RangeUnsatisfied
        statusCode in 200..299->Response.SuccessStatus
        else->Response.Other
    }
}
/** Account-local bounded diagnostics. No endpoint, identity, headers, body or error description. */
class NetworkDiagnostics {
    data class Snapshot(val recorded:Long=0,val samples:PersistentList<ResourceTransferMetric> = persistentListOf(),val closed:Boolean=false,
        val resourceRecorded:Long=0,val backgroundRecorded:Long=0,val backgrounds:PersistentList<ResourceBackgroundTransferMetric> = persistentListOf(),
        val httpRecorded:Long=0,val http:PersistentList<NetworkMetric> = persistentListOf(),
        val operationRecorded:Long=0,val operations:PersistentList<OperationStepMetric> = persistentListOf(),
        val projectionRecorded:Long=0,val projections:PersistentList<ProjectionMetric> = persistentListOf())
    private val lock=Any();private val mutable=MutableStateFlow(Snapshot())
    val state:StateFlow<Snapshot> = mutable.asStateFlow()
    fun snapshot()=mutable.value
    fun record(metric:ResourceTransferMetric)=synchronized(lock) {
        val old=mutable.value;if(old.closed) return
        val window=if(old.samples.size==128) old.samples.removeAt(0) else old.samples
        mutable.value=old.copy(recorded=increment(old.recorded),resourceRecorded=increment(old.resourceRecorded),samples=window.add(metric))
    }
    fun record(metric:ResourceBackgroundTransferMetric)=synchronized(lock) {
        val old=mutable.value;if(old.closed) return
        val window=if(old.backgrounds.size==128) old.backgrounds.removeAt(0) else old.backgrounds
        mutable.value=old.copy(recorded=increment(old.recorded),backgroundRecorded=increment(old.backgroundRecorded),backgrounds=window.add(metric))
    }
    fun record(metric:NetworkMetric)=synchronized(lock) {
        val old=mutable.value;if(old.closed) return
        val window=if(old.http.size==128) old.http.removeAt(0) else old.http
        mutable.value=old.copy(recorded=increment(old.recorded),httpRecorded=increment(old.httpRecorded),http=window.add(metric))
    }
    private fun increment(value:Long)=if(value==Long.MAX_VALUE) value else value+1
    fun record(metric:OperationStepMetric)=synchronized(lock) {
        val old=mutable.value;if(old.closed) return
        val window=if(old.operations.size==128) old.operations.removeAt(0) else old.operations
        mutable.value=old.copy(recorded=increment(old.recorded),operationRecorded=increment(old.operationRecorded),operations=window.add(metric))
    }
    fun record(metric:ProjectionMetric)=synchronized(lock) {
        val old=mutable.value;if(old.closed) return
        val window=if(old.projections.size==128) old.projections.removeAt(0) else old.projections
        mutable.value=old.copy(recorded=increment(old.recorded),projectionRecorded=increment(old.projectionRecorded),projections=window.add(metric))
    }
    fun close()=synchronized(lock) {mutable.value=mutable.value.copy(samples=persistentListOf(),backgrounds=persistentListOf(),http=persistentListOf(),operations=persistentListOf(),projections=persistentListOf(),closed=true)}
}
/** Legacy Kotlin name; the shared snapshot type is NetworkDiagnostics.Snapshot. */
typealias ResourceTransferDiagnostics = NetworkDiagnostics
/** Standalone adapters can opt in; an account scope always selects its own diagnostics. */
class ResourceTransferDiagnosticsScope(val diagnostics:ResourceTransferDiagnostics):AbstractCoroutineContextElement(Key) {
    companion object Key:CoroutineContext.Key<ResourceTransferDiagnosticsScope>
}
internal class MeasuredResourceTransfer(val metric:ResourceTransferMetric,private val diagnostics:ResourceTransferDiagnostics) {
    private val recorded=AtomicBoolean()
    fun record(verifiedPrefixBytes:Long?=null) {
        if(recorded.compareAndSet(false,true)) diagnostics.record(metric.copy(verifiedRangeRebuildPrefixBytes=
            verifiedPrefixBytes?.takeIf {metric.mode==ResourceTransferMetric.Mode.RangeDownload && metric.statusCode==200 && it in 0..metric.bodyBytesReceived}))
    }
}
/** Only instantiated after byte admission. Completion is recorded after the physical callback drains. */
internal class ResourceTransferMeasurement(context:CoroutineContext,private val mode:ResourceTransferMetric.Mode,
    private val nanoTime:()->Long=System::nanoTime) {
    private val owner=context[NetworkWorkScope]?.scheduler
    private val diagnostics=owner?.transferDiagnostics ?: context[ResourceTransferDiagnosticsScope]?.diagnostics
    private val retry=owner?.let {context.networkWorkFor(it)?.isRetry} ?: context[NetworkWorkIntent]?.isRetry ?: false
    private val start=nanoTime();private val started=AtomicBoolean();private val finished=AtomicBoolean()
    private val status=AtomicInteger();private val sent=AtomicLong();private val received=AtomicLong()
    private val cancelled=AtomicBoolean();private val failed=AtomicBoolean()
    fun start() {started.set(true)}
    fun headers(code:Int) {status.set(code)}
    fun sent(bytes:Long) {sent.set(bytes)}
    fun received(bytes:Long) {if(bytes>0) received.addAndGet(bytes)}
    fun cancel() {cancelled.set(true);failed.set(true)}
    fun fail() {failed.set(true)}
    fun finish():MeasuredResourceTransfer? {
        if(!finished.compareAndSet(false,true) || !started.get() || diagnostics==null) return null
        return MeasuredResourceTransfer(ResourceTransferMetric(mode,status.get().takeIf {it!=0},sent.get(),received.get(),
            (nanoTime()-start).coerceAtLeast(0),retry,cancelled.get(),failed.get()),diagnostics)
    }
}
