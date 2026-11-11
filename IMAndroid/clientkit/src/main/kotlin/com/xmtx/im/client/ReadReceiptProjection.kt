package com.xmtx.im.client

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

/** Hidden versions are retained so a delayed receipt cannot resurrect revoked disclosure. */
@Serializable data class DirectReadProjection(val room: RoomId,val reader: UserId,val sequence: Long,val recordedAt: Long,
    val visible: Boolean,val readerRevision: Long,val viewerRevision: Long) {
    init {
        require(uuidId(room.value) == room.value && uuidId(reader.value) == reader.value)
        require(sequence >= 0 && readerRevision >= 0 && viewerRevision >= 0 && (visible || sequence == 0L))
    }
    fun replacing(prior: DirectReadProjection?): DirectReadProjection {
        if(prior == null) return this
        require(room == prior.room && reader == prior.reader)
        val older = readerRevision < prior.readerRevision || viewerRevision < prior.viewerRevision
        val newer = readerRevision > prior.readerRevision || viewerRevision > prior.viewerRevision
        require(!(older && newer))
        if(older) return prior
        if(!newer) {
            require(visible == prior.visible)
            if(!visible || sequence < prior.sequence || sequence == prior.sequence && recordedAt <= prior.recordedAt) return prior
        }
        return this
    }
    companion object {
        fun decode(value: JsonObject) = DirectReadProjection(RoomId(value.string("room_id")),UserId(value.string("reader_user_id")),
            value.readNumber("read_through_room_sequence"),value.readNumber("recorded_at_ms"),
            value["is_visible"]?.jsonPrimitive?.takeUnless { it.isString }?.booleanOrNull ?: throw ClientFailure.Protocol(),
            value.readNumber("reader_preference_revision"),value.readNumber("viewer_preference_revision"))
    }
}
