package com.xmtx.im

import android.net.Uri
import androidx.compose.runtime.Immutable
import com.xmtx.im.client.*
import com.xmtx.im.platform.NormalizedPhoto
import com.xmtx.im.platform.PhotoCrop
import kotlinx.coroutines.*

@Immutable data class GroupAvatarEditorState(val id: String,val room: RoomId,val photo: NormalizedPhoto?=null,val crop: AvatarCrop=AvatarCrop(),
    val revision: Long?=null,val canManage: Boolean=false,val maximumBytes: Long?=null,val deadlineNanos: Long?=null,val hasAvatar: Boolean=false,
    val relatedAvailable:Boolean=true,val loading: Boolean=false,val busy: Boolean=false,val picking: Boolean=false,val openCrop: Boolean=false,val submitted: String?=null,val feedback: String?=null) {
    fun authorized()=canManage && deadlineNanos?.let { it-System.nanoTime()>0 }==true
}
internal enum class GroupAvatarTaskAction { Retry, Cancel, Abandon, Replace }
internal data class GroupAvatarManagementAccess(val authority: GroupAvatarEditAuthority,val maximumBytes: Long?)

/** Page-owned editing pixels; account-owned journal operations. All entry points run on Main. */
internal class GroupAvatarEditorController(val id: String,val room: RoomId,parent: CoroutineScope,
    private val load: suspend ()->GroupAvatarManagementAccess,
    private val read: suspend (Uri)->NormalizedPhoto,private val crop: suspend (NormalizedPhoto,PhotoCrop)->NormalizedPhoto,
    private val submit: suspend (GroupAvatarEditAuthority,NormalizedPhoto?)->String,
    private val act: suspend (String,GroupAvatarTaskAction,GroupAvatarEditAuthority?)->Unit,
    private val publish: (GroupAvatarEditorState)->Unit,private val focused:Boolean=false,private val verifyRelated:suspend ()->Boolean={true}) {
    private val scope=CoroutineScope(parent.coroutineContext+SupervisorJob(parent.coroutineContext[Job]))
    var state=GroupAvatarEditorState(id,room,relatedAvailable=!focused);private set
    private var active=false;private var closed=false;private var epoch=0L;private var refreshVersion=0L
    private var task: Job?=null;private var refreshTask: Job?=null;private var expiry: Job?=null;private var pending: Uri?=null
    private fun update(body: (GroupAvatarEditorState)->GroupAvatarEditorState) { if(!closed) { state=body(state);publish(state) } }
    private fun clearAuthority() { expiry?.cancel();update { it.copy(revision=null,canManage=false,maximumBytes=null,deadlineNanos=null,loading=false) } }
    fun foreground(value: Boolean) {
        if(closed || active==value) return
        active=value;epoch++;refreshVersion++;task?.cancel();refreshTask?.cancel();clearAuthority()
        update { it.copy(busy=false) };if(value) { refresh();readPending() } else pending=null
    }
    fun invalidate() { if(closed) return;refreshVersion++;refreshTask?.cancel();clearAuthority();if(active) refresh() }
    fun refresh() {
        if(closed || !active) return
        refreshTask?.cancel();val version=++refreshVersion;val generation=epoch;clearAuthority();update { it.copy(loading=true,relatedAvailable=!focused) }
        refreshTask=scope.launch {
            try {
                val related=verifyRelated();ensureActive();if(valid(generation) && version==refreshVersion) update {it.copy(relatedAvailable=related)}
                check(related) { "Related operation no longer owns this transfer" }
                val result=load();ensureActive();val value=result.authority.presentation
                require(value.state.room==room && value.valid())
                if(valid(generation) && version==refreshVersion) {
                    update { it.copy(revision=value.state.revision,canManage=value.canManage,maximumBytes=result.maximumBytes,
                        deadlineNanos=value.deadlineNanos,hasAvatar=value.state.media!=null) }
                    expiry=scope.launch { val left=value.deadlineNanos-System.nanoTime();if(left>0) delay((left+999999)/1000000);if(version==refreshVersion) clearAuthority() }
                }
            } catch(error: CancellationException) { throw error }
            catch(_: Exception) { if(valid(generation) && version==refreshVersion) update { it.copy(feedback="暂时无法读取群头像和管理权限，请刷新重试") } }
            finally { if(valid(generation) && version==refreshVersion) update { it.copy(loading=false) } }
        }
    }
    fun beginPick(): Boolean {
        if(closed || !active || state.busy || state.picking || !state.authorized() || state.maximumBytes==null) return false
        update { it.copy(picking=true,submitted=null,feedback=null) };return true
    }
    fun picked(uri: Uri?) { if(closed || !state.picking) return;update { it.copy(picking=false) };pending=uri;readPending() }
    fun pickerFailed() { if(!closed) { pending=null;update { it.copy(picking=false,feedback="无法打开系统图片选择器，请重试") } } }
    private fun readPending() {
        if(!active || state.busy || state.picking) return
        val uri=pending ?: return;pending=null
        perform { val photo=read(uri);ensureActive();update { it.copy(photo=photo,crop=AvatarCrop().constrained(photo.dimensions),openCrop=true,submitted=null) } }
    }
    fun resourceSubmitted(intent: String) {
        if(closed) return
        clearPhoto();update { it.copy(submitted=intent,feedback="群头像修改已保存，正在确认结果") };invalidate()
    }
    fun cropOpened() { update { it.copy(openCrop=false) } }
    fun changeCrop(value: AvatarCrop) { if(active && !state.busy) state.photo?.let { photo -> update { it.copy(crop=value.constrained(photo.dimensions)) } } }
    fun clearPhoto() { if(!state.busy) update { it.copy(photo=null,crop=AvatarCrop(),openCrop=false) } }
    fun save(remove: Boolean=false) {
        if(!state.authorized()) return
        val revision=state.revision ?: return;val photo=if(remove) null else state.photo ?: return;val rect=photo?.let { state.crop.rect(it.dimensions) }
        perform {
            val output=photo?.let { crop(it,requireNotNull(rect)) };ensureActive()
            // Reauthorize after image preparation; a changed version requires a new explicit save.
            val current=load();ensureActive();require(current.authority.presentation.state.revision==revision && current.authority.presentation.canManage)
            if(output!=null) require(output.data.size().toLong()<=requireNotNull(current.maximumBytes))
            val result=submit(current.authority,output);ensureActive();clearAuthority()
            update { it.copy(photo=null,openCrop=false,submitted=result,feedback="群头像修改已保存，正在确认结果") };refresh()
        }
    }
    fun action(intent: String,action: GroupAvatarTaskAction) {
        val revision=state.revision
        if(action==GroupAvatarTaskAction.Replace && (!state.authorized() || revision==null)) return
        perform {
            val authority=if(action==GroupAvatarTaskAction.Replace) load().also {
                require(it.authority.presentation.state.revision==revision && it.authority.presentation.canManage)
            }.authority else null
            ensureActive();act(intent,action,authority);ensureActive();update { it.copy(feedback="已处理这次群头像修改") };refresh()
        }
    }
    private fun perform(body: suspend CoroutineScope.()->Unit) {
        if(closed || !active || state.busy || state.picking) return
        val generation=epoch;update { it.copy(busy=true,feedback=null) }
        task=scope.launch {
            try { body();ensureActive() }
            catch(error: CancellationException) { throw error }
            catch(_: Exception) { if(valid(generation)) update { it.copy(feedback="暂时无法完成，请刷新后重试；已保存的修改仍会恢复") } }
            finally { if(valid(generation)) { update { it.copy(busy=false) };readPending() } }
        }
    }
    private fun valid(value: Long)=!closed && active && epoch==value
    fun close() { if(closed) return;closed=true;epoch++;pending=null;state=GroupAvatarEditorState(id,room);scope.cancel() }
}
