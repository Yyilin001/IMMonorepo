package com.xmtx.im.client

import java.util.UUID

/** Descriptive message context; selection never authorizes byte reads or a server-side import. */
data class AvatarResourceSelection(val descriptor: ResourceDescriptor,val source: MessageResourceSource) {
    init { require(eligible(descriptor) && descriptor.key.home==ResourceHome.Room(source.room)) }
    val key get()=descriptor.key
    val importSource get()=ResourceImportSource.Message(source.room,source.message,key.media)
    companion object {
        fun eligible(descriptor: ResourceDescriptor)=descriptor.state==ResourceState.Ready && descriptor.contentType in setOf("image/jpeg","image/png") && descriptor.byteCount<=50L*1024*1024
    }
}
interface AvatarResourceSelectionStore {
    suspend fun selectAvatarResource(key: ResourceKey): AvatarResourceSelection
    suspend fun isAvatarResourceCurrent(selection: AvatarResourceSelection): Boolean
    /** Source, descriptor, profile baseline and consumer admission must be checked in the same transaction. */
    suspend fun enqueueSelectedProfileAvatar(intent: ProfileIntent,selection: AvatarResourceSelection,now: Long): ProfileIntent
}
class AvatarResourceSelectionService(private val actor: UserId,private val store: AvatarResourceSelectionStore,private val now: ()->Long=System::currentTimeMillis) {
    suspend fun select(key: ResourceKey)=store.selectAvatarResource(key)
    suspend fun isCurrent(selection: AvatarResourceSelection)=store.isAvatarResourceCurrent(selection)
    suspend fun submit(baseline: ProfileView,selection: AvatarResourceSelection): ProfileIntent {
        require(baseline.user==actor && baseline.state==ProfileState.Active)
        val time=now()
        val source=ProfileAvatarImport(id(),ResourceImportRequest(id(),selection.importSource,ResourceUsage.UserAvatar,id()))
        val intent=ProfileIntent(id(),actor,id(),baseline.revision,Math.addExact(time,86400000),serverImport=source)
        return store.enqueueSelectedProfileAvatar(intent,selection,time)
    }
    private fun id()=UUID.randomUUID().toString().uppercase()
}

/** Atomic admission binds the exact selected message and the current group management fence. */
interface GroupAvatarResourceSelectionStore: AvatarResourceSelectionStore {
    suspend fun enqueueSelectedGroupAvatar(authority: GroupAvatarEditAuthority,command: GroupAvatarCommand,
        source: GroupAvatarImportPreparation,selection: AvatarResourceSelection,now: Long): GroupAvatarIntent
}
class GroupAvatarResourceSelectionService(private val actor: UserId,private val device: DeviceId,
    private val store: GroupAvatarResourceSelectionStore,private val now: ()->Long=System::currentTimeMillis) {
    suspend fun submit(authority: GroupAvatarEditAuthority,selection: AvatarResourceSelection): GroupAvatarIntent {
        val value=authority.presentation
        require(value.actor==actor && value.device==device && value.canManage && value.valid() && authority.fence.authorized)
        val source=GroupAvatarImportPreparation(newGroupAvatarId(),ResourceImportRequest(newGroupAvatarId(),selection.importSource,
            ResourceUsage.GroupAvatar(value.state.room),newGroupAvatarId()))
        val command=GroupAvatarCommand(newGroupAvatarId(),value.state.room,value.state.revision,GroupAvatarMutation.Set(source.request.targetMedia))
        return store.enqueueSelectedGroupAvatar(authority,command,source,selection,now())
    }
}
