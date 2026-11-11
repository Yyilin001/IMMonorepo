package com.xmtx.im.client

import kotlinx.collections.immutable.PersistentList
import kotlinx.coroutines.flow.StateFlow

enum class ResourceDownloadControl { Run,Pause,Cancel }
enum class ResourceDownloadPhase { Pending,Running,Completed,Stopped }
enum class ResourceDownloadIssue { Interrupted,Network,Authorization,Integrity,Storage,Unavailable,Policy }
/** Durable user intent, never a download URL, file path or authorization lease. */
data class ResourceDownloadWork(val id:String,val descriptor:ResourceDescriptor,val message:MediaMessageLocation,val createdAt:Long,
    val phase:ResourceDownloadPhase=ResourceDownloadPhase.Pending,val control:ResourceDownloadControl=ResourceDownloadControl.Run,
    val requested:Boolean=true,val attempts:Int=0,val owner:String?=null,val claim:String?=null,val issue:ResourceDownloadIssue?=null,
    val retryAt:Long=0,val serverRetryAt:Long=0,val finishedAt:Long?=null,val automatic:Boolean=false,val backgroundPending:Boolean=false) {
    init {
        require(uuidId(id)==id && descriptor.key.home==ResourceHome.Room(message.room) && descriptor.state==ResourceState.Ready && descriptor.checksum!=null)
        require(descriptor.byteCount in 1..512L*1024*1024 && createdAt>=0 && attempts in 0..5 && retryAt>=0 && serverRetryAt>=0)
        require((owner==null)==(claim==null));owner?.let {require(uuidId(it)==it)};claim?.let {require(uuidId(it)==it)}
        require((phase==ResourceDownloadPhase.Running)==(owner!=null))
        require((finishedAt!=null)==terminal && (finishedAt==null || finishedAt>=createdAt))
        require(!terminal || !requested)
        require(!requested || control==ResourceDownloadControl.Run)
        require(phase!=ResourceDownloadPhase.Completed || control==ResourceDownloadControl.Run)
        require(phase!=ResourceDownloadPhase.Stopped || control==ResourceDownloadControl.Cancel)
        require(!backgroundPending || phase==ResourceDownloadPhase.Pending && owner==null && !terminal)
    }
    val terminal get()=phase==ResourceDownloadPhase.Completed || phase==ResourceDownloadPhase.Stopped
}
/** A revoked source hides its name and navigation in the transfer UI, without losing task controls. */
data class ResourceDownloadSnapshot(val work:ResourceDownloadWork,val sourceAvailable:Boolean)
data class ResourceDownloadClaim(val work:ResourceDownloadWork) {
    init {require(work.phase==ResourceDownloadPhase.Running && work.owner!=null && work.claim!=null)}
}
interface ResourceDownloadJournal {
    val resourceDownloadChanges:StateFlow<Long>
    /** Admit at most two eligible local sources; optionally requeue bounded automatic policy failures. */
    suspend fun prepareAutomaticDownloads(now:Long,networkAllowed:Boolean) {}
    suspend fun resourceDownloads():PersistentList<ResourceDownloadSnapshot>
    suspend fun enqueueResourceDownload(key:ResourceKey,source:MessageResourceSource,now:Long=System.currentTimeMillis()):ResourceDownloadWork
    suspend fun controlResourceDownload(id:String,control:ResourceDownloadControl,now:Long=System.currentTimeMillis())
    suspend fun recoverResourceDownloads(owner:String,now:Long)
    suspend fun claimResourceDownload(id:String,owner:String,now:Long):ResourceDownloadClaim?
    /** Only called from inside the verified, message-authorized file borrow. */
    suspend fun completeResourceDownload(claim:ResourceDownloadClaim,read:MessageResourceRead,now:Long)
    suspend fun releaseResourceDownload(claim:ResourceDownloadClaim,issue:ResourceDownloadIssue,retryAt:Long?,serverRetryAt:Long,interrupted:Boolean,now:Long)
}
