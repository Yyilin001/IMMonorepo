package com.xmtx.im.client

import com.google.protobuf.ByteString
import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import okhttp3.OkHttpClient
import okhttp3.tls.HandshakeCertificates
import org.junit.Assume.assumeTrue
import java.io.File
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.test.*

/** Opt-in against an isolated real backend; default unit tests never provision accounts or require a server. */
class BackendIntegrationTests {
    @Test fun realBackendRegistersDiscoversOpensAndExchangesTextAcrossTwoAccounts() {
        val endpoint = System.getenv("IM_ANDROID_E2E_URL")
        assumeTrue("Set IM_ANDROID_E2E_URL, IM_ANDROID_E2E_TLS_PORT and IM_ANDROID_E2E_CA to opt in", endpoint != null)
        val ca = File(requireNotNull(System.getenv("IM_ANDROID_E2E_CA"))).inputStream().use {
            CertificateFactory.getInstance("X.509").generateCertificate(it) as X509Certificate
        }
        val trust = HandshakeCertificates.Builder().addTrustedCertificate(ca).build()
        val http = OkHttpClient.Builder().sslSocketFactory(trust.sslSocketFactory(), trust.trustManager)
            .followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false).callTimeout(20, TimeUnit.SECONDS).build()
        val transport = AccountClient(endpoint!!, http)
        val first = AuthSession(MemorySecrets(), transport)
        val second = AuthSession(MemorySecrets(), transport)
        val port = requireNotNull(System.getenv("IM_ANDROID_E2E_TLS_PORT")).toInt()
        val aSocket = RealtimeConnection("localhost", port, trust.sslSocketFactory(),authorPresentations=true)
        val bSocket = RealtimeConnection("localhost", port, trust.sslSocketFactory())
        runBlocking {
            try {
                withTimeout(240_000) {
                    val run = UUID.randomUUID().toString().replace("-", "").take(12)
                    val aHandle = "android_${run}_a"; val bHandle = "android_${run}_b"
                    val password = UUID.randomUUID().toString() + "aA1!"
                    val a = first.login(aHandle, password, true, aHandle, "Android A")
                    val b = second.login(bHandle, password, true, bHandle, "Android B")
                    println("E2E: two independent accounts registered")
                    verifyBackendAssertionRegistration(transport,aHandle,password,a.userId)
                    val api = AuthenticatedApi(first, transport, a.userId, a.deviceId)
                    val found = PublicIdentityDirectory(api, a.userId, a.deviceId).resolve("@$bHandle")
                    assertEquals(b.userId, found.identity.user); assertTrue(found.valid())
                    val command = DirectRoomCommand.create(a.userId, b.userId, System.currentTimeMillis())
                    val direct = DirectRoomClient(api)
                    var processing = false
                    var room: RoomId? = null
                    repeat(30) {
                        if (room == null) when (val result = direct.execute(command, processing, false)) {
                            is DirectRoomResult.Receipt -> { assertNotNull(result.room, "Opening rejected: ${result.rejection}"); room = result.room }
                            DirectRoomResult.Processing -> { processing = true; delay(1000) }
                            is DirectRoomResult.Deferred -> delay(maxOf(1000, result.delayMilliseconds))
                            DirectRoomResult.Unresolved -> delay(1000)
                            DirectRoomResult.Conflict -> fail("Direct-room identity conflict")
                        }
                    }
                    val opened = assertNotNull(room)
                    println("E2E: exact discovery and direct-room operation confirmed")
                    aSocket.connect(first.access()); bSocket.connect(second.access())
                    val aStore = BackendStore(); val bStore = BackendStore()
                    SyncEngine(aSocket, aStore).synchronize(); SyncEngine(bSocket, bStore).synchronize()
                    println("E2E: TLS authentication and initial personal sync completed")
                    if(System.getenv("IM_ANDROID_E2E_AUTHOR_PRESENTATIONS")=="true") {
                        verifyBackendAuthorPresentation(aSocket,a,b,opened)
                        verifyBackendAuthorPages(aSocket,a,b,opened,AuthenticatedApi(second,transport,b.userId,b.deviceId))
                    }
                    val aRooms=RoomSyncEngine(aSocket,aStore);val bRooms=RoomSyncEngine(bSocket,bStore)
                    aRooms.synchronize();bRooms.synchronize()
                    val aRoomSubscription=RoomEventSubscriptionClient(aSocket);val bRoomSubscription=RoomEventSubscriptionClient(bSocket)
                    aRoomSubscription.subscribe(opened,aStore.roomCursor(opened).sequence)
                    bRoomSubscription.subscribe(opened,bStore.roomCursor(opened).sequence)
                    if(System.getenv("IM_ANDROID_E2E_AUTHOR_PRESENTATIONS")=="true") verifyBackendEarlyAuthor(aSocket,a,b,opened) {
                        val early=MemorySendStore();val outbox=MessageOutbox(bSocket,early)
                        outbox.send(b.userId,opened,"Early author $run")
                        while(early.receipts.isEmpty()) {outbox.flush();delay(100)}
                        assertTrue(early.receipts.values.single().hasAccepted())
                    }
                    suspend fun expectRoomWake(socket: RealtimeConnection, send: suspend () -> Unit): RealtimeSyncHint.Room = coroutineScope {
                        val wake=async(start=CoroutineStart.UNDISPATCHED) {
                            withTimeout(30_000) {socket.syncEvents.first {it.hint is RealtimeSyncHint.Room && it.hint.room == opened}}
                        }
                        send()
                        val event=wake.await();assertEquals(socket.state.value.epoch,event.connectionEpoch)
                        event.hint as RealtimeSyncHint.Room
                    }
                    val text = "Android cross-account $run"
                    val received=expectRoomWake(bSocket) {MessageOutbox(aSocket,aStore).send(a.userId,opened,text)}
                    assertTrue(aStore.receipts.values.single().hasAccepted(), "Text was not accepted")
                    assertFalse(bStore.contains(text), "A wake must not commit message bodies")
                    verifyBackendRoomHeartbeat(bSocket,opened,received.head) {bStore.roomCursor(opened).sequence}
                    assertFalse(bStore.contains(text), "Heartbeat must not commit missing messages")
                    val bRecovery=bRooms.synchronizeRoom(opened)
                    assertTrue(bStore.contains(text));assertTrue(bRecovery.appliedThrough >= received.head)
                    val reply = "reply $run"
                    val replied=expectRoomWake(aSocket) {MessageOutbox(bSocket,bStore).send(b.userId,opened,reply)}
                    assertTrue(bStore.receipts.values.single().hasAccepted(), "Reply was not accepted")
                    assertFalse(aStore.contains(reply))
                    val aRecovery=aRooms.synchronizeRoom(opened)
                    assertTrue(aStore.contains(reply));assertTrue(aRecovery.appliedThrough >= replied.head)
                    assertTrue(opened in aStore.directory && opened in bStore.directory)
                    aRoomSubscription.unsubscribe(opened);bRoomSubscription.unsubscribe(opened)
                    println("E2E: both accounts received idle room wakes and committed authorized messages plus delivery progress without polling")
                    val aActivity = LiveActivityClient(aSocket); val bActivity = LiveActivityClient(bSocket)
                    aActivity.subscribeTyping(opened); bActivity.subscribeTyping(opened)
                    val initialPresence = aActivity.subscribePresence(opened)
                    assertEquals(b.userId, initialPresence.user)
                    assertFalse(initialPresence.online, "Authenticated connections begin with presence suppressed")
                    suspend fun expectActivity(action: suspend () -> Unit, matches: (LiveActivityHint) -> Boolean): RealtimeActivityEvent = coroutineScope {
                        val observed = async(start = CoroutineStart.UNDISPATCHED) {
                            withTimeout(30_000) { aSocket.activityEvents.first { matches(it.hint) } }
                        }
                        action()
                        observed.await().also { assertEquals(aSocket.state.value.epoch, it.connectionEpoch) }
                    }
                    expectActivity({ bActivity.setPresencePublicationMode(PresencePublicationMode.AllowWhenAuthorized) }) {
                        it is LiveActivityHint.Presence && it.value.room == opened && it.value.user == b.userId && it.value.online
                    }
                    expectActivity({ bActivity.setTyping(opened, true) }) {
                        it is LiveActivityHint.Typing && it.value.room == opened && it.value.user == b.userId && it.value.typing &&
                            it.value.expiresAtMillis > System.currentTimeMillis()
                    }
                    expectActivity({ bActivity.setTyping(opened, false) }) {
                        it is LiveActivityHint.Typing && it.value.room == opened && it.value.user == b.userId && !it.value.typing
                    }
                    expectActivity({ bActivity.setPresencePublicationMode(PresencePublicationMode.Suppressed) }) {
                        it is LiveActivityHint.Presence && it.value.room == opened && it.value.user == b.userId && !it.value.online
                    }
                    aActivity.unsubscribePresence(opened); aActivity.unsubscribeTyping(opened); bActivity.unsubscribeTyping(opened)
                    println("E2E: idle presence and typing leases arrived across accounts, with explicit privacy suppression and teardown")
                    val aLive = ConversationActivitySession(a.userId,aSocket.state.value.epoch,aActivity,aSocket.activityEvents,
                        aSocket.state,this,{aSocket.latestActivitySequence},aSocket::close)
                    val bLive = ConversationActivitySession(b.userId,bSocket.state.value.epoch,bActivity,bSocket.activityEvents,
                        bSocket.state,this,{bSocket.latestActivitySequence},bSocket::close)
                    try {
                        val aInterest = ConversationActivityInterest(opened,b.userId,onlineAllowed=true,typingAllowed=true)
                        val bInterest = ConversationActivityInterest(opened,a.userId,onlineAllowed=true,typingAllowed=true)
                        aLive.update(aInterest);bLive.update(bInterest)
                        withTimeout(30_000) { aLive.state.first { it.subscribed && it.online == true } }
                        bLive.update(bInterest.copy(hasDraft=true))
                        withTimeout(30_000) { aLive.state.first { b.userId in it.typing } }
                        bLive.update(bInterest)
                        withTimeout(30_000) { aLive.state.first { it.typing.isEmpty() } }
                        bLive.update(bInterest.copy(onlineAllowed=false))
                        withTimeout(30_000) { aLive.state.first { it.online != true } }
                        assertFalse(bSocket.state.value.connected)
                        aLive.update(aInterest.copy(room=null,peer=null))
                        assertEquals(ConversationActivityState(),aLive.state.value)
                        println("E2E: foreground coordinators rendered presence and typing, cleared draft leases and enforced privacy disconnect")
                    } finally { aLive.close();bLive.close() }
                    val refreshed = first.access(rejectedAccess = first.current())
                    assertEquals(a.deviceId, refreshed.deviceId)
                    aSocket.close(); aSocket.connect(refreshed)
                    println("E2E: refreshed session reauthenticated over TLS")
                }
            } finally {
                aSocket.close(); bSocket.close()
                withContext(NonCancellable) { withTimeout(45_000) { first.logout(); second.logout() } }
            }
        }
    }
}

