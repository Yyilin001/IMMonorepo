package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.coroutines.*
import kotlin.test.*

/** Observes real frames without replacing server responses or local cursor storage. */
internal suspend fun verifyBackendRoomHeartbeat(socket: RealtimeConnection,room: RoomId,expectedHead: Long,cursor: suspend ()->Long) {
    withTimeout(15000) {while(socket.roomProgressScope()?.room!=room) delay(10)}
    var sent: Heartbeat?=null;var received: HeartbeatAck?=null
    val observed=object: EnvelopeTransport by socket,RoomProgressConnection by socket {
        override suspend fun requestHeartbeat(heartbeat: Heartbeat,expectedEpoch: Long): Envelope {
            sent=heartbeat
            return socket.requestHeartbeat(heartbeat,expectedEpoch).also {received=it.heartbeatAck}
        }
    }
    val committed=cursor()
    HeartbeatClient(observed) {assertEquals(room,it);cursor()}.send()
    val report=assertNotNull(sent).roomProgressList.single()
    assertEquals(room,RoomId(report.roomId));assertEquals(committed,report.appliedRoomSequence)
    val state=assertNotNull(received).roomSubscriptionStatesList.single()
    assertTrue(state.ready);assertEquals(room,RoomId(state.roomId));assertEquals(report.scopeGeneration,state.scopeGeneration)
    assertTrue(state.highWatermark>=expectedHead);assertTrue(state.appliedRoomSequence>=committed)
    assertEquals(committed,cursor(),"Server progress never advances local storage")
}
