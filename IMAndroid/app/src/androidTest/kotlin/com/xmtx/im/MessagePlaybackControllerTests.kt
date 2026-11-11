package com.xmtx.im

import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.media3.common.Player
import androidx.test.platform.app.InstrumentationRegistry
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.security.MessageDigest

internal class PlaybackFixture(val video: Boolean=false) {
    val instrumentation=InstrumentationRegistry.getInstrumentation();val context=instrumentation.targetContext
    val file=File.createTempFile("playback-",".data",context.filesDir)
    val selection=MessagePlaybackSelection(MediaMessageLocation(RoomId("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"),MessageId("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")),"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
    val changes=MutableStateFlow(0L)
    var read:MessageResourceRead
    var available=true;var borrowCount=0;var released=0;var created=0;var rendered=false;var permitMillis=60000L
    var beforeBorrow:suspend ()->Unit={}
    init {
        resetBytes()
        read=MessageResourceRead(ResourceDescriptor(selection.key,1,if(video) "测试视频.mp4" else "测试音频.wav",if(video) "video/mp4" else "audio/wav",file.length(),checksum(),ResourceState.Ready,
            if(video) 320 else null,if(video) 180 else null,8000),MessageResourceSource(selection.location.room,selection.location.message,0,1),"A".repeat(32))
    }
    fun resetBytes() {instrumentation.context.assets.open(if(video) "playback/sample.mp4" else "playback/tone.wav").use {input->file.outputStream().use {input.copyTo(it)}}}
    fun checksum()=ResourceChecksum(MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") {"%02x".format(it)})
    fun controller(parent: CoroutineScope,publish: (MessagePlaybackState)->Unit={}):MessagePlaybackController=MessagePlaybackController(selection,parent,changes,
        resolve={check(available);read},borrow={expected,use->
            borrowCount++;try {beforeBorrow();withContext(Dispatchers.IO) {use(AuthorizedOriginalRead(expected,System.nanoTime()+permitMillis*1_000_000),file)}} finally {released++}
        },createPlayer={created++;createMessagePlayer(context).apply {volume=0f;addListener(object:Player.Listener {override fun onRenderedFirstFrame() {rendered=true}})}},publish=publish)
    fun close() {file.delete()}
}
class MessagePlaybackControllerTests {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private suspend fun until(test: ()->Boolean)=withTimeout(12000) {while(!test()) delay(20)}
    @Test fun localAudioPreparesPausedSeeksPlaysAndForegroundReloadNeverAutoplays()=runBlocking {withContext(Dispatchers.Main.immediate) {
        val fixture=PlaybackFixture();val owner=fixture.controller(this)
        try {
            owner.foreground(true);until {owner.state.ready};assertFalse(owner.state.playRequested);assertEquals(8000L,owner.state.durationMs);assertTrue(owner.state.seekable)
            owner.toggle();until {owner.state.playing && owner.state.positionMs>0};owner.seek(4000);until {owner.state.positionMs>=4000}
            owner.toggle();until {!owner.state.playRequested};owner.foreground(false);assertNull(owner.renderPlayer());assertFalse(owner.state.playing);until {fixture.released==1}
            owner.foreground(true);until {owner.state.ready};assertEquals(2,fixture.created);assertFalse(owner.state.playRequested);assertEquals(0L,owner.state.positionMs)
            owner.seek(Long.MAX_VALUE);until {owner.state.positionMs in 7990..8000};owner.seek(-100);until {owner.state.positionMs==0L}
        } finally {owner.close();owner.awaitClosed();fixture.close()}
    } }
    @Test fun completedAudioRestartsWithOneTapAndAudioFocusLossStopsSound()=runBlocking {withContext(Dispatchers.Main.immediate) {
        val fixture=PlaybackFixture();val owner=fixture.controller(this)
        val audio=fixture.context.getSystemService(android.content.Context.AUDIO_SERVICE) as android.media.AudioManager
        val request=android.media.AudioFocusRequest.Builder(android.media.AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(android.media.AudioAttributes.Builder().setUsage(android.media.AudioAttributes.USAGE_MEDIA).setContentType(android.media.AudioAttributes.CONTENT_TYPE_SPEECH).build())
            .setOnAudioFocusChangeListener {}.build()
        try {
            owner.foreground(true);until {owner.state.ready};owner.seek(7700);owner.toggle();until {owner.state.ended}
            assertFalse(owner.state.playRequested);owner.toggle();until {owner.state.playing && owner.state.positionMs<2000}
            assertEquals(android.media.AudioManager.AUDIOFOCUS_REQUEST_GRANTED,audio.requestAudioFocus(request));until {!owner.state.playing}
            owner.foreground(false);audio.abandonAudioFocusRequest(request);assertNull(owner.renderPlayer());until {fixture.released==1}
        } finally {audio.abandonAudioFocusRequest(request);owner.close();owner.awaitClosed();fixture.close()}
    } }
    @Test fun accessChangeStopsPlaybackAndLateBorrowCannotReplaceTheNewSource()=runBlocking {withContext(Dispatchers.Main.immediate) {
        val fixture=PlaybackFixture();val gate=CompletableDeferred<Unit>();val entered=CompletableDeferred<Unit>();var first=true
        fixture.beforeBorrow={if(first) {first=false;entered.complete(Unit);withContext(NonCancellable) {gate.await()}}}
        val owner=fixture.controller(this)
        try {
            owner.foreground(true);entered.await();fixture.read=fixture.read.copy(generation="B".repeat(32));fixture.changes.value++
            until {owner.state.ready};assertEquals(1,fixture.created);gate.complete(Unit);until {fixture.released==1};assertEquals(fixture.read,owner.state.read)
            owner.toggle();until {owner.state.playing};fixture.available=false;fixture.changes.value++;until {!owner.state.available};assertNull(owner.renderPlayer());until {fixture.released==2}
        } finally {gate.complete(Unit);owner.close();owner.awaitClosed();fixture.close()}
    } }
    @Test fun permitExpiryStopsThePlayerAndExplicitRetryObtainsANewBorrow()=runBlocking {withContext(Dispatchers.Main.immediate) {
        val fixture=PlaybackFixture().apply {permitMillis=1600};val owner=fixture.controller(this)
        try {
            owner.foreground(true);until {owner.state.ready};owner.toggle();until {owner.state.feedback?.contains("许可")==true};assertNull(owner.renderPlayer());assertFalse(owner.state.ready);until {fixture.released==1}
            fixture.permitMillis=60000;owner.retry();until {owner.state.ready};assertFalse(owner.state.playRequested);assertEquals(2,fixture.borrowCount)
        } finally {owner.close();owner.awaitClosed();fixture.close()}
    } }
    @Test fun malformedMediaStopsAndReleasesInsteadOfLoopingOrFetchingAnotherSource()=runBlocking {withContext(Dispatchers.Main.immediate) {
        val fixture=PlaybackFixture();fixture.file.writeText("not an audio stream");fixture.read=fixture.read.copy(descriptor=fixture.read.descriptor.copy(byteCount=fixture.file.length(),checksum=fixture.checksum()))
        val owner=fixture.controller(this)
        try {
            owner.foreground(true);until {owner.state.feedback?.contains("无法播放")==true};assertNull(owner.renderPlayer());until {fixture.released==1};assertEquals(1,fixture.borrowCount)
            fixture.resetBytes();fixture.read=fixture.read.copy(descriptor=fixture.read.descriptor.copy(byteCount=fixture.file.length(),checksum=fixture.checksum()))
            owner.retry();until {owner.state.ready};assertEquals(2,fixture.borrowCount)
        } finally {owner.close();owner.awaitClosed();fixture.close()}
    } }
    @Test fun closeDrainsAnUncancellableBorrowAndRejectsNonPlayableMetadata()=runBlocking {withContext(Dispatchers.Main.immediate) {
        val fixture=PlaybackFixture();val entered=CompletableDeferred<Unit>();val gate=CompletableDeferred<Unit>();fixture.beforeBorrow={entered.complete(Unit);withContext(NonCancellable) {gate.await()}}
        val owner=fixture.controller(this)
        try {
            owner.foreground(true);entered.await();owner.close();val closed=async {owner.awaitClosed()};delay(50);assertFalse(closed.isCompleted)
            gate.complete(Unit);closed.await();assertEquals(0,fixture.created);assertEquals(1,fixture.released)
            fixture.beforeBorrow={};fixture.read=fixture.read.copy(descriptor=fixture.read.descriptor.copy(contentType="text/plain"))
            val second=fixture.controller(this)
            try {second.foreground(true);until {second.state.feedback!=null};assertFalse(second.state.available);assertEquals(0,fixture.created)} finally {second.close();second.awaitClosed()}
        } finally {gate.complete(Unit);owner.close();owner.awaitClosed();fixture.close()}
    } }
}
