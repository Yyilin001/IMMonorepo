package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.*
import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.toPersistentList
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.Closeable
import java.net.InetSocketAddress
import java.util.concurrent.atomic.AtomicLong
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
import kotlin.coroutines.coroutineContext

interface EnvelopeTransport { suspend fun request(body: Envelope.Builder): Envelope }
/** Captured once for a durable attempt; neither requests nor cooldowns follow a later login. */
internal data class EnvelopeRequestSession(val transport:EnvelopeTransport,val scheduler:AccountWorkScheduler?)
/** This request never entered a session's pending/write queue. Earlier attempts may still be unknown. */
class RealtimeUnavailableBeforeAdmission(val reason:AccountWorkScheduler.Rejection?=null): java.io.IOException("Realtime connection unavailable before request admission")
/** One connection owner; socket close unblocks outstanding reads on background/logout. No mutation replay. */
class RealtimeConnection(private val host: String, private val port: Int,
    private val factory: SSLSocketFactory = SSLSocketFactory.getDefault() as SSLSocketFactory,
    private val requestTimeoutMillis: Long = 15_000,
    private val maximumPendingRequests: Int = 16,
    private val authorPresentations: Boolean = false) : EnvelopeTransport, RoomProgressConnection, AuthorPresentationSource, RealtimeCoverageSource, Closeable {
    init { require(requestTimeoutMillis > 0 && maximumPendingRequests in 1..32) }
    private val mutex = Mutex()
    private val ids = AtomicLong(0)
    private val lock = Any()
    private var session: Session? = null
    private var nextEpoch = 0L
    private var activitySequence = 0L
    val serverTime = ServerTimeAnchor()
    val latestActivitySequence: Long get() = synchronized(lock) { activitySequence }
    private val mutableState = MutableStateFlow(RealtimeConnectionState())
    val state = mutableState.asStateFlow()
    private val mutableCoverage = MutableStateFlow(RealtimeCoverageSnapshot())
    override val realtimeCoverage = mutableCoverage.asStateFlow()
    private val mutableEvents = MutableSharedFlow<RealtimeActivityEvent>(extraBufferCapacity = 128)
    /** Collect before subscribing. Overflow ends the connection instead of keeping potentially stale leases. */
    val activityEvents = mutableEvents.asSharedFlow()
    private val mutableSyncEvents = MutableSharedFlow<RealtimeSyncEvent>(extraBufferCapacity = 128)
    val syncEvents = mutableSyncEvents.asSharedFlow()
    private class Session(val socket: SSLSocket, val epoch: Long, maximumPending: Int,val scheduler:AccountWorkScheduler?) {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val pending = mutableMapOf<Long,Pending>()
        val admission = Semaphore(maximumPending)
        val controlAdmission=Semaphore(1)
        val writes = Mutex()
        var authenticated = false
        var accountEpoch: String? = null
        var accountRetired = false
        var authors: AuthorPresentationInbox? = null
        val authorWake = Channel<Unit>(Channel.CONFLATED)
        val coverage = RealtimeCoverageTracker(epoch)
    }
    private class Pending(val id: Long,val admission:Semaphore, val startsAccountChanges: Boolean = false, val heartbeat: Boolean = false, var authorStart: AuthorPresentationView? = null,
        val response: CompletableDeferred<Envelope> = CompletableDeferred())
    suspend fun connect(credentials: Credentials,scheduler:AccountWorkScheduler?=null) = mutex.withLock {
        var installed: Session? = null
        try { withContext(Dispatchers.IO) {
            coroutineContext.ensureActive()
            close()
            val connection = factory.createSocket() as SSLSocket
            val owner = synchronized(lock) { Session(connection, ++nextEpoch, maximumPendingRequests,scheduler).also { session = it; installed = it } }
            try {
                // Cancellation may have closed the previous session while the socket factory was
                // still creating this socket. Check again after ownership is installed, before I/O.
                coroutineContext.ensureActive()
                connection.sslParameters = connection.sslParameters.apply { endpointIdentificationAlgorithm = "HTTPS" }
                connection.soTimeout = 15_000
                connection.connect(InetSocketAddress(host, port), 10_000)
                connection.startHandshake()
                coroutineContext.ensureActive()
                val hello = handshakeExchange(owner, Envelope.newBuilder().setClientHello(ClientHello.newBuilder()
                    .addSupportedProtocolVersions(FrameCodec.VERSION).addSupportedCapabilityProfiles("base")
                    .setDeviceId(credentials.deviceId.value).setSupportsMessageSendOperations(true).setSupportsAuthorPresentationDelta(authorPresentations)), 0)
                val helloReceivedAt = System.nanoTime()
                if (!hello.hasServerHello() || hello.serverHello.serverTimeMs <= 0 || hello.serverHello.selectedProtocolVersion != FrameCodec.VERSION ||
                    hello.serverHello.selectedCapabilityProfile != "base" || !authorPresentations && hello.serverHello.authorPresentationStreamId.isNotEmpty() || !hello.serverHello.supportsMessageSendOperations ||
                    hello.serverHello.maximumMessageSendPayloadBytes < FrameCodec.MAX_PAYLOAD || hello.serverHello.selectedFrameCompressionValue != 0)
                    throw ClientFailure.Protocol()
                val authorStream=try {hello.serverHello.authorPresentationStreamId.takeIf {it.isNotEmpty()}?.let(::uuidId)}
                    catch(_: IllegalArgumentException) {throw ClientFailure.Protocol()}
                val authenticated = handshakeExchange(owner, Envelope.newBuilder().setAuthenticate(Authenticate.newBuilder()
                    .setAccessToken(credentials.accessToken).setDeviceId(credentials.deviceId.value).setPresencePublicationSuppressed(true)), FrameCodec.VERSION)
                if (!authenticated.hasAuthenticated() || UserId(authenticated.authenticated.userId) != credentials.userId ||
                    DeviceId(authenticated.authenticated.deviceId) != credentials.deviceId ||
                    authenticated.authenticated.selectedCapabilityProfile != "base" ||
                    authenticated.authenticated.selectedFrameCompressionValue != 0 ||
                    authenticated.authenticated.authorPresentationStreamId != hello.serverHello.authorPresentationStreamId ||
                    !authenticated.authenticated.supportsMessageSendOperations ||
                    authenticated.authenticated.maximumMessageSendPayloadBytes != hello.serverHello.maximumMessageSendPayloadBytes) throw ClientFailure.Protocol()
                coroutineContext.ensureActive()
                connection.soTimeout = 0 // The receive pump is idle-safe; each command has its own deadline.
                synchronized(lock) {
                    if (session !== owner) throw java.io.IOException("Realtime connection closed")
                    serverTime.observe(hello.serverHello.serverTimeMs, helloReceivedAt)
                    owner.authenticated = true
                    owner.authors=authorStream?.let {AuthorPresentationInbox(it,credentials.userId,credentials.deviceId)}
                    mutableCoverage.value = owner.coverage.snapshot()
                    mutableState.value = RealtimeConnectionState(owner.epoch, true,authorStream)
                    owner.scope.launch { receive(owner) }
                }
            } catch (e: Exception) { close(owner, e); throw e }
        } } catch (e: Exception) {
            // withContext has prompt cancellation on its return boundary, after authentication too.
            installed?.let { close(it, e) }
            throw e
        }
    }
    override val authenticatedEpoch: Long? get()=synchronized(lock) {session?.takeIf {it.authenticated}?.epoch}
    override fun roomProgressScope(): RoomProgressScope?=synchronized(lock) {session?.takeIf {it.authenticated}?.let {it.coverage.room(it.epoch)}}
    override suspend fun requestHeartbeat(heartbeat: Heartbeat,expectedEpoch: Long): Envelope =
        request(Envelope.newBuilder().setHeartbeat(heartbeat),expectedEpoch)
    override fun acceptRoomProgressHead(scope: RoomProgressScope,head: Long) {
        require(head>=0)
        val owner=synchronized(lock) {
            val current=session ?: return
            if(!current.authenticated || current.epoch!=scope.connectionEpoch || current.coverage.room(current.epoch)!=scope) return
            if(mutableSyncEvents.tryEmit(RealtimeSyncEvent(current.epoch,RealtimeSyncHint.Room(scope.room,head)))) null else current
        }
        if(owner!=null) close(owner,java.io.IOException("Realtime sync consumer fell behind"))
    }
    override suspend fun request(body: Envelope.Builder): Envelope=request(body,null)
    internal fun captureRequestSession():EnvelopeRequestSession {
        val owner=synchronized(lock) {session?.takeIf {it.authenticated}}
            ?: throw RealtimeUnavailableBeforeAdmission()
        return EnvelopeRequestSession(object:EnvelopeTransport {
            override suspend fun request(body:Envelope.Builder)=request(owner,body.build())
        },owner.scheduler)
    }
    private suspend fun request(body: Envelope.Builder,expectedEpoch: Long?): Envelope {
        coroutineContext.ensureActive()
        // Capture the owner before waiting: an old queued command must never migrate onto a new login.
        val owner=synchronized(lock) {session?.takeIf {it.authenticated && (expectedEpoch==null || it.epoch==expectedEpoch)}}
            ?: throw RealtimeUnavailableBeforeAdmission()
        // Freeze the caller-owned builder before either local or account admission can suspend.
        val frozen=body.build()
        return request(owner,frozen)
    }
    private suspend fun request(owner:Session,frozen:Envelope):Envelope {
        coroutineContext.ensureActive()
        synchronized(lock) {if(session!==owner || !owner.authenticated) throw RealtimeUnavailableBeforeAdmission()}
        val context=RealtimeFramePolicy.of(frozen).context(owner.scheduler?.let {coroutineContext.networkWorkFor(it)})
        val scheduler=owner.scheduler ?: return requestOwned(owner,frozen,false,owner.admission,null)
        val started=System.nanoTime()
        // Keep the handle outside the timeout scope: cancellation can win after acquire returns.
        var permit:AccountWorkScheduler.Permit?=null
        try {
            if(withTimeoutOrNull(requestTimeoutMillis) {permit=scheduler.acquire(context);true}!=true)
                throw RealtimeUnavailableBeforeAdmission(AccountWorkScheduler.Rejection.DeadlineExceeded)
            val remaining=requestTimeoutMillis-(System.nanoTime()-started)/1_000_000
            if(remaining<=0) throw RealtimeUnavailableBeforeAdmission(AccountWorkScheduler.Rejection.DeadlineExceeded)
            val admission=if(context.kind==NetworkWorkKind.Authentication) owner.controlAdmission else owner.admission
            return requestOwned(owner,frozen,true,admission,remaining)
        } catch(error:AccountWorkScheduler.AdmissionException) {throw RealtimeUnavailableBeforeAdmission(error.reason)}
        finally {withContext(NonCancellable) {permit?.let {scheduler.release(it)}}}
    }
    private suspend fun requestOwned(owner:Session,frozen:Envelope,holdPhysical:Boolean,admission:Semaphore,queueMillis:Long?):Envelope {
        var acquired=false
        try {
            if(queueMillis==null) {admission.acquire();acquired=true}
            else if(withTimeoutOrNull(queueMillis) {admission.acquire();acquired=true;true}!=true)
                throw RealtimeUnavailableBeforeAdmission(AccountWorkScheduler.Rejection.DeadlineExceeded)
        } catch(error:Throwable) {if(acquired) admission.release();throw error}
        var admitted=false
        var physical:Pending?=null
        var writer:Job?=null
        try {
            coroutineContext.ensureActive()
            val request=frozen.toBuilder().setRequestId(ids.incrementAndGet()).setProtocolVersion(FrameCodec.VERSION).build()
            val bytes=FrameCodec.encode(request)
            val pending=Pending(request.requestId,admission,request.hasAccountRoomChangesStart(),request.hasHeartbeat())
            synchronized(lock) {
                if(session !== owner) throw RealtimeUnavailableBeforeAdmission()
                if(pending.startsAccountChanges && ((owner.accountEpoch!=null && !owner.accountRetired) ||
                    owner.pending.values.any {it.startsAccountChanges})) throw ClientFailure.Protocol()
                when {
                    request.hasAuthorPresentationStart()->{
                        val value=request.authorPresentationStart
                        pending.authorStart=(owner.authors ?: throw ClientFailure.Protocol()).requested(AuthorPresentationStart(
                            value.streamId,value.viewId,value.messageRoomIdsList.map {RoomId(it)}.toPersistentList()))
                    }
                    request.hasAuthorPresentationInterests()->request.authorPresentationInterests.let {
                        (owner.authors ?: throw ClientFailure.Protocol()).requireIdentity(it.streamId,it.viewId)
                    }
                    request.hasAuthorPresentationReceipt()->request.authorPresentationReceipt.let {
                        (owner.authors ?: throw ClientFailure.Protocol()).requireIdentity(it.streamId,it.viewId)
                    }
                    request.hasAuthorPresentationEnd()->request.authorPresentationEnd.let {
                        (owner.authors ?: throw ClientFailure.Protocol()).requireIdentity(it.streamId,it.viewId,ending=true)
                    }
                }
                check(owner.pending.put(pending.id,pending)==null)
                admitted=true;physical=pending
            }
            // Physical work and its deadline belong to the session. Caller cancellation leaves the
            // correlation slot reserved until the late response, timeout or disconnect drains it.
            owner.scope.launch {
                try {withTimeout(requestTimeoutMillis) {pending.response.await()}}
                catch(e: TimeoutCancellationException) {close(owner,e)}
                catch(_: Exception) { /* A response failure or session close already owns cleanup. */ }
            }
            writer=owner.scope.launch {
                try {owner.writes.withLock {
                    coroutineContext.ensureActive()
                    owner.socket.outputStream.write(bytes);owner.socket.outputStream.flush()
                }} catch(e: Exception) {close(owner,e)}
            }
            val result=pending.response.await()
            result.throwGatewayFailure()
            return result
        } finally {
            // Once admitted, only receive/close may release physical capacity.
            if(!admitted) admission.release()
            else if(holdPhysical) withContext(NonCancellable) {
                // Caller cancellation cannot release an on-wire account permit. The session deadline,
                // a correlated reply, or socket close settles the response; then wait for the writer.
                try {physical!!.response.await()} catch(_:Exception) { /* Preserve the caller's original result. */ }
                writer?.join()
            }
        }
    }

    private suspend fun receive(owner: Session) {
        try {
            while (true) {
                coroutineContext.ensureActive()
                val result = FrameCodec.read(owner.socket.inputStream)
                synchronized(lock) {
                    if (session !== owner) return
                    if (result.requestId != 0L) {
                        val pending = owner.pending[result.requestId] ?: throw ClientFailure.Protocol()
                        if (pending.heartbeat && result.hasHeartbeatAck()) {
                            if (result.heartbeatAck.serverTimeMs <= 0) throw ClientFailure.Protocol()
                            serverTime.observe(result.heartbeatAck.serverTimeMs)
                        }
                        if(pending.startsAccountChanges && !result.hasError()) {
                            if(!result.hasAccountRoomChangesReady()) throw ClientFailure.Protocol()
                            val epoch=recoveryEpoch(result.accountRoomChangesReady.connectionEpoch)
                            if(epoch == owner.accountEpoch) throw ClientFailure.Protocol()
                            // Install before resuming the request: the next frame can already contain a reset.
                            owner.accountEpoch=epoch;owner.accountRetired=false
                        }
                        pending.authorStart?.let {expected->if(!result.hasError()) {
                            if(!result.hasAuthorPresentationStarted()) throw ClientFailure.Protocol()
                            val response=result.authorPresentationStarted
                            // Confirm before resuming the caller; the very next frame may be the first delta.
                            requireNotNull(owner.authors).confirm(expected,AuthorPresentationStart(response.streamId,response.viewId,
                                response.messageRoomIdsList.map {RoomId(it)}.toPersistentList()))
                        }}
                        owner.pending.remove(pending.id)
                        pending.admission.release()
                        pending.response.complete(result)
                    } else {
                        if(result.hasAuthorPresentationDelta()) {
                            (owner.authors ?: throw ClientFailure.Protocol()).accept(result.authorPresentationDelta.payload.toByteArray())
                            owner.authorWake.trySend(Unit)
                        }
                        if (result.hasRealtimeCoverage()) {
                            val coverage = RealtimeCoverageState.decode(result.realtimeCoverage, owner.epoch)
                            if (!owner.coverage.accept(coverage)) continue
                            mutableCoverage.value = owner.coverage.snapshot()
                        }
                        val hint = LiveActivityHint.decode(result)
                        if (hint != null && !mutableEvents.tryEmit(RealtimeActivityEvent(owner.epoch, hint, ++activitySequence)))
                            throw java.io.IOException("Realtime event consumer fell behind")
                        var syncHint = RealtimeSyncHint.decode(result)
                        if(syncHint is RealtimeSyncHint.AccountResync) {
                            if(owner.accountEpoch != syncHint.recoveryEpoch) throw ClientFailure.Protocol()
                            if(owner.accountRetired) syncHint=null else owner.accountRetired=true
                        }
                        if (syncHint != null && !mutableSyncEvents.tryEmit(RealtimeSyncEvent(owner.epoch,syncHint)))
                            throw java.io.IOException("Realtime sync consumer fell behind")
                        // No notification acknowledges durable delivery; the pull loop remains authoritative.
                    }
                }
            }
        } catch (e: Exception) { close(owner, e) }
    }

    /** Begin before sending AuthorPresentationClient.start. View ownership never crosses a reconnect. */
    override fun beginAuthorPresentationView(messageRooms: PersistentList<RoomId>): AuthorPresentationView=synchronized(lock) {
        val owner=session?.takeIf {it.authenticated} ?: throw RealtimeUnavailableBeforeAdmission()
        (owner.authors ?: throw IllegalStateException("Author presentation stream was not negotiated")).begin(messageRooms).also {owner.authorWake.trySend(Unit)}
    }
    /** Clears local delivery immediately. Send the exact remote end separately on its original connection. */
    override fun endAuthorPresentationView(view: AuthorPresentationView)=synchronized(lock) {
        session?.authors?.end(view);session?.authorWake?.trySend(Unit);Unit
    }
    override suspend fun nextAuthorPresentationDelta(view: AuthorPresentationView): ReceivedAuthorPresentationDelta {
        val owner=synchronized(lock) {session?.takeIf {it.authenticated}} ?: throw RealtimeUnavailableBeforeAdmission()
        while(true) {
            coroutineContext.ensureActive()
            val value=synchronized(lock) {
                if(session !== owner) throw RealtimeUnavailableBeforeAdmission()
                (owner.authors ?: throw ClientFailure.Protocol()).next(view)
            }
            if(value!=null) return value
            // A nonce expiry must also release an idle waiter without waiting for server traffic.
            val remaining=(view.renewByNanos-System.nanoTime()).coerceAtLeast(0)
            withTimeout(((remaining+999_999)/1_000_000).coerceAtLeast(1)) {owner.authorWake.receive()}
        }
    }

    private suspend fun handshakeExchange(owner: Session, body: Envelope.Builder, version: Int): Envelope {
        val current = owner.socket
        val request = body.setRequestId(ids.incrementAndGet()).setProtocolVersion(version).build()
        current.outputStream.write(FrameCodec.encode(request, version)); current.outputStream.flush()
        // Unsolicited hints do not acknowledge delivery; the durable pull loop remains authoritative.
        repeat(256) {
            coroutineContext.ensureActive()
            val result = FrameCodec.read(current.inputStream)
            if (result.requestId == request.requestId) {
                result.throwGatewayFailure()
                return result
            }
            if (result.requestId != 0L) throw ClientFailure.Protocol()
        }
        throw ClientFailure.Protocol()
    }
    private fun close(owner: Session, cause: Exception) {
        val pending=synchronized(lock) {
            if (session === owner) {
                session = null
                serverTime.reset()
                mutableCoverage.value = RealtimeCoverageSnapshot()
                mutableState.value = RealtimeConnectionState(owner.epoch, false)
            }
            val pending=owner.pending.values.toList();owner.pending.clear()
            owner.authors?.close();owner.authorWake.close();owner.coverage.clear()
            pending
        }
        // Close the actual socket before waking permit holders; a scheduled caller also joins its writer.
        runCatching { owner.socket.close() }
        owner.scope.cancel()
        pending.forEach {it.admission.release();it.response.completeExceptionally(cause)}
    }
    fun close(expectedEpoch: Long) {
        val old = synchronized(lock) { session?.takeIf { it.epoch == expectedEpoch } } ?: return
        close(old, java.io.IOException("Realtime connection closed"))
    }
    override fun close() {
        val old = synchronized(lock) { session } ?: return
        close(old, java.io.IOException("Realtime connection closed"))
    }
}
private fun Envelope.throwGatewayFailure() {
    if (hasError()) throw GatewayFailure(error.code, error.retryable, error.retryAfterSeconds)
}
data class RealtimeConnectionState(val epoch: Long = 0, val connected: Boolean = false,val authorStream: String? = null)
class GatewayFailure(val code: String, val retryable: Boolean, val retryAfterSeconds: Int) : Exception(code)
