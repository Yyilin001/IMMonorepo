package com.xmtx.im

import android.content.Context
import android.net.Uri
import androidx.media3.common.*
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.FileDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import com.xmtx.im.client.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collectLatest
import java.io.File
import java.util.UUID

data class MessagePlaybackSelection(val location: MediaMessageLocation,val media: String) {
    val key=ResourceKey(ResourceHome.Room(location.room),media)
}
data class MessagePlaybackState(val selection: MessagePlaybackSelection,val owner: String="",val available: Boolean=false,
    val read: MessageResourceRead?=null,val deadlineNanos: Long?=null,val loading: Boolean=false,val ready: Boolean=false,
    val playing: Boolean=false,val playRequested: Boolean=false,val buffering: Boolean=false,val ended: Boolean=false,val seekable: Boolean=false,
    val positionMs: Long=0,val durationMs: Long=0,val feedback: String?=null)

@androidx.annotation.OptIn(UnstableApi::class)
internal fun createMessagePlayer(context: Context): ExoPlayer=ExoPlayer.Builder(context)
    // Only progressive, account-owned local files. No HLS/DASH, remote playlists or secondary network fetches.
    .setMediaSourceFactory(ProgressiveMediaSource.Factory(FileDataSource.Factory()))
    .setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(),true)
    .setHandleAudioBecomingNoisy(true).build()

/** Main-thread navigation owner. Mutable Player and physical borrow never enter immutable UI snapshots. */
@androidx.annotation.OptIn(UnstableApi::class)
internal class MessagePlaybackController(val selection: MessagePlaybackSelection,parent: CoroutineScope,
    private val changes: Flow<Long>,private val resolve: suspend ()->MessageResourceRead,
    private val borrow: suspend (MessageResourceRead,suspend (AuthorizedOriginalRead,File)->Unit)->Unit,
    private val createPlayer: ()->ExoPlayer,private val publish: (MessagePlaybackState)->Unit) {
    val id=UUID.randomUUID().toString()
    private val owner=SupervisorJob(parent.coroutineContext[Job]);private val scope=CoroutineScope(parent.coroutineContext+owner)
    var state=MessagePlaybackState(selection,id);private set
    private var closed=false;private var active=false;private var epoch=0L;private var request=0L
    private var observer:Job?=null;private var playback:Job?=null;private var source:MessageResourceRead?=null
    private var player:ExoPlayer?=null
    private fun update(block: (MessagePlaybackState)->MessagePlaybackState) { if(!closed) { state=block(state);publish(state) } }
    private fun valid(e:Long,n:Long)=!closed && active && epoch==e && request==n
    private fun matches(read: MessageResourceRead)=read.descriptor.key==selection.key && read.source.room==selection.location.room && read.source.message==selection.location.message &&
        (read.descriptor.contentType.startsWith("audio/") || read.descriptor.contentType.startsWith("video/"))
    private suspend fun current()=resolve().also { currentCoroutineContext().ensureActive();check(matches(it)) }
    private fun releasePlayer() { val old=player;player=null;old?.release() }
    private fun stop() {
        request++;playback?.cancel();releasePlayer()
        update { it.copy(deadlineNanos=null,loading=false,ready=false,playing=false,playRequested=false,buffering=false,ended=false,seekable=false,positionMs=0,durationMs=0) }
    }
    fun foreground(value: Boolean) {
        if(closed || active==value) return
        active=value;val e=++epoch;observer?.cancel();stop();source=null
        update { it.copy(available=false,read=null,feedback=null) }
        if(value) observer=scope.launch { changes.collectLatest {
            try {
                val next=current()
                if(!closed && active && epoch==e && source!=next) {
                    stop();source=next;update {it.copy(read=next,available=true,feedback=null)};load(next)
                }
            } catch(error: CancellationException) { throw error }
            catch(_: Exception) { if(!closed && active && epoch==e) {stop();source=null;update {it.copy(available=false,read=null,feedback="音视频来源当前不可访问，请重试")}} }
        } }
    }
    private fun load(expected: MessageResourceRead) {
        val e=epoch;val n=++request
        update {it.copy(loading=true,feedback=null)}
        playback=scope.launch {
            try {
                borrow(expected) { authorized,file -> withContext(Dispatchers.Main.immediate) {
                    currentCoroutineContext().ensureActive();check(valid(e,n) && authorized.evidence==expected && current()==expected)
                    val remaining=authorized.deadlineNanos-System.nanoTime()
                    if(remaining<=0) throw MediaReadFailure(MediaReadFailureReason.Expired)
                    withTimeout(((remaining+999999)/1_000_000).coerceAtLeast(1)) {
                        val runtime=createPlayer();player=runtime
                        fun publishPlayer() {
                            if(valid(e,n) && player===runtime) update { it.copy(loading=false,ready=runtime.playbackState in setOf(Player.STATE_READY,Player.STATE_ENDED),
                                playing=runtime.isPlaying,playRequested=runtime.playWhenReady && runtime.playbackState!=Player.STATE_ENDED,buffering=runtime.playbackState==Player.STATE_BUFFERING,ended=runtime.playbackState==Player.STATE_ENDED,
                                seekable=runtime.isCurrentMediaItemSeekable,positionMs=runtime.currentPosition.coerceAtLeast(0),durationMs=runtime.duration.takeIf {it!=C.TIME_UNSET && it>0} ?: 0) }
                        }
                        runtime.addListener(object:Player.Listener {
                            override fun onEvents(player:Player,events:Player.Events) {publishPlayer()}
                            override fun onPlayerError(error: PlaybackException) {
                                if(valid(e,n) && player===runtime) {
                                    stop();update {it.copy(feedback="无法播放此格式或文件已损坏，可尝试用其他应用打开")}
                                }
                            }
                        })
                        try {
                            update {it.copy(deadlineNanos=authorized.deadlineNanos)}
                            runtime.setMediaItem(MediaItem.fromUri(Uri.fromFile(file)));runtime.playWhenReady=false;runtime.prepare()
                            while(isActive) {publishPlayer();delay(250)}
                        } finally { if(player===runtime) releasePlayer() }
                    }
                } }
            } catch(error: CancellationException) {
                if(valid(e,n) && currentCoroutineContext().isActive) update {it.copy(feedback="播放许可已结束，请重新加载")}
                throw error
            } catch(_: Exception) { if(valid(e,n)) update {it.copy(feedback="暂时无法加载音视频，请重试") } }
            finally { if(valid(e,n)) { releasePlayer();update {it.copy(deadlineNanos=null,loading=false,ready=false,playing=false,playRequested=false,buffering=false,seekable=false)} } }
        }
    }
    fun renderPlayer(): Player?=player?.takeIf { !closed && active && state.deadlineNanos?.let {it-System.nanoTime()>0}==true }
    fun toggle() {
        val runtime=renderPlayer() ?: return
        if(!state.ready && !state.buffering) return
        if(runtime.playbackState==Player.STATE_ENDED) {runtime.seekTo(0);runtime.play()} else if(runtime.playWhenReady) runtime.pause() else runtime.play()
    }
    fun seek(positionMs: Long) {
        val runtime=renderPlayer() ?: return
        if(state.ready && state.seekable && state.durationMs>0) runtime.seekTo(positionMs.coerceIn(0,state.durationMs))
    }
    fun retry() { if(active && !closed) {foreground(false);foreground(true)} }
    fun close() { if(closed) return;closed=true;active=false;epoch++;owner.cancel();releasePlayer();state=MessagePlaybackState(selection,id) }
    suspend fun awaitClosed() {owner.join()}
}
