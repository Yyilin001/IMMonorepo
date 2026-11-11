package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*

/** Installation fence, not a local cursor or permission to read message content. */
data class RoomProgressScope(val connectionEpoch: Long,val room: RoomId,val generation: Long,val baselineHead: Long)

interface RoomProgressConnection {
    val authenticatedEpoch: Long?
    fun roomProgressScope(): RoomProgressScope?
    /** Must reject rather than move an old heartbeat onto a replacement connection. */
    suspend fun requestHeartbeat(heartbeat: Heartbeat,expectedEpoch: Long): Envelope
    fun acceptRoomProgressHead(scope: RoomProgressScope,head: Long)
}

/** Heartbeat observations only wake authorized recovery; they never update persistent cursors. */
class HeartbeatClient(private val transport: EnvelopeTransport,
    private val durableRoomProgress: (suspend (RoomId)->Long?)?=null) {
    suspend fun send(clientTimeMillis: Long=System.currentTimeMillis()) {
        val progress=transport as? RoomProgressConnection
        val epoch=progress?.authenticatedEpoch
        if(progress!=null && epoch==null) throw RealtimeUnavailableBeforeAdmission()
        val heartbeat=Heartbeat.newBuilder().setClientTimeMs(clientTimeMillis.coerceAtLeast(0))
        val scope=progress?.roomProgressScope()?.takeIf {it.connectionEpoch==epoch}
        if(scope!=null) {
            val applied=durableRoomProgress?.invoke(scope.room)
            if(applied!=null) {
                if(applied<0) throw ClientFailure.Protocol()
                // Storage reads can suspend across a page switch or coverage loss.
                if(progress.roomProgressScope()==scope) heartbeat.addRoomProgress(GroupEventProgress.newBuilder()
                    .setRoomId(scope.room.value).setScopeGeneration(scope.generation).setAppliedRoomSequence(applied))
            }
        }
        val response=if(progress!=null) progress.requestHeartbeat(heartbeat.build(),requireNotNull(epoch))
            else transport.request(Envelope.newBuilder().setHeartbeat(heartbeat))
        if(!response.hasHeartbeatAck()) throw ClientFailure.Protocol()
        val states=response.heartbeatAck.roomSubscriptionStatesList
        if(states.size>1) throw ClientFailure.Protocol()
        for(state in states) {
            val room=try {RoomId(uuidId(state.roomId))} catch(_: IllegalArgumentException) {throw ClientFailure.Protocol()}
            if(state.scopeGeneration<=0 || state.highWatermark<0 || state.appliedRoomSequence<0 || state.appliedRoomSequence>state.highWatermark)
                throw ClientFailure.Protocol()
            if(state.ready && epoch!=null) {
                val installed=progress?.roomProgressScope()
                if(installed!=null && installed.connectionEpoch==epoch && installed.room==room && installed.generation==state.scopeGeneration)
                    progress.acceptRoomProgressHead(installed,state.highWatermark)
            }
        }
    }
}

/** One scope of each kind per physical connection, matching V2TLSFrameConnection's revision fences. */
internal class SyncCoverageTracker {
    private val revisions=mutableMapOf<SyncCoverageScope,Long>()
    private val generations=mutableMapOf<SyncCoverageScope,Long>()
    private val ended=mutableMapOf<SyncCoverageScope,Long>()
    private val states=mutableMapOf<SyncCoverageScope,RealtimeSyncHint.Coverage>()
    fun accept(value: RealtimeSyncHint.Coverage): Boolean {
        val kind=value.scope
        if(value.revision<=(revisions[kind] ?: 0) || value.generation<(generations[kind] ?: 0) ||
            value.state!=ActivityCoverageState.Ended && value.generation<=(ended[kind] ?: 0)) return false
        val old=states[kind]
        if(old!=null && old.scopeId==value.scopeId && old.state==ActivityCoverageState.Ready && value.state==ActivityCoverageState.Ready &&
            old.generation==value.generation && old.connectionEpoch==value.connectionEpoch && old.head!=value.head) throw ClientFailure.Protocol()
        revisions[kind]=value.revision;generations[kind]=value.generation
        if(value.state==ActivityCoverageState.Ended) {ended[kind]=value.generation;states.remove(kind)} else states[kind]=value
        return true
    }
    fun room(epoch: Long): RoomProgressScope?=states[SyncCoverageScope.Room]?.takeIf {it.state==ActivityCoverageState.Ready}
        ?.let {RoomProgressScope(epoch,RoomId(it.scopeId),it.generation,it.head)}
    fun clear() {revisions.clear();generations.clear();ended.clear();states.clear()}
}
