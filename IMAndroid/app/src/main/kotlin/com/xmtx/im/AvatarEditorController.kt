package com.xmtx.im

import android.net.Uri
import androidx.compose.runtime.Immutable
import com.xmtx.im.client.*
import com.xmtx.im.platform.NormalizedPhoto
import com.xmtx.im.platform.PhotoCrop
import com.xmtx.im.platform.CameraPhoto
import kotlinx.coroutines.*
import kotlin.math.min

@Immutable data class AvatarCrop(val zoom: Float=1f,val x: Float=0.5f,val y: Float=0.5f) {
    init { require(zoom.isFinite() && zoom in 1f..5f && x.isFinite() && y.isFinite() && x in 0f..1f && y in 0f..1f) }
    fun constrained(size: ResourceDimensions): AvatarCrop {
        val side=min(size.width,size.height)/zoom
        val halfX=side/size.width/2;val halfY=side/size.height/2
        return copy(x=x.coerceIn(halfX,1-halfX),y=y.coerceIn(halfY,1-halfY))
    }
    fun rect(size: ResourceDimensions): PhotoCrop {
        val value=constrained(size);val side=min(size.width,size.height)/value.zoom.toDouble()
        return PhotoCrop(value.x-side/size.width/2,value.y-side/size.height/2,side/size.width,side/size.height)
    }
}
enum class AvatarEditorOperation { PreparingCamera, Reading, Saving, Updating }
enum class AvatarPhotoSource { Library, Camera }
@Immutable data class AvatarEditorState(val id: String,val photo: NormalizedPhoto?=null,val crop: AvatarCrop=AvatarCrop(),
    val baseline: ProfileView?=null,val loadingProfile: Boolean=false,val operation: AvatarEditorOperation?=null,
    val source: AvatarPhotoSource?=null,val openCrop: Boolean=false,val submitted: String?=null,val feedback: String?=null) {
    val picking get()=source!=null
}

