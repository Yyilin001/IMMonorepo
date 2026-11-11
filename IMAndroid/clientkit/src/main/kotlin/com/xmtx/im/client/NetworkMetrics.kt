package com.xmtx.im.client

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException
import okhttp3.Protocol
import java.io.IOException
import java.io.InterruptedIOException
import java.net.SocketTimeoutException
import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext

/** Completed observed phases only; connect includes TLS in OkHttp. Missing phases remain null.
 * Durations sum completed occurrences within this call; they are not a disjoint wall-clock breakdown.
 */
data class HTTPPhaseTiming(val dnsNanos:Long?=null,val connectNanos:Long?=null,val tlsNanos:Long?=null,
    val requestNanos:Long?=null,val responseNanos:Long?=null,val networkProtocol:HTTPProtocol?=null) {
    init {require(listOf(dnsNanos,connectNanos,tlsNanos,requestNanos,responseNanos).all {it==null || it>=0})}
}
enum class HTTPProtocol { Http10,Http11,Http2,H2PriorKnowledge,Spdy3,Quic }

/** No URL, headers, identity, body, ordering key or free-form failure text is retained.
 * reusedConnection is true only when acquisition occurs without a connect attempt; otherwise unknown.
 * OkHttp may discard a newly created connection in favor of a pooled multiplexed connection.
 * receivedBytes counts decoded body bytes buffered by this client, excluding headers/TLS framing.
 */
data class NetworkMetric(val service:Service,val elapsedNanos:Long,val queuedNanos:Long,val receivedBytes:Long,
    val statusCode:Int?,val failure:Failure?,val cancelled:Boolean,val priority:NetworkWorkPriority,
    val isRetry:Boolean,val certainty:Certainty,val phases:HTTPPhaseTiming=HTTPPhaseTiming(),
    val transactionCount:Int=0,val reusedConnection:Boolean?=null) {
    enum class Service { Account,Authentication }
    enum class Failure { Admission,DeadlineExceeded,Transport,InvalidResponse,LocalProcessing }
    enum class Certainty { NotStarted,OutcomeUnknown,ResponseReceived }
    init {require(elapsedNanos>=0 && queuedNanos>=0 && receivedBytes>=0 && transactionCount>=0)
        require(statusCode==null || statusCode in 100..599)}
}

/** Standalone HTTP diagnostics; an explicitly selected account owner takes precedence. */
class NetworkDiagnosticsScope(val diagnostics:NetworkDiagnostics):AbstractCoroutineContextElement(Key) {
    companion object Key:CoroutineContext.Key<NetworkDiagnosticsScope>
}

internal class HTTPMeasurement(private val diagnostics:NetworkDiagnostics?,private val work:NetworkWorkContext,
    private val nanoTime:()->Long=System::nanoTime) {
    private val lock=Any()
    private val queuedAt=nanoTime()
    private var admittedAt:Long?=null
    private var started=false
    private var completeBody=false
    private var status:Int?=null
    private var received=0L
    private var recorded=false
    private var transactions=0
    private var reused:Boolean?=null
    private var connecting=false
    private var protocol:HTTPProtocol?=null
    enum class Phase { DNS,Connect,TLS,Request,Response }
    private val starts=mutableMapOf<Phase,Long>()
    private val durations=mutableMapOf<Phase,Long>()
    fun admitted()=synchronized(lock) {if(admittedAt==null) admittedAt=nanoTime()}
    fun started()=synchronized(lock) {started=true}
    fun headers(code:Int)=synchronized(lock) {status=code.takeIf {it in 100..599}}
    fun body(bytes:Long,complete:Boolean)=synchronized(lock) {received=maxOf(received,bytes);completeBody=completeBody || complete}
    fun begin(phase:Phase)=synchronized(lock) {
        starts[phase]=nanoTime()
        if(phase==Phase.Connect) connecting=true
        if(phase==Phase.Request && transactions<Int.MAX_VALUE) transactions++
    }
    fun end(phase:Phase)=synchronized(lock) {
        val start=starts.remove(phase) ?: return
        val duration=(nanoTime()-start).coerceAtLeast(0)
        val old=durations[phase] ?: 0
        durations[phase]=if(Long.MAX_VALUE-old<duration) Long.MAX_VALUE else old+duration
    }
    fun connected(value:Protocol)=synchronized(lock) {
        if(!connecting) reused=true
        connecting=false
        protocol=when(value) {
            Protocol.HTTP_1_0->HTTPProtocol.Http10;Protocol.HTTP_1_1->HTTPProtocol.Http11
            Protocol.HTTP_2->HTTPProtocol.Http2;Protocol.H2_PRIOR_KNOWLEDGE->HTTPProtocol.H2PriorKnowledge
            Protocol.SPDY_3->HTTPProtocol.Spdy3;Protocol.QUIC->HTTPProtocol.Quic
        }
    }
    /** Called before releasing physical admission, after cancellation has drained the callback. */
    fun finish(error:Throwable?):Unit=synchronized(lock) {
        if(recorded) return
        recorded=true
        val now=nanoTime()
        val failure=when(error) {
            null->null
            is AccountWorkScheduler.AdmissionException,is AccountRequestAdmissionFailure->NetworkMetric.Failure.Admission
            is TimeoutCancellationException,is AccountRequestDeadlineExceeded,is SocketTimeoutException->NetworkMetric.Failure.DeadlineExceeded
            is CancellationException->null
            is InterruptedIOException->if(error.message=="timeout") NetworkMetric.Failure.DeadlineExceeded else NetworkMetric.Failure.Transport
            is ClientFailure.Protocol,is kotlinx.serialization.SerializationException->NetworkMetric.Failure.InvalidResponse
            is IOException->NetworkMetric.Failure.Transport
            else->NetworkMetric.Failure.LocalProcessing
        }
        diagnostics?.record(NetworkMetric(
            service=if(work.kind==NetworkWorkKind.Authentication) NetworkMetric.Service.Authentication else NetworkMetric.Service.Account,
            elapsedNanos=admittedAt?.let {(now-it).coerceAtLeast(0)} ?: 0,
            queuedNanos=((admittedAt ?: now)-queuedAt).coerceAtLeast(0),receivedBytes=received,statusCode=status,
            failure=failure,cancelled=error is CancellationException && error !is TimeoutCancellationException,
            priority=work.priority,isRetry=work.isRetry,
            certainty=when {completeBody->NetworkMetric.Certainty.ResponseReceived;started->NetworkMetric.Certainty.OutcomeUnknown;else->NetworkMetric.Certainty.NotStarted},
            phases=HTTPPhaseTiming(durations[Phase.DNS],durations[Phase.Connect],durations[Phase.TLS],durations[Phase.Request],durations[Phase.Response],protocol),
            transactionCount=transactions,reusedConnection=reused))
        Unit
    }
}