private class BackendStore(private val outbox: MemorySendStore=MemorySendStore()) : SyncStore, RoomStore, OutboxStore by outbox {
    private var cursor = SyncCursor()
    private var manifest: SnapshotManifest? = null
    private val pages = mutableMapOf<Int, SnapshotPage>()
    private val roomCursors = mutableMapOf<RoomId, RoomCursor>()
    private val events = mutableListOf<ByteString>()
    val receipts get()=outbox.receipts
    var directory: PersistentMap<RoomId, RoomKind> = persistentMapOf()
    fun contains(text: String) = events.any { it.toStringUtf8().contains(text) }
    override val syncMutex=kotlinx.coroutines.sync.Mutex()
    private var rebuild=false
    override suspend fun requiresSnapshotRebuild()=rebuild
    override suspend fun requestSnapshotRebuild() {rebuild=true}
    override suspend fun discardSyncCapabilities(expected: SyncCursor) {check(cursor==expected);cursor=expected.copy(token="",pendingReceipt=null,pendingSequence=null)}
    override suspend fun cancelSnapshot(expected: SnapshotManifest) {check(manifest==expected);manifest=null;pages.clear();cursor=cursor.copy(token="",pendingReceipt=null,pendingSequence=null)}
    override suspend fun cursor() = cursor
    override suspend fun commit(batch: SyncBatch, expected: SyncCursor) {
        check(cursor == expected)
        cursor = SyncCursor(batch.generation, batch.recordsList.lastOrNull()?.userSyncSequence ?: cursor.sequence,
            batch.nextSyncToken, batch.syncReceipt.takeIf { batch.recordsCount > 0 })
    }
    override suspend fun acknowledged(expected: SyncCursor) { check(cursor == expected); cursor = cursor.copy(pendingReceipt = null,pendingSequence=null) }
    private var reset: SyncReset? = null
    override suspend fun pendingReset() = reset
    override suspend fun stageReset(expected: SyncCursor, reset: SyncReset) {check(cursor==expected);check(this.reset==null || this.reset==reset);this.reset=reset}
    override suspend fun cancelReset(expected: SyncReset) {check(reset==expected);reset=null;cursor=cursor.copy(token="",pendingReceipt=null,pendingSequence=null)}
    override suspend fun pendingSnapshot() = manifest
    override suspend fun stage(manifest: SnapshotManifest) { reset=null; this.manifest = manifest; pages.clear() }
    override suspend fun page(index: Int) = pages[index]
    override suspend fun stage(page: SnapshotPage) { pages[page.pageIndex] = page }
    override suspend fun snapshotImportProgress(manifest:SnapshotManifest)=testSnapshotProgress(manifest)
    override suspend fun importSnapshotPage(manifest:SnapshotManifest,page:SnapshotPage):SnapshotImportProgress {
        val imported=SnapshotImportValidation.advance(manifest,snapshotImportProgress(manifest),page)
        stage(page);return imported.progress
    }
    override suspend fun prepareSnapshotActivation(manifest:SnapshotManifest) {validateSnapshot(testSnapshotItems(manifest))}
    override suspend fun activateAcknowledgedSnapshot(manifest:SnapshotManifest) {activate(manifest,testSnapshotItems(manifest))}
    override suspend fun validateSnapshot(items: PersistentList<SnapshotItem>) { }
    override suspend fun activate(manifest: SnapshotManifest, items: PersistentList<SnapshotItem>) {
        cursor = SyncCursor(manifest.generation, manifest.baseUserSyncSequence, manifest.nextSyncToken); this.manifest = null; pages.clear()
    }
    override suspend fun reconcileDirectory(rooms: PersistentMap<RoomId, RoomKind>) { directory = rooms }
    override suspend fun acceptStates(states: kotlinx.collections.immutable.PersistentMap<RoomId,RoomSyncState>) {states.forEach {(room,state) -> acceptState(room,state)}}
        override suspend fun acceptState(room: RoomId, state: RoomSyncState) { roomCursors.putIfAbsent(room, RoomCursor()) }
    override suspend fun unavailable(room: RoomId) { roomCursors.remove(room) }
    override suspend fun roomCursor(room: RoomId) = roomCursors[room] ?: RoomCursor()
    override suspend fun commitRoom(page: GroupEventPage, expected: RoomCursor) {
        val room = RoomId(page.roomId); check(roomCursor(room) == expected)
        events.addAll(page.eventsList.map { it.payload }); roomCursors[room] = RoomCursor(page.nextRoomSequence)
    }
}
