package com.xmtx.im

import com.xmtx.im.client.*
import kotlinx.collections.immutable.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collectLatest

data class GroupAvatarPickerBaseline(val room: RoomId,val revision: Long,val deadlineNanos: Long)

data class AvatarResourcePickerState(val id: String,val search: String="",val positions: PersistentList<ResourceCatalogCursor?> = persistentListOf(null),
    val entries: PersistentList<ResourceCatalogEntry> = persistentListOf(),val previews: PersistentMap<ResourceKey,MessagePreviewBytes> = persistentMapOf(),val next: ResourceCatalogCursor?=null,val indexing: Boolean=false,
    val available: Boolean=false,val loading: Boolean=false,val selecting: Boolean=false,val submitting: Boolean=false,
    val baseline: ProfileView?=null,val loadingProfile: Boolean=false,val selected: AvatarResourceSelection?=null,val submitted: String?=null,val feedback: String?=null,
    val targetRoom: RoomId?=null,val groupBaseline: GroupAvatarPickerBaseline?=null) {
    val pageNumber get()=positions.size
    val busy get()=selecting || submitting
}

/** Page-owned reads are cancelled on leave; committed intents remain owned by the account runtime. */
internal class AvatarResourcePickerController(val id: String,private val actor: UserId,parent: CoroutineScope,
    private val changes: Flow<Long>,private val directory: suspend (ResourceCatalogQuery)->ResourceCatalogPage,
    private val select: suspend (ResourceKey)->AvatarResourceSelection,private val current: suspend (AvatarResourceSelection)->Boolean,
    private val refreshProfile: suspend ()->ProfileView?,private val submit: suspend (ProfileView,AvatarResourceSelection)->String,
    private val publish: (AvatarResourcePickerState)->Unit,
    private val preview: (suspend (ResourceKey)->MessagePreviewBytes)?=null,private val previewGeneration: suspend ()->String={ "" },
    val targetRoom: RoomId?=null,private val refreshGroup: (suspend ()->GroupAvatarEditAuthority)?=null,
    private val submitGroup: (suspend (GroupAvatarEditAuthority,AvatarResourceSelection)->String)?=null) {
    private val scope=CoroutineScope(parent.coroutineContext+SupervisorJob(parent.coroutineContext[Job]))
    init { require((targetRoom!=null)==(refreshGroup!=null) && (targetRoom!=null)==(submitGroup!=null)) }
    var state=AvatarResourcePickerState(id,targetRoom=targetRoom);private set
    private var groupAuthority: GroupAvatarEditAuthority?=null
    private var expiry: Job?=null
    private fun clearGroupAuthority() { expiry?.cancel();expiry=null;groupAuthority=null;update { it.copy(groupBaseline=null) } }
    fun invalidateGroupAuthority() { if(targetRoom==null || closed) return;clearGroupAuthority();profileVersion++;profileTask?.cancel();if(active && !state.submitting) refresh() }
    private var active=false;private var closed=false;private var epoch=0L;private var version=0L;private var profileVersion=0L
    private var visible=persistentSetOf<ResourceKey>();private var previewToken: String?=null
    private val previewJobs=mutableMapOf<ResourceKey,Job>();private val attempted=mutableSetOf<ResourceKey>()
    private fun clearPreviews() { previewJobs.values.forEach { it.cancel() };previewJobs.clear();attempted.clear();previewToken=null;update { it.copy(previews=persistentMapOf()) } }
    fun visible(keys: PersistentList<ResourceKey>) {
        if(closed || !active) return
        val next=keys.filter { key -> state.entries.any { it.descriptor.key==key } }.take(12).toPersistentSet()
        if(next==visible) return
        visible=next
        previewJobs.keys.filter { it !in next }.forEach { previewJobs.remove(it)?.cancel();attempted.remove(it) }
        attempted.retainAll(next);update { it.copy(previews=it.previews.filterKeys { key -> key in next }.toPersistentMap()) };loadPreviews()
    }
    private fun loadPreviews() {
        val fetch=preview ?: return;val token=previewToken ?: return
        if(!active || closed) return
        val e=epoch;val v=version
        for(key in visible) {
            if(key in attempted || key in previewJobs) continue
            val descriptor=state.entries.firstOrNull { it.descriptor.key==key }?.descriptor ?: continue
            attempted.add(key)
            val job=scope.launch(start=CoroutineStart.LAZY) {
                try {
                    val result=fetch(key);currentCoroutineContext().ensureActive()
                    if(valid(e,v) && previewToken==token && key in visible && result.read.generation==token && result.read.descriptor==descriptor && result.valid()) update { it.copy(previews=it.previews.put(key,result)) }
                } catch(error: CancellationException) { throw error } catch(_: Exception) { /* A failed preview leaves the explicit selection usable; refresh retries. */ }
                finally { if(previewJobs[key]===currentCoroutineContext().job) previewJobs.remove(key) }
            }
            previewJobs[key]=job;job.start()
        }
    }
    private var observer: Job?=null;private var task: Job?=null;private var profileTask: Job?=null
    private fun update(body: (AvatarResourcePickerState)->AvatarResourcePickerState) { if(!closed) { state=body(state);publish(state) } }
    private fun valid(e: Long,v: Long=version)=!closed && active && epoch==e && version==v
    fun foreground(value: Boolean) {
        if(closed || active==value) return
        active=value;epoch++;version++;observer?.cancel();task?.cancel();profileTask?.cancel();clearPreviews();clearGroupAuthority()
        update { it.copy(available=value,entries=persistentListOf(),selected=null,baseline=null,loading=false,loadingProfile=false,selecting=false,submitting=false) }
        if(value) { observe();refresh() }
    }
    fun search(value: String) {
        if(closed || !active || state.busy || value==state.search || value.toByteArray(Charsets.UTF_8).size>255) return
        update { it.copy(search=value,positions=persistentListOf(null),selected=null,feedback=null) };observe()
    }
    fun next() { if(!active || state.busy || state.loading) return;val next=state.next ?: return;update { it.copy(positions=it.positions.add(next),selected=null) };observe() }
    fun previous() { if(!active || state.busy || state.loading || state.positions.size<=1) return;update { it.copy(positions=it.positions.removeAt(it.positions.lastIndex),selected=null) };observe() }
    fun reload() { if(active && !state.busy) observe() }
    private fun observe() {
        observer?.cancel();clearPreviews();val v=++version;val e=epoch
        val query=ResourceCatalogQuery(category=ResourceCategory.Image,search=state.search,before=state.positions.last(),limit=30)
        update { it.copy(loading=true,entries=persistentListOf(),next=null,feedback=null) }
        observer=scope.launch {
            changes.collectLatest {
                try {
                    val page=directory(query);val token=previewGeneration();currentCoroutineContext().ensureActive()
                    val selected=state.selected;val remains=selected==null || current(selected)
                    currentCoroutineContext().ensureActive()
                    if(valid(e,v) && previewToken!=token) { clearPreviews();previewToken=token }
                    if(valid(e,v)) update { latest -> latest.copy(entries=page.entries.filter { AvatarResourceSelection.eligible(it.descriptor) }.toPersistentList(),
                        next=page.nextCursor,indexing=page.isIndexing,loading=false,
                        selected=if(!remains && latest.selected==selected) null else latest.selected,
                        feedback=if(!remains && latest.selected==selected) "所选图片的来源已变化，请重新选择" else latest.feedback) }
                    if(valid(e,v)) loadPreviews()
                } catch(error: CancellationException) { throw error }
                catch(_: Exception) { if(valid(e,v)) { clearPreviews();update { it.copy(entries=persistentListOf(),selected=null,loading=false,feedback="暂时无法读取聊天图片，请重试") } } }
            }
        }
    }
    fun refresh() {
        if(!active || closed || state.submitting) return
        profileTask?.cancel();clearGroupAuthority();val e=epoch;val p=++profileVersion
        update { it.copy(baseline=null,loadingProfile=true) }
        profileTask=scope.launch {
            try {
                if(targetRoom!=null) {
                    val authority=requireNotNull(refreshGroup).invoke();currentCoroutineContext().ensureActive()
                    val value=authority.presentation
                    require(value.actor==actor && value.state.room==targetRoom && value.canManage && value.valid() && authority.fence.authorized)
                    if(valid(e) && p==profileVersion) {
                        groupAuthority=authority
                        update { it.copy(groupBaseline=GroupAvatarPickerBaseline(targetRoom,value.state.revision,value.deadlineNanos)) }
                        expiry=scope.launch {
                            delay(((value.deadlineNanos-System.nanoTime()+999999)/1000000).coerceAtLeast(1))
                            if(p==profileVersion) clearGroupAuthority()
                        }
                    }
                } else {
                    val profile=refreshProfile();currentCoroutineContext().ensureActive()
                    if(valid(e) && p==profileVersion) update { it.copy(baseline=profile?.takeIf { p -> p.user==actor && p.state==ProfileState.Active },feedback=if(profile==null) "请刷新当前资料后重试" else it.feedback) }
                }
            } catch(error: CancellationException) { throw error }
            catch(_: Exception) { if(valid(e) && p==profileVersion) update { it.copy(feedback=if(targetRoom!=null) "暂时无法确认群管理权限，请刷新重试" else "暂时无法读取当前资料，请重试") } }
            finally { if(valid(e) && p==profileVersion) update { it.copy(loadingProfile=false) } }
        }
    }
    fun choose(key: ResourceKey) {
        if(!active || closed || state.busy || state.entries.none { it.descriptor.key==key }) return
        val e=epoch;val v=version;update { it.copy(selecting=true,selected=null,feedback=null) }
        task=scope.launch {
            try {
                val selection=select(key);currentCoroutineContext().ensureActive();check(selection.key==key && current(selection));currentCoroutineContext().ensureActive()
                if(valid(e,v)) update { it.copy(selected=selection) }
            } catch(error: CancellationException) { throw error }
            catch(_: Exception) { if(valid(e,v)) update { it.copy(feedback="图片来源已不可用，请刷新后重新选择") } }
            finally { if(valid(e,v)) update { it.copy(selecting=false) } }
        }
    }
    fun dismiss() { if(!state.submitting) update { it.copy(selected=null) } }
    fun confirm() {
        if(!active || closed || state.busy) return
        val selected=state.selected ?: return;val baseline=state.baseline;val authority=groupAuthority
        if(targetRoom==null && baseline==null || targetRoom!=null && (authority==null || !authority.presentation.valid())) return
        val e=epoch;val v=version
        update { it.copy(submitting=true,feedback=null) }
        task=scope.launch {
            try {
                val intent=if(targetRoom==null) submit(requireNotNull(baseline),selected) else requireNotNull(submitGroup).invoke(requireNotNull(authority),selected);currentCoroutineContext().ensureActive();clearGroupAuthority()
                if(valid(e,v)) update { it.copy(submitted=intent,selected=null,baseline=null) }
            } catch(error: CancellationException) { throw error }
            catch(_: Exception) { if(valid(e,v)) { clearGroupAuthority();update { it.copy(selected=null,baseline=null,feedback="来源或权限状态已变化，请刷新并重新选择；已保存的修改可在头像记录中查看") } } }
            finally { if(valid(e,v)) update { it.copy(submitting=false) } }
        }
    }
    fun close() { if(closed) return;clearGroupAuthority();closed=true;active=false;epoch++;scope.cancel();previewJobs.clear();attempted.clear();visible=persistentSetOf();state=AvatarResourcePickerState(id,targetRoom=targetRoom) }
}
