package com.xmtx.im.client

import kotlinx.collections.immutable.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

data class InvitationPrompt(val confirmation: InvitationConfirmation, val expiresNanos: Long, val replacing: String? = null)
data class InvitationManagementState(val links: PersistentList<InvitationLink> = persistentListOf(),
    val requests: PersistentList<GroupJoinRequest> = persistentListOf(), val cursor: String? = null,
    val preview: InvitationPreview? = null, val revision: Long? = null, val loading: Boolean = false,
    val busy: Boolean = false, val prompt: InvitationPrompt? = null, val error: String? = null,
    val works: PersistentList<InvitationWork> = persistentListOf())

/** One visible page owns this ephemeral presentation. Closing fences all late reads and erases bearer links. */
class InvitationManagement(private val room: RoomId?, private val client: InvitationClient,
    private val directory: InvitationDirectory, private val service: InvitationService, private val store: InvitationStore,
    private val mono: () -> Long = System::nanoTime) {
    private val mutableState = MutableStateFlow(InvitationManagementState())
    val state = mutableState.asStateFlow()
    private var generation = 0L
    private var closed = false
    private var refreshAfterWork = false
    private var baselineEnd = 0L
    private var previewSecret: InvitationSecret? = null
    private var cursors = persistentSetOf<String>()
    fun close() { closed = true; refreshAfterWork = false; generation++; previewSecret = null; baselineEnd = 0; mutableState.value = InvitationManagementState() }
    fun inputChanged() { generation++; previewSecret = null; mutableState.update { it.copy(preview = null, prompt = null, error = null, loading = false) } }
    fun dismiss() { mutableState.update { it.copy(prompt = null) } }
    suspend fun tick() {
        if(closed) return
        val g = generation
        val works = store.invitationWorks().filter { if(room != null) it.intent.room == room else it.intent.action is InvitationAction.Submit || it.intent.action is InvitationAction.Cancel }.toPersistentList()
        if(closed || g != generation) return
        val changed = works.any { work -> work.terminal && state.value.works.none { it.intent.key == work.intent.key && it.terminal } }
        // A fast completion may arrive while a previous read/action still owns the page.
        // Remember the refresh until it can run, even if the next poll sees the same terminal row.
        if(changed) refreshAfterWork = true
        mutableState.update { it.copy(works = works, prompt = it.prompt?.takeIf { p -> p.expiresNanos > mono() }) }
        if(refreshAfterWork && !state.value.loading && !state.value.busy) {
            refreshAfterWork = false
            refresh()
        }
    }
    suspend fun refresh() {
        if(closed || state.value.busy) return
        val secret = previewSecret
        if(room == null) { if(secret != null) preview(secret.rawValue); return }
        val g = ++generation; baselineEnd = 0; cursors = persistentSetOf()
        mutableState.update { it.copy(loading = true, links = persistentListOf(), requests = persistentListOf(), cursor = null, revision = null, prompt = null, error = null) }
        try {
            val started = mono(); val revision = client.baseline(room)
            val links = directory.links(room); val requests = directory.requests(room)
            if(closed || g != generation) return
            baselineEnd = started + 115000000000
            mutableState.update { it.copy(loading = false, links = links, requests = requests.requests, cursor = requests.cursor, revision = revision) }
        } catch(e: CancellationException) { throw e }
        catch(_: Exception) { if(!closed && g == generation) mutableState.update { it.copy(loading = false, error = "无法读取邀请和申请，请刷新后重试") } }
    }
    suspend fun more() {
        val cursor = state.value.cursor ?: return; val target = room ?: return
        if(closed || state.value.loading || state.value.busy) return
        val g = generation; mutableState.update { it.copy(loading = true, error = null) }
        try {
            require(cursor !in cursors && state.value.requests.size < 1000)
            val page = directory.requests(target,cursor)
            if(closed || g != generation) return
            require(page.cursor == null || page.cursor !in cursors)
            val merged = (state.value.requests + page.requests).distinctBy { it.request }.toPersistentList(); require(merged.size <= 1000)
            cursors = cursors.add(cursor)
            mutableState.update { it.copy(loading = false, requests = merged, cursor = page.cursor) }
        } catch(e: CancellationException) { throw e }
        catch(_: Exception) { if(!closed && g == generation) { baselineEnd = 0; mutableState.update { it.copy(loading = false, links = persistentListOf(), requests = persistentListOf(), cursor = null, revision = null, prompt = null, error = "申请列表已失效，请重新刷新") } } }
    }
    suspend fun preview(input: String) {
        if(closed || room != null || state.value.busy) return
        inputChanged(); val g = generation
        mutableState.update { it.copy(loading = true) }
        try {
            val secret = invitationSecret(input); val preview = directory.preview(secret)
            if(closed || g != generation) return
            previewSecret = secret; mutableState.update { it.copy(preview = preview, loading = false) }
        } catch(e: CancellationException) { throw e }
        catch(_: Exception) { if(!closed && g == generation) mutableState.update { it.copy(loading = false, error = "邀请无效、已失效或暂时无法读取") } }
    }
    private fun freshRevision(): Long {
        check(baselineEnd > mono() && !state.value.loading) { "请刷新群状态后重新确认" }
        return requireNotNull(state.value.revision)
    }
    fun create() = propose { requireNotNull(room) to InvitationAction.Create(604800,100,freshRevision()) }
    fun revoke(id: String) = propose {
        check(state.value.links.any { it.invite == id && it.state == "active" })
        requireNotNull(room) to InvitationAction.Revoke(id,freshRevision())
    }
    fun decide(id: String, approve: Boolean) = propose {
        check(state.value.requests.any { it.request == id && it.state == "pending" })
        requireNotNull(room) to InvitationAction.Decide(id,approve,freshRevision())
    }
    fun submit(note: String) = propose {
        val preview = requireNotNull(state.value.preview); val secret = requireNotNull(previewSecret)
        check(!preview.alreadyMember && preview.requestState in setOf(null,"cancelled"))
        preview.room to InvitationAction.Submit(preview.invite,secret.digest,invitationNote(note))
    }
    fun cancel() = propose {
        val preview = requireNotNull(state.value.preview); check(preview.requestState == "pending")
        preview.room to InvitationAction.Cancel(requireNotNull(preview.request))
    }
    fun reconfirm(work: InvitationWork) = propose(work.intent.key) {
        check(work.status == InvitationStatus.DraftPaused && state.value.works.contains(work))
        work.intent.room to when(val action = work.intent.action) {
            is InvitationAction.Create -> action.copy(revision = freshRevision())
            is InvitationAction.Revoke -> action.copy(revision = freshRevision())
            is InvitationAction.Decide -> action.copy(revision = freshRevision())
            else -> action
        }
    }
    private fun propose(replacing: String? = null, action: () -> Pair<RoomId,InvitationAction>) {
        if(closed || state.value.busy || state.value.loading) return
        try {
            val (target,value) = action(); val confirmation = service.confirmation(target,value)
            mutableState.update { it.copy(prompt = InvitationPrompt(confirmation,mono() + 30000000000,replacing), error = null) }
        } catch(_: Exception) { mutableState.update { it.copy(prompt = null, error = "请刷新群状态或邀请后重新确认") } }
    }
    suspend fun confirm() {
        val prompt = state.value.prompt ?: return
        val secret = if(prompt.confirmation.intent.action is InvitationAction.Submit && prompt.replacing == null) previewSecret else null
        dismiss()
        perform {
            check(prompt.expiresNanos > mono())
            if(prompt.replacing != null) service.reconfirm(prompt.replacing,prompt.confirmation)
            else service.enqueue(prompt.confirmation,secret)
            service.flush()
        }
    }
    suspend fun retry(id: String) = perform { service.retry(id); service.flush() }
    suspend fun discard(id: String) = perform { service.discard(id) }
    suspend fun closeOriginal(id: String) = perform { service.closeOriginal(id); service.flush() }
    private suspend fun perform(action: suspend () -> Unit) {
        if(closed || state.value.busy) return
        val g = generation; mutableState.update { it.copy(busy = true, error = null) }
        try { action() }
        catch(e: CancellationException) { throw e }
        catch(_: Exception) { if(!closed && g == generation) mutableState.update { it.copy(error = "操作尚未确认，请查看记录后继续核对") } }
        finally { if(!closed) mutableState.update { it.copy(busy = false) } }
        if(!closed && g == generation) tick()
    }
}
