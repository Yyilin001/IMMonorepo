package com.xmtx.im.client

import com.xmtx.imclientkit.generated.im.realtime.v2.*
import kotlinx.collections.immutable.PersistentList
import kotlinx.collections.immutable.toPersistentList
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import java.math.BigDecimal

/** A human-viewing declaration, independent of sync ACK and device delivery progress. */
@Serializable data class ReadCommand(val actor: UserId,val room: RoomId,val operation: String,val sequence: Long) {
    init { listOf(actor.value,room.value,operation).forEach { require(uuidId(it) == it) };require(sequence > 0) }
    val fingerprint get() = OperationFingerprint("readReceipt").apply {
        text("actor",actor.value);text("operation",operation);unsigned("readThroughRoomSequence",sequence);text("room",room.value)
    }.digest()
    fun identity() = roomIdentity(actor,room,operation,"readReceipt")
    fun payload() = buildJsonObject {
        put("actorUserID",wireId(actor.value));put("roomID",wireId(room.value));put("operationID",wireId(operation));put("readThroughRoomSequence",sequence)
    }
    fun recovery() = buildJsonObject { put("command",payload()) }
    companion object {
        fun decode(value: JsonObject) = ReadCommand(UserId(value.identifier("actorUserID")),RoomId(value.identifier("roomID")),uuidId(value.identifier("operationID")),value.readNumber("readThroughRoomSequence"))
    }
}
@Serializable data class ReadWatermark(val room: RoomId,val user: UserId,val sequence: Long,val recordedAt: Long) {
    init { listOf(room.value,user.value).forEach { require(uuidId(it) == it) };require(sequence > 0) }
    fun validate(command: ReadCommand) { require(room == command.room && user == command.actor && sequence >= command.sequence) }
}
sealed interface ReadResult {
    /** A watermark proof satisfies the intent without claiming the operation itself was executed. */
    data class Confirmed(val watermark: ReadWatermark,val original: Boolean): ReadResult
    data class Unavailable(val reason: String): ReadResult
    data object Unresolved: ReadResult
    data object Conflict: ReadResult
}
data class RoomReadCheckpoint(val room: RoomId,val applied: Long,val head: Long?)
data class ReadReadersPage(val room: RoomId,val message: MessageId,val readers: PersistentList<UserId>,val nextCursor: String?)
class ReadBackpressure(val delay: Long): Exception()
interface ReadReceiptTransport {
    suspend fun submit(command: ReadCommand): ReadResult.Confirmed
    suspend fun recover(command: ReadCommand): ReadResult
}
class ReadReceiptClient(private val realtime: EnvelopeTransport,private val api: AuthenticatedTransport,private val now: () -> Long = System::currentTimeMillis): ReadReceiptTransport {
    override suspend fun submit(command: ReadCommand): ReadResult.Confirmed = withTimeout(15000) {
        val response = realtime.request(Envelope.newBuilder().setRecordReadReceipt(RecordReadReceipt.newBuilder()
            .setRoomId(command.room.value).setOperationId(command.operation).setReadThroughRoomSequence(command.sequence)))
        if(!response.hasReadReceiptRecorded()) throw ClientFailure.Protocol()
        val value = response.readReceiptRecorded
        val watermark = ReadWatermark(RoomId(value.roomId),UserId(value.userId),value.readThroughRoomSequence,value.recordedAtMs)
        watermark.validate(command);ReadResult.Confirmed(watermark,true)
    }
    override suspend fun recover(command: ReadCommand): ReadResult = withTimeout(15000) {
        val body = command.recovery();require(body.toString().toByteArray().size <= 4096)
        val response = api.request("/v2/rooms/${command.room.value}/read-receipts/operations/recover",body)
        if(response.status in setOf(429,503)) throw ReadBackpressure(response.retryAfter?.let { retryAfterMilliseconds(it,now()) } ?: 0)
        if(response.status != 200) throw response.failure()
        if(response.body.toString().toByteArray().size > 65536) throw ClientFailure.Protocol()
        decode(command,response.body)
    }
    suspend fun readers(room: RoomId,message: MessageId,cursor: String? = null,limit: Int = 100): ReadReadersPage = withTimeout(15000) {
        uuidId(room.value);uuidId(message.value);require(limit in 1..100 && (cursor == null || cursor.isNotEmpty() && cursor.toByteArray().size <= 512))
        val response = realtime.request(Envelope.newBuilder().setListReadReceiptReaders(ListReadReceiptReaders.newBuilder()
            .setRoomId(room.value).setMessageId(message.value).setCursor(cursor.orEmpty()).setPageSize(limit)))
        if(!response.hasReadReceiptReadersPage()) throw ClientFailure.Protocol()
        val page = response.readReceiptReadersPage
        if(RoomId(page.roomId) != room || MessageId(page.messageId) != message || page.readersCount > limit || page.nextCursor.toByteArray().size > 512 ||
            page.nextCursor.isNotEmpty() && (page.nextCursor == cursor || page.readersCount == 0)) throw ClientFailure.Protocol()
        val readers = page.readersList.map { UserId(uuidId(it.userId)) }.toPersistentList()
        if(readers.toSet().size != readers.size) throw ClientFailure.Protocol()
        ReadReadersPage(room,message,readers,page.nextCursor.takeIf { it.isNotEmpty() })
    }
    companion object {
        fun decode(command: ReadCommand,value: JsonObject): ReadResult {
            require(value.size == 1)
            return when(val key = value.keys.single()) {
                "originalReceipt","watermarkProof" -> {
                    val proof = value.objectValue(key).objectValue("_0")
                    require(ReadCommand.decode(proof.objectValue("command")) == command)
                    validateRoomProof(command.actor,command.room,command.operation,"readReceipt",command.fingerprint,proof)
                    val fields = proof.objectValue(if(key == "originalReceipt") "receipt" else "watermark")
                    val watermark = ReadWatermark(RoomId(fields.identifier("roomID")),UserId(fields.identifier("userID")),fields.readNumber("readThroughRoomSequence"),readDate(fields.getValue("recordedAt")))
                    watermark.validate(command);ReadResult.Confirmed(watermark,key == "originalReceipt")
                }
                "currentUnavailable" -> {
                    val reason = value.objectValue(key).objectValue("_0");require(reason.size == 1)
                    val name = reason.keys.single();require(name in setOf("roomNotFound","permissionDenied","invalidWatermark") && reason.objectValue(name).isEmpty())
                    ReadResult.Unavailable(name)
                }
                "unresolved" -> { require(value.objectValue(key).isEmpty());ReadResult.Unresolved }
                "fingerprintConflict" -> { require(value.objectValue(key).isEmpty());ReadResult.Conflict }
                else -> throw ClientFailure.Protocol()
            }
        }
    }
}
internal fun JsonObject.readNumber(key: String): Long = get(key)?.jsonPrimitive?.takeUnless { it.isString }?.longOrNull ?: throw ClientFailure.Protocol()
private fun readDate(value: JsonElement): Long {
    val raw = value as? JsonPrimitive ?: throw ClientFailure.Protocol();if(raw.isString) throw ClientFailure.Protocol()
    val decimal = try { BigDecimal(raw.content).add(BigDecimal(978307200)).movePointRight(3) } catch(_: NumberFormatException) { throw ClientFailure.Protocol() }
    if(decimal.stripTrailingZeros().scale() <= 0) return try { decimal.longValueExact() } catch(_: ArithmeticException) { throw ClientFailure.Protocol() }
    val result = ((raw.doubleOrNull ?: throw ClientFailure.Protocol())+978307200.0)*1000
    if(!result.isFinite() || result < Long.MIN_VALUE.toDouble() || result >= Long.MAX_VALUE.toDouble()) throw ClientFailure.Protocol()
    return result.toLong()
}
