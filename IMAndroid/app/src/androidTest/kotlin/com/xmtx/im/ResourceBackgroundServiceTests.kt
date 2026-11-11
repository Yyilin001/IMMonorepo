package com.xmtx.im

import android.app.NotificationManager
import android.content.Intent
import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.lifecycle.Lifecycle
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import com.xmtx.im.platform.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger

class ResourceBackgroundServiceTests {
    @get:Rule val compose=createAndroidComposeRule<ComponentActivity>()
    private val instrumentation=InstrumentationRegistry.getInstrumentation()
    private val context get()=instrumentation.targetContext
    private fun id()=UUID.randomUUID().toString().uppercase()
    private val notifications get()=context.getSystemService(NotificationManager::class.java)
    private inner class Fixture {
        val actor=UserId(id());val store=openBoundFixtureStore(context,actor,DeviceId(id()))
        val source=File.createTempFile("background-service-",".txt",context.cacheDir).apply {writeText("private resource bytes")}
        val entered=CompletableDeferred<Unit>();val finish=CompletableDeferred<Unit>();val draining=CompletableDeferred<Unit>();val drained=CompletableDeferred<Unit>()
        val creates=AtomicInteger();val cancels=AtomicInteger();var holdDrain=false
        private var remote:ResourceUploadSession?=null
        val control=object:ResourceUploadControl {
            override suspend fun create(request:ResourceUploadRequest):ResourceUploadSession {
                creates.incrementAndGet()
                return ResourceUploadSession(ResourceUploadLocator(ResourceHome.Account(actor),id()),request.media,1,ResourceSessionState.Created,ResourceState.Pending,System.currentTimeMillis()+600000,null,persistentListOf(),null).also {remote=it}
            }
            override suspend fun status(previous:ResourceUploadSession)=requireNotNull(remote)
            override suspend fun target(session:ResourceUploadSession,request:ResourceUploadRequest)=ResourceTransferPlan(ResourceTransferMode.Put,"https://media.example.test/file",persistentListOf(),persistentMapOf(),null,System.currentTimeMillis()+60000,request.byteCount,null,null,request.checksum)
            override suspend fun finalize(session:ResourceUploadSession)=session.copy(state=ResourceSessionState.Completed,resourceState=ResourceState.Ready,bindableUntil=System.currentTimeMillis()+600000).also {remote=it}
            override suspend fun cancel(session:ResourceUploadSession):ResourceUploadSession {cancels.incrementAndGet();return session.copy(state=ResourceSessionState.Cancelled)}
        }
        val activity=AccountResourceActivity(context,store,control) {files->object:ResourceUploadBytes by ManagedResourceUploadBytes(files) {
            override suspend fun transfer(owner:String,work:ResourceUploadWork,plan:ResourceTransferPlan) {
                files.withOriginal(upload=work.id) {file->
                    entered.complete(Unit)
                    try {if(holdDrain) awaitCancellation() else finish.await()}
                    finally {withContext(NonCancellable) {draining.complete(Unit);if(holdDrain) finish.await();assertTrue(file.exists());drained.complete(Unit)}}
                }
            }
        }}
        val session=ResourceBackgroundSessions.register(activity)
        suspend fun prepare() {
            val asset=activity.files.importFile(source,"private-name.txt","text/plain",ResourceUsage.UserAvatar,1024)
            store.prepareResourceUpload(id(),asset.id,ResourceUploadRequest(id(),id(),asset.purpose,asset.contentType,asset.byteCount,asset.checksum,displayName=asset.displayName))
        }
        suspend fun start() {
            if(android.os.Build.VERSION.SDK_INT>=33) instrumentation.uiAutomation.grantRuntimePermission(context.packageName,android.Manifest.permission.POST_NOTIFICATIONS)
            compose.runOnUiThread {ResourceBackgroundSessions.start(context,session)}
            withTimeout(10000) {entered.await();session.state.first {it==ResourceBackgroundState.Running}}
            until {notifications.activeNotifications.any {it.notification.channelId=="resource-transfers"}}
            assertTrue("Active service must hold its bounded CPU wake lock",holdsTransferWakeLock())
        }
        suspend fun close() {
            finish.complete(Unit);ResourceBackgroundSessions.remove(session);activity.close();store.close();source.delete()
            until {notifications.activeNotifications.none {it.notification.channelId=="resource-transfers"}}
            assertFalse("Closing the account must release its CPU wake lock",holdsTransferWakeLock())
        }
    }
    private fun holdsTransferWakeLock():Boolean {
        val descriptor=instrumentation.uiAutomation.executeShellCommand("dumpsys power")
        return android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor).bufferedReader().use {reader->
            reader.lineSequence().any {it.contains("PARTIAL_WAKE_LOCK") && it.contains("IM:resource-transfer")}
        }
    }
    private suspend fun until(predicate:()->Boolean)=withTimeout(10000) {while(!predicate()) delay(10)}
    @Test fun visibleStartSurvivesActivityStopAndCompletesWithNotificationRemoved()=runBlocking {
        val f=Fixture()
        try {
            f.prepare();f.start()
            val notice=notifications.activeNotifications.single {it.notification.channelId=="resource-transfers"}.notification
            assertFalse(notice.extras.toString().contains("private-name"));assertFalse(notice.extras.toString().contains(f.actor.value))
            compose.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
            assertEquals(ResourceBackgroundState.Running,f.session.state.value);assertFalse(f.drained.isCompleted)
            f.finish.complete(Unit);withTimeout(10000) {f.session.state.first {it==ResourceBackgroundState.Completed}}
            assertTrue(f.drained.isCompleted);assertEquals(1,f.creates.get());assertEquals(0,f.cancels.get())
            assertEquals(ResourceUploadStage.Ready,f.store.resourceUploads().single().stage)
            assertNull(f.store.resourceUploads().single().execution.owner)
            until {notifications.activeNotifications.none {it.notification.channelId=="resource-transfers"}}
        } finally {compose.activityRule.scenario.moveToState(Lifecycle.State.RESUMED);f.close()}
    }
    @Test fun notificationStopWaitsForDrainAndDoesNotCancelTheResource()=runBlocking {
        val f=Fixture();f.holdDrain=true
        try {
            f.prepare();f.start();compose.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
            notifications.activeNotifications.single {it.notification.channelId=="resource-transfers"}.notification.actions.single().actionIntent.send()
            withTimeout(10000) {f.draining.await()}
            assertEquals(ResourceBackgroundState.Stopping,f.session.state.value);assertFalse(f.drained.isCompleted)
            assertNotNull(f.store.resourceUploads().single().execution.owner)
            f.finish.complete(Unit);withTimeout(10000) {f.session.state.first {it==ResourceBackgroundState.Stopped}}
            assertNull(f.store.resourceUploads().single().execution.owner);assertEquals(ResourceUploadAction.Status,f.store.resourceUploads().single().execution.next)
            assertEquals(0,f.cancels.get());assertFalse(f.store.resourceUploads().single().terminal)
            until {notifications.activeNotifications.none {it.notification.channelId=="resource-transfers"}}
        } finally {compose.activityRule.scenario.moveToState(Lifecycle.State.RESUMED);f.close()}
    }
    @Test fun accountRemovalInvalidatesLateStartAndDrainsBothLeases()=runBlocking {
        val f=Fixture();f.holdDrain=true
        try {
            f.prepare();val foreground=launch {f.activity.runForeground()};withTimeout(10000) {f.entered.await()};f.start()
            ResourceBackgroundSessions.remove(f.session)
            val closing=launch {f.activity.close()};withTimeout(10000) {f.draining.await()}
            assertFalse(closing.isCompleted);assertEquals(ResourceBackgroundState.Unavailable,f.session.state.value)
            f.finish.complete(Unit);withTimeout(10000) {closing.join();foreground.join()}
            assertNull(ResourceBackgroundSessions.find(f.session.token))
            compose.runOnUiThread {context.startService(Intent(context,ResourceBackgroundService::class.java).putExtra("session",f.session.token))}
            until {notifications.activeNotifications.none {it.notification.channelId=="resource-transfers"}}
            assertEquals(1,f.creates.get());assertEquals(0,f.cancels.get());assertEquals(ResourceBackgroundState.Unavailable,f.session.state.value)
        } finally {f.close()}
    }
    @Test fun transferScreenRequiresExplicitStartAndCanStopWithoutChangingTaskControls() {
        if(android.os.Build.VERSION.SDK_INT>=33) instrumentation.uiAutomation.grantRuntimePermission(context.packageName,android.Manifest.permission.POST_NOTIFICATIONS)
        val state=mutableStateOf(ResourceBackgroundState.Idle);var starts=0;var stops=0;var controls=0
        compose.setContent {MaterialTheme {ResourceTransfersScreen(ResourceTransfersState(available=true),true,false,{}, {}, {},{_,_->controls++},{},{},{},{},{},{},{},{_,_->},
            background=state.value,startBackground={starts++;state.value=ResourceBackgroundState.Running},stopBackground={stops++;state.value=ResourceBackgroundState.Stopping})}}
        compose.onNodeWithTag("resource-background-start").assertIsEnabled();assertEquals(0,starts)
        compose.onNodeWithTag("resource-background-start").performClick();compose.onNodeWithTag("resource-background-status").assertTextEquals("后台传输已开启")
        if(InstrumentationRegistry.getArguments().getString("captureBackgroundUI")=="true") {
            val image=compose.onRoot().captureToImage().asAndroidBitmap()
            File(context.filesDir,"resource-background-ui.png").outputStream().use {image.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)}
        }
        compose.onNodeWithTag("resource-background-stop").performClick();compose.onNodeWithTag("resource-background-stop").assertIsNotEnabled()
        assertEquals(1,starts);assertEquals(1,stops);assertEquals(0,controls)
        compose.runOnIdle {state.value=ResourceBackgroundState.Stopped}
        compose.onNodeWithTag("resource-background-start").assertIsEnabled()
    }
}
