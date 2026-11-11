package com.xmtx.im

import com.xmtx.im.client.*
import androidx.compose.runtime.*
import kotlinx.collections.immutable.*

internal fun messageSourceFixture(actor: UserId,source: Message)=object: MessageSourceStore {
    override suspend fun messageSources(room: RoomId,viewer: UserId,ids: PersistentSet<MessageId>)=
        if(viewer==actor && source.roomId==room && source.id in ids) persistentMapOf(source.id to source) else persistentMapOf()
}

/** Explicit in-memory source for media controller/UI tests; production real-mode never reads global bodies. */
@Composable internal fun rememberMessageSourceFixture(actor: UserId,source: Message): (RoomId)->MessageSourceSession? {
    val scope=rememberCoroutineScope()
    val current by rememberUpdatedState(source)
    val pages=remember(actor,scope) {mutableListOf<MessageSourceSession>()}
    val store=remember(actor) {object:MessageSourceStore {
        override suspend fun messageSources(room: RoomId,viewer: UserId,ids: PersistentSet<MessageId>)=
            current.takeIf {viewer==actor && it.roomId==room && it.id in ids && !it.withdrawn && !it.redacted}
                ?.let {persistentMapOf(it.id to it)} ?: persistentMapOf()
    }}
    LaunchedEffect(source) {pages.removeAll {it.state.value.closed};pages.forEach {it.refresh()}}
    return remember(store,scope) {{room->MessageSourceSession(store,room,actor,scope).also {pages.add(it)}}}
}

/** A real local account for shared-stack tests, without authentication or network side effects. */
internal fun installMediaNavigationSource(model: AppViewModel,fixture: AppState): AppState = kotlinx.coroutines.runBlocking {
    val context=androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().targetContext
    val actor=(fixture.session as SessionUi.SignedIn).user
    val device=DeviceId(java.util.UUID.randomUUID().toString())
    val store=openBoundFixtureStore(context,actor,device)
    fixture.snapshot.messages.map {it.roomId}.distinct().forEach {room->
        store.acceptState(room,com.xmtx.imclientkit.generated.im.realtime.v2.RoomSyncState.newBuilder().setRoomId(room.value).setHead(1).setViewerMembershipRevision(1).build())
    }
    val digest=java.security.MessageDigest.getInstance("SHA-256").digest("${actor.value}/${device.value}".toByteArray()).joinToString("") {"%02x".format(it)}
    android.database.sqlite.SQLiteDatabase.openDatabase(java.io.File(context.noBackupFilesDir,"im-$digest.db").path,null,android.database.sqlite.SQLiteDatabase.OPEN_READWRITE).use {db->
        fixture.snapshot.messages.forEach {message->
            db.execSQL("INSERT INTO messages(id,room,sender,text,source_text,time,revision,sequence,accepted_sequence,withdrawn,media) VALUES (?,?,?,?,?,?,?,1,1,0,?)",
                arrayOf<Any?>(message.id.value,message.roomId.value,message.sender.value,message.text,message.text,1,message.revision,message.media?.payload()?.toString()))
        }
    }
    val app=fixture.copy(snapshot=fixture.snapshot.copy(messages=persistentListOf()))
    kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
        fun field(name: String)=AppViewModel::class.java.getDeclaredField(name).apply {isAccessible=true}
        (field("operation").get(model) as? kotlinx.coroutines.Job)?.join()
        field("local").set(model,store);field("foreground").setBoolean(model,true)
        @Suppress("UNCHECKED_CAST") val state=field("mutableState").get(model) as kotlinx.coroutines.flow.MutableStateFlow<AppState>
        state.value=app
    }
    app
}

internal fun awaitMediaNavigationClosed(model: AppViewModel)=kotlinx.coroutines.runBlocking {
    val local=AppViewModel::class.java.getDeclaredField("local").apply {isAccessible=true}
    kotlinx.coroutines.withTimeout(10000) {
        while(kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {local.get(model)!=null}) kotlinx.coroutines.delay(10)
    }
}
