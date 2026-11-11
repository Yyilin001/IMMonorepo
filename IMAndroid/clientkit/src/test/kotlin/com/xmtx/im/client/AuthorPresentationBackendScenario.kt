package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import java.util.UUID
import kotlin.test.*

/** Uses the real negotiated gateway stream and its authoritative profile resolver, never seeded profile replies. */
internal suspend fun verifyBackendAuthorPresentation(socket: RealtimeConnection,actor: Credentials,peer: Credentials,room: RoomId) {
    assertNotNull(socket.state.value.authorStream)
    val current=socket.beginAuthorPresentationView(persistentListOf(room))
    val client=AuthorPresentationClient(socket)
    val keys=persistentListOf(ProfileKey(peer.userId,ProfileContext.DirectConversation),ProfileKey(peer.userId,ProfileContext.Room(room)))
    try {
        withTimeout(25000) {
            client.start(current.start)
            var interestSequence=1L
            client.interests(AuthorPresentationInterests(current.start.stream,current.start.view,interestSequence,keys))
            var retained=persistentMapOf<ProfileKey,ProfileReadResult.Available>()
            while(retained.size<keys.size) {
                val delta=socket.nextAuthorPresentationDelta(current)
                assertEquals(current,delta.view)
                val now=System.nanoTime()
                val available=delta.entries.filterIsInstance<ReceivedAuthorPresentationEntry.Available>().map {it.value}.filter {it.valid(now) && it.key in keys}
                available.forEach {
                    assertEquals(actor.userId,it.profile.lease.actor);assertEquals(actor.deviceId,it.profile.lease.device)
                    assertEquals("Android B",it.profile.displayName());retained=retained.put(it.key,it)
                }
                if(available.isNotEmpty()) {
                    val remaining=available.minOf {((it.deadlineNanos-System.nanoTime()).coerceAtLeast(0)/1_000_000).coerceAtMost(300000)}
                    client.receipt(AuthorPresentationReceipt(current.start.stream,current.start.view,delta.sequence,available.map {it.key}.toPersistentList(),remaining))
                }
                val retry=delta.entries.filterIsInstance<ReceivedAuthorPresentationEntry.Retryable>().minOfOrNull {it.notBeforeNanos}
                if(retained.size<keys.size && retry!=null) {
                    delay(((retry-System.nanoTime()).coerceAtLeast(0)+999999)/1_000_000)
                    client.interests(AuthorPresentationInterests(current.start.stream,current.start.view,++interestSequence,keys))
                }
            }
            assertEquals(keys.toSet(),retained.keys);assertTrue(retained.values.all {it.valid()})
            client.interests(AuthorPresentationInterests(current.start.stream,current.start.view,++interestSequence,persistentListOf()))
        }
    } finally {
        socket.endAuthorPresentationView(current)
        withContext(NonCancellable) {withTimeout(5000) {client.end(current.start)}}
    }
    assertTrue(socket.state.value.connected)
    println("E2E: negotiated author stream delivered authorized direct and room profiles, exact retention receipts and independent view cleanup")
}

/** HTTP is deliberately parked: these page values and subsequent rename must originate in the real author stream. */
internal suspend fun verifyBackendAuthorPages(socket: RealtimeConnection,actor: Credentials,peer: Credentials,room: RoomId,peerApi: AuthenticatedTransport)=coroutineScope {
    val keys=persistentListOf(ProfileKey(peer.userId,ProfileContext.DirectConversation),ProfileKey(peer.userId,ProfileContext.Room(room)))
    val page=ProfilePresentationPage(actor.userId,actor.deviceId,{awaitCancellation()},{ProfileFenceSnapshot("live",persistentMapOf())},this)
    page.update(keys,"live")
    val wire=AuthorPresentationClient(socket)
    var acknowledged=0
    val commands=object: AuthorPresentationCommands by wire {
        override suspend fun receipt(value: AuthorPresentationReceipt) {wire.receipt(value);acknowledged+=value.keys.size}
    }
    val coordinator=AuthorPresentationCoordinator(socket,commands,this)
    val profile=OwnProfileClient(peerApi,peer.userId)
    suspend fun rename(name: String) {
        val current=profile.current()
        val result=profile.submit(OwnProfileCommand(peer.userId,UUID.randomUUID().toString().uppercase(),current.revision,OwnProfilePatch(name),System.currentTimeMillis()+86400000))
        assertEquals(OwnProfileStatus.Committed,result.status)
    }
    try {
        coordinator.selectMessageRoom(room);assertTrue(coordinator.register(page))
        withTimeout(45000) {page.state.first {it.display.profiles.size==2 && it.display.profiles.values.all {value->value.profile.displayName()=="Android B"}}}
        rename("Android B realtime")
        withTimeout(45000) {page.state.first {it.display.profiles.size==2 && it.display.profiles.values.all {value->value.profile.displayName()=="Android B realtime"}}}
        assertTrue(acknowledged>=2)
        println("E2E: account coordinator installed both page contexts and a real peer rename with HTTP reads parked")
    } finally {
        coordinator.close();coordinator.awaitClosed();assertTrue(page.state.value.display.profiles.isEmpty());page.close()
        withContext(NonCancellable) {rename("Android B")}
    }
}

/** Message-driven author data arrives before its row is visible. Later deliveries and HTTP stay parked. */
internal suspend fun verifyBackendEarlyAuthor(socket: RealtimeConnection,actor: Credentials,peer: Credentials,room: RoomId,send: suspend ()->Unit)=coroutineScope {
    val key=ProfileKey(peer.userId,ProfileContext.Room(room));var delivered=false;var reads=0;var receipts=0
    val ready=CompletableDeferred<Unit>();val wire=AuthorPresentationClient(socket)
    val commands=object: AuthorPresentationCommands by wire {
        override suspend fun interests(value: AuthorPresentationInterests) {wire.interests(value);ready.complete(Unit)}
        override suspend fun receipt(value: AuthorPresentationReceipt) {wire.receipt(value);receipts++}
    }
    val source=object: AuthorPresentationSource by socket {
        override suspend fun nextAuthorPresentationDelta(view: AuthorPresentationView): ReceivedAuthorPresentationDelta {
            if(delivered) awaitCancellation()
            return socket.nextAuthorPresentationDelta(view).also {delta->
                if(delta.entries.any {it is ReceivedAuthorPresentationEntry.Available && it.key==key}) delivered=true
            }
        }
    }
    val page=ProfilePresentationPage(actor.userId,actor.deviceId,{reads++;awaitCancellation()},{ProfileFenceSnapshot("early",persistentMapOf())},this)
    page.update(persistentListOf(),"early")
    val coordinator=AuthorPresentationCoordinator(source,commands,this)
    try {
        coordinator.selectMessageRoom(room);coordinator.register(page)
        withTimeout(15000) {ready.await();send();while(!delivered || coordinator.bufferedCandidates().first==0) delay(20)}
        assertTrue(page.state.value.display.profiles.isEmpty());assertEquals(0,receipts)
        page.update(persistentListOf(key),"early")
        withTimeout(3000) {page.state.first {it.display.profiles[key]?.profile?.displayName()=="Android B"}}
        assertEquals(0,reads);assertEquals(0,receipts)
        println("E2E: message-driven early author was staged without a receipt and promoted on visibility with later stream and HTTP deliveries parked")
    } finally {coordinator.close();coordinator.awaitClosed();page.close()}
}