/** Main-thread page controller. No provider URI, bitmap, or editing pixels enter saved state/SQLite. */
internal class AvatarEditorController(val id: String,private val actor: UserId,parent: CoroutineScope,
    private val refreshProfile: suspend ()->ProfileView?,private val readPhoto: suspend (Uri)->NormalizedPhoto,
    private val cropPhoto: suspend (NormalizedPhoto,PhotoCrop)->NormalizedPhoto,
    private val submit: suspend (ProfileView,NormalizedPhoto?)->String?,private val resume: suspend (String)->Unit,
    private val discard: suspend (String)->Unit,private val publish: (AvatarEditorState)->Unit,
    private val createCamera: suspend ()->CameraPhoto={ error("相机不可用") }) {
    private val scope=CoroutineScope(parent.coroutineContext+SupervisorJob(parent.coroutineContext[Job]))
    var state=AvatarEditorState(id);private set
    private var foreground=false;private var closed=false;private var epoch=0L;private var refreshVersion=0L
    private var task: Job?=null;private var refreshTask: Job?=null;private var pending: Uri?=null
    private var camera: CameraPhoto?=null;private var cameraReturned=false
    private fun update(body: (AvatarEditorState)->AvatarEditorState) { if(!closed) { state=body(state);publish(state) } }
    fun foreground(active: Boolean) {
        if(closed || foreground==active) return
        foreground=active
        if(active) { refresh();readPending() }
        else { epoch++;refreshVersion++;task?.cancel();refreshTask?.cancel();pending=null;if(cameraReturned) releaseCamera();update { it.copy(baseline=null,loadingProfile=false,operation=null) } }
    }
    fun refresh() {
        if(closed || !foreground) return
        refreshTask?.cancel();val version=++refreshVersion;val generation=epoch
        update { it.copy(baseline=null,loadingProfile=true) }
        refreshTask=scope.launch {
            try {
                val value=refreshProfile();currentCoroutineContext().ensureActive()
                if(valid(generation) && version==refreshVersion) update { it.copy(baseline=value?.takeIf { p -> p.user==actor && p.state==ProfileState.Active },feedback=if(value==null) "暂时无法读取当前资料，请刷新后重试" else it.feedback) }
            } catch(error: CancellationException) { throw error }
            catch(_: Exception) { if(valid(generation) && version==refreshVersion) update { it.copy(feedback="暂时无法读取当前资料，请刷新后重试") } }
            finally { if(valid(generation) && version==refreshVersion) update { it.copy(loadingProfile=false) } }
        }
    }
    fun beginPick(): Boolean {
        if(closed || !foreground || state.operation!=null || state.picking) return false
        update { it.copy(source=AvatarPhotoSource.Library,submitted=null,feedback=null) };return true
    }
    fun picked(uri: Uri?) {
        if(closed || state.source!=AvatarPhotoSource.Library) return
        update { it.copy(source=null) };pending=uri;readPending()
    }
    fun pickerFailed() { if(!closed && state.source==AvatarPhotoSource.Library) { update { it.copy(source=null,feedback="无法打开系统图片选择器，请重试") };pending=null } }
    fun takePicture(launch: (Uri)->Unit)=perform(AvatarEditorOperation.PreparingCamera) {
        var created: CameraPhoto?=null
        try {
            // Complete ownership transfer before observing cancellation, then always close an unused lease.
            withContext(NonCancellable) { created=createCamera() };currentCoroutineContext().ensureActive()
            camera=requireNotNull(created);created=null;cameraReturned=false
            update { it.copy(source=AvatarPhotoSource.Camera,submitted=null) }
            try { launch(requireNotNull(camera).uri) }
            catch(_: Exception) { releaseCamera();update { it.copy(source=null,feedback="无法打开系统相机，请检查设备上的相机应用") } }
        } finally { created?.close() }
    }
    fun captured(success: Boolean) {
        if(closed || state.source!=AvatarPhotoSource.Camera || camera==null) return
        update { it.copy(source=null) }
        if(!success) releaseCamera() else { cameraReturned=true;readPending() }
    }
    private fun releaseCamera() { val capture=camera;camera=null;cameraReturned=false;capture?.close() }
    private fun readPending() {
        if(closed || !foreground || state.operation!=null || state.picking) return
        if(cameraReturned && camera!=null) {
            perform(AvatarEditorOperation.Reading) {
                val capture=camera ?: return@perform;camera=null;cameraReturned=false
                try { val photo=capture.prepare();currentCoroutineContext().ensureActive();acceptPhoto(photo) }
                finally { capture.close() }
            };return
        }
        if(pending==null) return
        val uri=pending!!;pending=null
        perform(AvatarEditorOperation.Reading) {
            val photo=readPhoto(uri);currentCoroutineContext().ensureActive()
            acceptPhoto(photo)
        }
    }
    private fun acceptPhoto(photo: NormalizedPhoto) { update { it.copy(photo=photo,crop=AvatarCrop().constrained(photo.dimensions),openCrop=true,submitted=null) } }
    fun cropOpened() { update { it.copy(openCrop=false) } }
    fun crop(value: AvatarCrop) {
        if(closed || !foreground || state.operation!=null) return
        state.photo?.let { photo -> update { it.copy(crop=value.constrained(photo.dimensions)) } }
    }
    fun clearPhoto() { if(state.operation==null) update { it.copy(photo=null,crop=AvatarCrop(),openCrop=false) } }
    fun save() {
        val photo=state.photo ?: return;val baseline=state.baseline ?: return;val crop=state.crop.rect(photo.dimensions)
        perform(AvatarEditorOperation.Saving) {
            val output=cropPhoto(photo,crop);currentCoroutineContext().ensureActive()
            val intent=submit(baseline,output);currentCoroutineContext().ensureActive()
            if(intent!=null) update { it.copy(photo=null,openCrop=false,submitted=intent,baseline=null,feedback="头像修改已保存，正在确认结果") }
            else update { it.copy(feedback="头像修改未能保存，请刷新资料后重试") }
        }
    }
    fun remove() {
        val baseline=state.baseline ?: return
        perform(AvatarEditorOperation.Saving) {
            val intent=submit(baseline,null);currentCoroutineContext().ensureActive()
            if(intent!=null) update { it.copy(baseline=null,feedback="移除头像的修改已保存，正在确认结果") }
        }
    }
    fun resourceSubmitted(intent: String) { update { it.copy(photo=null,openCrop=false,submitted=intent,baseline=null,feedback="聊天图片导入已保存，正在准备头像") } }
    fun resume(id: String)=perform(AvatarEditorOperation.Updating) { resume.invoke(id);currentCoroutineContext().ensureActive();refresh() }
    fun discard(id: String)=perform(AvatarEditorOperation.Updating) { discard.invoke(id);currentCoroutineContext().ensureActive();update { it.copy(feedback="已放弃这份头像修改") };refresh() }
    private fun perform(operation: AvatarEditorOperation,body: suspend ()->Unit) {
        if(closed || !foreground || state.operation!=null || state.picking) return
        val generation=epoch;update { it.copy(operation=operation,feedback=null) }
        task=scope.launch {
            try { body() }
            catch(error: CancellationException) { throw error }
            catch(_: Exception) { if(valid(generation)) update { it.copy(feedback="暂时无法完成，请重试；已保存的修改可以继续恢复") } }
            finally { if(valid(generation)) { update { it.copy(operation=null) };readPending() } }
        }
    }
    private fun valid(generation: Long)=!closed && foreground && epoch==generation
    fun close() { if(closed) return;closed=true;epoch++;pending=null;state=AvatarEditorState(id);scope.cancel();releaseCamera() }
}
