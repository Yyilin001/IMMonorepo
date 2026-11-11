package com.xmtx.im.client

import kotlinx.serialization.json.*

/** Personal sending availability; absence is unknown, not a denial or a relationship reason. */
data class DirectSendingCapability(val room:RoomId,val canSend:Boolean,val stateVersion:Long,val updatedAt:Long) {
    init {require(stateVersion>0 && updatedAt>=0)}
    companion object {
        fun decode(value:JsonObject):DirectSendingCapability {
            val room=value["room_id"] as? JsonPrimitive ?: throw ClientFailure.Protocol()
            val allowed=value["can_send"] as? JsonPrimitive ?: throw ClientFailure.Protocol()
            fun number(key:String):Long {
                val field=value[key] as? JsonPrimitive ?: throw ClientFailure.Protocol()
                if(field.isString) throw ClientFailure.Protocol()
                return field.longOrNull ?: throw ClientFailure.Protocol()
            }
            if(!room.isString || allowed.isString) throw ClientFailure.Protocol()
            return DirectSendingCapability(RoomId(canonicalId(room.content)),allowed.booleanOrNull ?: throw ClientFailure.Protocol(),number("state_version"),number("updated_at_ms"))
        }
    }
}
interface DirectSendingCapabilityStore {
    suspend fun directSendingCapability(room:RoomId,viewer:UserId):DirectSendingCapability?
}

/** Public account classification is independent of private send availability. */
data class ConversationSendingPolicy(val canSend:Boolean?=null,val accountKind:AccountKind?=null) {
    val allowsNewContent:Boolean get()=canSend!=false && accountKind!=AccountKind.System
    val restriction:String? get()=when {accountKind==AccountKind.System->"此系统账号仅用于发送通知";canSend==false->"当前无法向此会话发送消息";else->null}
}
