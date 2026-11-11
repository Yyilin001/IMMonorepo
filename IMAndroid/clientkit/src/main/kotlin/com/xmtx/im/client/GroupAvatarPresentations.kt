package com.xmtx.im.client

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.*

/** Ephemeral authorization response. A live account/page scope must still grant every byte read. */
data class GroupAvatarPresentation(val actor: UserId,val device: DeviceId,val state: GroupAvatarState,
    val membershipRevision: Long,val resourceGeneration: Long?,val canManage: Boolean,val avatar: AvatarAccess?,
    val observedAt: Long,val validUntil: Long,val serverNow: Long,val deadlineNanos: Long,val downloadDeadlineNanos: Long?,val wireBytes: Int=64*1024) {
    init {
        uuidId(actor.value);require(membershipRevision>=0 && wireBytes in 1..64*1024)
        require(Math.subtractExact(validUntil,observedAt) in 1..300_000 && observedAt<=serverNow && serverNow<validUntil)
        if(state.media==null) require(avatar==null && resourceGeneration==null)
        else require(avatar?.content?.media==state.media && resourceGeneration!=null && resourceGeneration>0)
        require((avatar?.plan==null)==(downloadDeadlineNanos==null))
        avatar?.plan?.let {
            require(it.expiresAt>serverNow && it.expiresAt<=validUntil && Math.subtractExact(it.expiresAt,observedAt) in 1..120_000)
            require(deadlineNanos-requireNotNull(downloadDeadlineNanos)>=0)
        }
    }
    fun valid(nowNanos: Long=System.nanoTime())=deadlineNanos-nowNanos>0
    override fun toString()="GroupAvatarPresentation(room=${state.room}, revision=${state.revision}, authorization=<redacted>)"
}
fun interface GroupAvatarReading { suspend fun read(room: RoomId): GroupAvatarPresentation }

class GroupAvatarPresentationClient(private val api: AuthenticatedTransport,private val actor: UserId,private val device: DeviceId,
    private val nanoTime: ()->Long=System::nanoTime): GroupAvatarReading {
    init { uuidId(actor.value) }
    override suspend fun read(room: RoomId): GroupAvatarPresentation {
        uuidId(room.value);val started=nanoTime()
        val response=withTimeout(15_000) { api.requestWithResourcePlans("/v2/rooms/${room.value}/avatar",maximumBytes=64*1024) }
        currentCoroutineContext().ensureActive()
        if(response.status!=200) throw response.failure()
        return decode(response.body,actor,device,room,started,nanoTime())
    }
    companion object {
        internal fun decode(value: JsonObject,actor: UserId,device: DeviceId,room: RoomId,started: Long,received: Long): GroupAvatarPresentation {
            require(value.resourceId("actorUserID")==actor.value && value.resourceId("deviceID")==device.value && received-started>=0)
            val state=GroupAvatarState.decode(value.resourceObject("state"));require(state.room==room)
            val observed=value.resourceNumber("observedAtUnixMilliseconds");val until=value.resourceNumber("validUntilUnixMilliseconds");val now=value.resourceNumber("serverNowUnixMilliseconds")
            require(Math.subtractExact(until,observed) in 1..300_000 && observed<=now && now<until)
            val deadline=started+(until-now)*1_000_000
            var access=value.resourceOptionalObject("avatar")?.let(AvatarAccess::decode)
            var download=access?.plan?.let {
                require(it.expiresAt>now && it.expiresAt<=until && Math.subtractExact(it.expiresAt,observed) in 1..120_000)
                started+(it.expiresAt-now)*1_000_000
            }
            if(download!=null && download-received<=0) { access=access?.copy(plan=null);download=null }
            val result=GroupAvatarPresentation(actor,device,state,value.resourceNumber("membershipRevision"),value.resourceOptionalNumber("resourceGeneration"),
                (value["canManage"] as? JsonPrimitive)?.takeUnless { it.isString }?.booleanOrNull ?: throw ClientFailure.Protocol(),
                access,observed,until,now,deadline,download,value.toString().toByteArray().size)
            if(!result.valid(received)) throw AvatarAccessFailure()
            return result
        }
    }
}
