package com.xmtx.im.client

/** Version evidence only. Contains no display lease, public identity or byte-transfer capability. */
internal data class ProfileRevisionFloor(val profile: Long,val visibility: Long,val authority: ProfileAuthority,val observedAt: Long,
    val alias: ProfileAlias?,val groupName: ProfileGroupName?,val avatar: AvatarContent?) {
    fun merged(other: ProfileRevisionFloor)=ProfileRevisionFloor(maxOf(profile,other.profile),maxOf(visibility,other.visibility),authority.merged(other.authority),
        maxOf(observedAt,other.observedAt),if((alias?.revision ?: 0)>=(other.alias?.revision ?: 0)) alias else other.alias,
        if((groupName?.revision ?: 0)>=(other.groupName?.revision ?: 0)) groupName else other.groupName,
        when {avatar==null->other.avatar;other.avatar==null->avatar;avatar.sameVariant(other.avatar)->if(avatar.version>=other.avatar.version) avatar else other.avatar
            other.profile>=profile->other.avatar;else->avatar})
    companion object {
        fun from(value: ProfileReadResult.Available,previous: ProfileRevisionFloor?=null)=value.profile.let {p->
            ProfileRevisionFloor(p.view.revision,p.view.visibilityRevision,p.lease.authority,p.lease.observedAt,
                if(p.view.state==ProfileState.Active) p.alias else previous?.alias,
                if(p.view.state==ProfileState.Active) p.groupName else previous?.groupName,value.avatar?.content ?: previous?.avatar)
        }
    }
}
internal fun AuthorizedProfile.meetsRevisionFloor(floor: ProfileRevisionFloor?): Boolean {
    if(floor==null) return true
    if(view.revision<floor.profile || view.visibilityRevision<floor.visibility || !lease.authority.isAtLeast(floor.authority) || lease.observedAt<floor.observedAt) return false
    if(view.state!=ProfileState.Active) return true
    fun <T> matches(value: T?,revision: Long,old: T?,oldRevision: Long)=revision>oldRevision || revision==oldRevision && value==old
    return matches(alias,alias?.revision ?: 0,floor.alias,floor.alias?.revision ?: 0) &&
        matches(groupName,groupName?.revision ?: 0,floor.groupName,floor.groupName?.revision ?: 0)
}
internal fun ProfileReadResult.Available.meetsObservedFloor(floor: ProfileRevisionFloor?): Boolean {
    if(!profile.meetsRevisionFloor(floor)) return false
    val current=avatar?.content;val old=floor?.avatar
    return current==null || old==null || !current.sameVariant(old) || current.version>old.version || current==old
}
